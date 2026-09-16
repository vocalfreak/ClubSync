# ClubSync Glossary

Terms as this project uses them.

- **Ingestion run / `IngestionRun`** — one pass of the `clubsync:ingest` rake task over the account list (every 2 days). The `ingestion_runs` table row is the single source of truth for what a run produced and what the Discord summary reports.
- **`is_event`** — nullable boolean column on `posts`, set by the extraction LLM based on its confidence/decision threshold once a post reaches `extracted`. Independent of whether an `events` row exists (that table holds structured field data for confirmed events).
- **Grace time** — healthchecks.io's "how late can the ping be" window past the 2-day period before the check is considered failed and `#clubsync-alerts` fires. Crashes don't wait it out — the app pings `/fail` immediately.
- **Hermetic notifier** — a reporting hook (`DiscordNotifier`, `HealthPing`) that rescues its own errors, logs them, and never raises. Control-plane failures never change run status and never suppress another notifier.
- **Dead-man's switch** — the healthchecks.io check acting as the external backstop for the app never getting to self-report (box down, OOM-kill, cron never fired).