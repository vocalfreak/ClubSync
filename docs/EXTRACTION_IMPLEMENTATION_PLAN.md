# ClubSync — Phase 3: Extraction Plan

*Last updated: September 24, 2026 — in-extraction CSRW guard (§6/§6.1) and prompt v3 wording (recap-wins, `qr_code_seen` precision) decided after the low/high extraction A/B review; rewritten after the extraction/dedup planning session — see §0.*

*Companion to the architecture master plan — implements Phase 3 (extraction). Read `MASTER_IMPLEMENTATION_PLAN.md` for the architecture and `REPO_STATE.md` for the audited current-state snapshot this is grounded on. `HEALTH_MONITORING_PLAN.md` owns run-level monitoring (a new Phase 3 section is specified there — §10 lists what this phase must emit). `DEDUPLICATION_IMPLEMENTATION_PLAN.md` is **on hold** — see §13.*

**Nothing in this doc is built yet.** No Gemini client, no `Extractor`, no `events` or `extractions` table. `GEMINI_API_KEY=` is only a placeholder in `env.example`. Items marked **OPEN** are collected in §14 with a proposed default.

## 0. What changed from the previous draft

| Topic | Was | Now | Why |
|---|---|---|---|
| Owner of the `events` table | Phase 2 (dedup) | **This phase**, with only the columns extraction writes | Extraction is the first writer of `events`. Dedup's own column (`event_group_id`) is added by the dedup plan later |
| Stage enum swap and `PostLoader` guard flip | Pass 0 of Phase 2/3 | **Moved to the dedup plan**, done when dedup actually lands | Until a dedup stage exists, `extracted` (integer 3) is the last stage and `PostLoader`'s current `extracted?` skip guard is correct. No enum change is needed for Phase 3 |
| Retrying a stalled post | Chain: `Extractor.call(post) if media_result.success?` | **Dispatch on `post.stage`** (§5.1) | Bug in the old wiring: a post at `media_processed` (extraction failed last cycle) makes `MediaProcessor` return `:skipped`, so `success?` is false and extraction never retried |
| Re-extraction of `extracted` posts | "Re-extracted idempotently next cycle" | **Never.** Extractor's guard is `media_processed?` only | The old text contradicted its own guard, and it would re-call Gemini for every finished post every cycle |
| `is_event` | LLM boolean with a threshold | **Derived from a closed category list** (§3); the category is stored | Easier for the model, easier to label, and the mapping can be changed later without re-calling Gemini |
| Audit trail | None (non-events left no trace) | **`extractions` table**, one row per Gemini call, failures included | Needed for the eval set, prompt versioning, replay, and debugging |
| Image source | Signed URLs or bytes, undecided | **B2 is the only image source**; `ObjectStore#get` returns bytes, sent inline | Nothing after `MediaProcessor` ever touches Apify's `displayUrl` |
| Error handling | Unspecified | **Two tiers + one per-post rescue + a run-level Gemini outage tracker** (§5.2–5.3) | One bug or one Gemini outage must not abort or hammer the whole run |
| Failure metrics | `stage_failure_counts` (a distribution of where posts ended up, including Video posts parked at `scraped` by design) | **Per-stage counters tallied from `Result`s** (owned by the health plan) | The old column was mislabeled |
| Event definition | Undefined | Written rule (§3) | Drives the prompt and the labels |
| Recurring/weekly events | Yes | **Out of v1** | None of the 41 accounts post them. If ever wanted, they would be admin-entered (deferred with manual submission) |
| Core fields | `title`, `starts_at`, `venue` | Adds `ends_at`, `registration_url`, `details` jsonb | Real posts use ranges and end times, sign-up links, and members-only notes |
| Dedup | Repost detection by dHash + caption embeddings | **Paused**; own session after real extraction data exists (§13) | The real duplicate pattern is same-event multi-post series, not reposts |
| Langfuse | Not considered | **Dropped from v1** (was "optional last pass") | `extractions` stays the permanent record; the eval set is a human process — no tracing UI or SDK dependency until debugging demands it |

## 1. Scope

Turn a `media_processed` post (caption + processed images in B2) into:

1. a stored **category** and a derived `posts.is_event` (`true`/`false`, set once),
2. an **`events` row** when the post is an event,
3. an **`extractions` row** for every Gemini call (success or failure),
4. `stage` advanced to `extracted`.

`extracted` is the last stage until dedup exists.

**Non-goals for v1:** dedup or linking of posts (§13), recurring events, admin-entered events, cross-account matching, the public site, translation, decoding QR codes.

## 2. Ownership: this phase vs. the dedup plan

**This plan owns:** the `events` and `extractions` tables and models; the stage-based dispatch refactor in `AccountPipeline`; `ObjectStore#get`; `GeminiClient`; the prompt, response schema, parser and threshold; `Extractor`; the run-level Gemini outage tracker; the per-post rescue; the monitoring hooks (§10); the eval set.

**The dedup plan owns (later):** the stage enum swap and `PostLoader` guard flip; `DHash` and `images.dhash` population; the `event_groups` table (one row per real-world event) and `deduplications` table (pair scores, audit log only); adding `events.event_group_id` as a nullable FK; the `Deduplicator`; its pipeline wiring. A post with no matches becomes a group of one; changing a dedup threshold means clearing `event_group_id`, deleting groups, and recomputing, with no post state to migrate.

## 3. What counts as an event (v1 rule)

**A post is an event if it tells people about something happening at a specific time and/or place that they can attend or join.** The topic doesn't matter: a fundraising booth, a volunteer night, a workout, or a talk all count. Members-only and online-only events count. "Date TBA" counts when a venue (or other attendable detail) is given. An announcement of an upcoming event counts; **a follow-up that just restates or counts down to an already-announced event does not** — the announcement post is the event, the follow-up is `reminder`.

**Not events:** committee/club recruitment, recaps, merch, deadlines, teasers ("something big is coming" with no time and no place), and reminder/countdown follow-ups ("N days left", "see you there", date reshares) pointing at an already-announced event.

### Category list (v1 — frozen 2026-09-21; the practice run may re-word definitions, the list itself is stable)

| `category` | Meaning | `is_event` |
|---|---|---|
| `event` | Attendable or joinable at a specific time and/or place | **true** |
| `club_and_society_registration_week` | CSRW — Club & Society Registration Week, the annual university-wide recruitment week (booth invites, "during CSRW" promos, sign-ups, post-week thank-yous/recaps); named descriptively so the model anchors on the week's semantics | **false** — technically attendable but never surfaced as an event card; posts stay queryable by category for the site's CSRW filter |
| `reminder` | A follow-up that restates or counts down to an already-announced event ("N days left", "see you there", date reshare) | false |
| `fundraising` | Asks for donations with no attendable time or place | false — by construction, not tweakable: the precedence rule below reclassifies any attendable solicitation as `event` |
| `recruitment` | Recruits for the club or committee itself, with no dated activity | false |
| `recap` | Photos or thanks about something already held | false |
| `merch_or_sales` | Selling items | false |
| `deadline` | A deadline for something else (applications, registration closing) with no event details of its own | false |
| `teaser` | Hype with no time and no place | false |
| `general_announcement` | Other club news (notices, greetings, rules) | false |
| `other` | Doesn't fit | false |

