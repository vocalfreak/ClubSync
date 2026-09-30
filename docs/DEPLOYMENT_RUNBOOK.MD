# Deployment Runbook — E5440

Ordered, copy-pasteable. `DEPLOYMENT_IMPLEMENTATION_PLAN.MD` is *why* each step exists; this file is *what to type*, in order, with a stop-gate at each risky point. Read it once before starting — do not run steps out of order, because out-of-order failures are ambiguous.

**State:** A1 (repo fixes) done and verified locally. B1–B3 done (domain `cyberjayahappenings.me`, Cloudflare zone **Active**). Everything below is unticked. C0 — the image-key extension fix — is **specified (plan, Track C) but not yet applied**, and must land before Step 4, the first run that writes prod images.

---

## Step 0 — Fill in these five things

Substitute as you go, or edit them into this file.

| Placeholder | What it is | How to find it |
|---|---|---|
| `APP_ROOT` | Absolute path to the checkout on the box | The plan and `config/schedule.rb` both default to `/srv/clubsync` — **probably wrong, confirm it** |
| `BOX_USER` | Your user on the box | `whoami` over SSH |
| `DB_PASSWORD` | Password for the Postgres `clubsync` role | You choose it in Step 2 |
| `TUNNEL_UUID` | Cloudflare tunnel ID | Printed by Step 5 |
| `B2_FRIENDLY_HOST` | The `fXXX.backblazeb2.com` host | Step 13. **Not** the `B2_ENDPOINT` in `.env` — that's the S3 host |

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

