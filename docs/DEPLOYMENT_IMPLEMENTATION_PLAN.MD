# ClubSync — Deployment (E5440, Docker Compose, Cron, Ops)

*Covers the master plan's compute/orchestration and Phase 1 containerization. **Scope: deployment only** — the public *path* (domain, DNS, tunnel) is in, the public *pages* are deferred to §8. Nothing in §8 blocks the deploy: `/up` is a complete smoke test for the tunnel. §1 lists what blocks the first deploy; §9 is the worklist, in three parallel tracks (B domain/tunnel, A app, C image host).*

## 0. Target

Self-hosted on the revived Dell Latitude E5440, which also runs ProPro's *staging*. `app` + `db` containers, a host crontab, a host systemd service. No Kubernetes, no deploy pipeline.

## 1. Blockers to clear before the first deploy

All six are config, no new code. **4 and 6 are fixed** (A1); 1–3 are `.env` values waiting on the box (A2); 5 is a hostname string waiting on the zone (B5). Evidence that 4 was a real boot failure: `RAILS_ENV=production bin/rails runner` raised `The 'cable' database is not configured for the 'production' environment` on a clean checkout — which also meant the Dockerfile's `assets:precompile`, and therefore the image build, could not succeed.

| # | Blocker | Fix | State |
|---|---|---|---|
| 1 | No `SECRET_KEY_BASE` — no `credentials.yml.enc`, no `master.key`, not in `.env`. Rails raises on boot. | §3 | A2 |
| 2 | No `DATABASE_URL` — `config/database.yml:14-16` gives production *only* `url: ENV["DATABASE_URL"]` | `postgres://clubsync:<pw>@db/clubsync_production` — host `db`, not `localhost` | A2 |
| 3 | No `POSTGRES_PASSWORD` — `docker-compose.yml:36` interpolates `${POSTGRES_PASSWORD}` from the host env, so Postgres gets an empty password | §3 | A2 |
| 4 | The solid gems each eager-load a `Record` that calls `connects_to` for a `:cache`/`:queue`/`:cable` database `config/database.yml` doesn't define. Boot failure, and `entrypoint.sh` runs `db:prepare` on every start. | §2.2 — removed the gems, not just the config | **fixed** |
| 5 | Compose publishes host **3010**; the tunnel ingress said `localhost:3000` | `localhost:3010` — §5 | B5 |
| 6 | `volumes: - .:/app` shadows the image's precompiled `public/assets` (gitignored, absent on the host) → every CSS/JS request 404s | §2.1 | **fixed** |

## 2. Docker Compose

The one line that matters: `127.0.0.1:<host>:3000`, never `0.0.0.0` or bare. Loopback means `cloudflared` is the only way in from outside the box — the entire point of a tunnel, and easy to lose to a copy-paste.

### 2.1 Committed file vs. the original sketch

`name: clubsync` scopes every network and volume to this project, and pinned `container_name`s are the real guard against ProPro's compose project — both stronger than the sketch's explicit network. The `db` service has no host port, plus a `pg_isready` healthcheck and `depends_on: condition: service_healthy`. Also `postgres:16-alpine` (the sketch said 17), and `env_file: .env` on `app` only — `db` interpolates `${POSTGRES_PASSWORD}` from the host env, so `.env` values stay readable by the app container.

**The `.:/app` bind mount is dropped.** It maps the host checkout over `/app` live — right for local dev, wrong for production. It deletes the build output (the image precompiles into `/app/public/assets`; `public/assets` is gitignored so the host copy has none, and the mount lands on top), and it makes the filesystem authoritative for what's running. Keep hot reload in a local-only `docker-compose.override.yml`, never the file you deploy from. No log mount needed — `production.rb` logs to STDOUT.

Undecided, none of it load-bearing: no `healthcheck:` on `app` despite the published port; no log rotation (the `json-file` driver grows unbounded); `environment: DATABASE_HOST: db` is dead config (`database.yml` never reads it); `bundle_cache:/usr/local/bundle` keeps gems across rebuilds but also keeps *stale* gems across a `Gemfile` change until `docker compose down -v`.

### 2.2 Solid Queue / Cache / Cable — the gems are gone, not just the config

