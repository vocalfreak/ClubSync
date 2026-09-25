# ClubSync — Deduplication Implementation Plan (Phase 2)

*Last updated: September 24, 2026 — near-simultaneous series rule (§4.1) and `deduplications.series` (§8) decided after the low/high extraction A/B review (the MIMOS trio and the iem_mmu 17:46 trio both failed dedup on cheap signals alone). `CONTEXT.md` owns the vocabulary; this doc owns the Phase 2 algorithm and schema.*

Companion docs: `docs/MASTER_IMPLEMENTATION_PLAN.md` (phasing), `docs/EXTRACTION_IMPLEMENTATION_PLAN.md` (production of the `events` rows this phase groups), `docs/HEALTH_MONITORING_PLAN.md` (run summary reporting for the new stage). A current-state grounding snapshot lives in `docs/REPO_STATE.md`.

**Status:** not built. No `DHash` implementation, `images.dhash` never populated, no `deduplications` table, no pairwise-matching code. `event_groups` and `events.event_group_id` do not exist yet.

---

## 1. Position in the pipeline

Dedup runs *after* extraction: it needs the extracted event fields (`is_event`, `starts_on`) and the per-signal inputs. Stage order is `scraped → media_processed → extracted → deduped`; `deduped` is the terminal stage.

- **Migration (prerequisite):** reorder `posts.stage` so `deduped` (2) moves after `extracted` (3) → `scraped: 0, media_processed: 1, extracted: 2, deduped: 3`. Until that lands, the enum keeps the shipped order `deduped: 2, extracted: 3` and `extracted?` is still the highest stage. **Data-remap caution:** this is a *value swap*, not a rename — existing rows hold integers, so a naive `UPDATE` would collide (both `deduped` and `extracted` live at values 2 and 3). Remap through a temp value (e.g. `extracted: 3 → 99`, then `deduped: 2 → 3`, then `99 → 2`), or rewrite via a string intermediary, before updating the enum definition.
- **`PostLoader` guard flip:** skip guard keys off `post.deduped?` (was `post.extracted?`).
- **Termination is not immunity.** A `deduped` post is "fully processed" — no stage work runs again — but it *stays eligible as a candidate* against newly-arrived same-account posts inside the rolling window. A later run can still merge it and log a `deduplication` for it.
- `deduped` is reached (and stage advance happens) immediately after disposition, regardless of merge vs. separate: nothing in this phase waits on a human.

## 2. Candidate filtering (deterministic, pre-scoring)

Cheap elimination before any signal work. A **candidate pair** is two posts that pass all of:

| Filter | Rule |
|---|---|
| **Same account** | `post_a.account == post_b.account`. Cross-account pairs are never candidates (v1 scope decision — cross-account dedup is explicitly deferred) |
| **Extracted** | both posts at `extracted` or beyond |
| **Event-derived** | both `is_event == true`. Non-event pairs never pass this filter, so they are never scored and never logged — `deduplications` only ever holds evaluated event pairs |
| **Position in window** | same-account post separation 0–21 days on `posted_at` — the window deliberately admits both the same-day profile-grid series (several posts, one event, published together) and the spaced announcement→reminder pattern. (Set to 0–21 on 2026-09-24 after the §11 dry run on the real extracted pool showed every labeled same-event pair was same-day; the veto floors + `MAX_DATE_GAP` carry the same-day-different-events separation) |
| **Not implausibly far in event date** | when *both* `starts_on` are known and disagree outside a sanity bound (well beyond the 3-week posted_at band, e.g. > 30 days apart), the pair is dropped before scoring. Exact value tunable at build time |

## 3. Signal layer — hand-rolled, zero new gems

Culture-setting precedent: `GeminiClient` already rejected the `google-genai` gem and hand-rolls Net::HTTP REST (`gemini_client.rb:4–8`). The signal layer follows the same grain — every signal is a thin pure-Ruby module, and the only non-trivial external calls reuse what already exists:

