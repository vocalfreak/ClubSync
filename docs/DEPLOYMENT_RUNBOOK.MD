# Deployment Runbook — E5440

Ordered, copy-pasteable. `DEPLOYMENT_IMPLEMENTATION_PLAN.MD` is *why* each step exists; this file is *what to type*, in order, with a stop-gate at each risky point. Read it once before starting — do not run steps out of order, because out-of-order failures are ambiguous.

**State (2026-10-01): the deploy is DONE and verified.** A1–A7, B1–B8 (including the `www` redirect) and C0–C8 are complete: the app serves `https://cyberjayahappenings.me/up` → 200 through the `clubsync` tunnel, the host crontab runs `clubsync:ingest` every 2 days, healthchecks.io is verified with its `#clubsync-alerts` Discord integration, and images come from `https://files.cyberjayahappenings.me` via the Worker over a **private** B2 bucket (`x-cache: HIT` on a repeat request). This file is kept as the **re-run path** for a rebuilt box, not as a worklist — every step below has been executed at least once. C0's one-off rekey (Step 4b) also already ran: 316 rows rekeyed, 5 junk rows failed, no live rekey step remains.

---

## Step 0 — Fill in these four things

Substitute as you go, or edit them into this file.

| Placeholder | What it is | How to find it |
|---|---|---|
| `APP_ROOT` | Absolute path to the checkout on the box | The plan and `config/schedule.rb` both default to `/srv/clubsync` — **probably wrong, confirm it** |
| `BOX_USER` | Your user on the box | `whoami` over SSH |
| `DB_PASSWORD` | Password for the Postgres `clubsync` role | You choose it in Step 2 |
| `TUNNEL_UUID` | Cloudflare tunnel ID | Printed by Step 5 |

Confirm before you touch anything:

```
which docker          # Step 11 needs this to be /usr/bin/docker
git -C $APP_ROOT remote -v   # is the box's clone wired to a git remote?
```

---

## Phase 1 — The app on the box

Before touching Cloudflare. The tunnel is only worth wiring up once the origin is known to answer — otherwise a public 502 has three candidate causes instead of one.

### Step 1 — Get the A1 code onto the box

**The step people skip, and skipping it is worse than it sounds.** A1 is not committed yet, so the box's clone still has the Solid gems that make production fail to boot and the `.:/app` bind mount that hides missing assets. Run Step 3 now and you are testing the broken version — and with the bind mount still present it will half-work and tell you nothing.

**Recommended: commit, then pull.** On your WSL machine:

```
git add -A && git commit -m "Deploy prep: drop Solid gems, fix production boot, set hosts"
```

Then on the box: `git pull`.

If the box has no git remote, copy the working tree instead:

```
rsync -av --exclude .git --exclude .env --exclude log --exclude tmp \
  ./ $BOX_USER@$BOX_HOST:$APP_ROOT/
```

`--exclude .env` matters: the box needs its own production `.env` (Step 2), not your dev one. No remote and no rsync? `scp` the changed files individually — the list is in the plan's A1 table.

### Step 2 — Write the production `.env`

On the box, in `$APP_ROOT/.env`. This is a **new, separate file** from your WSL one: the production values don't exist in your dev file, and your B2/Gemini/Apify credentials may differ per environment. Do not copy the dev `.env` over.

```bash
cd $APP_ROOT
bin/rails secret    # copy the output into SECRET_KEY_BASE below
```

```
SECRET_KEY_BASE=<paste>
POSTGRES_PASSWORD=<pick one>
DATABASE_URL=postgres://clubsync:<same password>@db/clubsync_production
DISCORD_ALERT_WEBHOOK_URL=<the #clubsync-alerts webhook>
```

Four things to get right:

- **`DATABASE_URL` host is `db`, not `localhost`.** The app reaches Postgres over the compose network, and compose publishes no database port at all.
- **The password in `DATABASE_URL` and `POSTGRES_PASSWORD` must match.** Compose interpolates the latter into the db service; the former is what the app authenticates with.
- **`DISCORD_ALERT_WEBHOOK_URL` is separate from `DISCORD_LOG_WEBHOOK_URL`.** The log webhook works; the alert one is empty today, so detected Gemini outages are logged and silently dropped. Same Discord, different channels.
- Then `chmod 600 .env .env.development .env.test`.

**Set `SECRET_KEY_BASE` once and never regenerate** — rotating invalidates every active session.

### Step 3 — First boot · **STOP GATE**

```bash
cd $APP_ROOT
docker compose up -d --build
```

