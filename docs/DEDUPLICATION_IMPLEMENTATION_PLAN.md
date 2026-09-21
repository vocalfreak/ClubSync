# ClubSync — Phase 2: Deduplication Plan

*Last updated: September 21, 2026 (revised after a repo audit — see §0).*

*Companion to the architecture master plan — implements Phase 2 (dedup) and changes where Phase 3 (extraction) sits in the pipeline. See `MASTER_IMPLEMENTATION_PLAN.md` for full context, and `REPO_STATE.md` for the audited current-state snapshot this revision was checked against.*

## 0. Revision notes (2026-09-21)

This plan was originally written by an agent unaware of the actual repo. The corrections and decisions in this revision are the result of an audit against `REPO_STATE.md`. **No implementation has happened yet** — this doc is the spec.

## 1. What changed from the original plan

| Decision | Was | Now | Why |
|---|---|---|---|
| Pipeline order | `scraped → media_processed → deduped → extracted` | `scraped → media_processed → extracted → deduped` | Dedup needs the LLM-extracted event date to break the "same flyer template, different session" case, and "merge by confidence" needs a confidence score to rank by — which only exists after extraction runs |
| Caption-similarity model | `gemini-embedding-001` | `gemini-embedding-2` | Newer multimodal embedding model, same free tier (GA April 2026) |
| Confident dHash match | Auto-merge, no further check | Always also run a caption/date check | Two visually-identical flyer posts (e.g. recurring "Week 3"/"Week 4" sessions) would otherwise get wrongly merged on image similarity alone |
| Ambiguous match (neither signal confident) | Undefined | Don't merge — show both publicly, flag for manual review | Matches the project's stated preference: a visible duplicate is a minor annoyance; a wrongly-merged pair silently buries a real event |
| `images.dhash` availability | Assumed "already populated in Phase 1" | **Not populated** — the column exists but nothing writes it. Phase 2 ships a `DHash` service; MediaProcessor populates the column from the resize bytes (see §5) | The audit found `media_processor` writes `Image` rows with `dhash` nil, and a test asserting `assert_nil image.dhash` |
| Skip-guard consequence of the reorder | Unstated | **`PostLoader`'s "fully processed" skip guard flips from `post.extracted?` to `post.deduped?`** (see §6) | The reorder makes `deduped` the terminal stage; without this, a deduped post would be re-scraped and re-extracted every cycle |
| `events` table | Assumed to exist (created "in Phase 1") | **Does not exist.** Phase 2 now creates it as a separate pass (§5), and with it resolves the long-open "where does per-field confidence live" item | The audit found no `events` table/model/migration despite the master plan's Phase 1 checkbox |

The reorder stays cheap: neither `extracted` nor `deduped` has real logic wired to it yet (both exist as enum values and factory traits only). But "cheap" is not "no-op" — see the `PostLoader` skip-guard change in §6.

## 2. Where this runs

Same as media processing: folded into the same per-post pass inside `AccountPipeline`, synchronous, right after each prior stage succeeds. For a given post: `PostLoader` persists the row → `MediaProcessor` runs → extraction runs → dedup runs. No separate job, no queue — matches the existing "no background workers" decision.

**Wiring is deferred until extraction exists.** There is no extraction step in the pipeline today (Phase 3 is unbuilt), and dedup compares posts that are at `extracted` or later. Per the master plan: build and unit-test dedup standalone here against known repost pairs; it won't be wired into the live pipeline until Phase 3 lands. This deferred-wiring stance applies to the *runtime* call from `AccountPipeline`, not to any of the schema/DHash/detection work, which gets built and tested now.

One consequence worth naming: within a single `AccountPipeline` run, if an account's fetch returns several posts, an earlier post in that batch may already be sitting at `stage: extracted` by the time a later post in the *same* run reaches dedup — that's fine and expected, it just means the rolling-window comparison set can include same-run siblings, not only posts from prior runs.

## 3. Duplicate-detection algorithm

For a post that's just finished extraction, compare it against every other post from the **same account** at `stage: extracted` or later, posted within the **last 14–21 days** (the existing rolling-window decision; exact value still open). For each candidate pair:

**Step 1 — dHash Hamming distance** (always, cheap, local; reads `images.dhash`, now populated by `MediaProcessor`)

**Step 2 — caption/date check** (always, cheap, local — even when Step 1 is confident)
A plain text comparison on the cleaned caption, or a regex/date-parse comparison against the two posts' *extracted* event dates (now available, since extraction runs first). **The date leg requires an `events` row** — it only applies when both posts are events (see §4, non-event handling). The caption leg applies to every post. Not a Gemini call.

**Step 3 — `gemini-embedding-2` caption similarity** (conditional — only when Steps 1 and 2 disagree, or land in the ambiguous band below)

### Decision bands