| Signal | Computation | Deps |
|---|---|---|
| **dHash (visual)** | `DHashService`: vips → 9×8 grayscale → row/col gradient → 64-bit hash. Hamming of the pair, **min across all image-to-image combinations** of the two posts' `images` rows (a reposted flyer inside a 9-image gallery still matches on one image) | `ruby-vips` (already in the Gemfile, powers `MediaProcessor`) |
| **Caption lexical overlap** | Jaccard over tokenized captions (downcased, non-alphanumerics stripped) — cheap, catches verbatim reposts. Optional stopword list decided at build time | none (pure Ruby) |
| **Date agreement (structural)** | `date_distance_days = |A.starts_on − B.starts_on|` | none |
| **Embedding cosine** | `GeminiClient#embed` — a *sibling* to `extract` hitting `models/<model>:embedContent`, same error taxonomy, injectable-http pattern. Never a fork of `extract` (different response shape: vector vs. candidates). Model comes from a **separate `GEMINI_EMBED_MODEL` env key** — do not reuse `GEMINI_MODEL` (the extraction model). **Tiebreaker only**, gated by §6 | extension of existing `GeminiClient` |
| **Fuzzy venue / organizer (Levenshtein/Jaro-Winkler)** | **Deferred** — correlates with caption Jaccard (a typo'd venue name moves both signals together), same independence-violation shape as Gap A. Revisit once `deduplications` holds enough real pairs to show whether caption overlap alone actually misses typo/abbreviation cases | (if ever: a real gem, `levenshtein-ffi` / `fuzzy-string-match` — the one signal where a gem is genuinely justified) |

### 3.1 Per-post caching: compute once, reuse across all pairs

The rolling window re-evaluates post X against a new candidate at every run, so anything per-*post* must be computed once and cached — never per-pair-per-run:

- **dHash:** written into the existing `images.dhash` column inside `MediaProcessor`'s resize/encode step (no backfill). Hamming is then free on every re-evaluation.
- **Caption embedding:** a new nullable column on `posts` (the single embedding of the caption, stored as a `jsonb` float array — **no pgvector**: cosine is hand-rolled over the array, keeping the zero-new-extension stance). Computed *lazily* — the first time a post's cheap score lands in the ambiguity band (§6) — then reused for every later pair. Caption is immutable after `extracted`, so the value never needs invalidation. Rationale: without it, every new candidate would re-pay an embedding call for X.
- **Jaccard and date-distance** are cheap enough to recompute per evaluation; they are not stored per-post.

## 4. Scoring — two-tier, bias toward reject

Three signals normalize to [0,1]:

- `caption =` Jaccard (raw)
- `visual = 1 − hash_distance/64`
- `date = max(0, 1 − date_distance_days/14)` — perfect at 0 days apart, 0 at ≥14 days apart

**Tier 1 — corroborated vetoes (hard blockers; revised 2026-09-24).** A sub-floor signal only blocks the merge when it is corroborated — with one structural exception:

| Veto | Fires when |
|---|---|
| `caption < 0.30` **AND** `hash > 16` | different text **and** clearly different art — `hash > DHASH_STRONG_MATCH_THRESHOLD (16)` — together say "different" → no merge |
| `date < 0.30` | `starts_on` ≥10 days apart → no merge |

Only *defined* signals veto: a channel that is simply *missing* cannot block (see both-null handling).

The corroboration rule replaces the old lone-channel floors. A single changed channel is *more content*, not evidence of a different event: identical art with a rewritten caption (the iem_mmu trio — hash 0) and an identical caption with barely-distinct art (Paw Fest) are both strong candidates. A lone visual veto could never have fired without the caption already being weak (with matching captions the cheapest blend is ≥ 0.70) — it was the **caption veto firing without visual corroboration** that over-rejected the iem_mmu recap/sign-up bursts, and the corrected rule is symmetric: neither caption nor visual can veto alone. `date` stays lone because the posts' own event dates disagreeing is structural, not stylistic.

**Tier 2 — weighted blend.** `score = 0.35·caption + 0.30·visual + 0.35·date`, renormalized over the weights of whatever signals are defined (an image-less post drops visual's 0.30 share into the others).

**Disposition (two bands, both automatic — no blocking state):**
- `score ≥ 0.72` → **merge**
- everything else → **separate** (logged, no merge)

**Merge threshold 0.72 is asymmetric — biased toward reject.** Example: identical flyer + same date + 50% caption overlap = 0.30 + 0.35 + 0.175·… ≈ 0.86 → merge; three middling 0.5s = 0.5 → separate. All numbers (weights, floors, threshold) are hand-set starting values, explicitly untuned, plastic until `deduplications` has real pairs to tune against.

### 4.1 Near-simultaneous series — timing overrides everything (decided 2026-09-24, window restored to 30 on 2026-09-25)

A candidate pair whose two posts were published within `SERIES_WINDOW_MINUTES = 10` of each other on `posted_at`, and that is **not date-conflicting**, merges outright — no signal scoring, no embedding, no vetoes. Date-conflicting means both `starts_on` known *and* different (that is the scalability guard: a genuinely different event announced in the same hour stays separate, which is what keeps this rule sane when the account list grows beyond MMU clubs). One or both dates unknown → still merges.

Why the bypass exists and what the numbers settled (evidence from the 2026-09-24 low/high A/B review):
- **The MIMOS trio** (`Dc0xHdvzrOy`/`Dc0xPgNTJaI`/`Dc0xZzTzRDJ`, ieeemmusb, 12:03/12:04/12:05) was weak on *every* cheap channel (hash 21–33 — each promo is distinct art; captions 0.14–0.22) with only the date channel strong, so even the corroborated veto keeps it separate; only timing catches it. Two of its three pairs have a nil `starts_on`, so the whole trio is unreachable by any "unknown date → don't merge" variant: nil dates mean the pair's complete-link component never forms. Its 1–2 min spacing merges well inside the 30-minute window.
- **The iem_mmu trio** (`DcboawMk4jJ`/`DcbohtoE9LB`/`DcbonV0E8pu`, 17:46/17:47/17:48) is **not** a series case — it is the corroborated veto's normal result. `hash_distance 0` (min-over-pairs Hamming is order-robust, so flipped carousel order is irrelevant) + `date_gap 0` + `caption_jaccard 0.10–0.18`: the old lone caption veto over-rejected it; under corroboration (hash 0 ≤ 16 = the art agrees) the pair lands in the ambiguity band (cheap 0.685–0.712) where the embedding tiebreaker arbitrates, so the series rule never needs to rescue it.

Real promo bursts are 1–2 min apart, so **30 minutes is deliberate headroom** (the review's original 30 was briefly tightened to 10 on 2026-09-24, then restored on 2026-09-25 so it stays comfortably above the observed bursts). The rule only fires for pairs that already survived the candidate prefilter (§2: same account, both `is_event`, 0–21 days) — it can never link cross-account or non-event posts. Series decisions are tagged `series: true` on `deduplications` (§8) with unscored `NULL` signal columns, and **complete-link clustering still applies** to them (a same-hour cluster whose members pairwise conflict still fragments).

## 5. Embedding tiebreaker (gated, signal-gathering — not a third band)

`gemini-embedding-2` cosine is **only** computed for pairs whose cheap blend lands in the ambiguity band

```
score ∈ [0.55, 0.72)
```

Then re-score replacing the caption channel wholesale: `score = 0.35·cosine + 0.30·visual + 0.35·date` (embedding is a strictly better caption-similarity estimator; when the cheap signals fight, the expensive one arbitrates). Re-apply the same corroborated vetoes (§4 — the raw caption/hash pair still governs them) and the same 0.72 threshold.

Pairs clearly in the separate band or clearly in the merge band never pay the embedding call. `embedding_cosine` starts as `NULL` in `deduplications` and is only ever written by this gate.

## 6. Clustering — complete-link

A multi-slot group (the "N days left" → announcement → registration series) is formed by **complete-link**: every pair inside the group must individually have crossed the merge threshold. Single-link is rejected — it lets A≈B≈C drift chain (B bridges A and C without A/C being the same event). Same-account windows are small enough that C(n,2) per group is affordable. A post with no matches is a group of one.

## 7. Disposition: `event_groups`, canonical event, nothing deleted

- Every merge unions the posts into one `event_groups` row; both posts' `events` rows get the shared `event_group_id`.
- `event_groups` is deliberately a bare shell: `id`, `created_at`, `updated_at` — all group structure lives on the members' `events.event_group_id`. No `title`/`venue` columns; the public card renders the canonical member's `events` row instead of duplicating fields. A post with no matches is a group of one (the pass creates its group row too), so every `events` row always has an `event_group_id`.
- **Canonical event** — the group member the public site's card shows — is the `events` row whose post has the **longest caption** (the registration-style post with the most detail). One simple tiebreak, wholesale: not a per-field cherry-pick, not a confidence vote.
- **Nothing is terminally deleted.** The losing post and its `events` row persist untouched; the group's members stay linked by the shared `event_group_id`. Image galleries pool across group members via `post_id`.
- Changing a threshold later means clearing `event_group_id`, deleting groups, and recomputing — no post state to migrate.

## 8. `deduplications` — the audit trail, nothing more

One evaluated **pairwise comparison** per row: a pair-score audit log, never the merge mechanism, never a review gate — every pair is acted on automatically the moment it's scored. Corrective review after publication is Phase 5, not a pipeline dependency.

```ruby
create_table :deduplications do |t|
  t.bigint   :post_a_id, null: false    # FK posts; invariant post_a_id < post_b_id
  t.bigint   :post_b_id, null: false
  t.string   :account                   # denormalized for admin reads (posts.account is a plain string)
  t.bigint   :ingestion_run_id, null: false  # FK — the run of the latest evaluation
  t.integer  :hash_distance             # visual: min Hamming; null = no image pair
  t.integer  :date_distance_days        # null = either side's starts_on unknown
  t.float    :caption_jaccard
  t.float    :embedding_cosine          # null = never computed (ambiguity-gate only)
  t.float    :weighted_score, null: nil  # null = series merge (never scored)
  t.string   :outcome, null: false      # "merged" | "separate"
  t.boolean  :series                    # true = merged via §4.1 (near-simultaneous series); null elsewhere
  t.datetime :decided_at, null: false
  t.timestamps
  # unique index on [post_a_id, post_b_id] = the upsert key
end
```

- **Upserted** on `(post_a_id, post_b_id)`: the latest evaluation overwrites signals/score/outcome/`ingestion_run_id`/`decided_at`. One row per pair, latest evaluation wins — the rolling-window re-open means a pair can be re-scored when a better third post arrives.
- `series = true` is a reason tag on §4.1 merges, not an admission into the window — a series pair was already a candidate (§2) before the rule bypassed its scoring. Its signal columns *and* `weighted_score` stay `NULL` (no scoring ran), which is itself the audit signal that the series rule fired.
- Raw vectors are **not** stored here (3000+ floats buy nothing the scalars don't already give the audit); the vector lives transitively — caption → `posts` embedding, image → `images.dhash`.
- `"separate"` is logged for every evaluated pair that doesn't merge, exactly like `"merged"` — the logging is per-pair, not per-outcome.

## 9. Open items — resolved this session

| Open item | Resolution |
|---|---|
| Single-link vs. complete-link | **Complete-link** (§6) |
| Both-null-dated pair handling | The `date` channel is *undefined* when either `starts_on` is unknown — it contributes no credit, no penalty, and never vetoes. Both-null pairs can still merge on strong caption+visual (the classic "same flyer, no date in either caption" repost). "Too strict" is avoided by construction, since strictness only comes from defined channels |
| Cross-account reposts | Never candidates (v1 scope; explicitly deferred) |
| Same-day promo trios don't merge (MIMOS / iem 17:46 misses) | **Near-simultaneous series rule** (§4.1, decided 2026-09-24, window restored to 30 on 2026-09-25): ≤30-min publication gap + not date-conflicting → merge regardless of vetoes, tagged `deduplications.series`; complemented by the **corroborated veto** (2026-09-24) that stops the caption channel vetoing alone, so the iem trio's identical-art bursts resolve through the ambiguity band instead of an over-eager veto |

## 10. Wiring (end of run) and the run summary

- Dedup is a **run-level pass at end of run**: after all accounts have been processed (so a run's extractions all exist), evaluate windowed candidate pairs per account, apply disposition, then write the run's `deduped` tallies into `ingestion_runs.stage_results` under `"deduped"` (e.g. `{"deduped": {"succeeded": 12, "merged": 4, "failed": 1}}`), which the existing Discord summary machinery renders like any other stage.
- `deduped` is a normal `stage_results` key: posts that failed at or before `extracted` are not tallied there; a post already `deduped` isn't re-tallied, but new pairs *against* it per §1 can still move it within a group and log a fresh `deduplication`.

### 10.1 Failure semantics — hermetic, digestible, attributable

Dedup is not Gemini or Apify: nothing downstream depends on it keeping the pipeline moving, so a dedup failure is **never a run failure**.

- **Pass-level (hermetic):** the whole pass is wrapped in its own rescue that logs the exception (truncated backtrace into the run's `notes`), counts any unanticipated raise into `unexpected_errors`, records what it can, and returns. It never propagates into `IngestionRunner`, so it can never set run status `crashed`, never `/fail` healthchecks.io, and never posts to `#clubsync-alerts`. No outage tracker for dedup.
- **Pair-level atomicity + attribution:** each pair's disposition (group writes + `deduplications` upsert + members' `stage` advance) is one transaction. A pair whose transaction errors marks **both its posts** with `last_error` / `stage_failed_at` (message naming the deduped stage) while `stage` stays at `extracted`, so the stalled-post admin view can point at dedup specifically — same shape as a media/extracted failure. The pair is tallied under `stage_results["deduped"]["failed"]` and silently re-evaluated next run (passive retry, no new machinery). Posts the pass never reached are not marked — only pairs that actually errored.
- **Embedding hiccup in the ambiguity band:** a transient whole-service failure on an embed call skips the tiebreaker — the pair is decided on the cheap score alone and still logged to `deduplications` with `embedding_cosine` NULL; the embed error is logged, not counted as a pair failure (the tiebreaker is getter-only, never the decider).

## 11. Validation before trusting it in the live pipeline

- Validate dHash alone against the labeled ground truth recorded in `docs/EXTRACTION_IMPLEMENTATION_PLAN.md` §13 (LUNGS pair, Studio Sessions triple, MIMOS pair, and the Misi Bekal same-day-different-events non-pair) plus the `MEASURE` query (`GROUP BY account, starts_on HAVING count(*) > 1`) on real dev data — before any threshold is relied on.
- Build and unit-test the whole module standalone against those known pairs; wire into the live pipeline only after Phase 3 lands (the note in MASTER §Phase 2).

## 12. Deferred (not this phase)

- **Fuzzy venue/organizer match (Levenshtein/Jaro-Winkler)** — see §3. Revisit when `deduplications` has enough real pairs to show caption overlap alone is missing typo/abbreviation cases.
- **OCR** — speculative complexity for a failure mode not yet confirmed. If real misreads later: one-off A/B run OCR on failing images, paste raw text into the extraction prompt as extra context, check with `clubsync:extraction_eval` before committing.
- **Cross-account dedup** — v1 scope line, never a candidate pair.
- **Recurring / annual events** — a new edition has a new date and new artwork; not a dedup case (extraction plan §13).