`database.yml` is 16 lines with no `cache:`/`queue:`/`cable:` blocks, while stock `rails new` `production.rb` wires all three. That's blocker 4, and it was worse than "raises in production": **the app could not boot in production at all.** Verified — `RAILS_ENV=production SECRET_KEY_BASE_DUMMY=1 bin/rails runner 'puts "OK"'` failed with `ActiveRecord::AdapterNotSpecified`. Since `assets:precompile` boots the app, the image build failed too.

None of the three is used. **Solid Queue** — `app/jobs/` holds only the stock 6-line `ApplicationJob`; zero `perform_later`, zero job classes. The pipeline is synchronous inside one `bin/rails clubsync:ingest`, and the master plan already settled it: *"Background jobs / workers: None, anywhere in this pipeline."* **Solid Cache** — zero `Rails.cache` calls; `perform_caching = true` is boilerplate with nothing behind it. **Solid Cable** — no `app/channels/` at all.

**Why the gems go, not just the config.** Deleting the five config lines and keeping the gems does not work, and the second failure teaches it: all three engines call `isolate_namespace` then eager-load their `Record` class in production, and each `Record` calls `connects_to` at load time. `solid_cable`'s raises `NoMethodError` on a `nil` `config_for("cable")`. The gems are boot-time coupling to three databases that do not exist, so removing them is the only way to make the single connection correct — and the smaller change: **-3 gems, -5 config lines, -2 config files, -1 binstub, -3 schema files**, no behaviour change.

The alternative costs 3 more Postgres databases on a shared box plus a supervisor *inside the web process*, so a wedged job or a DB blip can affect request handling on a box about to be internet-facing — bought for zero jobs. A database-backed queue also needs something to run the workers, and nothing here does.

**`config/recurring.yml` is deleted, deliberately**, so the deletion doesn't read as an oversight. It was Rails-generated, production-only, and held one entry: `clear_solid_queue_finished_jobs`, hourly — Solid Queue cleaning up after itself, requiring the supervisor that doesn't exist. Nothing referenced it, and the engine reads the file only if present. If `solid_queue` returns, the file returns with it. The tell that it never ran: it sat alongside `puma.rb:37`'s unset `SOLID_QUEUE_IN_PUMA` plugin and a `bin/jobs` binstub for a queue that never received jobs.

**Reversibility:** re-adding `solid_cache` is one `Gemfile` line plus a `cache:` block plus `db:cache:prepare`. Until then a single puma process makes in-memory fine, and Rails' `FileStore` default (what the app now boots with, verified) is right for a one-container deploy.

### 2.3 Other `production.rb` leftovers

Removed `config.active_storage.service = :local` — provably unused (`grep -rn "has_one_attached\|has_many_attached\|\.attach(\|variant(\|ActiveStorage" app/ lib/` returns zero hits; images go through `ObjectStore` → B2). Leaving it set is worse than leaving it boilerplate: `:local` would write into the container's untracked layer, now its only filesystem. Also removed `config.action_mailer.default_url_options = { host: "example.com" }` — dead, there is no email, and `app/mailers/application_mailer.rb` has no subclasses. `assume_ssl`/`force_ssl` were already set and are correct behind Cloudflare's edge.

**`config.public_file_server.enabled` stays at its Rails 8 default of `true`, deliberately.** A generated `production.rb` normally sets it `false` on the assumption that nginx or thruster serves `/public` — and thruster *is* in the Gemfile, which makes that look reasonable. It doesn't apply: cloudflared forwards straight to Puma, so disabling it 404s every digest-stamped stylesheet. `grep` finds no `RAILS_SERVE_STATIC_FILES` anywhere in railties 8.0.5.1, so setting that env var would be cargo cult.

**`config.hosts` is now `["cyberjayahappenings.me"]`.** The usual justification is backwards: production defaults to `@hosts = []`, and `default_middleware_stack.rb:16-17` only inserts `HostAuthorization` when hosts is non-empty — so before this change *every* `Host` header was accepted. Setting the domain turns the middleware on and locks the allowlist to one name. `files.cyberjayahappenings.me` is deliberately absent: image requests are served by Cloudflare straight from B2 and never reach the app.

