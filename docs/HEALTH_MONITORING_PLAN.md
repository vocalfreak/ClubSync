# ClubSync — Health Monitoring Implementation Spec (Phase 1)

*Scope: monitoring for `clubsync:ingest` only. Public-site uptime monitoring (Phase 5, once Cloudflare Tunnel is live) is explicitly out of scope for this doc — noted at the end as forward-looking.*

*Companion doc: `docs/DATA_INGESTION_PLAN.md` specifies `AccountPipeline` (per-account work) and `IngestionRunner` (run-level orchestration — loops accounts, tallies results, calls the notifiers below). This doc owns `IngestionRun`, `DiscordNotifier`, and `HealthPing`; that doc owns everything `IngestionRunner` calls into to actually do the scraping.*

**Status · September 16, 2026:** Fully implemented and verified live. The 2-account dry run confirmed both delivery tracks: Discord summary posted to `#clubsync-log` and healthchecks.io pinged (finished). All checklist items below are done; only the healthchecks.io/Discord pieces are already in place (check `clubsync-ingest`, period 2d, grace 1h, Discord integration with `#clubsync-alerts`, webhooks in `.env`/`env.example`).

*Naming note: this doc uses `ingestion_runs`/`IngestionRun` throughout, matching the vocabulary the master plan already uses ("ingestion pass", "ingestion run"). If that still feels off once you're looking at the migration, `scrape_runs`/`ScrapeRun` is a clean drop-in rename — nothing below depends on the name itself, just rename consistently before running the migration.

---

## 1. Architecture: two tracks, one channel-pair

There is no single mechanism that can guarantee "always send one summary, no matter what," because a process can die in ways that leave no code running to report anything (power loss, OOM-kill, cron never firing). So this splits into two tracks that together *behave* like one:

| Track | Catches | Mechanism | Can it be "always"? |
|---|---|---|---|
| **App self-report** | Anything `IngestionRunner` is alive to catch — an `AccountPipeline` failure it read as a `Result`, or an unanticipated exception it caught in its own outer `rescue` | `IngestionRun` row + Discord webhook message, posted from `IngestionRunner`'s top-level `ensure` block | Yes, for every case where the process survives long enough to reach `ensure` |
| **External dead-man's switch** | The process never got that far, or never even started — box down, container OOM-killed, cron didn't fire, or a crash so hard the `ensure` block itself never runs | healthchecks.io `/start` + grace-time, `/fail` pinged explicitly from `IngestionRunner`'s `ensure`/rescue on any caught exception | Only external monitoring can catch this category — it's the backstop, not a duplicate |

Both route into Discord, but into **different channels by urgency**, not by subsystem:

- **`#clubsync-log`** — every run, clean or not. Routine, skim-only. Posted directly by the app via a Discord webhook.
- **`#clubsync-alerts`** — only fires when something needs actual attention: healthchecks.io's own Discord integration posts here on a missed/late ping (the "app never got to report" case), and this is where Phase 5's future uptime-down and abuse alerts will also land. Kept separate specifically so routine noise in `#clubsync-log` never trains you to skim past a real alert.

Net effect: in the common case (run finishes, even with some account failures) you get exactly one message, in `#clubsync-log`. In the rare case the app can't self-report, `#clubsync-alerts` is the one that fires instead.

---

## 2. Schema

### 2.1 New table: `ingestion_runs`

```ruby
create_table :ingestion_runs do |t|
  t.datetime :started_at, null: false
  t.datetime :finished_at
  t.integer  :status, null: false, default: 0    # running:0 / finished:1 / crashed:2 (integer enum, mirrors posts.stage)
  t.integer  :accounts_processed, default: 0
  t.integer  :accounts_failed, default: 0
  t.integer  :posts_scraped, default: 0          # post payloads fetched from Apify this run
  t.jsonb    :failed_accounts, default: []               # [{account:, reason:}, ...]
  t.jsonb    :stage_failure_counts, default: {}           # {"scraped"=>2, "media_processed"=>1}
  t.text     :notes                                        # free-text: exception message/backtrace on crash
  t.timestamps
end
```

Notes:
- `status` mirrors `posts.stage`'s integer-enum pattern (see `db/migrate/20260915000000_replace_status_with_stage_on_posts.rb`) — a `status` enum on the model (`running`/`finished`/`crashed`), integer-backed, default `running`.
- `failed_accounts` and `stage_failure_counts` are jsonb rather than normalized rows — this table is written once per run (every 2 days) and read as a whole, not queried per-field; normalizing would add joins for no real benefit at this volume.
- No FK to `posts` on this side — the relationship is owned by `posts.last_ingestion_run_id` (below), so `IngestionRun` doesn't need to know about individual posts to exist.

### 2.2 New column: `posts.last_ingestion_run_id`

```ruby
add_reference :posts, :last_ingestion_run, foreign_key: { to_table: :ingestion_runs }, null: true
```

Set by `PostLoader` every time it creates or refreshes a row (i.e. the same two branches that already touch the DB — `shortcode not found → create` and `shortcode found, stage != extracted → refresh`), called from `AccountPipeline` with the `ingestion_run_id` it was given (see `docs/DATA_INGESTION_PLAN.md` §2). The `skip` and `no_row` branches don't touch it, consistent with `PostLoader` already leaving untouched rows alone.