**Precedence rule (fixes the sign-up confusion).** If a post gives a specific time and/or place people can attend or join, the category is `event` **regardless of topic** — even when it also asks for sign-ups or donations. Topic categories (`fundraising`, `recruitment`, …) apply only when there is no attendable time or place.

**CSRW outranks event (2026-09-24).** Registration-week context is always `club_and_society_registration_week`, never `event` — even when it names a booth/time/place. The value names the week descriptively (Club & Society Registration Week; some clubs write "recruitment week"); it covers the week's own invites, a club's "during CSRW" booth or lucky-draw promo, sign-ups for it, and the post-CSRW thank-you/recap. A post only about some other standalone event that happens to land in that week (e.g. a theatre fundraiser unrelated to registration) stays `event`.

**Recap wins (decided 2026-09-24, v3 wording, pending build).** A post primarily recounting a finished event (thank-you, after-action, photos) is `recap` — or `club_and_society_registration_week` when the recap is the week's own — **never `event`, even when it also re-points at already-announced upcoming events**. An announcement carrying *new* attendable information stays `event`. This closes the `DdI3NLXHeYN` review case (a CSRW/Initiation recap text that also lists D.I.C.E. League and a board-games hangout got classified `event` at 0.9 confidence on both thinking levels); the extraction prompt gains a precedence line + CHEAT SHEET row (v3).

**Sign-ups are an attribute of an event, never a category and never the event's date.** They land in `registration_url` (caption text only), `details.registration_via` (`"link"` or `"qr"`), and `details.members_only`. A sign-up or booth window mentioned inside another event's post is *not* that event's date.

**QR codes** on a poster are a hint that the post is a sign-up-bearing event poster. The model does not guess where a QR points. `qr_code_seen` is `true` only when a clearly visible QR code is actually printed in an image — never inferred from context or "scan for more" wording (decided 2026-09-24, v3 wording, after the `Dc0xZzTzRDJ` A/B false positive).

The mapping lives in one code constant (`Categories`); changing it later means re-deriving `is_event` from stored data, not re-calling Gemini (§6).

### Real examples (September 21, 2026 sample; practice data only — not part of the exam set)

| Post | Category | Notes |
|---|---|---|
| Paw Fest (mmusuperheroes) | `event` | 2 May 2026, 07:30–14:00, Rumah Amanah, Hulu Langat. Posted as a profile-grid series: same caption, different graphics, same day |
| Misi Bekal — donation details | `fundraising` | Bank details, no time or place → non-event by default |
| Misi Bekal — booth | `event` | 20–22 Jan 2026, 10:00–17:00 daily, in front of CNMX/CLC |
| Misi Bekal — volunteers needed | `event` | 13 Feb 2026, 20:15 → 02:00 next day, Klang Valley. Also mentions the 20–22 Jan sign-up booth, which is **not** the event date |
| Spartan workout (mmuwatersports) | `event` | Carousel of 3: details, QR and trainer are in the images; caption has a form link |

## 4. Data model

### 4.1 `events` (created by this phase)

```ruby
create_table :events do |t|
  t.references :post, null: false, foreign_key: true, index: { unique: true }  # one row per post
  t.string   :title
  t.date     :starts_on                                        # nullable
  t.time     :starts_time                                      # null = no time given
  t.date     :ends_on                                           # nullable
  t.time     :ends_time                                         # null = no time given
  t.string   :venue
  t.string   :registration_url   # from caption text only
  t.jsonb    :details, null: false, default: {}                # members_only, online_only, registration_via, notes
  t.float    :title_confidence,     null: false, default: 0.0
  t.float    :starts_at_confidence, null: false, default: 0.0
  t.float    :venue_confidence,     null: false, default: 0.0
  t.timestamps

  t.check_constraint "ends_on IS NULL OR starts_on IS NOT NULL"
  t.check_constraint "ends_on IS NULL OR starts_on IS NULL OR ends_on >= starts_on"
end
add_index :events, :starts_on
```

Local Malaysia wall-clock time throughout, split into a date and a time column — no UTC conversion, no ambiguous single-string format. `starts_time`/`ends_time` are `null` when no time was given (this replaces the earlier `starts_at_has_time` boolean). Sorting becomes `ORDER BY starts_on, starts_time`, which is fine while everything is one timezone (Q4: `Asia/Kuala_Lumpur` for all accounts).

`per_field_confidence` is now three plain float columns instead of jsonb — the set of keys (`title`, `starts_at`, `venue`) never varies, so a fixed jsonb shape bought nothing and the threshold queries lose the `->>` cast (§8).

No `event_group_id` — the dedup plan adds that nullable FK to `event_groups` later. `post_id` stays `NOT NULL`; admin-entered events (deferred) would relax it later.

Note the `references ... index: { unique: true }` form: an earlier dedup draft also called `add_index` and would have collided with the index `references` already creates.

### 4.2 `extractions` (audit log; one row per Gemini call)

```ruby
create_table :extractions do |t|
  t.references :post, null: false, foreign_key: true   # NOT unique
  t.string   :status, null: false                      # "succeeded" | "failed"
  t.string   :error_kind                               # "whole_service" | "this_post" (failed only)
  t.text     :error
  t.string   :model
  t.string   :prompt_version
  t.string   :category
  t.float    :category_confidence
  t.jsonb    :raw_response                             # full parsed JSON from Gemini
  t.integer  :input_tokens
  t.integer  :output_tokens
  t.integer  :duration_ms
  t.integer  :image_count
  t.timestamps
end
```

Same role as `ingestion_runs` and (later) `deduplications`: monitoring, auditing and evaluation. **Nothing in the pipeline decides anything from it.** The one operational use is replay (a future rake task): change the category mapping, then rebuild `is_event` and `events` rows from `raw_response` without paying for new Gemini calls.

### 4.3 `posts` — one new column

