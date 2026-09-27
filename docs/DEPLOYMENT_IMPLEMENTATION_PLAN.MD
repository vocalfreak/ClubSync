# ClubSync — Public Site & Admin Review Worklist

*Elaborates the master plan's Phase 5. Decided this session: Namecheap `.me` domain (via GitHub Student Pack) + Cloudflare Tunnel for the public path. Tailscale stays admin-only — the two paths should never overlap.*

## 1. Domain & DNS

- Claim the domain: `nc.me/landing/github` (GitHub Student Pack) → get `<name>.me`, free for the first year, free SSL cert bundled (though the cert ends up unused here — Cloudflare's edge issues and terminates its own).
- Add the site to Cloudflare (free plan). Cloudflare assigns two nameservers.
- In Namecheap: Domain List → Manage → Nameservers → Custom DNS → paste Cloudflare's two nameservers.
- Wait for propagation (minutes to ~24h) — confirm via the Cloudflare dashboard showing the zone as "Active."
- From this point on, Namecheap is purely the registrar of record. Every actual DNS record (the tunnel's CNAME, anything else) is managed in Cloudflare's dashboard, not Namecheap's — that split is the thing worth internalizing, not just clicking through.

## 2. Cloudflare Tunnel — one-time creation

- Cloudflare Zero Trust dashboard → Networks → Tunnels → Create a tunnel, or via CLI:
```
cloudflared tunnel login
cloudflared tunnel create clubsync
```
- Creating the tunnel generates a credentials file (`<tunnel-id>.json`). Give it the same treatment as `.env`: git-ignored, `chmod 600`, transferred once via `scp` over the Tailscale IP.
- Route DNS to the tunnel — this auto-creates the CNAME in Cloudflare DNS:
```
cloudflared tunnel route dns clubsync events.<yourdomain>.me
```
- Ingress config (`~/.cloudflared/config.yml` on the E5440):
```yaml
tunnel: clubsync
credentials-file: /home/<user>/.cloudflared/<tunnel-id>.json

ingress:
  - hostname: events.<yourdomain>.me
    service: http://localhost:3000
  - service: http_status:404
```
- `http://localhost:3000` is the app's Compose-exposed port. *Why* that's bound to `127.0.0.1` only, and how `cloudflared` stays running persistently (systemd service), are deployment concerns — see the separate deployment doc, not duplicated here.

## 3. Rails config (`config/environments/production.rb`)

- `config.assume_ssl = true` and `config.force_ssl = true` — correct now that Cloudflare's edge terminates TLS, not the Rails process. Same three-hop model as ProPro (browser → Cloudflare edge → tunnel → origin), different reverse proxy.
- `config.hosts << "events.<yourdomain>.me"` — Rails' host-authorization allowlist. Without this, Rails returns a 403 for a host it doesn't recognize, even though the tunnel is routing correctly.
- Confirm the generated production boilerplate does **not** configure ActiveStorage `:local` (unused — B2 goes through the custom `ObjectStore`) or a Mailgun/mailer block (no email in ClubSync). Leave both out rather than configuring and disabling them.

## 4. Public pages (no auth)

Route + controller for browsing confirmed events. **This is blocked on the open `events`-table question** flagged in the master plan — whether "confirmed event" data lives directly on `posts` (`is_event`, `stage`) or in a separate `events` table joined to `posts` changes the query shape entirely. Sketch, assuming the former, so there's something concrete to react to:

```ruby
# app/controllers/events_controller.rb — sketch, pending the events-table decision
class EventsController < ApplicationController
  def index
    @posts = Post.where(is_event: true, stage: :extracted).order(posted_at: :desc)
  end
end
```

If the `events` table turns out to be the real store, this becomes `Event.joins(:post).where(...)` instead. Don't build the view layer directly against `posts` columns until that's settled — it's a rewrite later, not an extension, if it goes the other way.

## 5. Public "report this is wrong" action

Same open dependency as §4 — what gets flagged needs somewhere to record it. Two honest options, not a decision:

- **(a)** columns directly on `posts`/`events` (`flagged_at`, `flag_reason`)
- **(b)** a small standalone `flags` table (`post_id`/`event_id`, `reason`, `created_at`) — better if more than one flag per post, or flag history, ever matters

Whichever it is: a simple unauthenticated `POST`, rate-limited (§6), marking the post/event as needing human attention — feeding into the *same* admin surface as everything else needing review, not a separate workflow (already decided in the master plan).

## 6. Rack::Attack

```ruby
# config/initializers/rack_attack.rb
class Rack::Attack
  throttle("flag-endpoint/ip", limit: 5, period: 1.minute) do |req|
    req.ip if req.post? && req.path.match?(%r{\A/events/\d+/flag})
  end

  throttle("public-routes/ip", limit: 60, period: 1.minute) do |req|
    req.ip unless req.path.start_with?("/admin")
  end
end
```
Add `gem "rack-attack"`; recent versions auto-insert the middleware, otherwise `config.middleware.use Rack::Attack` in `application.rb`. The limits above are starting points — cheap to retune once real traffic shows up.

## 7. Admin/review surface (HTTP Basic Auth)

```ruby
# app/controllers/admin/base_controller.rb
module Admin
  class BaseController < ApplicationController
    http_basic_authenticate_with name: ENV.fetch("ADMIN_USERNAME"), password: ENV.fetch("ADMIN_PASSWORD")
  end
end
```
`ADMIN_USERNAME`/`ADMIN_PASSWORD` in `.env`, same secrets handling as everything else.

What it shows — decided vs. open:
- **Decided, buildable now:** stalled posts — `Post.where.not(last_error: nil)`. Doesn't depend on anything unresolved.
- **Open:** posts flagged for review via per-field confidence or the public flag action — depends on the same events/confidence-storage question as §4/§5.

## 8. Order of operations

1. Claim domain (Namecheap)
2. Add to Cloudflare, delegate nameservers, wait for propagation
3. Create tunnel + route DNS
4. `production.rb` changes, deploy
5. `cloudflared` running (deployment doc) pointed at the app's Compose-exposed port
6. Verify `https://events.<domain>.me` actually reaches the app **before** building public pages against it — much easier to debug the tunnel with a stock Rails welcome page than with a half-built controller in the way
7. Build public pages → Rack::Attack → admin surface, in that order — each layer benefits from the previous one already existing


# ClubSync — Deployment (E5440, Docker Compose, Cron, Ops)

*Elaborates the master plan's compute/orchestration and Phase 1 containerization items. Covers everything that keeps the app actually running on the box — not the public-site/domain work, which is its own doc.*

## 0. What's being deployed, where

Self-hosted on the revived Dell Latitude E5440, which also runs ProPro's *staging* environment — separate containers, separate Postgres, isolated Docker networks. No Kubernetes, no CI/CD pipeline for this project — deliberately minimal: a cron-triggered batch job plus a small public Rails app.

## 1. Docker Compose layout

```
clubsync/
├── docker-compose.yml
├── Dockerfile
├── .env                # git-ignored, chmod 600
└── ...
```

```yaml
# docker-compose.yml
services:
  app:
    build: .
    env_file: .env
    ports:
      - "127.0.0.1:3000:3000"   # localhost-only -- cloudflared is the only thing that should ever reach this
    depends_on:
      - db
    networks:
      - clubsync

  db:
    image: postgres:17
    env_file: .env
    volumes:
      - clubsync_pg_data:/var/lib/postgresql/data
    networks:
      - clubsync
    # no ports: mapping here -- db is reachable only from app, via the clubsync network, never from the host directly

networks:
  clubsync:
    name: clubsync_net   # distinct name so it can't collide with ProPro staging's compose network

volumes:
  clubsync_pg_data:
```

The one line that matters most: `127.0.0.1:3000:3000`, not `0.0.0.0:3000:3000` or bare `3000:3000`. Binding to localhost means the only way in from outside the box is through `cloudflared` — that's the entire point of a tunnel instead of directly exposing a port, and it's easy to silently lose that guarantee with a copy-pasted Compose file. The explicit `networks:`/named volume keep this stack from ever colliding with ProPro staging's compose project on the same host, even though both run Postgres.

## 2. Secrets

- `.env` — git-ignored, `chmod 600`. The same file backs both `env_file:` directives above: Postgres reads `POSTGRES_USER`/`POSTGRES_PASSWORD`/`POSTGRES_DB`, Rails reads `DATABASE_URL`, the Apify token, B2 credentials, the Gemini API key, `ADMIN_USERNAME`/`ADMIN_PASSWORD`, and the healthchecks.io ping URL.
- Transferred once via `scp` over the Tailscale IP, never committed — matches the account-level decision already made for ClubSync generally.
- The `cloudflared` tunnel credentials file (`<tunnel-id>.json`, created in the public-site doc) gets identical treatment: `chmod 600`, `scp`'d over Tailscale, git-ignored.

## 3. Cron via the `whenever` gem

```ruby
# config/schedule.rb
every 2.days, at: "3:00 am" do
  # stagger across the 41 accounts inside the rake task itself (e.g. a
  # sleep/spread between each account's Apify call), not via multiple
  # cron lines -- keeps this schedule file simple and the staggering
  # logic in Ruby where it's testable
  runner "ClubSync::Ingestion.run_all", output: "log/cron.log"
end
```

`whenever --update-crontab` runs on the **host**, not inside a container — it writes directly to the host's crontab, which then shells into Docker:

```
0 3 */2 * * cd /path/to/clubsync && /usr/bin/docker compose exec -T app bin/rails runner 'ClubSync::Ingestion.run_all' >> /path/to/clubsync/log/cron.log 2>&1
```

`-T` disables pseudo-TTY allocation for `docker compose exec` — cron has no TTY, and this call fails without it. Re-run `whenever --update-crontab` any time `schedule.rb` changes; it isn't applied automatically.

## 4. `cloudflared` as a persistent service

Tunnel creation, DNS routing, and the ingress config are covered in the public-site doc — this is just "keep it running":

```
sudo cloudflared service install
sudo systemctl enable --now cloudflared
systemctl status cloudflared   # confirm it's back up after any reboot
```

Runs as a systemd service directly on the host, not containerized — the simplest way to guarantee it survives a reboot without wiring it into the Compose stack.

## 5. Health monitoring delivery

healthchecks.io ping at the end of a successful ingestion run:
```ruby
# at the end of ClubSync::Ingestion.run_all, on success
Net::HTTP.get(URI(ENV.fetch("HEALTHCHECKS_PING_URL")))
```
Missed-ping alerting: healthchecks.io's native Telegram integration (connect the bot, `/start`, no custom bot code) — **this is the confirmed decision from the master plan.**

A note worth flagging rather than silently resolving: a separate, still-open question (posed earlier, not yet answered) mentioned a possible `DiscordNotifier` as part of a larger `IngestionRunner` health-object set. If that direction gets picked instead, this section needs revisiting — as it stands, healthchecks.io + Telegram is the only thing actually decided, and it's what this doc builds against.

## 6. Coexistence with ProPro staging

Separate compose project, separate Postgres container/volume, separate Docker network (§1) — no shared state between the two. Spot-check resource contention under real concurrent load with `docker stats` / `htop` once both have been running for a while — this was flagged as an intent to verify, not something to just assume holds indefinitely.

## 7. Tailscale (admin access only)

Already set up per the master plan: SSH into the E5440 from anywhere, no port-forwarding; lid-close sleep disabled. Strictly separate from the public path in §4 of the public-site doc — nothing about the Cloudflare Tunnel setup should also be reachable over the tailnet-only path, and vice versa. Conflating Serve/Funnel/reverse-proxy layers is a common, very debuggable-in-hindsight source of "which hop is actually broken" confusion — worth keeping the two paths mentally (and configurationally) separate from day one.

## 8. First-deploy order of operations

1. Provision Docker + Compose on the E5440 (if not already there)
2. `scp` `.env` + the tunnel credentials file over Tailscale
3. `docker compose up -d`, then run migrations: `docker compose exec app bin/rails db:migrate`
4. Install `cloudflared` as a systemd service, confirm the tunnel reaches the app (public-site doc, §8 step 6)
5. `whenever --update-crontab` on the host
6. Trigger one ingestion run manually first (`docker compose exec app bin/rails runner ...`) before trusting cron to do it unattended
7. Confirm a healthchecks.io ping actually lands after that manual run
8. Confirm ProPro staging's containers are unaffected (`docker stats`)