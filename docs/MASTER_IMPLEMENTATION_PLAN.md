# ClubSync — Architecture & Implementation Master Plan

*Last updated: September 14, 2026*

## 1. Goal

Ingest event posts from ~41 Instagram accounts, extract structured event data (date, venue, etc.) via vision LLM, dedupe reposts, and surface confirmed events — as a solo-maintained side project, self-hosted, near-zero monthly cost, correctness prioritized over speed.

**v1 scope:** Instagram only. Everything else (Telegram/Threads/manual submission, cross-account dedup, notification-trigger phone layer) is explicitly deferred.

## 2. Finalized Architecture Decisions

| Component | Decision | Replaces (original doc) |
|---|---|---|
| Media storage | Backblaze B2 (S3-compatible), via a thin `ObjectStore` wrapper (`put`/`get_url`) | Self-hosted MinIO on the E5440 |
| Media processing (resize/compress) | Folded into the same ingestion pass, synchronous, run immediately after the adapter persists the `Post` row (not before) — avoids any queueing delay before Instagram's signed `displayUrl` expires. Each image resized to 1080px max width and re-encoded as WebP via `ruby-vips` (confirmed a valid Gemini vision input MIME type). Uploaded via the existing `ObjectStore`, now passing `content_type: "image/webp"` explicitly since it otherwise defaults to JPEG. Per-image metadata (`b2_key`, dimensions, byte size, ordinal position, a nullable `dhash` for Phase 2) lands in a new `images` table — one row per image, so a `Sidecar` post's images (Instagram caps carousels at 10, so no extra cap needed) are properly modeled rather than crammed into an array column. Only the processed bytes are kept — no original retained, same "Instagram is the source of truth" logic already used to justify skipping Postgres backups. Note: `source_url` (the permalink) and the actual expiring image URL are different fields — the latter is `raw_payload["displayUrl"]` (`Image` posts) or each `raw_payload["childPosts"][i]["displayUrl"]` (`Sidecar` posts); nothing reads these yet | New — Phase 1 checklist item was underspecified (no storage shape, no failure semantics) |
| Media processing — atomicity & retry | All of a post's images are fetched/resized/uploaded inside one DB transaction: either every `images` row for that post gets written, or none do. On any failure (expired URL, corrupt file, network error), the post's status becomes/stays `failed` and its `raw_payload` is still refreshed to whatever was just scraped. Retry is passive, not a dedicated job: the same account gets re-scraped every 2 days regardless, so a `failed` post picked up again in a later run (with a fresh, unexpired `displayUrl`) is simply re-attempted; a post already `done`/`needs_review`/`rejected` is left alone. Gets resilience against transient failures for the cost of one status check, no new scheduling machinery | New — resolves "what retries a failed post?", previously unspecified |
| "Prune" (compress/prune before B2) | Descoped for v1. B2 doesn't auto-delete anything when the 10GB free tier is exceeded — it either bills (~$0.007/GB/month) or, with a hard cap and no payment method, rejects new uploads (a pipeline failure, not silent data loss). At WebP/1080px volume across 41 accounts every 2 days, reaching that threshold is far off. Revisit only if B2 usage becomes a real line item — options then are Backblaze's basic lifecycle (hide/delete) rules, or app-level deletion of images tied to past events | Was assumed to be a needed mechanic; turned out not to be |
| Compute / orchestration | Self-hosted on the revived Dell Latitude E5440, cron-triggered, containerized via Docker + Compose (`app` + `db` services). The same box also hosts ProPro's *staging* environment (separate containers, separate Postgres instance) — the two workloads don't overlap in a way that stresses the hardware (ClubSync's cron job is bursty and network-bound; ProPro staging traffic is light), confirmed by intent to spot-check with `docker stats`/`htop` under real concurrent load. Heroku (GitHub Student Pack credit) was considered again but reserved for ProPro *production* instead, since that has real coordinator/lecturer/student users who benefit more from managed uptime — staging carries a lower uptime bar so co-locating it here is an accepted trade-off | Was briefly considered for Heroku; reverted — see Section 4 |
| Remote access / management | Tailscale (SSH into the E5440 from anywhere, no port-forwarding); lid-close sleep already disabled. This is for your own admin/SSH access — separate from the public-facing path below, which reaches the app over the open internet, not the tailnet | N/A — new since last revision |
| Database | Postgres, self-hosted on the E5440, in its own container — kept separate from ProPro's Postgres instance since ProPro is a real project with a real team. Backups are explicitly out of scope for v1: Instagram is the source of truth for the underlying content, so losing this DB costs a re-scrape + re-extraction pass (time, some free-tier API calls), not permanent data loss — a materially different risk than ProPro, which holds data with no external copy | Was an open gap ("has to be backed up manually"); resolved as intentionally deferred, not forgotten |
| Secrets | `.env`, git-ignored, `chmod 600`, transferred once via `scp` over the Tailscale IP — never committed | Rails encrypted credentials (considered, dropped as unnecessary overhead for a solo project) |
| Health monitoring delivery | healthchecks.io ping at the end of each successful ingestion run; missed-ping alerts routed to Telegram via healthchecks.io's native Telegram integration (bot + `/start`, no custom bot code needed) | A Grafana/Loki/VictoriaMetrics stack was considered and deferred — too heavy a resource sink for the E5440 relative to what one cron job's heartbeat needs |
| App framework | Ruby on Rails — single app, single language | N/A |
| Perceptual hashing (dedup) | Hand-rolled dHash in Ruby, using `ruby-vips` (already needed for the 1080px resize step) | Python `imagehash` library |
| Extraction LLM | Google Gemini (3.1 Flash-Lite or 3 Flash), via Google AI Studio free tier | "Undecided vision-capable LLM" |
| Embeddings (caption-similarity fallback) | Google `gemini-embedding-001`, same free-tier account | "Undecided" embedding API |
| Scheduling | OS cron on the E5440, managed via the `whenever` gem, staggered every 2 days. Since the app runs in a container, `whenever` writes a host-level crontab entry that calls `docker compose exec app bin/rails clubsync:ingest` rather than running a scheduler inside the container | Heroku Scheduler (considered, not used) |
| Scraping | Apify Instagram Post Scraper | Unchanged |
| Public exposure | **Resolved: in v1 scope.** Cloudflare Tunnel (`cloudflared`) on the E5440 fronts a public-facing surface — anyone can browse confirmed events and report one as wrong, no login, no reaching out to the maintainer | Was the open decision below; previously assumed Tailscale-only |
| Admin/review surface protection | Now that part of the app is internet-facing via the same Rails process, "nobody but me is on this tailnet" no longer protects the review queue. Gated in-app with HTTP Basic Auth (credentials via `.env`), independent of which network path a request came in on | N/A — new requirement created by adding public exposure |
| Public write abuse protection | Rack::Attack, IP-based rate limiting on the flag endpoint and public routes generally, since the flag action is now an unauthenticated public write | N/A — new |

Media storage stays unaffected by any of this — B2 is already off-box, so there's no self-hosted bucket to expose either way.

## 6. Implementation Phases

**Phase 1 — Foundation**
- [x] Rails app scaffold
- [x] B2 `ObjectStore` wrapper (`put`/`get_url`) — built and tested
- [x] Postgres schema/migration: `posts` (shortcode unique key, account, raw caption, image hash, B2 key(s), `raw_payload` jsonb, status enum), `events` (structured fields, confidence per field, linked post ids)
- [X] Apify integration + secrets (`.env`, git-ignored, `chmod 600`)
- [X] Adapter layer: raw JSON → canonical Post struct, validated, `raw_payload` always persisted regardless of validation outcome
- [X] Migration: make `account`, `post_type`, `source_url`, `posted_at` nullable on `posts` — lets a structurally-invalid post still persist as a `rejected` row instead of being dropped, for resilience against upstream (Apify/Instagram) structural changes
- [ ] Media processing (folded into the same ingestion pass, right after the `Post` row is persisted):
  - [ ] Migration: new `images` table (`post_id` FK, `position`, `b2_key`, `content_type`, `width`, `height`, `byte_size`, nullable `dhash`), unique index on `[post_id, position]`
  - [ ] For each post's image(s) — `raw_payload["displayUrl"]` (`Image`) or each `raw_payload["childPosts"][i]["displayUrl"]` (`Sidecar`) — fetch, resize to 1080px max width, re-encode as WebP via `ruby-vips`
  - [ ] Upload each via `ObjectStore#put`, passing `content_type: "image/webp"` explicitly
  - [ ] Wrap all of one post's image writes in a single transaction: all `images` rows or none
  - [ ] On success: `images` rows persisted, post stays/becomes `pending`. On failure: post becomes/stays `failed`, `raw_payload` still refreshed to the latest scrape
  - [ ] On re-encountering an existing `shortcode`: skip if `done`/`needs_review`/`rejected`; retry media processing if `failed`
- [ ] Containerize the app: Docker + Compose, `app` (Rails/Puma) + `db` (Postgres) services, isolated from ProPro's containers/DB
- [ ] Health monitoring skeleton (see Section 5) — don't defer this to "later." Delivery: healthchecks.io ping per successful run, native Telegram integration for missed-ping alerts

**Phase 2 — Dedup**
- [ ] Implement dHash in Ruby (grayscale + resize via `ruby-vips`, bit comparison, Hamming distance), populate the `images.dhash` column added above
- [ ] Validate against a handful of known repost pairs before trusting it
- [ ] Same-account rolling-window comparison (14–21 days)
- [ ] Caption-similarity fallback via `gemini-embedding-001` + cosine similarity (only runs if dHash finds no match)
- [ ] Match resolution: merge by confidence, not recency
- *Note: this module's runtime trigger depends on Phase 3 (extraction) succeeding — build and unit-test it standalone here against known repost pairs; it won't be wired into the live pipeline until Phase 3 lands.*

**Phase 3 — Extraction**
- [ ] Gemini API client: one call per post (caption + image(s)) → structured fields + per-field confidence, carousel posts pass all images together
- [ ] Confidence gating: rule-based checks (valid calendar date, non-empty/reasonable venue) run independent of LLM-reported confidence; below-bar fields land as `needs_review`, distinct from the adapter's `rejected` state
- [ ] **Small hand-labeled eval set** — still an open blocker (Section 8), needed to actually tune where the confidence bar sits before launch

**Phase 4 — Orchestration & resilience**
- [ ] Cron via the `whenever` gem, staggered across the 41 accounts (not all triggered at once — avoids hammering Instagram/Apify simultaneously), every 2 days — writes a host crontab entry invoking `docker compose exec app bin/rails clubsync:ingest`
- [ ] Status tracking — five states: `pending` (mapped, awaiting extraction) / `done` (extraction confirmed) / `needs_review` (extraction ran, confidence below bar) / `rejected` (adapter-level structural invalidity) / `failed` (transient downstream error, retryable — see Media processing atomicity & retry above for the media-fetch case specifically). Retry with backoff on `failed`, no retry on `rejected`
- [ ] Circuit breaker per source

**Phase 5 — Public site & Admin/review surface**
- [ ] Pick a domain for the tunnel (subdomain of an existing domain you control, or a new cheap domain — either works)
- [ ] Cloudflare Tunnel (`cloudflared`) set up on the E5440, routed to that domain, forwarding to the app container
- [ ] `production.rb`: adopt `assume_ssl`/`force_ssl` (correct now that Cloudflare's edge terminates TLS — same pattern as ProPro, different reverse proxy); add the tunnel domain to `config.hosts`; leave out ActiveStorage `:local` (unused — B2 goes through the custom `ObjectStore`) and the Mailgun/mailer block (no email in ClubSync)
- [ ] Public pages: browse confirmed (`done`) events, no auth required
- [ ] Public "report this is wrong" action on an event — routes it into the existing review queue (`needs_review`) rather than a separate workflow; likely needs a small addition to the `events` table to track that a flag came in (exact column TBD against the current `events` schema)
- [ ] Rack::Attack: IP-based rate limiting on the flag endpoint and public routes generally
- [ ] Admin/review view for `needs_review`/`rejected`/`failed` posts, gated with HTTP Basic Auth in-app — do not rely on Tailscale-only reachability for this anymore, since the app is now partially public