The first build takes a while: `bundle install`, then `assets:precompile` (which also builds Tailwind). Ignore it, but watch for it to *finish successfully* — the precompile step boots the app, and is a real test.

Then, **on the box** (not WSL):

```bash
curl -I http://127.0.0.1:3010/up
```

**Expect `HTTP/1.1 200 OK`.** Two things that look like failures but aren't:

- **Connection-refused from WSL is expected.** Compose binds `127.0.0.1:3010` deliberately. It says nothing about the deploy.
- **A 200 is expected, not a redirect.** `assume_ssl = true` makes Rails treat every request as HTTPS.

**If this is not a 200, stop.** Everything after assumes a working origin, and debugging a tunnel against a broken app is miserable.

```bash
docker compose ps
docker compose logs --tail=50 app
docker compose exec app bin/rails runner 'puts Rails.env'   # must print "production"
```

If that last one prints `development`, the image is stale — Step 1 didn't land.

### Step 4 — Prove the pipeline actually runs

```bash
docker compose exec app bin/rails clubsync:ingest
```

Watch it to completion, then confirm two side effects: a run summary reached `#clubsync-log` (`DISCORD_LOG_WEBHOOK_URL`, already working), and a ping landed in healthchecks.io — check the check's log, the UUID is `HEALTHCHECKS_PING_URL` in `.env`.

This is the first point where Gemini, Apify, B2 and Discord are exercised together. A successful `/up` proves none of them.

✅ **C0 has landed** (2026-09-30) — `ObjectStore#put` derives the key's extension from `content_type`, so this run writes `<sha256>.webp` keys to the fresh prod bucket and every image URL is edge-cacheable once Track C is up. Nothing to do here; keys are permanent on a new bucket, so this is the run where that mattered.

### Step 4b — Rekey completed (2026-09-30)

The one-off rekey of images written before C0 landed ran on 2026-09-30. **316 rows rekeyed, 5 failed** (the failures were the pre-existing junk rows with nil byte sizes: `k`, `kA1`, `kA2`, `kB1`, `kB2`, ids 317–321). The task copied each object to `<sha256>.webp` (by content-type) and repointed rows only after a confirming `head_object`. Old extensionless objects remain in B2 and were never deleted. The tooling (`ImageRekeyer`, `clubsync:rekey_images`, `ObjectStore#copy`/`#exists?`) existed at commit `8ab89a171e44018cb17ff7c26b7916faa9d18fae` and was removed in a later cleanup commit; no live rekey is needed going forward.

---

## Phase 2 — The tunnel

Only now. B5 was the first step that actually required the Active zone.

**No inbound ports need opening.** `cloudflared` dials *out* to Cloudflare's edge, so the box can sit behind CGNAT on a residential connection with no router changes. If the service starts but never connects, the cause is outbound filtering (port 7844), not a missing port forward. Expect the tunnel to appear in the dashboard under **Zero Trust → Networks → Tunnels** even though the CLI created it.

### Step 5 — Create the tunnel

On the box, over Tailscale:

```bash
cloudflared tunnel login
```

Prints a URL and waits. The box is headless — **open that URL in your desktop browser** and authorise. The certificate lands on the box, not your browser.

```bash
cloudflared tunnel create clubsync
```

Prints a UUID and the path to the credentials JSON. That UUID is `TUNNEL_UUID`.

### Step 6 — Route DNS

```bash
cloudflared tunnel route dns --overwrite-dns clubsync cyberjayahappenings.me
```

**`--overwrite-dns` is required, not a convenience.** The apex already carried proxied A/AAAA records, so without the flag this fails with `An A, AAAA or CNAME record already exists with that host`. It creates the CNAME to `<uuid>.cfargotunnel.com` and replaces those records.

**The flag touches only the apex.** `www` is a separate record, handled in Step 6b — if the old `www` records are still present they will keep serving whatever they served before, and nothing here changes them.

Quick check (this box has no `dig`; use `getent`):

```bash
getent hosts cyberjayahappenings.me
```

### Step 6b — Redirect `www` to the apex · Cloudflare UI only

No tunnel change, no `config.hosts` change. The app only ever sees the apex, so `www` never reaches it.

1. **Ensure a proxied (orange cloud) `www` record exists.** If the old ones are gone, an `AAAA` record to `100::` is enough — a redirect-only hostname never needs a real origin.
2. **Rules → Redirect Rules → Single Redirect.** Host equals `www.cyberjayahappenings.me`; dynamic target `concat("https://cyberjayahappenings.me", http.request.uri.path)`; **status 302 to start**; preserve query string on.
3. **Verify, then harden to 301:**

