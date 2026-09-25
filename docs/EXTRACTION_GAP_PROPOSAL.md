# ClubSync — Open Work (as of 2026-09-23, revised)

Scope for this pass: **retry/backoff, payload safety, dead-lettering, token
budget + model selection, and misc small items only.** Deploy is off the
table until dedup (Phase 2) exists — see "Deferred" below. Pass 5's eval set
stays excluded too.

## 1. Retry-with-backoff on transient Gemini failures

- [x] Inside `Extractor`, wrap the Gemini call: retry on `TimeoutError` /
      `RateLimitedError` / `ServerError` at 2s then 4s (3 attempts total)
- [x] `AuthError` is excluded from retry — config problem, not transient; fail
      once and alert rather than adding latency for nothing
- [x] This-post errors (`BlockedError` / `InvalidResponseError`) are never
      retried — same input would produce the same rejection
- [x] Confirm where `GeminiOutage` counts a failure: **per post, after the
      full retry+fallback chain is exhausted** — not per raw attempt. (Retry
      inside, outage tracker outside — standard resilience layering. Counting
      raw attempts would silently couple the outage tracker's sensitivity to
      however many retries/fallback models happen to be configured.)
- [x] Tests: fake client failing twice then succeeding → 3 calls total,
      `:success`; injectable sleep so tests don't actually wait 6s

## 2. Carousel payload safety

- [x] Preflight size check in `GeminiClient#build_request`: serialize the
      request body, check `json.bytesize` — soft-warn (log only) at 12MB,
      hard-fail at 18MB with a new `GeminiClient::PayloadTooLargeError`
      (this-post class)
- [x] Preflight **validity** check alongside the size check: reject
      non-decodable bytes returned from `ObjectStore#get` before spending the
      network round-trip on them, not just check size — a truncated/corrupt B2
      read currently still costs a full Gemini call before failing
      (implemented as a full vips decode via `Vips::Image.new_from_buffer`)
- [ ] One-time measurement: worst-case encoded request bytes for a synthetic
      10-image carousel built from the existing pool; record the real number
      (`clubsync:measure_payload` is built — run it and record the number)
- [ ] `media_resolution` setting — decide via the same empirical test as §4,
      not separately (the env knob and request wiring are NOT built yet —
      deliberately, so the choice isn't made before the measurement)

## 3. Per-post dead-lettering

- [x] `Post#dead_lettered?` — true when the most recent 3 `extractions` rows
      are all `failed` with `error_kind: "this_post"`, consecutively. Any
      `succeeded` row or any `whole_service` row in that tail resets it — one
      Gemini-wide outage can't dead-letter a post, and a success clears the
      slate
- [x] `Extractor` guard returns a skip result **without** calling Gemini and
      **without** writing a new `extractions` row (keeps the audit log honest,
      doesn't extend the counter)
- [x] Append the dead-lettered count to the run summary
- [x] Tests: 3-in-a-row this-post failures skips Gemini entirely (fake-client
      call count 0); a `whole_service` row in the tail prevents dead-lettering;
      a `succeeded` row resets it
- Note: the `Post.dead_lettered` scope was originally meant to feed the admin
  review view — that view is deferred too, so this item now just needs the
  scope to exist for later, not a page to display it on.

## 4. Token budget tracking + model selection

Do these together — they share the same empirical test.

- [x] **Primary model settled (2026-09-23):** `gemini-3.1-flash-lite`, single model, no fallback — decision from free-tier RPD arithmetic (~500/day lite vs ~20/day full Flash; the ~400-post-run framing below) plus the live 503 evidence (3.5/3.8-flash in sustained spikes, lite healthy on the 12-post pass). The full-vs-lite accuracy comparison on a shared pool is still a worthwhile §3/§5 check but no longer gates the default.
- [ ] Confirm actual RPD / RPM / TPM on the AI Studio dashboard for the chosen model (and note lite-class tolerance for carousel-heavy payloads) — published numbers vary by tier/project and change without notice; treat any outside source as a lead, not ground truth. Once the real device-grade numbers are confirmed, set `GEMINI_DAILY_REQUESTS` / `GEMINI_DAILY_TOKENS` and the §13 soft-cap alert becomes active.
- [ ] Reason to take this seriously: current third-party trackers put
      full "Flash"-class models around ~20 requests/day on free tier vs.
      ~500/day for Flash-Lite. If that's close to right, full Flash can't
      cover a ~400-post run at all — this reframes the question from "pick a
      fallback" to "confirm the primary is even viable"
- [ ] Same test pass: compare `media_resolution: HIGH` vs. the unspecified
      default on a few dense-small-text posters from the pool. No billing
      enabled means no dollar cost either way — decide on accuracy/token-count
      evidence, not a charges concern
- [ ] Once a primary model is confirmed: `GEMINI_MODEL` +
      `GEMINI_FALLBACK_MODELS` (ordered list), rotating on `TimeoutError` /
      `RateLimitedError` / `ServerError` only, with the per-model attempt
      counter reset feeding into §1's retry loop (rotation machinery is
      implemented and env-gated — only the final model values are pending the
      confirmation above)
- [x] `extractions.ingestion_run_id` FK (nullable; backfill `NULL` for
      existing rows) — thread `ingestion_run_id:` into `Extractor.call`
- [x] `ingestion_runs.token_usage` jsonb, summed from that run's `extractions`
      rows, appended as one line to the Discord run summary
- [x] Soft-cap alert to `#clubsync-alerts` at 80% of whatever the *confirmed*
      daily quota turns out to be — don't hardcode 80% of an unconfirmed
      number (implemented env-gated; inert until the caps are set)

## 5. Misc small items

- [x] Rename `DISCORD_ALERTS_WEBHOOK_URL` → `DISCORD_ALERT_WEBHOOK_URL`
      (code side — matches the existing doc's spelling)
- [x] One-paragraph note added to the extraction plan's prompt-rules section:
      captions are untrusted input; no instruction-separation hardening in v1;
      revisit only if a bad classification ever looks deliberate rather than a
      model mistake. No code for this item.

## Deferred (not being worked on this pass)

- **Deploy to the E5440** — held until dedup (Phase 2) exists. Nothing in
  §1–5 above depends on deploy or blocks it.
- **Dedup (Phase 2)** — now the actual gating item for deploy; not scoped in
  this doc.
- **Run-overlap protection** (partial unique index on `ingestion_runs.status`,
  stale-run reclaim) — only matters once cron runs unattended. Not urgent
  while deploy itself is on hold; revisit together when deploy comes back into
  scope.
- **Private admin review view** — parked along with deploy; nothing here
  needs it yet.
- **Pass 5's ~50-post blind-labeled eval set + `clubsync:extraction_eval`** —
  still excluded, unrelated to today's reasoning.
- **Shadow-evaluation-before-shipping-a-prompt-change discipline** — same,
  becomes relevant once there's an actual `prompt_version` bump on the table.
- **The per-source circuit breaker and the public-facing half of Phase 5**
  (Cloudflare Tunnel, Rack::Attack, no-auth public routes) — already
  known-open, unaffected by anything in this doc.