Independent of the tunnel and the app — pure Cloudflare config. Needed before the deferred public pages, not before the deploy. Safe to run any time, including while Phase 3 is pending. Per [Backblaze's walkthrough](https://www.backblaze.com/blog/free-image-hosting-with-cloudflare-transform-rules-and-backblaze-b2/) — no app route, no Ruby. Images go browser → Cloudflare → B2 and never touch the box.

### Step 13 — Bucket is public

Backblaze → Buckets → your bucket → **Public**. Note the **friendly** hostname from a file's details (`fXXX.backblazeb2.com`) — that's `B2_FRIENDLY_HOST`. **Do not use `B2_ENDPOINT`** from `.env`: that reads `https://s3.us-west-004.backblazeb2.com`, the S3-compatible API host, and the Step 15 rewrite prepends `/file/<bucket>`, which only makes sense against the friendly host.

### Step 14 — DNS

DNS → Add record: CNAME, name `files`, target `B2_FRIENDLY_HOST`.

**Confirm the record is proxied (orange cloud), not DNS-only.** New CNAMEs default to proxied, so it usually is — but check, because nothing else in this track will tell you. Grey means Cloudflare isn't in the request path: no Transform Rules, no cache-control rewrite, no ETag, no CORS, no path rewrite. Raw B2 responses, uncached, and every page view spends a Class B transaction. **The entire reason this track exists is the orange cloud.**

**Expect a 522 right now** — Cloudflare fetches upstream over plain HTTP by default and B2 is HTTPS-only. That is the article's intended intermediate state, not a failure.

⚠️ **Do not "fix" the 522 by turning the proxy off.** It is the natural reflex and the one move that destroys this track permanently and invisibly: the 522 goes away and so does the edge caching. The real fix is Step 15.

### Step 15 — SSL mode, SXG, and the four Transform Rules

**SSL/TLS → Overview → encryption mode: confirm `Full (strict)` or `Full`, not `Flexible`.** Flexible is what causes the 522.

⚠️ *Before changing anything, look at what it's already set to. The apex returned 526 (invalid origin cert) before the tunnel was cut over, and a 526 is only possible when Cloudflare validates the origin cert — which Flexible never does. So the zone is most likely already at Full/Full(strict) and there may be nothing to change. Also note the blast radius is smaller than it looks: zone SSL mode does not govern the apex at all, because a tunnel's edge→origin hop is the tunnel's own encrypted channel. It matters only for the `files.` → B2 CNAME, so it cannot be the reason `cyberjayahappenings.me` misbehaves.*

**Settings → Auto Minify / SXG: turn OFF Automatic Signed Exchanges.** SXG is incompatible with B2 and breaks in some browsers.

**Rules → Transform Rules**, four rules in this order. The free plan allows 10.

1. **Rewrite URL** — condition `not starts_with(http.request.uri.path, "/file/<bucket>")` (so short and long URLs both work), dynamic **rewrite** with expression `concat("/file/<bucket>", http.request.uri.path)`
2. **Modify response header** — set `ETag` to `concat(http.response.headers["x-bz-content-sha1"][0], http.response.headers["x-bz-info-src_last_modified_millis"][0], http.response.headers["x-bz-file-id"][0])` and remove the `x-bz-*` headers. The `[0]` indexes are required (header values are arrays). If all three are absent the ETag is empty and Cloudflare omits the header — which is what you want
3. **Modify response header** — set `cache-control` to `public, max-age=31536000`, matching on the existing `max-age=14400` so B2's `no-store` on 404s passes through untouched
4. **CORS** — set `Access-Control-Allow-Origin: *`, matching on `.webp` (everything in B2 is WebP; add others defensively if you ever serve a raw upload)

Two notes so these don't read as arbitrary:

- **The year-long TTL in rule 3 is correct, not optimistic.** The article warns it "effectively assumes once created, files on the image host are immutable." Keys are `SHA256(bytes)` plus a constant extension suffix, so the same key can never hold different content — and that guarantee is what makes repeat views free.
- **Rule 4 matches the URL path extension, not the bytes.** The key has to end in `.webp` for the rule to fire. C0 in the plan is what makes that true — apply it before C1, or this rule never fires.

The most common mistake here is referencing `http.response.headers` in a rule that means request headers, or vice versa.

**Know about this now, though it bites later:** the free plan's **Bot Fight Mode** and **Security Level** can serve a JavaScript challenge to a non-browser client. Nothing in this deploy is affected — healthchecks.io pings `hc-ping.com` directly and never touches Cloudflare — but the *deferred* public uptime monitor, pointed at `cyberjayahappenings.me`, would get challenged, and that presents as a mysterious Rails error rather than a Cloudflare one.

### Step 16 — Verify · **STOP GATE**

Copy a real key from the B2 file list rather than computing a hash, so you're testing an object that definitely exists:

```bash
curl --head https://files.cyberjayahappenings.me/<sha256>.webp
curl --head https://files.cyberjayahappenings.me/<sha256>.webp   # again
```

**On the second call, expect:** `cf-cache-status: HIT` — the whole point, and the direct evidence that repeat views have stopped spending B2's 2,500/day free Class B transactions · `cache-control: public, max-age=31536000` · no `x-bz-*` headers · an `etag`. A 404 should show `BYPASS`, not `HIT`.

| `cf-cache-status` | Meaning | Where to look |
|---|---|---|
| `HIT` on the second call | Working. Stop here | — |
| `MISS` on the second call | Eligible, but not being stored | Rule 3's match expression |
| `DYNAMIC` | Never eligible — didn't even try | The key's extension |
| `BYPASS` on a 404 | Expected. B2's `no-store` passing through | — |

`DYNAMIC` is the one that wastes the most time: Cloudflare never considered the asset cacheable *at request time*, so no Transform Rule can fix it after the fact. [Default cache behavior](https://developers.cloudflare.com/cache/concepts/default-cache-behavior/) matches on extension and explicitly *not* on MIME type, so a bare `<sha256>` is never cacheable however the bytes are labelled. The extension fix is already in `ObjectStore#put`; a DYNAMIC here means something upstream of it didn't land.

### Step 17 — Point the app at the CDN

Only after Step 16 passes:

```bash
echo 'PUBLIC_IMAGE_BASE_URL=https://files.cyberjayahappenings.me' >> $APP_ROOT/.env
cd $APP_ROOT && docker compose up -d
```

`get_url` prefers this and falls back to the raw B2 URL when blank, so nothing breaks if you skip it — you just pay B2 for every page view.

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
| `files.…` returns 522 | Expected between Steps 14 and 15 |
| `cf-cache-status: MISS` on repeat requests | Rule 3's match expression isn't matching |
| `cf-cache-status: DYNAMIC` | The key has no extension. Never cacheable at request time, so no Transform Rule can fix it |
| `files.…` 404s for keys you can see in B2 | Key sent without `.webp`, or the `files.` record is DNS-only |
| App edits have no effect | No bind mount any more. `docker compose up -d --build` |

## Two things to do once, later

- **The domain is free for year one** via the GitHub Student Pack, and the hostname dies with the domain — a lapse takes the whole public path down. Recurs annually.
- **When you rename the codebase**, `config.hosts` in `config/environments/production.rb` and `PUBLIC_IMAGE_BASE_URL` are the two values holding the current domain. `grep -rn cyberjayahappenings.me` finds them both.