This is what makes `stage_failure_counts` computable without inferring membership from timestamps:

```ruby
Post.where(last_ingestion_run_id: run.id).group(:stage).count
```

---

## 3. `IngestionRunner` shape

Full object spec (looping, tallying, `AccountPipeline` interface) lives in `docs/DATA_INGESTION_PLAN.md` §3 — reproduced here only for the pieces this doc's guarantees depend on:

```ruby
def self.call
  run = IngestionRun.create!(started_at: Time.current, status: :running)
  HealthPing.start  # hc-ping.com/<uuid>/start

  begin
    Account.all.each do |account|
      result = AccountPipeline.call(account, ingestion_run_id: run.id)
      # tally result into run — see docs/DATA_INGESTION_PLAN.md §3
    end

    run.stage_failure_counts = Post.where(last_ingestion_run_id: run.id).group(:stage).count
    run.status = :finished

  rescue => e
    # AccountPipeline let this propagate — an unanticipated bug, not an account-level hiccup
    run.status = :crashed
    run.notes = "#{e.class}: #{e.message}\n#{e.backtrace&.first(10)&.join("\n")}"
    HealthPing.fail  # immediate /fail, don't wait for grace-time to expire

  ensure
    run.finished_at = Time.current
    run.save!
    DiscordNotifier.post_run_summary(run)   # always, regardless of status
    HealthPing.finish(run.status) unless run.status == :crashed  # success ping only if not already /fail'd
  end
end
```

Per-account resilience is **not** IngestionRunner's job — `AccountPipeline` rescues its own anticipated failures (Apify timeout/rate-limit/network) internally and reports them as a `Result`, so IngestionRunner never needs a per-account `rescue` of its own. The `rescue`/`ensure` shown here exists purely as the backstop for whatever `AccountPipeline` didn't anticipate — that's the entire reason a `crashed` status exists at all.

**Both notifiers are hermetic** (see §4.3): each posts/pings inside its own `rescue` that logs the failure and swallows the exception. A Discord outage can neither crash the run nor suppress the healthchecks ping — if `post_run_summary` raises, `HealthPing.finish` still runs immediately after. Control-plane failures never change run status and never trigger a false missed-ping alert.

---

## 4. Discord integration

### 4.1 Server & channel setup (manual, one-time)

1. Create a Discord server (or use an existing one — either works).
2. Create two text channels:
   - `#clubsync-log` — routine run summaries. Set channel permissions so only the bot/webhook can post here (optional but keeps it clean).
   - `#clubsync-alerts` — missed-ping alerts from healthchecks.io + future Phase 5 abuse/uptime alerts.
3. For each channel, create a webhook:
   - Channel Settings → Integrations → Webhooks → New Webhook.
   - Name it (e.g. "ClubSync Bot"), copy the webhook URL.
   - Repeat for the other channel.
4. Add both webhook URLs to `.env` (`chmod 600`, git-ignored — same pattern as existing secrets):

```
DISCORD_LOG_WEBHOOK_URL=...    # #clubsync-log
DISCORD_ALERT_WEBHOOK_URL=...  # #clubsync-alerts (used by healthchecks.io's integration, not the app)
```

5. Add both URLs to `env.example` as placeholders (git-tracked, no real values):

```
DISCORD_LOG_WEBHOOK_URL=       # webhook for #clubsync-log
DISCORD_ALERT_WEBHOOK_URL=     # webhook for #clubsync-alerts (healthchecks.io integration)
```

No Discord bot is needed — webhooks are sufficient for one-way posting. The app posts to `DISCORD_LOG_WEBHOOK_URL`; healthchecks.io's native Discord integration posts to `DISCORD_ALERT_WEBHOOK_URL`.

### 4.2 Message format

`DiscordNotifier.post_run_summary(run)` builds one message from the `IngestionRun` row — no separate summary-building logic elsewhere, the DB row *is* the source of truth for what gets rendered:

- Status (finished / finished with N failures / crashed)
- Accounts processed / failed, posts scraped
- Failed accounts list (if any)
- Per-stage breakdown (if any posts didn't reach `extracted`)
- Duration (`finished_at - started_at`)

The app only ever posts to `DISCORD_LOG_WEBHOOK_URL`. It never posts to the alert channel — that's healthchecks.io's job, configured on their end (see below), keeping the "which channel gets which kind of message" decision in one place instead of split across two codebases. Uses stdlib `Net::HTTP` (same approach as `MediaProcessor#fetch_image`) — no new HTTP dependency.

### 4.3 Hermetic failure semantics

- `DiscordNotifier` rescues its own network/timeout errors, logs them, and never raises — a webhook failure must not affect run status, and must not prevent `HealthPing` from being called (ordering in the `ensure` block is safe only because of this).
- `HealthPing` rescues its own errors the same way — a failed ping is logged (`"healthchecks ping failed: ..."`) and ignored; the run's `IngestionRun` row and `#clubsync-log` message are still produced.
- Rationale: control-plane reporting is best-effort by design. The `#clubsync-alerts` channel exists precisely because the app may be unable to report; a reporting failure itself is never treated as a run failure.

---

## 5. healthchecks.io configuration

Ping URL lives in `.env` (`chmod 600`, git-ignored), same pattern as all other secrets:

```
HEALTHCHECKS_PING_URL=https://hc-ping.com/<check-uuid>
```

`HealthPing` appends the suffix per call: `/#{suffix}` where suffix is `start`, `fail`, or empty (plain success). Add `HEALTHCHECKS_PING_URL=` placeholder to `env.example` (git-tracked, no real value). If the var is missing/blank, `HealthPing` rescues and logs — a misconfigured check degrades to "no external backstop," never to a crash.

- One check: `clubsync-ingest`.
- Period: 2 days. **Grace time: 1 hour** — a run is considered failed if no ping arrives within 2 days + 1 hour of the last successful ping; this window is only reached when the process never got to ping at all (crashes ping `/fail` immediately, so they alert without waiting out the grace window). Tighten further if real submit-to-submit gaps show up shorter.
- Discord integration on this check → `#clubsync-alerts` webhook, so a missed ping / unrecovered "down" state posts there automatically, no app code involved.
- Ping calls from `IngestionRunner`: `/start` at run begin, `/fail` immediately from the crash branch, plain success ping from `ensure` otherwise. This means genuine crashes alert *immediately* rather than waiting out the grace window — grace-time timeout is reserved for the case nothing could call `/fail` at all (the box itself is the problem).

---

## 6. Explicitly deferred (not this doc)

- **Public-site uptime monitoring** (Phase 5) — separate tool (e.g. UptimeRobot/Better Stack free tier) hitting the Cloudflare Tunnel URL, alerts into `#clubsync-alerts`. Not needed until the tunnel exists.
- **Rack::Attack abuse alerts** (Phase 5) — will need debouncing/batching into one alert per abuse episode rather than one Discord message per blocked request, same shape of problem already solved here for per-account failures. Design when Phase 5 is actually being built, not now.
- **Sentry / exception tracebacks** — `IngestionRun.notes` captures a truncated backtrace for crashes, which may be enough for a solo project. Revisit only if that's not enough to debug from in practice.
- **Host-level checks** (disk, B2 usage) — out of scope until there's more than a skeleton backend.

---

## 7. Phase 1 checklist (replaces the existing "Health monitoring skeleton" bullet)

> **Prerequisite:** `AccountPipeline` and `IngestionRunner` (`docs/DATA_INGESTION_PLAN.md`) must exist first — this doc's guarantees (one summary per run, hermetic notifiers) are properties of `IngestionRunner`'s `ensure` block, which doesn't exist until that doc's Phase 4 checklist is built.

- [x] Migration: `ingestion_runs` table (integer enum for `status`, per §2.1)
- [x] Migration: `posts.last_ingestion_run_id` (nullable FK)
- [x] `PostLoader`: set `last_ingestion_run_id` on create and refresh branches; leave unset on `skip` and `no_row`
- [x] `IngestionRun` model (integer-backed `status` enum: running/finished/crashed, mirroring `Post.stage`)
- [x] `DiscordNotifier` service: `post_run_summary(run)`, posts to `DISCORD_LOG_WEBHOOK_URL` via `Net::HTTP`, hermetic (rescue + log, never raises)
- [x] `HealthPing` service: `start` / `fail` / `finish` wrapping `HEALTHCHECKS_PING_URL` + suffix, hermetic (rescue + log, never raises, no-op if var blank)
- [x] `IngestionRunner`'s outer `rescue`/`ensure` and notifier calls (object itself specified in `docs/DATA_INGESTION_PLAN.md` §3 — this checklist item is about the notifier wiring, not the looping/tallying logic)
- [x] Tests (Minitest, matching existing suite):
  - [x] `IngestionRun` model test (enum values, defaults)
  - [x] `PostLoader` test additions: `last_ingestion_run_id` set on create/refresh, not on skip/no_row
  - [x] `DiscordNotifier` test: correct URL/body posted; swallows a network error (stub `Net::HTTP` to raise)
  - [x] `HealthPing` test: correct suffix per call; swallows a network error; no-op when URL blank
  - [x] `IngestionRunner` test: outer exception → `crashed` + `/fail`; `ensure` always saves and calls both notifiers even when one raises (per-account tallying tests live in `docs/DATA_INGESTION_PLAN.md` §6, not duplicated here)
- [x] healthchecks.io: create `clubsync-ingest` check, period 2d, grace 1h, Discord integration → `#clubsync-alerts`
- [x] Discord: create server (if needed), create `#clubsync-log` and `#clubsync-alerts` channels
- [x] Discord: create webhooks for both channels, add URLs to `.env` + `env.example`; add `HEALTHCHECKS_PING_URL` to `.env` + `env.example`
- [x] Dry run against a small account subset to sanity-check the summary format before trusting it on the full 41 — done (2 accounts, status `finished`, summary + ping both confirmed working)