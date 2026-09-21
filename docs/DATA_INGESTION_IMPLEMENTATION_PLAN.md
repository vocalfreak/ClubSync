# ClubSync — Data Ingestion Implementation Plan (Phase 4)

*Scope: the per-account and per-run orchestration that turns a list of Instagram accounts into `Post`/`Image` rows — `Account`, `AccountPipeline`, `IngestionRunner`, and the `clubsync:ingest` rake task. Run-level bookkeeping (`IngestionRun`) and reporting (Discord/healthchecks.io) are specified in `docs/HEALTH_MONITORING_PLAN.md`; this doc owns everything `IngestionRunner` calls *into*, that doc owns everything `IngestionRunner` calls *out to*.*

**Status · September 16, 2026:** Fully implemented and tested. Live dry run over 2 real accounts (`itsocietymmu`, `mmusports`): status `finished`, 2/2 accounts, 0 failed, 20 posts (12 `media_processed`, 8 `scraped` — all `Video`, so untouched by design). One decision note: **`resultsLimit` is 10, not 15** (see §6 — user-confirmed default; update reflected throughout). Remaining only the deploy-time setup on the E5440.

---

## 1. Why two objects, not one

Everything used to be sketched as logic living directly inside `task ingest: :environment do ... end`. Two problems with that: a rake task's `do...end` block is awkward to unit-test on its own, and it was carrying two genuinely different responsibilities — "do the work for one account" and "run the whole thing and report on it." Splitting on that seam:

| Object | Owns | Doesn't own |
|---|---|---|
| `AccountPipeline` | Fetch one account from Apify → `PostAdapter` → `PostLoader` → `MediaProcessor`, per post | Anything about `IngestionRun`, Discord, healthchecks — doesn't know they exist |
| `IngestionRunner` | Loop over all accounts, tally results into `IngestionRun`, decide `crashed` vs `finished`, call the two notifiers | The actual scraping/loading/processing — delegates every account to `AccountPipeline` |
| `clubsync:ingest` (rake task) | Nothing — just invokes `IngestionRunner.call` | Everything |

This mirrors the `PostAdapter`/`PostLoader` split already in the codebase: one object that's pure per-item work with no DB/side-effect awareness beyond what it's told to touch, one object that owns orchestration and writes.

---

## 2. `Account`

**Why a table, not a constant:** the original sketch had `IngestionRunner` iterate `Account.all` with no model behind it. A plain constant/YAML list would work for iteration alone, but Phase 4's own "Circuit breaker per source" item needs per-account state (a failure streak, a disabled-until timestamp) that has to persist *between* runs — unlike stage progression, there's no idempotent substitute for that memory. Since nothing in this stack provides an external KV store (Sidekiq/Redis already ruled out), that state has to live in Postgres regardless, which means this table gets built during Phase 4 either way. Building it now avoids doing the migration twice.

