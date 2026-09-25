# ClubSync — Current Repo Shape & State (for planning agents)

*Last audited: September 21, 2026.*

Read this before writing any plan for this repo. It is a snapshot of the codebase **as it exists now**, not as the master plan describes it. The master plan and its companions drift from reality (e.g. Phase 1's `events` table was marked done but never created); the schema and `app/` are ground truth. Re-audit before you rely on anything here.

## 1. Stack

- Rails 8.0, Ruby 3.4, PostgreSQL (via `pg`), Puma.
- `ruby-vips` for image resize/encode; `aws-sdk-s3` for the Backblaze B2 `ObjectStore`.
- `whenever` for cron (every 2 days, host-level crontab delegating into the Docker container). `config/schedule.rb` renders `docker compose exec app bin/rails clubsync:ingest`.
- `dotenv` (`.env`, git-ignored) for all runtime config (no `env.example` file; keys are documented in `.env*` themselves). No encrypted credentials.
- Minitest + `factory_bot_rails` + `faker`. No background workers/queue usage in the ingestion path.
- Test conventions: literals reserved for what a test asserts; incidental values come from Faker; `factory_bot` traits for stage states. 171 test blocks across `test/` as of 2026-09-21.

## 2. Schema (from `db/schema.rb`, migrations `db/migrate/`)

### `posts` — the pipeline unit of work

| Column | Type | Notes |
|---|---|---|
| `shortcode` | string, **unique** | Apify `shortCode` |
| `account` | string, nullable | plain string, **no FK** to `accounts` |
| `post_type` | string, nullable | `"Image"`, `"Sidecar"`, or unsupported (e.g. `"Video"`) |
| `caption`, `source_url` | text / string | nullable |
| `posted_at` | datetime | nullable |
| `raw_payload` | jsonb, **not null** | the full Apify hash; always overwritten on refresh |
| `stage` | integer enum | **`scraped: 0, media_processed: 1, deduped: 2, extracted: 3`** — the current order has `deduped` *before* `extracted`; a Phase 2 reorder to `scraped → media_processed → extracted → deduped` is planned (both stages currently have no logic wired) |
| `is_event` | boolean, nullable | `nil` until extraction runs, then `true`/`false` |
| `last_error` | text | written by stage-services on failure |
| `stage_failed_at` | datetime | written by stage-services on failure |
| `last_ingestion_run_id` | FK → `ingestion_runs` | ties the post to the run that last wrote it |

`Post` model (`app/models/post.rb`): `enum :stage, { scraped: 0, media_processed: 1, deduped: 2, extracted: 3 }`, `has_many :images`.

### `images` — one row per processed image

`post_id` FK (unique `[post_id, position]`), `b2_key`, `content_type` (`image/webp`), `width`, `height`, `byte_size`, **`dhash` string, nullable and currently never populated**, `position`. Atomic per post: written only inside `MediaProcessor`'s single transaction.

### `accounts`

`handle` (unique). The 41 handles are seeded via `db/seeds.rb` (not a migration). No circuit-breaker columns yet.

### `ingestion_runs`

One row per `clubsync:ingest` pass. `status` (running/finished/crashed), `accounts_processed`, `accounts_failed`, `failed_accounts` (jsonb), `posts_scraped`, `stage_results` (jsonb, e.g. `{"media_processed": {"succeeded": 8, "failed": 1}, "extracted": {"succeeded": 9}}`), `unexpected_errors` (integer), `started_at`, `finished_at`, `notes`. (Replaced the former `stage_failure_counts`, which never tallied skipped/parked posts correctly.)

### `events`

One row per confirmed event, created by `Extractor` on success when the extracted category is an event. Unique `post_id` FK to `posts`, with check constraints (`starts_on`/`ends_on` consistency, nullable-vs-confidence). Holds structured fields + per-field confidence. See `docs/EXTRACTION_IMPLEMENTATION_PLAN.md`.

### `extractions`

The extraction audit log — one row per Gemini call per post. `status` (`succeeded`/`failed`), `prompt_version`, `model`, `category`, `category_confidence`, `raw_response` (full parsed JSON — the replayable truth), `error`/`error_kind` (for failed), tokens/duration/image_count for succeeded. Never drives any pipeline decision.

## 3. Services (`app/services/`)

| Service | Responsibility | Key behavior / guard |
|---|---|---|
| `Adapters::Apify::PostAdapter` | Pure mapping of one raw Apify hash → canonical attrs + validation. **Never touches the DB**, never decides stage/is_event | Returns `Result` (`valid?` / `errors` / `fatal?`); `fatal?` only for missing/blank shortcode; `raw_payload` captured in every non-fatal result |
| `PostLoader` | Owns every write to `posts` | Outcomes: `created` / `refreshed` / `skipped` / `no_row`. **Skip rule:** `post.extracted?` → skip entirely (fully processed). **Note:** when Phase 2 reorders stages, this guard must flip to `deduped?` — the "fully processed" terminal stage becomes `deduped`. Never advances `stage` itself |
| `MediaProcessor` | Fetch → resize to 1080px → re-encode WebP → `ObjectStore.put` → create `images` rows, all in one transaction | Guard: `post.scraped?`; sets `stage = :media_processed`, clears `last_error`/`stage_failed_at` on success; on failure sets error state and leaves stage put. **Never repopulates `images.dhash`** (column stays nil) |
| `AccountPipeline` | Per-account chain: Apify fetch → `PostAdapter` → `PostLoader` → per-stage dispatch (`MediaProcessor` for `scraped?` `Image`/`Sidecar`; `Extractor` for `media_processed?` when the run's `GeminiOutage` isn't active) | Narrow rescue on `ApifyClient::TimeoutError`, `RateLimitedError`, `Net::OpenTimeout` only; plus a per-post broad rescue that records "Unexpected …" and increments `unexpected_errors`. Returns `Result` (`success?` / `errors` / `posts_scraped` / `stage_results` / `unexpected_errors`) |
| `IngestionRunner` | `IngestionRunner.call` — loops `Account.all`, tallies into `IngestionRun` (including summing `stage_results`/`unexpected_errors`), creates one `GeminiOutage` per run and passes it down, outer `rescue`/`ensure` calls `HealthPing` + `DiscordNotifier` (+ `post_gemini_outage` when the outage became active) | Terminal object; called only from `clubsync:ingest` |
| `ApifyClient` | `apify/instagram-post-scraper`, `POST .../run-sync-get-dataset-items`, input `{"username": [handle], "resultsLimit": 10}`, token as `Authorization: Bearer` | Distinct exception classes for timeout / rate-limit |
| `ObjectStore` | B2 `put` / `get` / `get_url` wrapper | `put` takes `content_type:` explicitly; `get(b2_key)` returns raw bytes (used by `Extractor`) |
| `GeminiClient` | Plain `Net::HTTP` REST caller for the Gemini API (transport only) | Exception taxonomy: whole-service (`TimeoutError`/`RateLimitedError`/`AuthError`/`ServerError`), this-post (`BlockedError`/`InvalidResponseError`); guards on `GEMINI_API_KEY`/`GEMINI_MODEL` |
| `Extractor` | Extraction stage service: read images via `ObjectStore#get` in position order → one Gemini call → `ExtractionParser` (pure) → `ConfidenceThreshold` (pure) → one transaction (succeeded `extractions` row + `events` row if `is_event` + post → `extracted`) | Guard: `post.media_processed?`; expected failures return `Result(status: :failed, error_kind:)` (whole-service vs this-post), never raise; a bug raises and `AccountPipeline`'s per-post rescue catches it |
| `GeminiOutage` | Pure in-memory consecutive-whole-service-failure tracker per run | Becomes active at 5; once active the pipeline skips `Extractor` (posts wait at `media_processed`); any other outcome resets the streak |
| `Categories` / `ExtractionPrompt` / `ExtractionParser` / `ConfidenceThreshold` / `GeminiPayload` | Pure extraction primitives (category enum + `is_event` mapping; v0 prompt/system/config; strict JSON parsing; threshold on venue/placeholders/sanity window; base64 payload builder) | Deterministic, fully test-covered; re-derivation source of truth is `extractions.raw_response` |
| `HealthPing` / `DiscordNotifier` | Hermetic notifiers — rescue their own errors, log, never raise | Control-plane failures never change run status |
| (`Adapters::...` subclass) `PostAdapter` | — | see above |

The rake tasks (`lib/tasks/clubsync.rake`): `clubsync:ingest` delegates to `IngestionRunner.call`; `clubsync:extract_one[shortcode]` runs `Extractor` on a single post for manual debugging; `clubsync:snapshot` dumps the dev DB for recovery (§4); task `clubsync:measure_payload` / `clubsync:extract_pool[model,limit]` support the payload/quota probes.

## 4. What is not built yet (as of 2026-09-21)

- **Remaining extraction work (Pass 5)** — the pipeline is now live-verified end to end (2026-09-22): `extract_one` + a 12-post eval pass against the real Gemini API (7 events + 5 non-events, all rule-consistent; 503s logged as `whole_service` failed rows and retried next run), config (`responseSchema`, `seed`, `temperature 0`, `thinkingConfig low`) accepted live with no hidden thinking bill. The second category-coverage pass is done on a 79-post pool (10 accounts scraped media-only; 13/13 agreement vs. human labels on a mini set; distribution event 27 · recap 24 · general_announcement 15 · recruitment 10 · deadline 1 · teaser 1 · other 1; found `clubs_and_society_registration_week` missing, 4/27 events were CSRW false positives). Not yet built: the ~50-post blind labeled eval set with `clubsync:extraction_eval`, and a "run the eval twice" wobble check. **RESOLVED (2026-09-23): the model-fallback question is settled** — `GEMINI_MODEL` is `gemini-3.1-flash-lite`, single model, no fallback (user decision from free-tier RPD arithmetic ~500/day lite vs ~20/day full Flash, plus the live 503 evidence), `GEMINI_FALLBACK_MODELS` deliberately absent. **RESOLVED (2026-09-24): the CSRW category is landed** as `club_and_society_registration_week` (`Categories::CSRW`, extraction prompt precedence + few-shot cheat sheet, extracted-from-list schema; `event?("club_and_society_registration_week") == false` so it never surfaces as an event card but stays queryable by category for the site's future CSRW filter). The category value is the descriptive name, not the acronym — renamed from `csrw` the same day (`VERSION` v1→v2) so the model anchors on the week's semantics rather than decoding "CSRW". Stored posts tagged `event`/`recap`/`other`/nil in the pre-category pool are re-tagged without a Gemini re-call by `CsrwRetagger` via the `clubsync:retag_csrw` rake task (lexical/fuzzy caption detector — the "fuzzy search" approach — 11 of 100 posts matched on the 2026-09-23 backup pool, 0 events kept as cards; dev-DB copy re-tagged + renamed on 2026-09-24). Same-day dev-DB recovery: rebuilt from the 2026-09-22 Apify dataset replay (below) — 100 distinct posts through the real loader→media→extraction chain, 91 extracted, 32 events, 0 unexpected, `DISCORD_LOG_WEBHOOK_URL` summary + healthchecks all fired. The spread used for the live run is recorded only in the evalset; real values live in `.env` (gitignored, single source).
- **BUILT 2026-09-24 (after the low/high extraction A/B review):** (a) **dedup corroborated veto + near-simultaneous series rule** — the caption veto now fires only with visual corroboration (caption Jaccard `< 0.30` AND min Hamming `> 16`; `date` vetoes alone), and a same-account candidate pair published ≤30 min apart and not date-conflicting merges outright, bypassing scoring and vetoes, tagged `deduplications.series` with unscored `NULL` signals (`weighted_score` made nullable for this) (§4/§4.1 of the dedup plan; the MIMOS trio is the pinned series case, the iem_mmu 17:46 trio the corroboration case); (b) **in-extraction CSRW guard** — new posts whose captions match the tightened `CsrwRetagger::MARKERS` (`\bCSRW\b` + club-society form; bare `registration|recruitment week` dropped) get force-corrected to `club_and_society_registration_week` inside `Extractor` before any `events` row, so nothing is ever deleted in the live path (the one-off rake keeps its destroy for historical repair); (c) **prompt v3** — recap-wins precedence + CHEAT SHEET row, and `qr_code_seen` true only for a clearly visible QR printed in an image. All three fully test-covered; deltas to `deduplicator.rb`, `extractor.rb`, `csrw_retagger.rb`, `extraction_prompt.rb`, migrations `20260924000001` + `20260924000002`.
- **Dedup (Phase 2)** — built 2026-09-24: `DHashService`, `CaptionJaccard`, two-tier scoring, complete-link clustering, `deduplications` audit log, run-level `deduped` wiring, and the §4 veto/series amendments above all implemented and tested. Remaining is only the Phase 5 admin/review surface (below).
- **Public site / admin review surface (Phase 5)** — no controllers/views beyond the Rails scaffold, no Cloudflare Tunnel, no Basic Auth, no Rack::Attack.
- **Circuit breaker per source** — `accounts` has no state columns (distinct from the run-scoped `GeminiOutage`, which is in-memory).
- **Backups** — `clubsync:snapshot` added 2026-09-23: `pg_dump` of the dev DB to `backups/dev-<stamp>.sql` (gitignored), restore via `psql -d clubsync_development -f backups/<file>.sql`. Image bytes are separately guaranteed by B2 content-addressing (same SHA key re-put = reuse, never re-upload). Apify dataset exports land under `data/apify_export/` (gitignored) and can be replayed offline with a throwaway driver script (`/tmp`), skipping the live Apify fetch but running the real loader→media→extraction chain.

## 5. Docs index

- `MASTER_IMPLEMENTATION_PLAN.md` — architecture & phasing; **revised 2026-09-21** to the `scraped → media_processed → extracted → deduped` order and to reconcile the `events`-table history (see the correction block under its status line); **2026-09-23** dedup-spec-revision correction block + rewritten Phase 2 checklist.
- `DATA_INGESTION_IMPLEMENTATION_PLAN.md` — `Account`, `AccountPipeline`, `IngestionRunner`, rake task, Apify client. Implemented.
- `HEALTH_MONITORING_PLAN.md` — `IngestionRun`, `DiscordNotifier`, `HealthPing`. Implemented; §6 carries the Phase 2 dedup-stage reporting note.
- `POST_LODAER_IMPLEMENTATION_PLAN.md` — PostLoader spec (note the filename typo). Implemented; §7 flags `events`-table involvement as open.
- `SCHEMA_POST_STATUS_REMODEL.md` — stage model decisions (historical; see its status note). Its "where per-field extraction confidence is stored" open item is resolved on the three float columns `events.title_confidence` / `starts_at_confidence` / `venue_confidence` — see MASTER §2 / extraction plan §8 (not the `per_field_confidence` jsonb an earlier draft named).
- `DEDUPLICATION_IMPLEMENTATION_PLAN.md` — **rewritten 2026-09-23** from the simplified proposal into the Phase 2 spec: candidate window (same-account, 0–21 days since 2026-09-24, events only), hand-rolled signal layer, two-tier scoring (veto floors + 0.72 blend), gated embedding tiesbreaker, complete-link, canonical = longest caption, `deduplications` audit log, run-level wiring. **2026-09-24:** near-simultaneous series rule decided (§4.1) + `deduplications.series` column (§8), then amended same day — **corroborated veto** replaces the lone caption/visual floors (§4), the series window is tightened to 10 (§4.1), and `weighted_score` is nullable (§8) — all built with the amendment (**2026-09-25:** the series window is restored to 30).
- `EXTRACTION_IMPLEMENTATION_PLAN.md` — Phase 3 companion. **2026-09-24:** in-extraction CSRW guard (§6/§6.1) and prompt v3 wording (recap-wins + `qr_code_seen` precision) decided and built. **2026-09-25:** event tags decided and built — the frozen 37-tag `EventTags` list (§3) stored verbatim on `events.tags` (migration `20260925000002`), schema row §7.1 + prompt rule 12, `ExtractionPrompt` v4, lenient out-of-list dropping in `ExtractionParser` (ADR: `docs/adr/2026-09-25-event-tags-verbatim-labels.md`). Remaining: the hand spot-check of 10–15 real posts (§12 Pass 7).

## 6. Env vars (`env.example`)

`APIFY_API_TOKEN` (raw token only), `APIFY_RESULTS_LIMIT=10`, `B2_*`, `DATABASE_URL`, `GEMINI_API_KEY` (blank until supplied), `GEMINI_MODEL` + `GEMINI_FALLBACK_MODELS` (rotation pool; no `media_resolution` wiring yet — decision is gated on the payload/accuracy measurement, see extraction gap doc), `GEMINI_DAILY_REQUESTS` / `GEMINI_DAILY_TOKENS` (soft-cap alert triggers; unset = alert inert), `DISCORD_LOG_WEBHOOK_URL`, `DISCORD_ALERT_WEBHOOK_URL` (renamed from `DISCORD_ALERTS_WEBHOOK_URL`), `HEALTHCHECKS_PING_URL`.