```bash
curl -I https://www.cyberjayahappenings.me/anything
```

Expect a redirect whose `location:` header is `https://cyberjayahappenings.me/anything` — the path must be preserved, or you have built a rule that drops every path. Once that passes, switch the status to 301 and re-run the same curl.

### Step 7 — Write the ingress config

Write it straight into `/etc/cloudflared/`, which is where the service will read it from:

```bash
sudo mkdir -p /etc/cloudflared
sudo nano /etc/cloudflared/config.yml
```

```yaml
tunnel: $TUNNEL_UUID
credentials-file: /etc/cloudflared/$TUNNEL_UUID.json
ingress:
  - hostname: cyberjayahappenings.me
    service: http://localhost:3010
  - service: http_status:404
```

**`credentials-file` must be an absolute path into `/etc/cloudflared/`.** Left pointing at a home directory — a valid path for a root service to read — it starts, authenticates with no tunnel, and fails quietly.

**`localhost:3010`, not `3000`.** Compose publishes host 3010 → container 3000; 3000 is the image's `EXPOSE` and what Puma binds *inside* the container. A tunnel on the wrong port authenticates, connects, routes, and returns nothing.

The catch-all `http_status:404` is required — ingress rules match in order and the last must be the fallback.

You also need a copy at `~/.cloudflared/` if you want the CLI (`cloudflared tunnel list`, `route dns`, `delete`) to find its config. Two copies will drift; **`/etc/cloudflared/config.yml` is canonical**, since that is what the service reads.

### Step 8 — Install as a service

Copy the credentials into the system location, then install:

```bash
sudo cp ~/.cloudflared/$TUNNEL_UUID.json /etc/cloudflared/
sudo chmod 600 /etc/cloudflared/$TUNNEL_UUID.json

sudo cloudflared --config /etc/cloudflared/config.yml service install
sudo systemctl enable --now cloudflared
systemctl status cloudflared
journalctl -u cloudflared -n 30 --no-pager
```

**`--config` is passed explicitly, on purpose.** `sudo` sets `$HOME=/root`, which is how cloudflared loses track of a config it found as your user; the bare command works only by falling back to run-time search order. Passing the path makes the systemd unit unambiguous and matches Cloudflare's own guidance for the sudo case. (An earlier draft of this runbook claimed the bare command was fine in the step and blamed a *missing* `--config` in the troubleshooting table — both cannot be true, and the table was wrong.)

The upside of `/etc/cloudflared/` over `~/.cloudflared/`: the tunnel survives removal of the user account or a restructured home directory.

### Step 9 — Public check · **STOP GATE**

From anywhere, including WSL:

```bash
curl -I https://cyberjayahappenings.me/up
```

**Expect `200`.** A `502` here with a working Step 3 means the tunnel can't reach `localhost:3010` — check Step 7 (3010, not 3000) and Step 8. This is the first moment the whole chain is proven: DNS → Cloudflare edge → tunnel → cloudflared → `127.0.0.1:3010` → Puma.

No ordering constraint against Phase 4 is needed here: zone SSL mode does not govern a tunnel hostname at all, since the edge→origin hop is the tunnel's own encrypted channel.

---

## Phase 3 — Cron and alerting

### Step 10 — Point the schedule at the real path

```bash
cd $APP_ROOT
grep -n 'APP_ROOT =' config/schedule.rb
```