**Migration** — deliberately minimal, no circuit-breaker columns yet (that state isn't designed):

```ruby
create_table :accounts do |t|
  t.string :handle, null: false
  t.timestamps
end
add_index :accounts, :handle, unique: true
```

`posts.account` is untouched — stays a plain string, no FK, no `PostLoader` changes. There's no current need to join `posts` against `accounts`, so this doesn't force any churn on the existing schema.

**Population — `db/seeds.rb`, not a data migration:**

```ruby
# db/seeds.rb
HANDLES = %w[handle_one handle_two ...] # the 41, maintained by hand

HANDLES.each { |h| Account.find_or_create_by!(handle: h) }
```

This matters, not just style: `schema.rb`'s own header states the intended fresh-environment path is `bin/rails db:schema:load`, which loads the schema snapshot directly and does **not** replay old migrations. A migration that inserted the 41 rows would work today but silently produce an empty `accounts` table on any future fresh provision of the E5440 — no error, just a pipeline that runs zero accounts. `db/seeds.rb` is the correct home for static reference data precisely because it's meant to be re-run explicitly, matching how `.env`/secrets are already handled (one manual step per environment, not automatic on deploy).

**No admin UI for managing accounts in v1.** Adding or removing a handle is a `db/seeds.rb` edit + `rails db:seed` + redeploy — same shape as every other config change in this project. Worth stating as a decision rather than leaving it as an unnoticed gap.

**Naming note:** keep seeded `handle` values matching Instagram's canonical casing for the account, so they stay visually consistent with whatever ends up in `posts.account` from the raw payload — nothing currently enforces or depends on an exact match, but it avoids confusion later if the two ever do need correlating.

---

## 3. `AccountPipeline`

**Location:** `app/services/account_pipeline.rb` — same directory as `PostAdapter`/`PostLoader`.

**Interface:**

```ruby
result = AccountPipeline.call(account, ingestion_run_id: run.id)  # account is an Account instance
result.success?        # => true/false
result.errors          # => [] or ["Apify timeout after 30s", ...]
result.posts_scraped   # => Integer — post payloads actually fetched this call, 0 on failure
```

Mirrors `PostAdapter::Result`'s shape (`valid?`/`errors`) rather than inventing a new convention. No `fatal?` — unlike `PostAdapter`, there's no case where an account-level failure should stop anything beyond that one account, so there's nothing for a caller to branch on beyond `success?`.

**What it does, per account:**

1. Fetch the account's recent posts via the existing Apify integration (already built, Phase 1), using `account.handle`.
2. For each raw post payload: `PostAdapter.call(raw)` → `PostLoader.call(adapter_result, ingestion_run_id: ingestion_run_id)` → if the resulting `Post` is `scraped` and its `post_type` is `Image`/`Sidecar`, hand it to `MediaProcessor`.
3. Increment an internal `posts_scraped` counter for every payload fetched from Apify in step 1 (not per stage — matches `IngestionRun#posts_scraped`'s existing semantics).
4. Return a `Result` with `success: true` once the account's posts are all handed through the chain.

**Failure handling — narrow, not blanket:**

```ruby
begin
  posts = ApifyClient.fetch_account(account.handle)
rescue ApifyClient::TimeoutError, ApifyClient::RateLimitedError, Net::OpenTimeout => e
  return Result.new(success: false, errors: [e.message], posts_scraped: 0)
end
```

Only exception classes that represent *anticipated* failure modes (Apify timeout, rate limit, network blip) are rescued here. Anything else — a `NoMethodError` from a bad assumption about payload shape, a bug in `AccountPipeline` itself — is **not** rescued and propagates straight up to `IngestionRunner`, where it's meant to be treated as a real bug (§4). Same distinction the master plan already draws for `PostAdapter`/`PostLoader` ("a real failure here is a bug that raises") — expected failure becomes data, unexpected failure stays an exception.

If a specific post inside the loop fails (e.g. `MediaProcessor` errors on one image), that does **not** fail the whole account — `Post.stage` simply doesn't advance for that post, exactly as already specified for `MediaProcessor` in the master plan. `AccountPipeline#errors` only reflects account-level failure (couldn't fetch the account at all); per-post failure is tracked on `posts.last_error`/`stage_failed_at`, not duplicated here.

---

## 4. `IngestionRunner`

**Location:** `app/services/ingestion_runner.rb`.

**Interface:** `IngestionRunner.call` — no arguments, no return value consumed by anything (terminal object, called only from the rake task).

**Behavior:**

```ruby
def self.call
  run = IngestionRun.create!(started_at: Time.current, status: :running)
  HealthPing.start

  begin
    Account.all.each do |account|
      result = AccountPipeline.call(account, ingestion_run_id: run.id)

      if result.success?
        run.accounts_processed += 1
        run.posts_scraped += result.posts_scraped
      else
        run.accounts_failed += 1
        run.failed_accounts << { account: account.handle, reason: result.errors.join("; ") }
      end
      run.save!
    end

    run.stage_failure_counts = Post.where(last_ingestion_run_id: run.id).group(:stage).count
    run.status = :finished

  rescue => e
    # AccountPipeline let this propagate — an unanticipated bug, not an account-level hiccup
    run.status = :crashed
    run.notes = "#{e.class}: #{e.message}\n#{e.backtrace&.first(10)&.join("\n")}"
    HealthPing.fail

  ensure
    run.finished_at = Time.current
    run.save!
    DiscordNotifier.post_run_summary(run)
    HealthPing.finish(run.status) unless run.status == :crashed
  end
end
```

Note what's gone compared to the original single-block sketch: no per-account `begin/rescue` here — `IngestionRunner` just reads `result.success?`. Per-account resilience now lives entirely inside `AccountPipeline`'s narrow rescue; `IngestionRunner`'s outer `rescue`/`ensure` is reserved for exactly what it says — something `AccountPipeline` didn't anticipate, i.e. a bug.

`DiscordNotifier`, `HealthPing`, and the `IngestionRun` model are specified in `docs/HEALTH_MONITORING_PLAN.md` — `IngestionRunner` only calls them, it doesn't define them.

---

## 5. The rake task

```ruby
namespace :clubsync do
  task ingest: :environment do
    IngestionRunner.call
  end
end
```

That's the whole task. Everything else is unit-testable Ruby objects.

---

## 6. Apify fetch client

The client targets Apify's **Instagram Post Scraper** actor — `apify/instagram-post-scraper` (not the general-purpose `apify/instagram-scraper`, which has a different input schema). `AccountPipeline` calls into it for the per-account fetch step: one synchronous actor run per handle via

```json
{"username": [account.handle], "resultsLimit": 10}
```

(`username` is the actor's array-typed input field — singular, not `usernames`) — returning that account's items directly, matching `AccountPipeline`'s per-account contract and keeping failure isolation intact: one account's timeout fails one account, not all 41. A single batched run across all handles was considered and rejected — it would collapse every account into one failure domain, defeating the narrow per-account rescue this whole design is built around. Cost is not a factor either way: Apify bills per result returned, not meaningfully per run, so 41 small runs vs. one large run barely affects usage against the free tier.

**Endpoint & auth:**

- `POST https://api.apify.com/v2/actors/apify~instagram-post-scraper/run-sync-get-dataset-items` — note the tilde between owner and actor name (`apify~instagram-post-scraper`), not a slash
- Token sent via an `Authorization: Bearer <token>` header — never as a `?token=` query param
- `Content-Type: application/json` on the POST body (the actor input above)
- Apify's sync-and-wait endpoint enforces a hard 300-second ceiling on the run before it returns a 408. That bounds how large a single account's `resultsLimit` can practically go before a slow run risks timing out mid-fetch — one more reason the limit stays modest (below)

If the client doesn't already expose distinct exception classes for these failure modes (needed for the narrow rescue in §3), that's a small gap to close rather than a new integration: open/read timeout (or HTTP 408, the sync-ceiling cut-off) → `ApifyClient::TimeoutError`; HTTP 429 or a failed run → `ApifyClient::RateLimitedError`; anything else raises as an unanticipated bug (the narrow-rescue contract treats only anticipated failures as data).

**Cost watch, not a blocker:** `resultsLimit: 10` is a resolved number — a safety ceiling above typical per-account posting volume, not a cost lever, since Apify bills per actual result returned rather than per limit set. (The original draft said 15; 10 was confirmed as the working default in the September 2026 build/dry run.) You mainly need new posts since the last scrape, not full history re-fetched every 2 days. Worth a glance at Apify's usage dashboard after the first few real runs to confirm the free tier holds.

---

## 7. Testing

Matches existing conventions (Minitest, `factory_bot_rails` + `faker`, literals reserved for what's actually asserted on):

- **`Account` test:** `handle` uniqueness validated at the DB level (unique index).
- **`AccountPipeline` test:** successful account → `Result.success? == true`, correct `posts_scraped`; `ApifyClient::TimeoutError` (and the other anticipated classes) → `Result.success? == false` with the error message captured; an unrelated exception (e.g. stub `PostLoader` to raise `NoMethodError`) → propagates out of `AccountPipeline.call`, is **not** caught.
- **`IngestionRunner` test:** multiple accounts, mix of successful/failed `Result`s → `IngestionRun` tallies correctly (`accounts_processed`, `accounts_failed`, `failed_accounts` keyed by `handle`, `posts_scraped`); an `AccountPipeline` call that raises → run ends `crashed`, `HealthPing.fail` called, `ensure` still saves the run and calls `DiscordNotifier` even after the crash.
- **Rake task test:** thin — just asserts `IngestionRunner.call` is invoked (`Rake::Task["clubsync:ingest"].invoke` + mock/spy), no logic duplicated here.

---

## 8. Phase 4 checklist (replaces "Build the `clubsync:ingest` rake task" bullet)

- [x] Migration: `accounts` table (`handle` string, unique index) — per §2
- [x] `Account` model
- [x] `db/seeds.rb`: the 41 handles, `find_or_create_by!`
- [x] `AccountPipeline` service (`app/services/account_pipeline.rb`) — fetch → `PostAdapter` → `PostLoader` → `MediaProcessor` chain per account, `Result` object (`success?`/`errors`/`posts_scraped`), narrow rescue on anticipated Apify exception classes only
- [x] `IngestionRunner` service (`app/services/ingestion_runner.rb`) — loops `Account.all`, tallies `Result`s into `IngestionRun`, outer `rescue`/`ensure`, calls `DiscordNotifier`/`HealthPing` (both specified in `docs/HEALTH_MONITORING_PLAN.md`)
- [x] Thin `clubsync:ingest` rake task — single call to `IngestionRunner.call`
- [x] Confirm/extend the existing Apify client: targets `apify/instagram-post-scraper` via `POST .../actors/apify~instagram-post-scraper/run-sync-get-dataset-items`, input `{"username": [handle], "resultsLimit": 10}`, token sent via `Authorization: Bearer` header; expose distinct exception classes for timeout/rate-limit/network failure
- [x] Tests per §7
- [x] Cron via `whenever` (unchanged from master plan Phase 4) — sequential per-account processing inside `AccountPipeline`'s loop is what provides staggering; no separate offset-schedule logic needed. `config/schedule.rb` written and rendering verified; host crontab install deferred to deploy
- [x] Post state tracking (unchanged from master plan Phase 4) — `stage`/`is_event`/`last_error`/`stage_failed_at`, idempotent re-attempt on next scrape
- [ ] Circuit breaker per source (unchanged, still open — will add its own columns to `accounts` when designed; not detailed in this doc)