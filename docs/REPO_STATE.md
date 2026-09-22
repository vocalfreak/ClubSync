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
| `AccountPipeline` | Per-account chain: Apify fetch → `PostAdapter` → `PostLoader` → per-stage dispatch (`MediaProcessor` for `scraped?` `Image`/`Sidecar`; `Extractor` for `media_processed?` when the run's `GeminiBreaker` isn't open) | Narrow rescue on `ApifyClient::TimeoutError`, `RateLimitedError`, `Net::OpenTimeout` only; plus a per-post broad rescue that records "Unexpected …" and increments `unexpected_errors`. Returns `Result` (`success?` / `errors` / `posts_scraped` / `stage_results` / `unexpected_errors`) |
| `IngestionRunner` | `IngestionRunner.call` — loops `Account.all`, tallies into `IngestionRun` (including summing `stage_results`/`unexpected_errors`), creates one `GeminiBreaker` per run and passes it down, outer `rescue`/`ensure` calls `HealthPing` + `DiscordNotifier` (+ `post_breaker_open` when the breaker opened) | Terminal object; called only from `clubsync:ingest` |
| `ApifyClient` | `apify/instagram-post-scraper`, `POST .../run-sync-get-dataset-items`, input `{"username": [handle], "resultsLimit": 10}`, token as `Authorization: Bearer` | Distinct exception classes for timeout / rate-limit |
| `ObjectStore` | B2 `put` / `get` / `get_url` wrapper | `put` takes `content_type:` explicitly; `get(b2_key)` returns raw bytes (used by `Extractor`) |
| `GeminiClient` | Plain `Net::HTTP` REST caller for the Gemini API (transport only) | Exception taxonomy: whole-service (`TimeoutError`/`RateLimitedError`/`AuthError`/`ServerError`), this-post (`BlockedError`/`InvalidResponseError`); guards on `GEMINI_API_KEY`/`GEMINI_MODEL` |
| `Extractor` | Extraction stage service: read images via `ObjectStore#get` in position order → one Gemini call → `ExtractionParser` (pure) → `ConfidenceGate` (pure) → one transaction (succeeded `extractions` row + `events` row if `is_event` + post → `extracted`) | Guard: `post.media_processed?`; expected failures return `Result(status: :failed, error_kind:)` (whole-service vs this-post), never raise; a bug raises and `AccountPipeline`'s per-post rescue catches it |
| `GeminiBreaker` | Pure in-memory consecutive-whole-service-failure counter per run | Opens at 5; once open the pipeline skips `Extractor` (posts wait at `media_processed`); any other outcome resets the streak |
| `Categories` / `ExtractionPrompt` / `ExtractionParser` / `ConfidenceGate` / `GeminiPayload` | Pure extraction primitives (category enum + `is_event` mapping; v0 prompt/system/config; strict JSON parsing; gate on venue/placeholders/sanity window; base64 payload builder) | Deterministic, fully test-covered; re-derivation source of truth is `extractions.raw_response` |
| `HealthPing` / `DiscordNotifier` | Hermetic notifiers — rescue their own errors, log, never raise | Control-plane failures never change run status |
| (`Adapters::...` subclass) `PostAdapter` | — | see above |

The rake tasks (`lib/tasks/clubsync.rake`): `clubsync:ingest` delegates to `IngestionRunner.call`; `clubsync:extract_one[shortcode]` runs `Extractor` on a single post for manual debugging.

## 4. What is not built yet (as of 2026-09-21)

- **Remaining extraction work (Pass 5)** — the pipeline is now live-verified end to end (2026-09-22): `extract_one` + a 12-post eval pass against the real Gemini API (7 events + 5 non-events, all rule-consistent; 503s logged as `whole_service` failed rows and retried next run), config (`responseSchema`, `seed`, `temperature 0`, `thinkingConfig low`) accepted live with no hidden thinking bill. The second category-coverage pass is done on a 79-post pool (10 accounts scraped media-only; 13/13 agreement vs. human labels on a mini set; distribution event 27 · recap 24 · general_announcement 15 · recruitment 10 · deadline 1 · teaser 1 · other 1; found `clubs_and_society_registration_week` missing, 4/27 events were CSRW false positives). Not yet built: the ~50-post blind labeled eval set with `clubsync:extraction_eval`, the CSRW category + prompt reword (`VERSION` bump), and a "run the eval twice" wobble check. Watch item: `gemini-3.5-flash` (the `.env` pick) sat in a sustained 503 spike while `gemini-3.1-flash-lite` stayed healthy — a model-fallback decision is pending before launch. The spread used for the live run is recorded only in the evalset; real values live in `.env` (gitignored, single source).
- **Dedup (Phase 2)** — no `DHash` implementation (Ruby or otherwise), `images.dhash` never populated, no caption/embedding comparison, no `dedup_decisions` table, no pairwise-matching code.
- **Public site / admin review surface (Phase 5)** — no controllers/views beyond the Rails scaffold, no Cloudflare Tunnel, no Basic Auth, no Rack::Attack.
- **Circuit breaker per source** — `accounts` has no state columns (distinct from the run-scoped `GeminiBreaker`, which is in-memory).
- **Backups** — intentionally out of scope (Instagram is source of truth).

## 5. Docs index

- `MASTER_IMPLEMENTATION_PLAN.md` — architecture & phasing; **revised 2026-09-21** to the `scraped → media_processed → extracted → deduped` order and to reconcile the `events`-table history (see the correction block under its status line).
- `DATA_INGESTION_IMPLEMENTATION_PLAN.md` — `Account`, `AccountPipeline`, `IngestionRunner`, rake task, Apify client. Implemented.
- `HEALTH_MONITORING_PLAN.md` — `IngestionRun`, `DiscordNotifier`, `HealthPing`. Implemented.
- `POST_LODAER_IMPLEMENTATION_PLAN.md` — PostLoader spec (note the filename typo). Implemented; §7 flags `events`-table involvement as open.
- `SCHEMA_POST_STATUS_REMODEL.md` — stage model decisions; its "where per-field confidence is stored" open item (listed still open in its status note) is now resolved on `events.per_field_confidence` — see MASTER §2 / dedup plan §5.
- `DEDUPLICATION_IMPLEMENTATION_PLAN.md` — revised 2026-09-21; Phase 2 spec (detection algorithm, `events` table pull-forward, `dedup_decisions`).
- `EXTRACTION_IMPLEMENTATION_PLAN.md` — new; Phase 3 companion.

## 6. Env vars (`env.example`)

`APIFY_API_TOKEN` (raw token only), `APIFY_RESULTS_LIMIT=10`, `B2_*`, `DATABASE_URL`, `GEMINI_API_KEY` (blank until supplied), `GEMINI_MODEL` (blank until supplied), `DISCORD_LOG_WEBHOOK_URL`, `DISCORD_ALERTS_WEBHOOK_URL`, `HEALTHCHECKS_PING_URL`.