| Hamming distance (Step 1) | Step 2 agrees? | Verdict |
|---|---|---|
| ≤ `T_low` | Yes | **Confident duplicate** → merge |
| ≤ `T_low` | No (dates/captions clearly differ) | **Ambiguous** → run Step 3 |
| `T_low`–`T_high` | — | **Ambiguous** → run Step 3 |
| ≥ `T_high` | — | **Confident non-duplicate** → no action |

`T_low` and `T_high` are placeholders — set them from the validation task (§8): compare a handful of known repost pairs against a handful of known non-duplicates, find the gap between the two clusters, pick a strict cutoff on the duplicate side given we're erring toward false negatives.

If Step 3 still doesn't produce a confident answer, the pair falls through to **Ambiguous** below rather than being forced into a yes/no.

## 4. What each verdict actually does

**Confident duplicate → merge (events only).** Nothing happens to the `Post` rows. The lower-confidence extraction's `events` row gets retired: set its `superseded_by_event_id` to the canonical event, and add its post id to the canonical event's `linked_post_ids`. The public site only ever shows events with `superseded_by_event_id IS NULL`, so the retired row stops appearing without anything being deleted. "Confidence" for picking the canonical one = the extraction's per-field confidence (stored on the `events` row, see §5), weighted toward the fields that matter — date and venue, not category or registration link, per the fields already decided as core. Ties fall back to whichever was scraped first, only as a last resort.

**Merge never applies to a pair where neither post is an event.** A non-event post has no `events` row to retire and never surfaces publicly, so merging it is meaningless. Such pairs are still detected and logged (§5 `dedup_decisions`) so the eval log stays complete; verdict records `ambiguous`/`rejected` but no merge action is taken.

**Ambiguous → don't merge.** Both posts' `events` rows stand independently and both show publicly — consistent with preferring a visible duplicate over a wrongly-buried event. The pair gets logged so it sits in a queue for manual merge/reject later; nothing blocks on that review happening.

**Confident non-duplicate → no action.** Both posts continue independently. Not logged individually — see §5.

Every post, regardless of verdict, advances its own `stage` to `deduped` once this check completes. Merge outcome affects the `events` table, not the post's own pipeline progress.

## 5. Data model changes

**Pass A — `events` table (Phase 2, separate pass from dedup).** Resolves the master plan's long-open "where does per-field confidence live" item: per-field confidence is stored on the `events` row itself, which also answers the future "needs review" query (`events WHERE per_field_confidence->'starts_at' < threshold AND superseded_by_event_id IS NULL`).

```ruby
create_table :events do |t|
  t.references :post, null: false, foreign_key: true      # canonical post
  t.string     :title                                     # extracted title/session name
  t.datetime   :starts_at                                 # extracted date/time (core field)
  t.string     :venue                                     # extracted venue (core field)
  t.jsonb      :per_field_confidence, default: {}         # { "starts_at" => 0.9, "venue" => 0.8, ... }
  t.jsonb      :linked_post_ids, default: []              # post ids merged into this event
  t.bigint     :superseded_by_event_id                    # nullable self-FK; set when retired
  t.timestamps
end
add_index  :events, :post_id, unique: true                # one canonical events row per post
add_foreign_key :events, :events, column: :superseded_by_event_id
```

(Draft column set — the field list beyond `starts_at`/`venue` is Phase 3's extraction output surface; §4's canonical-pick weighting only relies on `starts_at` + `venue` + `per_field_confidence` + `linked_post_ids` + `superseded_by_event_id`.)

**Pass B — enum reorder + `dedup_decisions` (Phase 2, separate pass).**

- `posts.stage` enum reorder to `scraped → media_processed → extracted → deduped`. No new/renamed values; just swaps integer slots (`extracted` 2↔`deduped` 3). No rows exist at either stage today, so no data rewrite is needed — but the migration should still defensively remap `2`→`3`/`3`→`2` in case any test/prod row is ever at those values.
- New `dedup_decisions` table — one row per *pair* actually evaluated. Columns: `post_a_id`, `post_b_id` (FKs; **unique index on the ordered pair**), `dhash_distance`, `caption_check_result` (agree/disagree), `embedding_similarity` (nullable — only populated when Step 3 ran), `verdict` (`merged`/`ambiguous`/`rejected`), `created_at`, `resolved_at` (nullable — set when a human resolves an ambiguous pair).

**Upsert, not append.** Re-evaluating the same pair updates the existing row in place (`ON CONFLICT (post_a_id, post_b_id) DO UPDATE` of the computed columns) and **never overwrites `resolved_at`** once set. In the normal flow a pair is evaluated only once anyway (the §6 skip guard prevents re-runs); the upsert is a safety net for the pre-Phase-3 window and for posts that crash between extraction and dedup.

This one table does double duty: it's the review queue (`WHERE verdict = 'ambiguous' AND resolved_at IS NULL`) *and* the evaluation log for checking dedup performance over time — the borderline-distance rows are exactly what you'd sample when spot-checking. No separate table needed for either purpose.

