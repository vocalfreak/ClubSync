# ClubSync — Current Repo Shape & State (for planning agents)

*Last audited: October 1, 2026.*

Read this before writing any plan for this repo. It is a snapshot of the codebase **as it exists now**, not as the master plan describes it. The master plan and its companions drift from reality; the schema and `app/` are ground truth. Re-audit before you rely on anything here.

## 1. Stack

- Rails 8.0, Ruby 3.4, PostgreSQL (via `pg`), Puma.
- `ruby-vips` for image resize/encode + the hand-rolled dHash; `aws-sdk-s3` for the Backblaze B2 `ObjectStore`.
- `whenever` for cron (every 2 days, host-level crontab delegating into the Docker container). `config/schedule.rb` renders `docker compose exec app bin/rails clubsync:ingest`, and that crontab entry **is installed on the E5440**.
- `dotenv` (`.env`, git-ignored) for all runtime config (no `env.example` file; keys are documented in `.env*` themselves). No encrypted credentials.
- Minitest + `factory_bot_rails` + `faker`. No background workers/queue usage in the ingestion path.
- Test conventions: literals reserved for what a test asserts; incidental values come from Faker; `factory_bot` traits for stage states. **281 tests / 1184 assertions** as of 2026-10-01, rubocop clean across 115 files.
- **A second, separate JS codebase exists**: `workers/image-proxy/` — the Cloudflare Worker that serves images publicly (plain JS + vitest, `aws4fetch`, deployed with `wrangler` from a dev machine, never bundled into the Rails image). 30 vitest cases, gated by its own `test_workers` CI job. Not part of the Rails app; see §4.

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
| `stage` | integer enum | **`scraped: 0, media_processed: 1, extracted: 2, deduped: 3`** — `deduped` is terminal. (The original order had `deduped: 2` before `extracted: 3`; migration `20260923000002_reorder_posts_stage` corrected it, and `PostLoader`'s skip guard flipped with it.) |
| `is_event` | boolean, nullable | `nil` until extraction runs, then `true`/`false`, derived once from `category` via `Categories.event?` |
| `category` | string, nullable | the extraction LLM's pick from the closed `Categories` list (e.g. `event`, `recap`, `club_and_society_registration_week`) |
| `embedding` | jsonb, nullable | caption embedding for dedup's tiebreaker; lazily populated, never backfilled |
| `last_error` | text | written by stage-services on failure |
| `stage_failed_at` | datetime | written by stage-services on failure |
| `last_ingestion_run_id` | FK → `ingestion_runs` | ties the post to the run that last wrote it |

`Post` model (`app/models/post.rb`): the enum above, `has_many :images` (ordered by `position`), `has_one :event`, `has_many :extractions`, plus a `dead_lettered` scope and `#dead_lettered?` (tail of 3 `extractions` rows all `failed` with `error_kind: "this_post"`).

### `images` — one row per processed image

`post_id` FK (unique `[post_id, position]`), `b2_key`, `content_type` (`image/webp`), `width`, `height`, `byte_size`, **`dhash` string — now populated** by `DHashService` inside `MediaProcessor`'s resize/encode step (no backfill; a failure logs and leaves it nil), `position`. Atomic per post: written only inside `MediaProcessor`'s single transaction.

### `accounts`

`handle` (unique) only. The 41 handles are seeded via `db/seeds.rb` (not a migration). **Still no circuit-breaker columns.**

### `ingestion_runs`

One row per `clubsync:ingest` pass. `status` (running/finished/crashed), `accounts_processed`, `accounts_failed`, `failed_accounts` (jsonb), `posts_scraped`, `stage_results` (jsonb, now including a `deduped` section: `{"media_processed": {…}, "extracted": {…}, "deduped": {"evaluated": n, "merged": n, "separate": n, "failed": n}}`), `unexpected_errors` (integer), `token_usage` (jsonb), `started_at`, `finished_at`, `notes`.

### `events`

One row per confirmed event, created by `Extractor` on success when the extracted category is an event. Unique `post_id` FK to `posts`, nullable `event_group_id` FK (dedup's grouping), the three float confidence columns (`title_confidence` / `starts_at_confidence` / `venue_confidence`), structured fields (`title`, `starts_on`/`starts_time`, `ends_on`/`ends_time`, `venue`, `registration_url`, `details` jsonb), and **`tags`** — a never-null string array (`[]` = untagged) holding the frozen 37-value `EventTags` list verbatim. Check constraints cover `starts_on`/`ends_on` consistency. See `docs/EXTRACTION_IMPLEMENTATION_PLAN.md`.

### `event_groups`

`created_at`/`updated_at` only — the join lives on `events.event_group_id`. One row per merged cluster.

### `deduplications`

One row per evaluated pair (unique `(post_a_id, post_b_id)`). `account`, `ingestion_run_id`, the signal columns (`hash_distance`, `date_distance_days`, `caption_jaccard`, `embedding_cosine`), `weighted_score` (**nullable** — `NULL` for an unscored series merge), `outcome`, `series` (boolean), `decided_at`. No raw vectors stored. Created as `dedup_decisions` and renamed by `20260925000001`.

### `extractions`

The extraction audit log — one row per Gemini call per post. `status` (`succeeded`/`failed`), `error`/`error_kind` (`whole_service` vs `this_post`), `prompt_version`, `model`, `category`, `category_confidence`, `raw_response` (full parsed JSON — the replayable truth), `ingestion_run_id`, tokens/duration/image_count for succeeded. Never drives any pipeline decision.

## 3. Services (`app/services/`)

| Service | Responsibility | Key behavior / guard |
|---|---|---|
| `Adapters::Apify::PostAdapter` | Pure mapping of one raw Apify hash → canonical attrs + validation. **Never touches the DB**, never decides stage/is_event | Returns `Result` (`valid?` / `errors` / `fatal?`); `fatal?` only for missing/blank shortcode; `raw_payload` captured in every non-fatal result |
| `PostLoader` | Owns every write to `posts` | Outcomes: `created` / `refreshed` / `skipped` / `no_row`. **Skip rule: `post.deduped?`** — the terminal stage, so post-loading skips fully-processed posts entirely. Never advances `stage` itself |
| `MediaProcessor` | Fetch → resize to 1080px → re-encode WebP → compute dHash → `ObjectStore.put` → create `images` rows, all in one transaction | Guard: `post.scraped?`; sets `stage = :media_processed`, clears `last_error`/`stage_failed_at` on success. **Populates `images.dhash`**; a dHash failure is logged, not fatal |
| `Extractor` | Extraction stage: read images via `ObjectStore#get` in position order → one Gemini call → `ExtractionParser` → `ConfidenceThreshold` → one transaction (succeeded `extractions` row + `events` row if `is_event` + post → `extracted`). Retries transient whole-service failures 3× across `GEMINI_FALLBACK_MODELS`, skips dead-lettered posts, and force-corrects CSRW-marked captions to the csrw category before any `events` row | Guard: `post.media_processed?`; expected failures return `Result(status: :failed, error_kind:)`, never raise |
| `Deduplicator` | Phase 2 end-of-run pass: candidate prefilter → per-channel signals → corroborated veto / series merge / weighted blend → complete-link clustering → `event_groups` + `deduplications` rows | Every evaluated pair is logged and acted on automatically; merge or stay separate, never a review gate. Hermetic: never crashes the run |
| `DHashService` / `CaptionJaccard` / `CosineSimilarity` | Pure dedup signal primitives (zero new gems) | Deterministic, fully test-covered |
| `AccountPipeline` | Per-account chain: Apify fetch → `PostAdapter` → `PostLoader` → per-stage dispatch (`MediaProcessor`, then `Extractor` when the run's `GeminiOutage` isn't active) | Narrow rescue on `ApifyClient::TimeoutError`, `RateLimitedError`, `Net::OpenTimeout`; plus a per-post broad rescue that records "Unexpected …" into `unexpected_errors` |
| `IngestionRunner` | Loops `Account.all`, tallies into `IngestionRun`, creates one `GeminiOutage` per run, outer `rescue`/`ensure` calls `HealthPing` + `DiscordNotifier` (+ `post_gemini_outage`) and finally the dedup pass | Terminal object; called only from `clubsync:ingest` |
| `ApifyClient` | `apify/instagram-post-scraper`, `POST .../run-sync-get-dataset-items`, input `{"username": [handle], "resultsLimit": 10}`, token as `Authorization: Bearer` | Distinct exception classes for timeout / rate-limit |
| `ObjectStore` | B2 `put` / `get` / `get_url` wrapper | `put` keys objects as `<sha256><ext>` with the extension derived from `content_type` through the frozen `EXTENSIONS` map (`.bin` fallback); `get(b2_key)` returns raw bytes (used by `Extractor`); `get_url` prefers `PUBLIC_IMAGE_BASE_URL` and **still has zero callers** |
| `GeminiClient` | `Net::HTTP` REST caller for the Gemini API (transport only), plus an `embed` sibling for `gemini-embedding-2` | Exception taxonomy: whole-service (`TimeoutError`/`RateLimitedError`/`AuthError`/`ServerError`) vs this-post (`BlockedError`/`InvalidResponseError`) |
| `Categories` / `EventTags` / `ExtractionPrompt` / `ExtractionParser` / `ConfidenceThreshold` / `GeminiPayload` / `GeminiQuotaAlert` / `GeminiUsage` | Pure extraction primitives: the category enum and its `is_event` mapping, the frozen verbatim tag list, the versioned prompt, strict JSON parsing, threshold rules, base64 payload builder, daily-usage soft-cap alert | Deterministic and fully test-covered; `extractions.raw_response` is the re-derivation source of truth |
| `GeminiOutage` | Pure in-memory consecutive-whole-service-failure tracker, one per run | Becomes active at 5; once active the pipeline skips `Extractor` (posts wait at `media_processed`); any other outcome resets the streak |
| `CsrwRetagger` | One-off historical repair: re-tag stored pre-category posts to the csrw category from caption markers alone, no Gemini re-call | Behind `clubsync:retag_csrw` with `DRY_RUN=true`; the live path no longer needs it (`Extractor` force-corrects instead) |
| `HealthPing` / `DiscordNotifier` | Hermetic notifiers — rescue their own errors, log, never raise | Control-plane failures never change run status |

The rake tasks (`lib/tasks/clubsync.rake`): `clubsync:ingest` delegates to `IngestionRunner.call`; `clubsync:extract_one[shortcode]` runs `Extractor` on a single post for manual debugging; `clubsync:measure_payload` / `clubsync:extract_pool[model,limit]` support the payload/quota probes; `clubsync:retag_csrw` is the historical CSRW retagger; `clubsync:snapshot` dumps the dev DB for recovery. **The one-off `clubsync:rekey_images` was removed 2026-10-01** (C8) together with `ImageRekeyer` and `ObjectStore#copy`/`#exists?`.

## 4. What is not built yet (as of 2026-10-01)

- **The public site and admin/review surface (Phase 5)** — the *path* is live (domain, tunnel, SSL, `config.hosts`, image host) but there is nothing published through it: no controllers/views beyond `StyleguideController`, no index route, no Basic Auth, no Rack::Attack, no flag endpoint, no public-site uptime monitoring.
- **The hand-labeled extraction eval set (Phase 3, Pass 5)** — a ~50-post blind labeling plus `clubsync:extraction_eval` and a "run it twice" wobble check. This is the one open item gating confidence in the extraction thresholds.
- **Circuit breaker per source (Phase 4)** — `accounts` still has no state columns (distinct from the run-scoped in-memory `GeminiOutage`).
- **Public-site uptime monitoring** — the deferred monitor must hit `https://` directly and expect a possible Bot Fight Mode challenge for non-browser clients.

**Built and deployed (2026-10-01), for contrast:** the whole ingest → media → extract → dedup chain in production on the E5440 behind a Cloudflare Tunnel; cron + healthchecks.io with its Discord integration; and the image host (`workers/image-proxy`) serving `files.cyberjayahappenings.me` from a **private** B2 bucket using a read-only single-bucket key, cached at the edge (`x-cache: HIT` on a repeat request).

## 5. Docs index

- `MASTER_IMPLEMENTATION_PLAN.md` — architecture & phasing; **revised through 2026-10-01**: Phases 1–4 built, deployment complete, Phase 2's checklist fully ticked, Phase 5's path items ticked with the pages still open.
- `DEPLOYMENT_IMPLEMENTATION_PLAN.MD` + `DEPLOYMENT_RUNBOOK.MD` — the E5440 deploy: why each step exists, and the copy-pasteable version. **All of Tracks A, B and C are complete as of 2026-10-01**; both files are kept as the re-run path for a rebuilt box.
- `DATA_INGESTION_IMPLEMENTATION_PLAN.md` — `Account`, `AccountPipeline`, `IngestionRunner`, rake task, Apify client. Implemented.
- `HEALTH_MONITORING_PLAN.md` — `IngestionRun`, `DiscordNotifier`, `HealthPing`. Implemented; §6 carries the Phase 2 dedup-stage reporting note.
- `DEDUPLICATION_IMPLEMENTATION_PLAN.md` — the Phase 2 spec (candidate window, hand-rolled signals, corroborated veto, series rule, complete-link, canonical = longest caption). **Built and running.**
- `EXTRACTION_IMPLEMENTATION_PLAN.md` — Phase 3 companion. Built, including the in-extraction CSRW guard and event tags.
- `POST_LODAER_IMPLEMENTATION_PLAN.md` — PostLoader spec (note the filename typo). Implemented.
- `docs/adr/` — `2026-09-25-css-first-tailwind-v4-pipeline`, `2026-09-25-event-tags-verbatim-labels`, `2026-09-30-private-b2-behind-a-cloudflare-worker`.

## 6. Env vars (`env.example`)

`APIFY_API_TOKEN` (raw token only), `APIFY_RESULTS_LIMIT=10`, `B2_*` (app's **upload** key — deliberately distinct from the Worker image host's `B2_READ_KEY_ID` / `B2_READ_APP_KEY` secrets), `DATABASE_URL`, `GEMINI_API_KEY`, `GEMINI_MODEL` (single model; the fallback rotation pool was dropped 2026-09-23), `GEMINI_DAILY_REQUESTS` / `GEMINI_DAILY_TOKENS` (soft-cap alert triggers; unset = alert inert), `DISCORD_LOG_WEBHOOK_URL`, `DISCORD_ALERT_WEBHOOK_URL`, `HEALTHCHECKS_PING_URL`, `PUBLIC_IMAGE_BASE_URL` (the image host origin; inert until `get_url` has callers).