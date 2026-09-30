# ADR-0003: Serve images from a private B2 bucket through a Cloudflare Worker

- **Date:** 2026-09-30
- **Status:** Accepted (reverses the image-host approach decided 2026-09-27)

## Context

The committed image-host plan was Backblaze's "free image hosting with Cloudflare Transform Rules and B2": make the bucket **public**, CNAME `files.cyberjayahappenings.me` at the bucket, and let Transform Rules rewrite the request onto B2 and rewrite its response headers. Zero application code, zero Ruby, and the E5440 never sees an image byte.

One step of it is unobtainable: making a B2 bucket public requires a payment method on file. The account was created to avoid exactly that — the whole reason the free tier was the plan's failure mode ("uploads rejected, not billed"). The Cloudflare account and a Workers subscription are both card-free; a *public* bucket is not. So the one step that removes the bucket's own permission model is the one step unavailable.

The cost story that motivated the track still stands: B2's free allowance is 2,500 Class B transactions a day account-wide, every browser `<img>` load is its own `b2_download_file_by_name`, and repeat views must be served from the edge or they spend that allowance. The bucket must stay private *and* images must stay off the box.

## Decision

Keep the bucket private. A Cloudflare Worker bound to `files.cyberjayahappenings.me` signs reads with a **read-only, application key scoped to that one bucket** and caches at the edge with the Cache API. Browser → Cloudflare → Worker (cache check) → B2 only on a miss. The Transform Rules plan (old C1–C5, the SSL-mode step and the Signed Exchanges step) is withdrawn.

This is the conventional shape, not a workaround: private bucket, least-privilege credential, edge proxy that validates its input. The Rails app already signs B2 requests with SigV4 through the S3 API; the Worker does the same thing from the edge, with the same endpoint, bucket and region.

The Worker's read key is named `B2_READ_KEY_ID` / `B2_READ_APP_KEY`, **not** `B2_KEY_ID` / `B2_APPLICATION_KEY`. The Rails `.env` names are the *upload* key; reusing them for the edge would make a copy-paste of a value from the app's `.env` into `wrangler secret put` a silent privilege upgrade from read-only to write on the whole bucket.

Path validation is strict: `^/[a-f0-9]{64}\.webp$`, GET and HEAD only. The old extensionless objects therefore become unreachable over HTTP while remaining in B2 and still readable by the app through the S3 API.

## Consequences

- Images still never touch the E5440, and the read-only key caps the blast radius of a leaked edge secret to *reading one bucket*.
- The Worker runs on **every** image request including cache hits, against a free plan of roughly 100,000 requests a day with a small per-request CPU budget. A popular page could exhaust that where Transform Rules — which are not billed per request — would not. This is the cost of refusing the card.
- The Cache API is only available on a Cloudflare-attached domain, so the Worker must stay bound to `files.` and is never exercised through `*.workers.dev`. Verification happens against the real hostname.
- Cache hits are verified by the Worker's own `x-cache` header. `cf-cache-status` is not reliable for a response served from the Cache API and is deliberately not part of the C6 check.
- Signing is a hard dependency now (`aws4fetch`), and the endpoint/bucket/region must be duplicated in `wrangler.toml [vars]` — drift there is a 502 at the edge rather than an exception in the app.
- Reverting means re-deciding the public-bucket question, so this is recorded rather than left as a preference.