**Drift, fixed:** `Dockerfile:1` was `ruby:3.3-slim` while `.ruby-version` is `ruby-3.4.7`, the `Gemfile` pins `json ~> 2.12` citing Ruby 3.4, and CI runs 3.4. Bumped to `ruby:3.4-slim`. Not a build-breaker — `Gemfile.lock` has no `RUBY VERSION` pin and Rails 8.0.5.1 only needs >= 3.2 — it was drift, not breakage. `BUNDLE_WITHOUT="development:test"` is now set, so dotenv, brakeman, web-console and test tooling don't ship. `BUNDLE_DEPLOYMENT` is deliberately *not* set: it implies `path=vendor/bundle`, which would install gems into the app layer and defeat the `bundle_cache` volume. Still no `USER` directive, so the container runs as root — acceptable single-purpose, and changing it now would need `chown` of every writable path.

## 3. Secrets

`.env` backs both services, git-ignored, `chmod 600`, `scp`'d once over Tailscale, never committed. The tunnel credentials file gets identical treatment at `/etc/cloudflared/`, outside the repo, so it needs no `.gitignore` rule.

**`SECRET_KEY_BASE` goes in `.env`.** The master plan opted out of encrypted credentials and every other secret is in `.env`; this follows rather than growing a new mechanism. It's also the only option that works — there is no `credentials.yml.enc` and no `master.key`, so `secret_key_base` resolves to `nil`. Run `bin/rails secret`, drop the output in `.env`. Rails checks `ENV["SECRET_KEY_BASE"]` before it looks for a credentials file. **Set once, never regenerate.**

Also missing: `POSTGRES_PASSWORD` (blocker 3). `ADMIN_USERNAME`/`ADMIN_PASSWORD` belong with the admin surface (§8). `PUBLIC_IMAGE_BASE_URL` is the fifth — a new key, needed only once Track C has a working hostname (C7); until then `get_url` falls back to the raw B2 URL.

Hygiene, fixed: `.env` was mode `0644`, so were `.env.development` and `.env.test`, and `.env` holds a live B2 key, Apify token, Gemini key and both webhook URLs (`chmod 600` is A2, on the box). `env.example` **now exists** — missing despite `REPO_STATE.md` §6 and `HEALTH_MONITORING_PLAN` §5 both describing it; it documents all 24 keys the code reads, flags the three production-only ones as having no default, and notes `GEMINI_EMBED_MODEL` is a separate model family from `GEMINI_MODEL`. `.dockerignore` now excludes `backups/` (~1.1 MB of `pg_dump`), `data/apify_export/`, `Design_mockups/`, `docs/`, `test/` and the committed 346 KB `test.jpg`. The stray lowercase `dockerignore` is deleted — Docker only ever read `.dockerignore`, so it was inert, and it wasn't itself excluded, so it was landing in the image.

## 4. Cron via `whenever`

The host crontab shells into the container. `whenever --update-crontab` runs on the **host**, never in a container, and must be re-run any time `schedule.rb` changes.

```
0 3 */2 * * cd /path/to/clubsync && /usr/bin/docker compose exec -T app bin/rails clubsync:ingest >> /path/to/clubsync/log/cron.log 2>&1
```

The entry point is the rake task `clubsync:ingest` (`lib/tasks/clubsync.rake:3` → `IngestionRunner.call`). Accounts are staggered by construction — `IngestionRunner` does `Account.all.each` sequentially (`ingestion_runner.rb:7`) — so no `sleep` between accounts and no offset cron lines.

The `config/schedule.rb` in the tree renders a command that won't work from cron, on four counts: missing `-T` (cron has no TTY), no `cd` (crontab runs with `$HOME` as cwd, so `docker compose` finds no compose file), no redirect (cron mails output to nobody), and no `at:` so it fires at midnight rather than 03:00. `whenever --update-crontab` has never been run anywhere; there is no crontab in the repo and no cron daemon in the image, both by design.

The cron time and the healthchecks.io period are one decision, not two — `HEALTH_MONITORING_PLAN` §5 sets period 2 days / grace 1 hour on check `clubsync-ingest`. Move the cron without the check and every run becomes a false "missed ping".

## 5. Cloudflare Tunnel

The CLI route, not the dashboard's token install — a deliberate choice for learning. On the box:

```
cloudflared tunnel login
cloudflared tunnel create clubsync
cloudflared tunnel route dns --overwrite-dns clubsync cyberjayahappenings.me
```