`stage` (progress) and `last_error` / `stage_failed_at` (debug) stay exactly as they are, and `is_event` (business result, `nil` until extracted) is unchanged. Progress and outcome stay separate; failure is **not** added as a `stage` value (dedup's "later than extracted" logic relies on the integer order, and the state-vs-outcome split was a deliberate decision in the stage remodel).

New: `posts.category` (nullable string), set alongside `is_event`. Category currently lives only in `extractions`, which can hold several succeeded rows per post once re-extraction exists — a column on `posts` avoids digging through the audit log for the current category.

### 4.4 `ingestion_runs` additions (specified in the health plan)

`stage_results` jsonb (e.g. `{"media_processed": {"succeeded": 8, "failed": 1}, "extracted": {"succeeded": 9}}`) and `unexpected_errors` integer, tallied in memory from each stage's `Result` and **summed by `IngestionRunner` across `AccountPipeline` results**. They replace `stage_failure_counts`, which is dropped. Only `succeeded`/`failed` are counted: services are invoked per §5.1 only when a post is at exactly their stage, so a post already past a stage is not tallied there (`:skipped` results are ignored rather than counted), and Video posts parked at `scraped` are never counted. `AccountPipeline::Result` gains two fields — `stage_results` (per-stage outcome hash) and `unexpected_errors` — fed by `process_post`'s per-stage calls and its one `rescue`.

## 5. Pipeline integration

### 5.0 Pipeline flow (reference)

The end-to-end flow, written for reference. Each step is specified in detail in its owning doc: steps 1–5 in `DATA_INGESTION_IMPLEMENTATION_PLAN.md` and `POST_LODAER_IMPLEMENTATION_PLAN.md`, step 6 here (§6–§8), step 7 in §13 / the dedup plan, step 8 in §8.

1. **Cron triggers Apify's Instagram scrape every 48 hours** (`clubsync:ingest`), staggered across the 41 accounts.
2. **Apify returns raw JSON** — one object per post, see the sample payload (`ExampleJsonResult`) for the field shape.
3. **Adapter (service) parses the raw JSON fields and creates a `Result` object**, not yet loaded to the DB, that contains:
   - `Result` (`valid?` / `errors` / `fatal?`)
   - `attributes`
   - `raw_payload`
   - Errors (if invalid; `fatal` only for missing/blank shortcode)
4. **Loader (service) takes the adapter's `Result` and inserts/updates the `post` row by shortcode**:
   - shortcode not found → create row, `stage: scraped`
   - shortcode found, `stage == extracted` → skip entirely, do not touch the row
   - shortcode found, `stage != extracted` → refresh `raw_payload`, continue
   - Adapter fatal result (no shortcode) → no `post` row
   - `Result` reports `created` / `refreshed` / `skipped` / `no_row`
   - Loader does not advance `stage` and never touches `is_event` / `last_error` / `stage_failed_at`
5. **Media processing** — runs right after the Loader persists the `post` row, in the same ingestion pass:
   - only for posts whose `post_type` is Image or Sidecar and `stage` is `scraped`
   - fetch each image's `displayUrl` (or `childPosts[i].displayUrl` for carousels)
   - resize to 1080px max width; compress to WebP; upload to B2 with `content_type: "image/webp"`
   - create new `images` rows (one transaction per post)
   - on success, `stage` advances to `media_processed`; on failure, `stage` stays put with `last_error`/`stage_failed_at` set (`raw_payload` still refreshed)
   - no per-image status column
6. **Extraction (LLM)** — calls once per post; the input is:
   - the caption,
   - all images retrieved from B2,
   - and it returns structured fields + per-field confidence, and classifies event vs non-event, setting `is_event` (nil until `stage == extracted`).
   - on success, `stage` advances to `extracted`.
   
   The prompt asks for the following features in JSON format (schema §7.1): `checks` (emitted first), `category` (enum below), `category_confidence` (0–1), `title`, `starts_date`, `starts_time`, `ends_date`, `ends_time`, `venue`, `registration_url`, `registration_via`, `members_only`, `online_only`, `confidence` (per-field 0–1), `notes`.
   
   Categories (closed list, §3): `event`, `club_and_society_registration_week`, `reminder`, `fundraising`, `recruitment`, `recap`, `merch_or_sales`, `deadline`, `teaser`, `general_announcement`, `other` — the registration-week category landed 2026-09-24 (the previously-pending "csrw" category, stored under the descriptive value `club_and_society_registration_week`; see §3 table, `Categories`, and the `CsrwRetagger` guard in §6/§6.1 for csrw-force-correcting new posts, plus the one-off re-tagger for pre-category stored posts).
7. **Dedup (run-level end-of-run pass)** — compares each account's event posts and links same-event ones into a shared group; owned by the dedup plan (`docs/DEDUPLICATION_IMPLEMENTATION_PLAN.md`):
   - candidate pairs: same account, both `is_event`, posted 0–21 days apart (admits the same-day profile-grid series *and* the spaced announcement→reminder pattern), and — when both event dates are known — not implausibly far apart (max 30 days); cross-account pairs are never candidates
   - signals: caption Jaccard, image dHash Hamming similarity (min over every image pair), and date proximity (14-day half-life); a missing channel simply drops out — no credit, no veto
   - caption embeddings use the LLM as a tiebreaker only: when the cheap score lands in the ambiguity band (0.55–0.72), encode both captions lazily, replace the caption channel with the cosine, re-blend
   - corroborated veto (2026-09-24): a pair only vetoes on sub-floor caption when the art *also* disagrees (caption Jaccard `< 0.30` AND min Hamming `> 16`, `DHASH_STRONG_MATCH_THRESHOLD`); the `date` channel vetoes alone — this is what keeps same-day different-event pairs apart
   - near-simultaneous series (built 2026-09-24, window restored to 30 on 2026-09-25): a same-account pair published ≤30 min apart and not date-conflicting (both `starts_on` known *and* different) **merges outright, bypassing scoring and vetoes**, and logs `series: true` with unscored `NULL` signals — this is what catches same-day promo bursts of distinct-art or sub-floor-caption posts (the MIMOS trio); the date guard keeps a genuinely different event announced in the same hour separate (§4.1 of the dedup plan)
   - merge/separate: score ≥ 0.72 → merge, below → separate; every pair is acted on automatically and logged to `deduplications` (one row per pair, audit only)
   - complete-link clustering: a group only forms when every member pair merged — loose pairs downgrade to separate (a same-day series can still form a real size-3+ group)
   - if positive: the pair's posts coalesce into one `events` group and the emptied shells retire; separate and unpaired posts each get a group-of-one — so every `events` row always carries an `event_group_id`
   - on success, `stage` advances to `deduped` (terminal stage — skipped entirely on later runs); on failure, the pair's posts stay `extracted` with `last_error`/`stage_failed_at` set and are re-evaluated next run; the whole pass is hermetic — a dedup failure is never a run failure
8. **Decision thresholds** — rule-based checks (valid calendar date, non-empty/reasonable venue) independent of the LLM's confidence (§8):
   - fields below the threshold get flagged/labelled for review; fields above do not
   - where the per-field review flag lives is resolved in §8 — three float confidence columns on the `events` row; "needs review" is a query, not a status. What counts as "below" is the Pass 5 review bar.

### 5.1 Dispatch on `post.stage`

`AccountPipeline`'s per-post loop stops chaining on the previous step's result and instead lets each stage self-guard on the post's current stage:

```ruby
posts.each do |raw|
  posts_scraped += 1
  adapter_result = Adapters::Apify::PostAdapter.new.parse_post(raw)
  loader_result  = PostLoader.call(adapter_result, ingestion_run_id: ingestion_run_id)
  next if loader_result.no_row? || loader_result.skipped?

  process_post(loader_result.post, raw)
end

def process_post(post, raw)
  MediaProcessor.call(post, raw_payload: raw) if post.scraped? && supported_type?(post)
  Extractor.call(post) if post.media_processed? && !outage.active?
rescue StandardError => e
  record_unexpected(post, e)
end
```

`PostLoader` is unchanged. A finished post (`extracted`) is skipped by `PostLoader`; a stalled post resumes from its current stage on the next scrape, which is what the master plan always claimed. Dispatch lands **before** Gemini exists (Pass 0) with a regression test for the stalled-`media_processed` case.

### 5.2 Two-tier error rule

| Kind | Examples | Handling |
|---|---|---|
| **Expected** | Gemini timeout / 429 / 5xx / auth failure, blocked response, malformed JSON, image read from B2 failed | The stage service **returns** `Result(status: :failed, error_kind:)`, writes `last_error`/`stage_failed_at`, and writes a failed `extractions` row. Never raises |
| **Unexpected (a bug)** | `NoMethodError`, bad migration state, … | The service raises. The **one** per-post `rescue` in `process_post` records `last_error` ("Unexpected ClassName: message"), logs the backtrace, increments `unexpected_errors`, and continues. The run is never aborted by one post, and the Discord summary calls unexpected errors out |

`MediaProcessor`'s existing broad `rescue StandardError` is left alone for now. `IngestionRunner`'s outer `rescue`/`ensure` remains the backstop for things outside a post (DB down, `Account.all` failing).

### 5.3 Run-level Gemini outage tracker (in memory, one run)

`IngestionRunner` creates one `GeminiOutage` and passes it into every `AccountPipeline.call`. It counts **consecutive whole-service failures** (`error_kind: "whole_service"`: bad key, quota/429, timeout, 5xx). At **5** in a row it becomes active: the rest of the run skips `Extractor`, scraping and media continue, and affected posts wait at `media_processed` for the next cron pass. Any other outcome resets the count — a success, or a this-post failure (Gemini answered, so the service is up). It is not persisted; it resets every run. It is the run-scoped cousin of Phase 4's per-source circuit breaker, which needs DB memory across runs.

**Surfacing the outage on `#clubsync-alerts`** (Q10 resolved): when the outage becomes active, `DiscordNotifier` also posts an outage line to `#clubsync-alerts` (a new hermetic method — same rescue-and-swallow contract as `post_run_summary`). Rationale: a persistent Gemini outage otherwise looks like a healthy run — the run finishes, `stage_results` shows posts stuck at `media_processed`, and only `#clubsync-log` (skim-only) carries the fact. Exact message shape is the health plan's concern; the decision is made.

## 6. `Extractor` — the stage service

Follows `MediaProcessor`'s pattern: `Extractor.call(post, **kwargs)`, injectable collaborators (`client:`, `object_store:`), and a `Result(status, error, error_kind)` with `success?` / `skipped?` / `failed?`.

1. **Guard:** `:skipped` unless `post.media_processed?`. No images on the post → failed (this-post).
2. **Read images** ordered by `position` via `ObjectStore#get(b2_key)` (bytes). Nothing else is ever an image source.
3. **Call Gemini** once with caption, `posted_at`, timezone and all images, **outside any DB transaction**.
4. **Parse** (`ExtractionParser`, pure) and **threshold** (`ConfidenceThreshold`, pure). Invalid response → failed (this-post). A structurally valid but semantically impossible date (e.g. `2026-02-30`) or JSON truncated at the token limit both count as `InvalidResponseError` — the response schema guarantees shape, not truth.
5. **Derive** `is_event` from the category via `Categories`.
6. **CSRW guard (decided 2026-09-24, pending build):** if `CsrwRetagger` matches the caption's lexical markers (see §6.1), override the parsed attributes to `category: club_and_society_registration_week, is_event: false` *before* the event-row step. Because it runs before `create_event`, a csrw post never gets an `events` row and **nothing is ever deleted in the live path** — the guard is the "verifier" once hoped for as a run-end stage, just placed where it makes deletion unnecessary. `extractions.raw_response` still records what Gemini actually said; `extractions.category` records the stored (guarded) value.
7. **Success — one short transaction:** create the succeeded `extractions` row; create the `events` row if `is_event` (step 6 already made that false for guard-matched posts); update the post (`category`, `is_event`, `stage: :extracted`, clear `last_error`/`stage_failed_at`).
8. **Failure:** write a failed `extractions` row and set `last_error`/`stage_failed_at` on the post; `stage` stays `media_processed`.

### 6.1 The CSRW guard markers (decided 2026-09-24, pending build)

Promotes `CsrwRetagger` from a one-off re-tagger to a per-extraction backstop, with a tightened marker set:

| Marker | Kept? | Rationale |
|---|---|---|
| `\bCSRW\b` | kept | The literal acronym — the `DdI3NLXHeYN` case (recap caption containing "CSRW") and most CSRW posts. Deliberately aggressive: marker match wins even for a passing "after CSRW" mention — recall over precision, consistent with the §3 recap-wins policy, pinned by a test |
| `club.{0,40}society.{0,40}(?:registration\|recruitment).{0,10}week` | kept | The descriptive form clubs actually write |
| `(?:registration\|recruitment).{0,10}week` (bare) | **dropped** | Too loose — a standalone event whose caption merely says "registration week" is not a CSRW post; this is the incident-mention protection |

The one-off `clubsync:retag_csrw` rake keeps its full-scan + event-row destroy semantics purely for repairing historical rows (the dev DB was already repaired that way); the live path never deletes because the guard prevents the row from existing.

**Idempotency:** the guard makes extraction run exactly once per post in normal flow, and the unique `events.post_id` index is the safety net. A failed extraction writes no `events` row, so a retry is a plain `create!` — no upsert. Deliberate re-extraction (new prompt version) is a future rake task that resets `stage`; not in v1.

**Fields are extracted for every post** (nullable), not only events; only the category mapping decides whether an `events` row exists. That is what makes the replay above possible. (Q8 resolved: every post — the single required-but-nullable schema makes "events-only" a separate schema, not a toggle.)

## 7. Gemini call and prompt spec

- **Model:** a Gemini vision-capable model via Google AI Studio, ID in `GEMINI_MODEL`. **Working default (2026-09-23): `gemini-3.1-flash-lite`, single model, no fallback** — settled by arithmetic (full Flash ≈ 20 requests/day free-tier vs Flash-Lite ≈ 500/day, per the September 2026 quota drill-down) plus the live run's evidence of 3.5/3.8-flash 503 spikes while lite stayed healthy; the default is `GEMINI_MODEL=gemini-3.1-flash-lite` in `.env` (single source) with `GEMINI_FALLBACK_MODELS` deliberately absent, so the extractor's transient-failure retries stay within the one model. One model, no tiering, low temperature.
- **One call per post:** caption + `posted_at` + timezone + **all** of the post's images (carousels up to 10) in `position` order, as inline bytes. The model must see the whole post at once because details may live only in the images.
- **Structured output:** Gemini's structured output (JSON MIME type plus a response schema) guarantees *shape*, not *values* — the output is valid JSON, `category` is always one of the enum values, and every key is present. Every field is required-but-nullable so keys are never absent; the schema stays flat, and property order is set explicitly (`propertyOrdering`) since the `checks`-first design (§7.1) depends on it. `ExtractionParser` still validates on top, because the schema can't guarantee truth — see §6, step 4.
- **Reproducibility, not determinism:** values still vary between calls. Temperature 0, a pinned model ID (not a moving alias), a `seed`, and a fixed `prompt_version` all reduce variation but don't eliminate it. The plan leans on reproducibility instead: extract once, store `raw_response`, and make everything after it (parser, gate, `Categories`, dedup) deterministic code. To measure the remaining wobble, run the eval set twice on the same `prompt_version`; any field that flips between runs gets tightened in the prompt or accepted as low-confidence (§11).

### 7.1 Response schema (LLM → parser)

| Field | Type | Notes |
|---|---|---|
| `checks` | object | Booleans `has_date`, `has_time`, `has_venue`, `asks_signup`, `asks_donation`, `qr_code_seen`. Stored in `raw_response` only. Emitted first |
| `category` | enum | The closed list in §3; anything else → failed (this-post) |
| `category_confidence` | 0–1 | |
| `title` | string \| null | As written, not translated |
| `starts_date` | string \| null | Always `YYYY-MM-DD`. Fixed single format — no longer a field that's sometimes a date and sometimes a datetime |
| `starts_time` | string \| null | Always `HH:MM`, local wall-clock; `null` when no time is given |
| `ends_date` | string \| null | Same format as `starts_date` |
| `ends_time` | string \| null | Same format as `starts_time` |
| `venue` | string \| null | As written |
| `registration_url` | string \| null | Caption text only |
| `registration_via` | `"link"` \| `"qr"` \| null | → `details` |
| `members_only`, `online_only` | boolean \| null | → `details` |
| `confidence` | object | `title`, `starts_at`, `venue`, each 0–1 |
| `notes` | string \| null | e.g. "post lists 3 events"; → `details.notes` |

The timezone is `Asia/Kuala_Lumpur` (Q4 resolved). `starts_date`/`starts_time`/`ends_date`/`ends_time` are local wall-clock strings stored directly into `events.starts_on` / `starts_time` / `ends_on` / `ends_time` — no UTC conversion anywhere in the pipeline.

### 7.2 Prompt rules (spec; the literal prompt text is written in Pass 2 from the practice run)

1. **Event test and precedence** exactly as in §3, with the sign-up rules. **Recap wins (v3, decided 2026-09-24):** a recap stays `recap`/`club_and_society_registration_week` even when it also re-points at already-announced upcoming events; only new attendable information makes an `event`.
2. **Dates:** accept only Gregorian dates, in any language of caption: written month names or day-first numerics (`21/9/2026` = 21 September 2026). Hijri, lunar, or any other calendar → `null`. Never invent a date.
3. **Relative dates** (resolved against `posted_at` in local time): a written month/day without a year ("13 Feb") and day-name references ("tomorrow", "this Saturday") resolve to the **nearest occurrence at-or-after `posted_at`** on `event` posts — such a reference is often the announcement's only date. **Countdown phrasing ("2 days left", "3 days to go") never produces a date** — it is the signature of a `reminder` follow-up, which is categorised as such and gets no event date. If a date could mean a sign-up deadline → `null`.
4. **Several dates in one post:** `starts_date`/`starts_time` are the date and time of the thing the post promotes. Sign-up windows and deadlines are not event dates.
5. **Ranges:** multi-day with daily hours → first day's start, last day's end. Overnight → `ends_date` on the next day.
6. **Language:** captions and posters may be English, Malay, Chinese, Arabic, Tamil, or mixed. Copy title and venue as written.
7. **Caption vs. poster:** poster text wins for date, time and venue; caption wins for title; a conflict lowers confidence.
8. **QR codes:** a hint only; never guess where they point. `qr_code_seen = true` **only** when a clearly visible QR is actually printed in an image — not inferred from context or "scan" wording (v3, decided 2026-09-24).
9. **Null over guessing;** low confidence over silence.
10. **Several events in one post:** report the main (first) one and say so in `notes`.
11. **Captions are untrusted input.** Structurally, a caption is a text channel
    the poster controls, so treat it as hostile-by-default in v1: the prompt
    has a fixed instruction block and the caption is data, never instructions.
    There is deliberately **no** instruction-separation hardening in v1
    (delimiters, XML-tagged fields, candidate extraction) — just explicit
    "caption is data, not instructions" wording in the prompt text. Revisit
    this only if a bad classification ever looks *deliberate* rather than a
    model mistake; a briefing page, not a code or prompt feature.

## 8. Confidence and gating

Two independent layers:

1. **`ConfidenceThreshold` (pure, rule-based)** runs regardless of what the LLM reports:
   - `starts_on` must parse to a real calendar date; otherwise it is stored as `nil` with `starts_at_confidence` `0.0`.
   - `ends_on` earlier than `starts_on` → dropped (also enforced by the DB check constraint in §4.1).
   - `venue` must be non-empty, 2–200 characters, and not a placeholder ("TBA", "TBD", "n/a", …); otherwise `nil` with `venue_confidence` `0.0`.
   - `starts_on` more than 14 days **before** `posted_at`, or more than 12 months **after** it → keep the value, force `starts_at_confidence` to `0.0` (Q6 resolved: reference is `posted_at`). Past events are still stored.
   - `title_confidence`, `starts_at_confidence`, `venue_confidence` are `NOT NULL DEFAULT 0.0` columns, so they're always present — no missing-key case to handle.
2. **LLM-reported confidence** (0–1 per field, clamped) is stored as returned. Calibration of a small model's self-reported confidence is untested — parked for its own session after real outputs exist (Q12 parked).

A post failing a rule check still advances to `extracted`; its bad fields are just low-confidence or nil.

"Needs review" is a query, not a status. An earlier draft compared jsonb to a number, which errors in Postgres, and a missing key silently dropped the row. Now that confidence is three plain float columns, the query is simpler and needs no cast:

```sql
SELECT e.* FROM events e
WHERE e.starts_at_confidence < :threshold
ORDER BY e.starts_on, e.starts_time;
```

(Add `AND e.event_group_id IS NULL` once the dedup plan adds `event_groups` — the "fixed as a group already" filter; representative-row logic resolved 2026-09-23 as canonical = longest-caption member, `docs/DEDUPLICATION_IMPLEMENTATION_PLAN.md` §7.)

## 9. Services and models

| Piece | Responsibility |
|---|---|
| `ObjectStore#get(b2_key)` | New. Returns bytes from B2 (assumes the wrapper holds an `Aws::S3::Client`; confirm against the code) |
| `GeminiClient` | REST transport over `Net::HTTP` (2026-09-21 decision: the rubygems `google-genai` gem turned out to be an unofficial 0.1.1 single-author port with no request timeouts and error classes that clash with this taxonomy — used the plan's stated fallback). One `extract(contents:, system_instruction:, generation_config:)` call → a `Response` (parsed JSON text, token usage, duration, model). The JSON payload (caption text, inline images, response schema) is built by **`GeminiPayload`** (Pass 2) and fed in — the client is transport only. Exception taxonomy mirroring `ApifyClient`: `TimeoutError`, `RateLimitedError`, `AuthError`, `ServerError` (all **whole-service**); `BlockedError`, `InvalidResponseError` (**this-post**). Hermetic and injectable (`http:`, mirroring `ApifyClient`) |
| `ExtractionPrompt` | Prompt text + JSON response schema + `VERSION` (bumped by hand; stored in `extractions.prompt_version`). v2 = CSRW landed under the descriptive value (2026-09-24); **v3 (decided 2026-09-24, pending build)** adds the recap-wins precedence line + CHEAT SHEET row and the precise `qr_code_seen` wording (§3, §7.2) |
| `Categories` | The closed category list and its `event?` mapping (one constant) |
| `ExtractionParser` | **Pure**, mirrors `PostAdapter`: Gemini's JSON → canonical attributes + `Result` (`valid?` / `errors`). Never touches the DB |
| `ConfidenceThreshold` | **Pure** rule checks (§8) |
| `Extractor` | The stage service (§6): guard, orchestration, DB writes, `Result` |
| `GeminiOutage` | In-memory consecutive-failure tracker (§5.3) |
| `Event`, `Extraction` | ActiveRecord models |
| `LlmTrace` *(optional, Pass 6)* | Langfuse wrapper; env-flagged; rescues and swallows its own errors like `DiscordNotifier`/`HealthPing` |
| Rake tasks | `clubsync:extract_one[shortcode]` (manual run on one post); `clubsync:extraction_eval` (live scoring against the eval set, outside CI) |

Config: `GEMINI_API_KEY` (exists), `GEMINI_MODEL` (new), optional `LANGFUSE_*`.

## 10. Monitoring hooks (owned by `HEALTH_MONITORING_PLAN.md`, new section)

This phase must emit, and the health plan presents:

- Per-stage counters (`stage_results`) and `unexpected_errors` (§4.4).
- Gemini failures by kind, outage-active flag, number of extractions skipped because it was active, tokens used.
- Run duration broken down by fetch / media / extraction.

The health plan's new section covers: recomputing the healthchecks.io **grace time** (it is a maximum run time, not just a missed-run buffer — healthchecks.io marks a check down when a `/start` ping isn't followed by a success ping within the grace time, per its "Measuring Script Run Time" docs; the current 1h was sized for the Apify fetch only); first-run behavior (a full backfill could mean ~400 sequential Gemini calls); outage alert routing; the `stage_failure_counts` replacement.

## 11. Testing and eval

**Tests (Minitest, existing conventions):** Gemini is never called in the suite — `Extractor` takes an injected fake client. Gemini payloads come from FactoryBot **hash factories** following the Apify pattern (Faker for incidental filler; literals only for what a test asserts; a trait per category and per failure). `FactoryBot.lint` covers the AR-backed `Event`/`Extraction` factories. Required cases:

- Pure: `ExtractionParser`, `ConfidenceThreshold`, `Categories`, `GeminiOutage`.
- `Extractor`: guard skip; success as event; success as non-event (no `events` row, `is_event: false`); whole-service failure; this-post failure; transaction rollback; images read in `position` order.
- Dispatch: a stalled `media_processed` post **is** retried (regression for §0); an unexpected error on one post doesn't stop the others; the outage tracker becomes active at 5 and resets on success.
- `AccountPipeline`/`IngestionRunner`: counters and `unexpected_errors` land on the `IngestionRun`.

**Eval set — what it is for.** Your labels are the answer key. Without them, "is the prompt good enough?" is a feeling and every prompt or model change is a guess about whether things got better. With ~50 labeled posts, each `prompt_version` gets a score (category right, date right, venue right), and the review-confidence bar can be chosen where errors cluster below it. It **blocks public launch and threshold tuning, not the code** — the pipeline can be built and dry-run first with conservative defaults. Because *values* aren't guaranteed even at temperature 0 (§7), also run the eval set twice on the same `prompt_version`: any field that flips between the two runs is a signal to tighten the prompt or treat that field as inherently low-confidence, rather than a one-off scoring artifact.

- **Practice set (no labels):** a fresh scrape in Pass S of ~10 accounts — **the dev DB and B2 are wiped first**, so the old dry-run posts and the 32 two-year-old images are discarded (OPEN Q16 is closed as moot; those samples no longer exist as a resource). The non-English risk (Arabic and Tamil script on posters, mixed-language captions) needs deliberately non-English accounts in the scrape, since an English-only pool won't exercise it. The five posts in §3 are practice data.
- **Exam set (labeled blind):** ~50 posts, sampled separately from the practice posts, spread across languages and categories, **labeled before any model output is seen** (correcting the model's answers instead leads to nodding along and a flattering score). Fields: shortcode, category, `is_event`, title, `starts_date`, `starts_time`, `ends_date`, `ends_time`, venue. Stored as a fixture file; scored by `clubsync:extraction_eval` against live Gemini, not in CI. **Labeler and size (resolved — this plan's own labeler): the maintainer labels ~50 posts, blind, alone; a second labeler added only if one turns up.** If few-shot examples are added to the prompt, they come from the practice posts only — never the exam set, which has to stay unseen by prompt-writing to remain a valid check.

## 12. Passes and worklist

**Pass S — Practice run (throwaway; ships no code)**
- [x] **Wipe the dev DB and B2 first** — the previous dry-run rows/objects are discarded (the production box starts fresh on the E5440 anyway); Pass S begins from a clean state. *Note: closed as moot in practice — the live drill-down ran against the existing fresh-scrape dry-run posts with B2-reachable media, no wipe needed (see Pass 4 note).*
- [x] Scrape ~10 accounts (include non-English ones) up to `media_processed` with the existing pipeline; **time it** (feeds §10). *Note: 10 accounts scraped → 79 pool posts (media-only, blind), ~58 min total scrape time, 4–8 min/account sequential.*
- [x] Throwaway script: caption + `posted_at` + images → Gemini → raw JSON; no DB writes. Run on the 14 dry-run posts, the old images, then ~40 pool posts. *Note: done via the live pipeline + throwaway runner scripts over the 79-post pool, with DB writes (extraction always persisted).*
- [x] Read outputs; log misses; revise the category list and rule wording; count how many posts land in `other`; note what confused the model (sign-ups, multiple dates, relative dates). *Note: reviewed vs. human labels — 13/13 agreement; distribution event 27 · recap 24 · general_announcement 15 · recruitment 10 · deadline 1 · teaser 1 · other 1; fundraising/reminder/merch 0 hits. Findings recorded under Pass 5 (CSRW missing category, casting-call → recruitment, dedup groups in §13).*
- [x] Check model ID, limits, structured-output support (including which schema keywords it accepts), and image token cost for 10-image carousels. *Note: live checks passed — responseSchema + seed + temperature 0 + thinkingConfig low accepted; no thoughtsTokenCount under schema+low; token counts verified (825 in / 252 out on 3.5-flash, ~2065/277 on lite). Model availability: 3.5/3.8-flash were in a sustained 503 spike; 3.1-flash-lite was used live. Image-token cost for a full 10-image carousel not separately measured — carousels in the pool were short.*

**Pass 0 — Schema and dispatch (behavior-preserving)**
- [x] Migrations: `events`, `extractions`, `posts.category`; `Event`/`Extraction` models and factories (lint)
- [x] Stage-based dispatch in `AccountPipeline` (§5.1) with the regression test; per-post rescue and `unexpected_errors` counting
- [x] *Stage enum and `PostLoader` are untouched*

**Pass 1 — Gemini plumbing**
- [x] `ObjectStore#get`
- [x] `GeminiClient` + exception classes (hermetic tests) over **plain `Net::HTTP` REST** (2026-09-21: inspected `google-genai` 0.1.1 on rubygems — unofficial port, no request timeouts, mis-shaped error classes → adopted the plan's pre-agreed REST fallback; `GeminiPayload` (Pass 2) feeds it `contents`/`generationConfig`); `GEMINI_MODEL` in `env.example`

**Pass 2 — Prompt, schema, parser, gate**
- [x] `Categories`; `ExtractionPrompt` (v0 written straight from §7.2 — the practice run hasn't happened yet, Pass S rewording still applies; `VERSION`); response schema
- [x] `ExtractionParser`, `ConfidenceThreshold`, Gemini payload factories, tests
- [x] Second category-coverage pass on the final prompt (does the list cover a good share of real posts?) — done on the 79-post pool: 7 of 10 categories hit; `fundraising`/`reminder`/`merch_or_sales` saw 0 hits; review found `clubs_and_society_registration_week` missing (see Pass 5 note)

**Pass 3 — `Extractor`**
- [x] `Extractor` per §6, with tests

**Pass 4 — Wire and monitor**
- [x] Add `Extractor` to dispatch; create `GeminiOutage` in `IngestionRunner` and pass it down
- [x] `ingestion_runs` migration (`stage_results`, `unexpected_errors`), runner tallying, Discord summary lines (health plan section)
- [x] `clubsync:extract_one[shortcode]`
- [x] Live drill-down + eval on the existing 12-post dry-run dataset (dev `.env` now carries real `GEMINI_API_KEY`; `.env` is the single source after empty placeholders were removed from `.env.development`/`.env.test`): 12/12 extracted, 7 events + 5 non-events, rule-consistent; the pessimistic-Pass-S wipe was unnecessary — the dry-run posts were already fresh scrapes with B2-reachable media. Ran on `gemini-3.1-flash-lite` because `gemini-3.5-flash` (the `.env` pick) was in a sustained 503 demand spike; 503s landed as `whole_service` failed rows exactly as designed (post stays `media_processed`, retried next run). Confirmed live: `responseSchema` + `seed` + `temperature: 0` + `thinkingConfig: {thinkingLevel: "low"}` all accepted; `thoughtsTokenCount` absent under schema+low so no hidden thinking bill. Caveat: `Clubsync:extract_one`-style retries kept hitting 503s on both 3.5/3.8-flash; a fallback model is worth revisiting before launch.
- [x] Doc sync (§15)

**Pass 5 — Eval set and thresholds** *(blocks public launch, not code)*
- [ ] Label ~50 posts blind; `clubsync:extraction_eval`; choose the review bar; revise the prompt and bump `VERSION`; confirm the category mapping (e.g. `fundraising`); run the eval set twice on one `prompt_version` to check for flip-flopping fields

**Eval status on the 79-post pool (2026-09-22, ~20 posts reviewed):** precision ≈85% on event-extractions (23 confirmed / 27, with 4 false positives) — the FPs are **all one cause**: Clubs & Society Registration Week (CSRW). Bare CSRW posts and "booth at CSRW" posts (`DcnfuWmjtp2`, `DRLjN_Qklju`, `DWv8dGCEuik`, `DcYl75RvyyU`) recur every semester and are not events; the §3 `PRECEDENCE` "any time/place → event" rule over-fires on them. Decision: add a `clubs_and_society_registration_week` category (non-event) with a carve-out in the prompt, and a "casting call = recruitment (not deadline)" prompt line; the AGM/general-meeting-as-event reading is confirmed. **RESOLVED 2026-09-24: the category, the reworded prompt and its `VERSION` v2 bump all landed** (the rename to the descriptive value is in `REPO_STATE.md` §4 / `§3` above). The further **v3 wording (recap-wins + `qr_code_seen` precision) and the in-extraction CSRW guard are decided 2026-09-24 and pending build** (§3 / §6 / §6.1). `recruitment` keeps its name (a casting call is also recruitment, and renaming would orphan ~10 stored rows). The three dedup groups found during review live in §13.

**Pass 6 — Langfuse (dropped from v1)**
- [x] **Out of v1 (2026-09-21):** `extractions` is the permanent record and the ~50-post eval set is a human process; no tracing UI, no SDK dependency, no `LlmTrace`. Revisit only if post-launch debugging demands it.

## 13. Deferred to the dedup session

Dedup was paused until this phase produced real `events` rows. **The dedup session ran 2026-09-23 and `docs/DEDUPLICATION_IMPLEMENTATION_PLAN.md` was rewritten into the full Phase 2 spec; this section stays here as the ground-truth input that spec was built on** — the labeled pairs below are the validation seed the dedup plan §11 references. Hypotheses in this section that were settled differently are annotated. What we knew:

- **Annual events are not a dedup case.** A new edition has a new date and new artwork.
- **Real pattern:** clubs post profile-grid series — several posts for one event, different graphics, often the same caption, same day — plus announcement/registration/"N days left" follow-ups. Per the maintainer, clubs' reposts of others' content do not go on their own profile grid, and the scraper only reads the grid. So the original image-based repost detection (dHash) may have little to do. Worth confirming once on a real payload.
- **Labeled ground truth (2026-09-22 review of the 79-post pool; recorded for the dedup session, no code or DB change made):**
  - LUNGS theatre trip (tamucyb): posts `DcfRDaVgTnf` + `DcfxBVUhY00`, anchor **`DcfxBVUhY00`**. (A review line that read "DX3aM04keXp dedup with DcfxBVUhY00" was a typo — those are different accounts/events; the real LUNGS pair is the tamucyb one.)
  - Studio Sessions HIP-HOP (rentakmmu): `DX3aFuuEen9` + `DX3aSadEWFt` + `DX3aM04keXp`, anchor **`DX3aM04keXp`**.
  - Industrial Visit to MIMOS (ieeemmusb): `Dc0xPgNTJaI` + `Dc0xZzTzRDJ`, anchor **`Dc0xZzTzRDJ`**.
  - These are stored nowhere as a fixture by design — the dedup phase builds `deduplications` (pair-score audit) and `event_group_id` when it lands; until then the only copy of this ground truth lives in this doc.
- **Same account, same day, different events must stay separate** (Misi Bekal: donation, booth and volunteers posts).
- **First hypothesis (partially superseded 2026-09-23):** same account + same `starts_on` (+ compatible venue) → same event. In the settled spec this became one *channel* (`date`) of a weighted score, not a hard rule — and the **veto floors** are what carry the "never merge on a single channel alone" principle (in particular, never on caption similarity alone). Images and caption are equal channels, not tie-breakers. **Canonical** is the longest-caption member, wholesale — not a completeness/confidence vote. See `docs/DEDUPLICATION_IMPLEMENTATION_PLAN.md` §4 / §7.
- **Model:** two tables instead of merge columns on `events`. `event_groups` gets one row per real-world event (a post with no matches is a group of one); `events.event_group_id` is a nullable FK added by dedup; `deduplications` stays a pair-score audit log only, with no foreign-key-less array field. The public site lists groups, and each card shows the group's canonical member — the single longest-caption post's `events` row (dedup plan §7). Changing a threshold means clearing `event_group_id`, deleting groups, and recomputing — no post state to migrate.
- **Possible optimization:** extract once per exact-caption group.
- **Measure first**, after Pass 4 on real data:

```sql
SELECT p.account, e.starts_on, count(*) AS posts
FROM events e JOIN posts p ON p.id = e.post_id
WHERE e.starts_on IS NOT NULL
GROUP BY p.account, e.starts_on
HAVING count(*) > 1
ORDER BY posts DESC;
```

- The session also owns: the stage enum swap, the `PostLoader` guard flip, `event_groups`, `deduplications`, and `events.event_group_id`. If dedup ends up as query-time grouping, the `deduped` enum value is simply removed.

For now, same-day and same-caption posts are **not linked**: each becomes its own `events` row. The public site doesn't exist yet, so nothing is harmed, and the linking rule should be tuned on real output.

## 14. Open questions — status after the 2026-09-21 grill session

Nearly all are resolved; the three remaining "kept" rows (12, 17, 19) and 18 (dedup) are parked on purpose — they cannot be decided before real extraction output or the dedup session exists. What could not be decided in prose is a fact-check (Q13: model ID + free-tier limits at Pass S).

| # | Question | Default if not answered |
|---|---|---|
| 1 | Store `title`/`venue` as written, or also an English title? | **Resolved:** as written, no English/translation field in v1 |
| 2 | Date-only events (no time given) | `starts_time` stays `null`; no separate boolean needed now that date and time are split columns |
| 3 | Relative dates and missing years | **Resolved:** explicit + day-name refs → nearest occurrence on/after `posted_at` for `event` posts; **countdown phrasing never produces a date** (`reminder` signature); the `reminder` category is non-event with no event date (§7.2 rule 3) |
| 4 | Timezone for all 41 accounts | `Asia/Kuala_Lumpur`; stored as local wall-clock throughout, no UTC conversion |
| 5 | Posts listing several events | One `events` row for the main event; `notes` flags it |
| 6 | Sanity window for `starts_on` | **Resolved:** reference is `posted_at` (not scrape time); keep 14 days before / 12 months after; bad values keep `starts_at_confidence` 0.0 but the row is still stored and sorted |
| 7 | Final category list; `fundraising` mapping | **Resolved:** the 10-category v1 list is frozen (§3); `reminder` added; practice run may only re-word definitions. `fundraising` is non-event **by construction** — the precedence rule already reclassifies any attendable solicitation as `event`, so its `is_event` is not tweakable |
| 8 | Extract fields for every post, or only events? | **Resolved:** every post (replay + one required-but-nullable schema; practice run may still veto at Pass S) |
| 9 | Throttling / per-run cap on Gemini calls | **Resolved:** none beyond the outage tracker — no `GEMINI_MIN_INTERVAL_SECONDS`/`EXTRACTION_MAX_PER_RUN` knobs in v1; sequential ≤410/run on a 2-day cadence fits free-tier RPM; knobs only if Pass S timing says otherwise |
| 10 | Should the outage becoming active post to `#clubsync-alerts`? | **Resolved:** yes — hermetic outage line to `#clubsync-alerts` (§5.3); message shape owned by the health plan |
| 11 | Eval set: who labels, how many | **Resolved:** ~50 posts, blind, by the maintainer alone; a second labeler only if one turns up; required before public launch |
| 12 | Calibrating self-reported confidence | **Parked (kept open):** store as-is; own session once real outputs exist |
| 13 | Exact Gemini model ID and free-tier limits | **Resolved (2026-09-23): `gemini-3.1-flash-lite`, single model, no fallback** — free-tier RPD arithmetic (full Flash ≈20 vs lite ≈500) plus the live 503-spike evidence settled it; `GEMINI_MODEL` carries the ID in `.env` and `GEMINI_FALLBACK_MODELS` stays absent so retries stay within the one model. The only open piece is device-grade RPD/TPM confirmation on the AI Studio dashboard before setting `GEMINI_DAILY_REQUESTS`/`GEMINI_DAILY_TOKENS` caps (§13 soft-cap then becomes active) |
| 14 | Category mapping location | **Resolved:** code constant (`Categories`), locked with the §3 freeze |
| 15 | Langfuse Ruby SDK vs OpenTelemetry | **Resolved:** dropped from v1 (§12 Pass 6) — no tracing UI or SDK until debugging demands it |
| 16 | The 32 old images: do captions/dates still exist? | **Closed as moot:** dev DB and B2 wiped before Pass S; practice set comes from a fresh scrape (§11) |
| 17 | Admin-entered events (weekly meetings etc.) | **Deferred (kept):** with manual submission; `events.post_id` becomes nullable then |
| 18 | Linking same-day series posts | **Parked:** dedup session (§13), not this phase |
| 19 | Health-plan section specifics (grace time, first run, alert routing) | **Deferred (kept):** owned by `HEALTH_MONITORING_PLAN.md` §10, decided after Pass S timing — except Q10's routing, which is resolved in §5.3 |
| 20 | Gemini SDK transport | **Resolved:** reviewed the rubygems `google-genai` gem at Pass 1 — it is an unofficial 0.1.1 single-author port (no request timeouts, `ClientError`/`ServerError` classes that clash with our taxonomy). Took the plan's pre-agreed fallback: plain `Net::HTTP` REST to `:generateContent` with `x-goog-api-key`, mirroring `ApifyClient`. Structured output (`generationConfig.responseSchema`, `propertyOrdering`) is still verified live at Pass S |
| 21 | `stage_results` skipped bucket | **Resolved:** dropped — only `succeeded`/`failed` are counted per stage; posts already past a stage aren't tallied there (§4.4) |

## 15. Doc sync and existing-code observations

**Edits needed elsewhere:**

> **Executed 2026-09-23** (the dedup grilling session): the dedup-plan lines below ran as its full rewrite (`docs/DEDUPLICATION_IMPLEMENTATION_PLAN.md`); the master plan's Phase 2 checklist and "needs review" query were corrected; the health plan §6 gained the dedup-stage reporting note; `env.example` carries `GEMINI_MODEL`. The items are kept below as the historical record they were issued against.

- **Master plan:** Phase 2 items for the reorder migration and guard flip → "with dedup, on hold"; the `events` table → Phase 3; replace the Phase 3 checklist with §12; `is_event` row → derived from category; correct the "needs review" query (§8).
- **Dedup plan:** add a "paused" note; §1 table rows for the reorder and skip guard → deferred; §5 Pass A becomes "create `event_groups`, add `event_group_id` to `events`" (and drop its old `linked_post_ids`/`superseded_by_event_id` design); §6 and §10 updated; seed §13's observations.
- **Health plan:** new Phase 3 monitoring section (§10).
- **`env.example`:** `GEMINI_MODEL`; optional `LANGFUSE_*`.
- **`REPO_STATE.md`:** re-audited after Pass 4 (extraction services, `events`/`extractions`, `stage_results` replacement, env keys).

**Observations from reading the current code (no action required now):**

1. `AccountPipeline` has no per-post rescue, so today a bug in any one post crashes the whole run (Pass 0 changes this on purpose).
2. `MediaProcessor` uploads to B2 inside its DB transaction; when a later image fails, the rows roll back but the already-uploaded objects stay in B2, and retries call `images.destroy_all` without deleting the old objects. Small at this volume; worth a cleanup later.
3. `stage_failure_counts` counts every post the run touched, including Video posts parked at `scraped` by design — this is why it is being replaced.