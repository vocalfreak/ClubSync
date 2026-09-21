# ClubSync — Post Status Model: Decisions

**Status · September 16, 2026:** All schema/decision content here is shipped — `posts.stage` (integer enum), `is_event`, `last_error`, `stage_failed_at` live in the app (migration `20260915000000`); `SCHEMA_POST_STATUS_REMODEL`'s "Loader routing logic" was later refined by `docs/POST_LODAER_IMPLEMENTATION_PLAN.md` (Loader no longer advances stage at all). The "Still open" item below (where per-field extraction confidence is stored) remains open — Phase 3 concern.

Supersedes the old single `posts.status` enum (`pending`/`done`/`needs_review`/`rejected`/`failed`) and the retry logic tied to it.

## Schema changes (`posts` table)

- **Drop** `status` (integer enum) entirely.
- **Add** `stage` (string/enum, not null, default `scraped`): one of `scraped`, `media_processed`, `deduped`, `extracted`. The last pipeline stage that completed successfully for this row. Advances one stage at a time, never skips ahead.
- **Add** `is_event` (boolean, nullable, default `nil`): `nil` until `stage == extracted`; set to `true`/`false` by decision-thresholding immediately after LLM extraction, in the same step (not its own stage).
- **Add** `last_error` (text, nullable) and `stage_failed_at` (datetime, nullable): describe the most recent failure. Both cleared the next time that stage succeeds.
- **No** retry-count/attempts column, no attempts table. A failed stage is just re-attempted from scratch on the next cron pass — operations (resize/upload, dedup hash, LLM call) are treated as idempotent, so nothing needs to track "how many times."

## Removed concepts

- **`rejected` is gone, not stored anywhere.** Structural invalidity is inferred, never a stored value:
  - Missing/blank shortcode → Adapter returns a fatal result → Loader never creates a row.
  - Unsupported `post_type` (e.g. `"Video"`) → Adapter returns a non-fatal invalid result → Loader still creates the row (raw payload preserved), but `stage` never advances past `scraped`. "Is this rejected" is answered by checking `post_type NOT IN ('Image', 'Sidecar')`, not a status column.
- **`needs_review` is not a post-level column.** It depends on per-field extraction confidence, which isn't designed yet (see Open Items). Once it exists, "needs review" is a query (`is_event = true AND <some field below threshold>`), not a stored status.
- **No image-level status column.** Media processing is one atomic transaction per post — images for a post either all exist or none do. Revisit only if a real partial-failure or per-image dedup need shows up later.
- **No background job/worker system anywhere in this pipeline.** Everything is cron-triggered via a rake task, never triggered by a user request, so there's no request/response cycle to protect. (Contrast with the other Rails project's CSV-import/email workers, which exist specifically to get slow work out of a controller action.) Retry-on-demand for one specific failed post would be the one legitimate reason to add a queue later — not needed now.
- **The old "found + status failed → retry" Loader branch is gone**, along with the multi-scraper (Instaloader-primary/Apify-fallback) design it was built for.

## Loader routing logic (replaces the old status-based branching)

1. Shortcode not found → create Post, `stage: scraped`.
2. Shortcode found, `stage == extracted` → fully processed, skip entirely.
3. Shortcode found, `stage != extracted` → attempt to advance to the next stage; on failure, set `last_error` / `stage_failed_at`, leave `stage` unchanged, move to the next post.
4. Adapter fatal result (no shortcode) → no row, nothing to do.

## Corrections to the previous session's code

- `Adapters::Apify::PostAdapter::Result` (`valid?` / `errors` / `fatal?`) is unaffected — no change.
- Update the class comment "Never decides `Post#status` — that's `PostLoader`'s job" → should say **`stage`/`is_event`**, since `status` no longer exists in that form.
- The planned `PostLoader::Result` shape must **not** include a `retried` outcome (it was scoped for the old retry/status model). Its outcome set should be something like `created` / `skipped` / `advanced` / `stalled` — finalize the exact names when it's built, but `retried` doesn't survive into it.
- Existing `PostAdapter` tests need no changes — they only test mapping/validation, which the stage-model swap doesn't touch.

## Still open

- Where per-field extraction confidence is stored (jsonb column on `posts` vs. a separate table) — needed before `needs_review`/review-queue logic can be built.
- What the public site actually displays as "status" to visitors — out of scope here; this doc is internal pipeline modeling only.