**`--overwrite-dns` is required, not optional.** The apex already carried proxied A/AAAA records, so a plain `route dns` fails with `An A, AAAA or CNAME record already exists with that host`. The flag replaces them with the tunnel CNAME. It touches **only the apex** — `www` is a separate record, handled at B5b.

`/etc/cloudflared/config.yml` is canonical, because that is what the service reads:

```yaml
tunnel: <tunnel-id>
credentials-file: /etc/cloudflared/<tunnel-id>.json
ingress:
  - hostname: cyberjayahappenings.me
    service: http://localhost:3010
  - service: http_status:404
```

`credentials-file` must be an absolute path into `/etc/cloudflared/`. Left pointing at a home directory, the service starts, authenticates with no tunnel, and fails quietly.

**3010, not 3000.** Compose publishes host 3010 → container 3000. 3000 is what the image `EXPOSE`s and what Puma binds *inside* the container. Aiming at 3000 is the likeliest way to get a tunnel that authenticates, connects, routes, and returns nothing.

Persistence on the host, not in Compose:

```
sudo cloudflared --config /etc/cloudflared/config.yml service install
sudo systemctl enable --now cloudflared
```

**`--config` is passed explicitly, deliberately.** `sudo` sets `$HOME=/root`, which is how cloudflared loses track of a config it found as your user; the bare command works only by falling back to run-time search order. Passing the path makes the systemd unit unambiguous and matches Cloudflare's own guidance for the sudo case. The old runbook claimed the bare command was fine in one place and blamed a missing `--config` in another — that contradiction is resolved.

Two copies of `config.yml` now exist and will drift. The upside: the tunnel survives removal of the user account.

Domain, once: claim it (Namecheap `.me` via the GitHub Student Pack), add it to Cloudflare free, set Namecheap's custom nameservers to Cloudflare's two, wait for the zone **Active**. After that Namecheap is registrar of record only. **Done — the zone is Active.**

## 6. Health monitoring

Built and tested, and better than a single success ping. `HealthPing` (`app/services/health_ping.rb`) pings `/start` at run begin, `/fail` immediately from the crash branch, and bare success otherwise — so a genuine crash alerts immediately instead of waiting out the grace window, which is reserved for "nothing could call `/fail` at all" (box down, OOM-kill, cron never fired). It is hermetic: it rescues and logs its own errors and no-ops when the ping URL is blank, so a misconfigured check degrades to "no external backstop", never to a crash.

**Missed-ping alerting is Discord → `#clubsync-alerts`**, via healthchecks.io's native Discord integration. This is *not* app code: the app only pings, healthchecks.io detects the miss and posts itself — one webhook URL in their Integrations tab, zero Ruby. The master plan §2 and `HEALTH_MONITORING_PLAN` §5 both said Discord; an earlier draft here claimed Telegram, which appears nowhere in the repo and is explicitly deferred in the master plan's v1 scope. Telegram would also have meant running a bot and `/start`ing it — a second identity and channel for the same alert class.

One live gap: `DISCORD_ALERT_WEBHOOK_URL` is present but **empty**, and `discord_notifier.rb:24,32` post the Gemini-outage alert to it — so a detected outage is logged and silently dropped. (`DISCORD_LOG_WEBHOOK_URL`, the per-run summary to `#clubsync-log`, is set and working.) Also inert by design, from missing env vars: `GEMINI_DAILY_REQUESTS`/`GEMINI_DAILY_TOKENS` (soft-cap alert) and `GEMINI_EMBED_MODEL` (the dedup tiebreaker).

## 7. ProPro coexistence & Tailscale

Separate compose project, pinned container names, separate volume and network, separate Postgres — no shared state. Spot-check contention with `docker stats`/`htop` once both have run under real load; that's a to-verify, not an assumption.

Tailscale is SSH-only, never port-forwarded, lid-close sleep already disabled. Keep it strictly separate from the tunnel: conflating Serve/Funnel/reverse-proxy hops is a very debuggable-in-hindsight source of "which layer is broken". The one place the two paths touched in the repo was a stale `docker-compose.yml` comment justifying the loopback bind with "Tailscale Funnel only ever proxies to 127.0.0.1", the pre-tunnel decision. Reworded to name cloudflared.

## 8. Deferred — public pages & admin surface

