# image-proxy

The image host for ClubSync. A Cloudflare Worker bound to
`files.cyberjayahappenings.me` that reads images from a **private** Backblaze B2
bucket and caches them at the edge.

```
browser → Cloudflare → Worker (caches.default) → B2, only on a miss
```

The E5440 never sees an image byte. The bucket stays private because making a B2
bucket public requires a payment method on file — see
`docs/adr/2026-09-30-private-b2-behind-a-cloudflare-worker.md`.

## What it serves

One path shape, and nothing else:

```
/<64 lowercase hex chars>.webp
```

That is `SHA256(bytes)` plus a constant extension suffix, the key the Rails app
already writes. Anything else is a 404 without a request to B2, which is what
makes it safe to keep a read credential at the edge. Only `GET` and `HEAD`;
everything else is a 405.

## Responses

| Case | Status | Notes |
|---|---|---|
| Cached | 200 | `x-cache: HIT` |
| Fetched from B2 | 200 | `x-cache: MISS`, `Cache-Control: public, max-age=31536000, immutable` |
| Key exists in the shape, not in the bucket | 404 | `Cache-Control: public, max-age=60` |
| B2 403 / 5xx, or a network error | 502 | `no-store`; the status is logged, never the signed request |

Only whitelisted headers leave this Worker: `Content-Type`, `Content-Length`,
`ETag`, `Cache-Control`, `Access-Control-Allow-Origin` and `x-cache`. No
`x-amz-*`, no `x-bz-*`, no `server`.

**Verify with `x-cache`, not `cf-cache-status`.** `cf-cache-status` is not
reliable for a response served out of the Cache API.

## Configuration

`wrangler.toml` holds the three non-secret values — `B2_ENDPOINT`, `B2_BUCKET`,
`B2_REGION` — and the custom domain route. They are the same values the Rails app
reads from `.env`; drift here is a 502 at the edge rather than an error in the
app.

The read credential is a Worker secret, never a var:

```bash
npx wrangler secret put B2_READ_KEY_ID
npx wrangler secret put B2_READ_APP_KEY
```

`workers_dev = false` is deliberate. The Cache API is only available on a
Cloudflare-attached domain, so serving through `*.workers.dev` would appear to
work while every request silently missed the cache.

## Development

```bash
npm install
cp .dev.vars.example .dev.vars   # then fill in the two values
npm test                        # 30 vitest cases, no network
npx wrangler dev                # local, against the real bucket
npx wrangler deploy
```

Tests inject `fetch`, the cache and (optionally) the signer, so the suite runs
without the Workers runtime. One case uses the real `aws4fetch` signer to prove
the SigV4 header is actually produced — signing is pure computation, so it needs
no network.