Edit it to your actual path (and `DOCKER` if `which docker` wasn't `/usr/bin/docker`), then commit. Check the rendering before installing:

```bash
bundle exec whenever
```

**Expect one line, and read it:**

```
0 3 1,3,5,7,... * * /bin/bash -l -c 'cd $APP_ROOT && /usr/bin/docker compose exec -T app bin/rails clubsync:ingest >> $APP_ROOT/log/cron.log 2>&1'
```

`1,3,5,…` looks alarming — it is `every 2.days` rendered as *odd days of the month*, not "every 48 hours". The longest gap it can produce is exactly 2 days, matching the healthchecks period, so a missed-ping alert can't fire spuriously. Across a month boundary it can run *more* often (Jan 31 → Feb 1 is 24 hours). Harmless.

### Step 11 — Install the crontab · **on the host**

```bash
gem install whenever        # host gem, not in the container
cd $APP_ROOT
whenever --update-crontab
crontab -l
```

Two traps:

- **Never run this inside the container.** It writes a crontab into the container's own filesystem, discarded on the next rebuild — and it will look like it worked.
- **`whenever` must be on the host.** It ships in the app's bundle, which is inside the container.

`ls $APP_ROOT/log/` should show `cron.log` or `.keep`, or the redirect in Step 10 writes nowhere.

### Step 12 — Wire up missed-ping alerts

Web UI at healthchecks.io, not code. The check **already exists** — a live `hc-ping.com` UUID is in `.env`.

- Confirm **period 2 days, grace 1 hour** on check `clubsync-ingest`. One decision with the cron time in Step 10; if they disagree, every run is a false "missed ping".
- **Integrations → Discord** → add the `#clubsync-alerts` webhook. healthchecks.io posts the alert itself, so there is no Ruby involved. Same webhook as `DISCORD_ALERT_WEBHOOK_URL` in Step 2.

Do not create a second check.

---

## Phase 4 — The image host (Track C)

Independent of the tunnel and the app: a Cloudflare Worker reading a **private** B2 bucket. Needed before the deferred public pages, not before the deploy. Safe to run any time, including while Phase 3 is pending. Images go browser → Cloudflare → Worker → B2 and never touch the box.

**The bucket stays private.** Making a B2 bucket public requires a payment method on file, which is the one thing this account is avoiding; Workers and B2 application keys are both card-free. The Worker signs reads with a read-only key restricted to that one bucket, and only ever asks B2 for a path matching `^/[a-f0-9]{64}\.webp$` — so the credential at the edge cannot be pointed at anything else. See `docs/adr/2026-09-30-private-b2-behind-a-cloudflare-worker.md`.

Steps 13–15 run on **your machine** (in this checkout), not on the box. Step 16 verifies from anywhere.

### Step 13 — B2 read key · **do not paste these anywhere**

Backblaze → **App Keys → Add Key**:

- **Name:** `clubsync-image-proxy-read`
- **Capabilities:** `Read Files` **only**
- **Bucket restriction:** restrict to this one bucket. Include `Read Bucket` too — on a cache miss the Worker issues a `HEAD` to check existence, which needs bucket-level read
- **TTL:** leave empty (non-expiring)

**Leave the bucket itself private.** Nothing in this step sets it to Public.

⚠️ **The application key is shown exactly once.** Copy it somewhere you will paste from locally (a password manager) — not chat, not an issue, not the repo. Never reuse `B2_KEY_ID`/`B2_APPLICATION_KEY` from `.env`: those are the app's upload key, and a copy-paste between the two is a silent privilege upgrade that also breaks rotation.

You need four values: key ID, application key, bucket name, S3 endpoint, region. The last three already exist in `.env` as `B2_BUCKET`, `B2_ENDPOINT`, `B2_REGION` — copy them into `wrangler.toml`.

### Step 14 — Configure, test locally, deploy

```bash
cd workers/image-proxy
npm install

cp .dev.vars.example .dev.vars    # then paste the key ID and application key into it
npm test                          # 30 vitest cases, no network — always run this

npx wrangler dev                  # optional: serve locally against the real bucket
npx wrangler login                # browser OAuth, or use a scoped API token via CLOUDFLARE_API_TOKEN
npx wrangler secret put B2_READ_KEY_ID
npx wrangler secret put B2_READ_APP_KEY   # paste; not echoed, not in shell history
npx wrangler deploy
```

Check the three non-secret values in `wrangler.toml` against your `.env` before deploying: `B2_BUCKET`, `B2_REGION`, and `B2_ENDPOINT` — which must be the **S3-compatible** host (`https://s3.<region>.backblazeb2.com`), not the friendly `fXXX` host. A wrong one is a 502 at the edge rather than an error in the app.

`secret put` is per-environment. If the Worker is later run in production mode, set both secrets again with `npx wrangler secret put --env production`.

`workers_dev = false` is deliberate: the Cache API only works on a Cloudflare-attached domain, so testing through `*.workers.dev` would appear to work while every request silently missed the cache.

### Step 15 — Confirm the custom domain · **STOP GATE**

`wrangler.toml` carries the route, so **the first deploy creates the `files` DNS record automatically** — there is no CNAME to add by hand.

Check it in the dashboard:

- **Workers & Pages → `image-proxy` → Settings → Domains** shows `files.cyberjayahappenings.me` as **Active**
- **DNS → Records** has a proxied `files` record (orange cloud). A custom-domain Worker needs it proxied — grey means Cloudflare is not in the request path at all

No SSL/TLS mode change, and no Signed Exchanges setting: the Worker→B2 hop is its own signed HTTPS request from Cloudflare's edge, and neither zone setting governs it.

### Step 16 — Verify · **STOP GATE**

Take a real rekeyed key from the B2 file list (they end in `.webp`; Step 4b rekeyed them on 2026-09-30) rather than computing a hash, so you are testing an object that definitely exists:

```bash
curl -sI https://files.cyberjayahappenings.me/<sha256>.webp
curl -sI https://files.cyberjayahappenings.me/<sha256>.webp   # again
```

**On the second call, expect:** `x-cache: HIT` — the Worker's own header, and the direct evidence that repeat views have stopped spending B2's Class B transactions · `cache-control: public, max-age=31536000, immutable` · `content-type: image/webp` · an `etag` · no `x-amz-*` or `x-bz-*` headers.

**Read `x-cache`, not `cf-cache-status`.** `cf-cache-status` is not reliable for a response served out of the Cache API, and it will mislead you.

| What you see | Meaning | Where to look |
|---|---|---|
| `x-cache: HIT` on the second call | Working. Stop here | — |
| `x-cache: MISS` on both calls | Serving, but nothing is being stored | Cache API unavailable — almost always a DNS-only record or a `workers.dev` URL |
| `502` | B2 refused or failed the signed request | `npx wrangler tail`, then the `B2_*` vars and the two secrets |
| `502` for an image the app shows fine | The Worker reads the same private bucket with a *different* credential | Confirm `B2_READ_*` is the Step 13 key, not the upload key |
| `404` for a key you can see in B2 | Extensionless key (one of the 5 rows Step 4b could not rekey), or the object is genuinely absent | Re-run nothing — check the row's `b2_key` ends in an extension |
| `404` on `/nope` | Correct — the path regex rejects it before any B2 call | — |
| `405` on `POST /<key>.webp` | Correct — only GET/HEAD are served | — |

Then confirm the app itself is untouched: `curl -sI https://cyberjayahappenings.me/up` still returns `200`.

### Step 17 — Point the app at the Worker

Only after Step 16 passes:

```bash
echo 'PUBLIC_IMAGE_BASE_URL=https://files.cyberjayahappenings.me' >> $APP_ROOT/.env
cd $APP_ROOT && docker compose up -d
```

`get_url` prefers this and falls back to the raw B2 URL when blank, so nothing breaks if you skip it — you just get URLs no browser can load, because the bucket is private.

---
---

## When something breaks

| Symptom | Almost certainly |
|---|---|
| `curl` from WSL → connection refused | Expected. The port is loopback-only on the box; run it over SSH |
| `/up` 502 publicly, but 200 on the box | Tunnel can't reach the app. Check Step 7 (`3010`, not `3000`) and Step 8 (`--config`) |
| `route dns` fails with "record already exists" | Missing `--overwrite-dns`, Step 6 |
| `www` doesn't redirect, or the path vanishes | The Redirect Rule in Step 6b, not the tunnel |
| `/up` 200 publicly but the page is unstyled | Assets missing. `docker compose logs app` for a precompile failure; confirm no `.:/app` crept back in |
| `Rails.env` is `development` in the container | Pre-A1 image. Redo Step 1 and rebuild |
| Cloudflared service starts, no tunnel | `credentials-file` still points at a home directory, or `--config` was omitted in Step 8 |
| Cron never runs, `cron.log` empty | `whenever` ran in the container, or `APP_ROOT` is wrong, or `docker` isn't at the path in `schedule.rb` |
| healthchecks "missed ping" despite runs | Cron time and healthchecks period disagree — Steps 10 and 12 are one decision |
| `files.…` 502s | The Worker reached B2 and was refused — `npx wrangler tail`, then the `B2_*` vars and the two secrets (Steps 13–14) |
| `x-cache: MISS` on repeat requests | The Cache API isn't storing. Almost always a DNS-only `files.` record, or you tested via `workers.dev` (Steps 14–15) |
| `files.…` 404s for keys you can see in B2 | The key is extensionless — one of the 5 rows Step 4b's rekey could not fix — so the Worker's path regex rejects it |
| `files.…` returns HTML or a challenge | Bot Fight Mode / Security Level serving a non-browser client a challenge. The deferred uptime monitor would hit this; `curl -sI` from a script should not |
| App edits have no effect | No bind mount any more. `docker compose up -d --build` |

## Two things to do once, later

- **The domain is free for year one** via the GitHub Student Pack, and the hostname dies with the domain — a lapse takes the whole public path down. Recurs annually.
- **When you rename the codebase**, `config.hosts` in `config/environments/production.rb` and `PUBLIC_IMAGE_BASE_URL` are the two values holding the current domain. `grep -rn cyberjayahappenings.me` finds them both.