## 6. Pipeline consequence the reorder forces

`PostLoader` currently skips any post that is `post.extracted?` — "fully processed, never touch again" (`app/services/post_loader.rb`, skip branch). After the reorder the terminal stage is **`deduped`**, so:

- `PostLoader`'s skip guard flips to `post.deduped?`.
- The two `post_loader_test.rb` skip tests referencing `:extracted` update accordingly (still covered by the `:deduped` factory trait).
- A post at `extracted` (e.g. crashed before dedup) is *not* skipped — it's re-scraped, re-extracted idempotently, and dedup finally completes.

This is why the "cheap reorder" in §1 is a migration on ordering *plus* one guard change, not a no-op.

## 7. dHash mechanics

- New pure service, `DHash` (`bytes → hex digest string`), unit-tested standalone against known repost pairs per the master plan's Phase 2 validation item.
- **Called from `MediaProcessor` at the resize/encode step**, hashing the resized WebP bytes already in memory — no B2 retrieval, no extra I/O, no backfill. `MediaProcessor` writes the value into the `Image` row it already creates.
- **No backfill for pre-existing rows.** The handful of media_processed posts from the September dry run keep `dhash` nil and are ignored (dev data; production starts fresh on the E5440). A nil hash simply excludes a post from the comparison set.
- Current order of operations in `MediaProcessor` (fetch → resize → encode → upload → insert `images` row) adds one hashing step before the insert; the atomic one-transaction-per-post semantics are unchanged.

## 8. What Phase 5's admin surface needs, as a result

The admin/review surface (already on the roadmap) now has a second job beyond "posts stuck in `last_error`": a queue of ambiguous pairs from `dedup_decisions` (`verdict = 'ambiguous' AND resolved_at IS NULL`) waiting on a manual merge/reject call — resolution sets `resolved_at`. Worth a one-line addition to that phase's checklist rather than a new phase. The "update the public events query to filter `superseded_by_event_id IS NULL`" step belongs to Phase 5 too (no public query exists yet).

## 9. Explicitly deferred / open

- **`T_low` / `T_high` exact values** — set via the known-repost-pairs validation, not guessed here.
- **Confidence-weighting formula for canonical pick** — the date/venue-weighted average above is a first cut; revisit once real confidence distributions exist from Phase 3.
- **`events` column set beyond the core fields** — final shape is Phase 3's extraction output surface; Phase 2 creates the table per §5.
- **Cross-account dedup** — still out of v1 scope, unchanged.
- **What "manually resolve" looks like in the admin UI** (a merge button, a reject button) — implementation detail for Phase 5.
- **Whether `gemini-embedding-2` is used for caption-only or image+caption vectors** — this plan uses it for caption similarity (Step 3); image similarity is already covered by dHash. Embedding spaces of `001` vs `2` are incompatible, so don't mix (irrelevant today — nothing is embedded yet).

## 10. Implementation checklist

- [ ] Migration (Pass B): reorder `posts.stage` enum to `scraped → media_processed → extracted → deduped` (defensive value remap included)
- [ ] `PostLoader`: flip skip guard `extracted?` → `deduped?`; update the two skip tests
- [ ] Migration (Pass A): create `events` table per §5 (fields, `per_field_confidence`, `linked_post_ids`, `superseded_by_event_id` self-FK, unique `post_id`)
- [ ] Migration (Pass B): create `dedup_decisions` table with unique index on `(post_a_id, post_b_id)`
- [ ] Implement the pure `DHash` service (grayscale + resize via `ruby-vips`, bit comparison, Hamming distance)
- [ ] Wire `DHash` into `MediaProcessor`'s resize/encode step so `images.dhash` is populated on first pass (no backfill)
- [ ] Validate `DHash` against a handful of known repost pairs before trusting it
- [ ] Implement the local caption/date check (no API call); date leg applies only when both posts have `events` rows
- [ ] Wire `gemini-embedding-2` as the Step 3 tiebreaker, gated to only fire on disagreement/ambiguous-band cases
- [ ] Validate `T_low`/`T_high` against known repost pairs and known non-duplicates
- [ ] Merge logic: retire the lower-confidence `events` row, relink post id, set `superseded_by_event_id` — **events pairs only**; non-event pairs are detect+log only
- [ ] Log every rolling-window comparison to `dedup_decisions` (one row per pair, upsert, preserve `resolved_at`)
- [ ] Wire dedup into `AccountPipeline`, immediately after extraction succeeds, same pattern as media processing — **deferred until Phase 3 extraction is live**
- [ ] Update `posts.stage` to `deduped` on completion, regardless of verdict
- [ ] Phase 5: public events query filters `superseded_by_event_id IS NULL`; admin queue lists unresolved ambiguous pairs