Parked 2026-09-27, not cancelled. Four master-plan Phase 5 items: the public events index, the "report this is wrong" action (and its storage shape, still unanswered), Rack::Attack (gem not in the bundle), and the admin/review surface (no auth exists; `gem "bcrypt"` is commented out at `Gemfile:25`). A fifth, public image delivery, was parked here and has since been *decided* — twice: first as Track C Transform Rules, then reversed on 2026-09-30 to a private bucket behind a Cloudflare Worker (Track C, and `docs/adr/2026-09-30-private-b2-behind-a-cloudflare-worker.md`).

**The events-table question is settled, against the old sketch.** `db/schema.rb:49-71` has the `events` table, `app/models/event.rb` exists, `events.post_id` is uniquely indexed — strictly 1:1 with `posts`. So the query is `Event.joins(:post).where(posts: { is_event: true, stage: :deduped })`, not `Post.where(...)`. The filter is `stage: :deduped` (terminal), and lists render *event groups* via `events.event_group_id`, each card showing the canonical member's row. "Canonical = longest caption" lives in `app/services/deduplicator.rb`, not on the model — `Event` is 4 lines with no scopes, so the index's query will be the first scopes written on it.

**Public image delivery — private bucket + Cloudflare Worker.** Decided 2026-09-30, and it *reverses* the Transform Rules approach this section used to describe. Everything about *why* an image host exists still holds; only the mechanism moved.

The reason it matters is cost, not access control. B2's free allowance is 2,500 Class B transactions/day *account-wide* plus 1 GB/day egress, and every uncached read of an image is its own `b2_download_file_by_name`. A script run of 200–300 downloads is nothing against that; a public site spends it per visitor per page view.

Three ClubSync-specific facts worth keeping:

- **The year-long `cache-control` rests on immutability, and immutability is structural here.** Keys are `SHA256(bytes)` plus a constant extension suffix, so identical bytes ⇒ identical key ⇒ identical object, forever. The Worker sends `public, max-age=31536000, immutable` and the key is the reason that is honest.
- **The `.webp` extension is now load-bearing twice over.** It was there for [Cloudflare's extension-based cache eligibility](https://developers.cloudflare.com/cache/concepts/default-cache-behavior/), and now the Worker's own `^/[a-f0-9]{64}\.webp$` is what keeps an arbitrary path from ever becoming a signed B2 request — which is what makes a read-only key at the edge acceptable. The old extensionless objects are unreachable over HTTP as a result; they stay in B2 and the app still reads them through the S3 API.
- **The public URL leaks nothing.** `https://files.<domain>/<sha256>.webp` is a content hash of a post already public on Instagram.

The Track C Transform Rules steps are withdrawn along with the decision: no public bucket (it needs a payment method, which is the one thing this account is avoiding), no SSL-mode dance (the Worker-to-B2 hop is a signed HTTPS request from Cloudflare's own edge, and the zone's SSL mode does not govern a custom-domain Worker), and no Signed Exchanges setting to turn off. What replaces them is a read-only, single-bucket B2 key and a ~100-line Worker — see Track C.

**One code change landed, one env value pending.** `ObjectStore#get_url` prefers `ENV["PUBLIC_IMAGE_BASE_URL"]` and falls back to the raw B2 URL, so dev keeps hitting B2 while prod emits the Worker hostname; it reads the injected `@bucket` rather than re-reading the env var (it had silently ignored a `bucket:` argument), and `chomp`s a trailing slash. `ObjectStore#put` now derives its extension from `content_type` via the frozen `EXTENSIONS` map, so keys are `<sha256>.webp` rather than bare hex — see C0. `get_url` has zero callers today. Still pending: the *env value* for `PUBLIC_IMAGE_BASE_URL`, which remains blocked on C7.

Also noted, not decided: the public index shape (recommend upcoming-first with past events faded below, no query params yet, though the frozen 37-value `EventTags` list was built to feed a filter), and public-site uptime monitoring (the master plan's last Phase 5 item; the monitor must hit `https://` directly).

## 9. Order of operations & worklist

**Three parallel tracks, not a sequence.** Nameserver propagation — the one step whose pace wasn't yours — is finished, so the work is B4–B8 and A2–A7, with Track C (committed Worker, unblocks nothing here) floating free alongside either.

The app work goes first *within* the parallel stretch, for a debugging reason rather than a dependency one: if the tunnel test fails and you haven't proven the origin, you have three candidate causes — DNS, tunnel routing, or the app. If `/up` already returns 200 on loopback, it has exactly one. Same argument the master plan makes in the other direction, applied to ordering.

### Track B — domain & tunnel · yours, external accounts

**B1–B3 are done: the zone is Active.** Nothing below is implied by that — a zone serving DNS says nothing about whether a tunnel exists.

- [x] **B1** **DONE** — domain is `cyberjayahappenings.me`, claimed via the GitHub Student Pack (Namecheap).
- [x] **B2** **DONE** — Cloudflare account (free) created, domain added as a zone. Established by the zone reaching Active, only possible once Cloudflare is authoritative.
- [x] **B3** **DONE** — Namecheap custom nameservers set to Cloudflare's two, propagation finished. **This was the wait; it gated B5.**
- [ ] **B4** `cloudflared tunnel login` && `cloudflared tunnel create clubsync` · §5
- [ ] **B5** `cloudflared tunnel route dns --overwrite-dns clubsync cyberjayahappenings.me` · §5 — the flag is required; the apex already had records
- [ ] **B5b** Cloudflare UI only, no tunnel or `config.hosts` change: ensure a proxied `www` record exists (if the old ones are gone, an `AAAA` to `100::` is enough), then a Redirect Rule — host equals `www.cyberjayahappenings.me`, dynamic target `concat("https://cyberjayahappenings.me", http.request.uri.path)`, 301, preserve query string. Test with 302 first, then switch to 301. Verify with `curl -I https://www.cyberjayahappenings.me/anything` and check `location:` preserves the path
- [ ] **B6** Write `/etc/cloudflared/config.yml` with ingress → `http://localhost:3010` · §5
- [ ] **B7** `sudo cloudflared --config /etc/cloudflared/config.yml service install` && `sudo systemctl enable --now cloudflared` · §5
- [ ] **B8** `curl -I https://cyberjayahappenings.me/up` → 200

### Track A — app · A1 is ours, A2–A7 are yours on the box

- [x] **A1** Repo fixes — the six blockers in §1, expanded below. **DONE**, verified locally: production boot, `assets:precompile`, rubocop, 277 tests / 1175 assertions green. The Docker *image build* is the one unverified piece — no Docker in the WSL session, so it has to run on the box (A4)
- [ ] **A2** On the E5440, add to `.env`: `SECRET_KEY_BASE` (`bin/rails secret`), `POSTGRES_PASSWORD`, `DATABASE_URL` (`postgres://clubsync:<pw>@db/clubsync_production` — host `db`, not `localhost`), and `DISCORD_ALERT_WEBHOOK_URL` (empty today, so Gemini-outage alerts are silently dropped). Then `chmod 600` on `.env`, `.env.development`, `.env.test`. · §3, §6
- [ ] **A3** `scp` `.env` over Tailscale
- [ ] **A4** `docker compose up -d`, then `curl -I http://127.0.0.1:3010/up` → 200. **If this doesn't work, stop** — nothing downstream matters yet
- [ ] **A5** `docker compose exec app bin/rails clubsync:ingest` by hand; confirm a healthchecks ping landed and the run summary reached `#clubsync-log` · §6
- [ ] **A6** `whenever --update-crontab` on the host · §4
- [ ] **A7** healthchecks.io: **the check already exists** — a live `hc-ping.com` UUID is in `.env`. Verify period 2d / grace 1h and add the Discord integration → `#clubsync-alerts`. Don't create a second check. · §6

#### A1 expanded — repo changes

| File | Change | Blocker |
|---|---|---|
| `config/environments/production.rb` | dropped `cache_store`, `active_job.queue_adapter`, `solid_queue.connects_to`, `active_storage.service`, `action_mailer.default_url_options`; **set** `config.hosts = ["cyberjayahappenings.me"]` and uncommented the `/up` `host_authorization` exclusion. Added a note that `public_file_server.enabled` must stay `true` | 4, 6 |
| `config/cable.yml` | production `solid_cable` block → `adapter: async`. The block couldn't just be deleted — `solid_cable`'s engine eager-loads `SolidCable::Record`, which raises on a `nil` `config_for("cable")` | 4 |
| **`Gemfile`** | **removed all three solid gems.** Unplanned but forced: every solid engine eager-loads its `Record` class, which calls `connects_to` at boot. The gem removal, not the config removal, is what actually clears blocker 4 | 4 |
| `config/recurring.yml`, `config/cache.yml`, `config/queue.yml`, `bin/jobs`, `db/{cache,queue,cable}_schema.rb` | **deleted** — all dead once the gems go. `recurring.yml`'s rationale in §2.2 | 4 |
| `config/puma.rb` | removed `plugin :solid_queue if ENV["SOLID_QUEUE_IN_PUMA"]` (referenced a now-absent gem; was inert either way) | 4 |
| `docker-compose.yml` | dropped `.:/app`; reworded the stale "Tailscale Funnel" comment to name cloudflared, and noted the loopback bind means `/up` can only be verified from an SSH session on the box | 6 |
| `config/schedule.rb` | added `at: "3:00 am"`, `cd`, `-T`, `>> log/cron.log 2>&1`, and an `APP_ROOT` constant to edit once. Header says to run `whenever --update-crontab` **on the host** | — |
| `Dockerfile` | `ruby:3.3-slim` → `ruby:3.4-slim`; `BUNDLE_WITHOUT="development:test"`. Explicitly *not* `BUNDLE_DEPLOYMENT` | — |
| `.dockerignore` | added `backups/`, `data/apify_export/`, `Design_mockups/`, `test.jpg`, `docs/`, `test/` | — |
| `dockerignore` (repo root) | **deleted** — stray lowercase duplicate, committed, inert, and baked into the image | — |
| `env.example` | **created** — all 24 keys the code reads, no real values. `PUBLIC_IMAGE_BASE_URL` as a blank optional key | — |
| `app/services/object_store.rb` | `get_url` prefers `PUBLIC_IMAGE_BASE_URL`, falls back to the raw B2 URL, `chomp`s a trailing slash, uses the injected `@bucket`. **Not a deploy blocker** — the value waits on C7 | — |
| `test/services/object_store_test.rb` | 4 new tests: fallback, preference, trailing slash, injected-bucket regression | — |

One future cliff: the Student Pack domain is free for the first year, and the tunnel hostname dies with the domain — a lapse takes the public path down. Recurs annually.
### Track C — image host · Worker + private bucket, no deploy dependency

**Decision (2026-09-30).** The bucket stays **private**. Making a B2 bucket public required a payment method on file, which is the one thing this account is avoiding — Workers and B2 application keys are both card-free, a public bucket is not. A Cloudflare Worker at `files.cyberjayahappenings.me` signs read requests to B2 with a **read-only, single-bucket application key** and caches the result at the edge. This replaces the Transform Rules plan (old C1–C5, plus the SSL-mode and Signed Exchanges steps, which no longer apply) — see `docs/adr/2026-09-30-private-b2-behind-a-cloudflare-worker.md`. The `.webp` key work (C0) still matters, now for a second reason: it is what makes the path strictly validatable at the edge.

**Why this is conventional, not a hack.** Private bucket, least-privilege credential, edge proxy with strict input validation. The Rails app already signs B2 requests (SigV4 through the S3 API). The Worker does the same thing from the edge.

**Path.** Browser → Cloudflare → Worker (cache check) → B2 (only on a miss). The E5440 is not involved at all. Deploys come from the dev machine, not the box.

**Limits to remember (verify at signup).** Workers free plan: about 100,000 requests a day and a small CPU budget per request. Every image request runs the Worker, including cache hits — that per-request cost is what the Transform Rules approach would not have had. The Cache API only works on a Cloudflare-attached domain, not `*.workers.dev`, so `workers_dev = false` and the Worker is bound to `files.` and never tested through `workers.dev`.

- [x] **C0** `ObjectStore#put` derives the extension from `content_type` (`EXTENSIONS`, with a `.bin` fallback). The one-off rekey of pre-existing extensionless rows ran on the box on 2026-09-30 (runbook Step 4b: 316 rekeyed, 5 junk rows failed) and its tooling was removed under C8. Old objects left in place deliberately — the `.env` came from dev and dev's rows still reference them
- [ ] **C1** *(human, B2)* Create an **application key**: read-only, restricted to this one bucket, no other capabilities. Do not reuse the app's upload key. Leave the bucket **private**. Note the key ID, the application key, the S3 endpoint and the region. Never paste these into chat, an issue, or the repo. B2 shows the key only at creation
- [ ] **C2** *(agent)* The Worker in `workers/image-proxy/`: validates the path against `^/[a-f0-9]{64}\.webp$`, accepts only `GET` and `HEAD` (405 otherwise), checks the edge cache, on a miss fetches from B2 with a SigV4-signed request via `aws4fetch` (service `s3`, region from config), and returns clean headers (`Cache-Control: public, max-age=31536000, immutable`, `Content-Type`, `ETag`, `Access-Control-Allow-Origin: *`, and an `x-cache: HIT|MISS` header so C6 can verify). No `x-amz-*` or other B2 headers pass through. Secrets are Worker secrets, never code. B2 404 → 404 with `public, max-age=60`; B2 403/5xx or a network error → 502 `no-store`, logging the status and never the signature
- [ ] **C3** *(agent)* Tests for the handler with injected `fetch`, cache and signer: bad paths, wrong method, HEAD, hit, miss-then-store, B2 404/403/5xx, header whitelist, query string ignored, network failure. `workers/` in `.dockerignore`; `node_modules/`, `.wrangler/`, `.dev.vars` in `.gitignore`; a committed `.dev.vars.example`. A `test_workers` CI job. Update the runbook
- [ ] **C4** *(human, dev machine)* Authenticate `wrangler` (browser login, or a scoped API token). Set the two secrets with `wrangler secret put`, one at a time: `B2_READ_KEY_ID`, `B2_READ_APP_KEY`. Deploy. **The custom domain route creates the `files` DNS record automatically**
- [ ] **C5** *(human, Cloudflare)* Confirm `files.cyberjayahappenings.me` shows as a Worker custom domain in the dashboard (Workers & Pages → the Worker → Settings → Domains), and that a proxied `files` DNS record exists
- [x] **C6** Verify: `curl -sI https://files.cyberjayahappenings.me/<key>.webp` twice, with a real rekeyed key. **The second response must show `x-cache: HIT` — the Worker's own header, not `cf-cache-status`,** which is not reliable for a response served out of the Cache API. Confirm `cache-control: public, max-age=31536000, immutable`, `content-type: image/webp`, an `etag`, and no `x-amz-*`/`x-bz-*`. A malformed path returns 404, a `POST` returns 405, and a well-formed key that does not exist returns 404 with `cache-control: public, max-age=60`. The apex `/up` still returns 200
- [ ] **C7** Set `PUBLIC_IMAGE_BASE_URL=https://files.cyberjayahappenings.me` in `.env` on the box, and restart the app · §3
- [x] **C8** *(cleanup, done after C6 passed)* Removed the one-off rekey task, `ImageRekeyer`, its tests, and `ObjectStore#copy`/`#exists?` in one commit; the runbook's live rekey commands are now a past-tense note (2026-09-30, 316 rows rekeyed, 5 failed, tooling last present at `8ab89a171e44018cb17ff7c26b7916faa9d18fae`). Keep `~/images-before-rekey.sql` for a few days, then delete it. **The old extensionless B2 objects were not deleted**

## 10. Known, deliberately

Backups are out of scope (Instagram is the source of truth, a re-scrape is the recovery); `clubsync:snapshot` is dev-oriented with no rotation and no off-box copy. Kamal is in the Gemfile with a live `bin/kamal` but `config/deploy.yml` is untouched scaffold (`your-user`, `192.168.0.1`, `app.example.com`, a `/rails/storage` volume against an image that uses `/app`) and `.kamal/secrets` reads a `config/master.key` that doesn't exist — deleting it is cheaper than leaving it to mislead. CI is not a deploy pipeline, and it can't catch blocker 4 because the test env uses `:null_store` with no queue adapter.

Worth stating positively: the **Tailwind v4 pipeline is built and working** (`app/assets/tailwind/application.css` → `app/assets/builds/tailwind.css`, 13.5 KB of real scanned utilities, wired in the layout, watcher in `Procfile.dev`, precompiled in the `Dockerfile`; ADR `2026-09-25-css-first-tailwind-v4-pipeline`). That's what blocker 6 destroys, and it means the deferred pages already have their CSS.
