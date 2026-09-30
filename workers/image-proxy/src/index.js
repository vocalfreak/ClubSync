import { AwsClient } from "aws4fetch";

// A stored image is addressed by SHA256(bytes) plus a constant suffix, so the
// only path this host ever serves is /<64 hex>.webp. Validating it here is what
// makes the signing credential safe to leave at the edge: an arbitrary path
// never becomes a B2 request, and the same regex is why the old extensionless
// objects are unreachable over HTTP.
const KEY_PATTERN = /^\/[a-f0-9]{64}\.webp$/;

// Content-addressed means immutable, so a year is the honest max-age rather than
// a hopeful one: the bytes at a key can never change.
const IMMUTABLE = "public, max-age=31536000, immutable";

// A miss on a real key is worth remembering briefly -- a deploy that points the
// site at a not-yet-rekeyed key should not hammer B2 -- but never for long,
// because the fix is a rekey, not a wait.
const NEGATIVE = "public, max-age=60";

const DEFAULT_TYPE = "image/webp";

// Everything the client is allowed to see. B2's own headers (x-amz-*, x-bz-*,
// server timing) are not forwarded: they are B2's internals, and the one that
// matters for verification is the x-cache header below, set here.
function publicHeaders(upstream, { cacheControl, cacheStatus, status }) {
  const headers = new Headers({ "Cache-Control": cacheControl, "x-cache": cacheStatus });
  const type = upstream?.headers.get("content-type");
  headers.set("Content-Type", type?.startsWith("image/") ? type : DEFAULT_TYPE);

  const length = upstream?.headers.get("content-length");
  if (length) headers.set("Content-Length", length);

  const etag = upstream?.headers.get("etag");
  if (etag) headers.set("ETag", etag);

  headers.set("Access-Control-Allow-Origin", "*");
  return headers;
}

// AwsClient#sign is a method on the instance and is async, so the signer handed
// to the handler is a closure over it -- a plain function that the injected-fake
// tests can replace, and the real one can be awaited.
function buildSigner(env) {
  const aws = new AwsClient({
    accessKeyId: env.B2_READ_KEY_ID,
    secretAccessKey: env.B2_READ_APP_KEY,
    service: "s3",
    region: env.B2_REGION
  });
  return (request) => aws.sign(request);
}

// endpoint may be a bare host or a full URL; the Rails ObjectStore passes
// whatever is in .env, so accept both rather than making the operator notice.
function b2Url(env, key) {
  const base = env.B2_ENDPOINT.replace(/\/+$/, "");
  return `${/^https?:\/\//.test(base) ? base : `https://${base}`}/${env.B2_BUCKET}${key}`;
}

export function createHandler({ env, fetchImpl, cache, signer, logger = console }) {
  const sign = signer ?? buildSigner(env);

  return async function handle(request, ctx = {}) {
    if (request.method !== "GET" && request.method !== "HEAD") {
      return new Response("method not allowed", {
        status: 405,
        headers: { Allow: "GET, HEAD", "Cache-Control": "no-store" }
      });
    }

    const { origin, pathname: key } = new URL(request.url);
    if (!KEY_PATTERN.test(key)) {
      return new Response("not found", { status: 404, headers: { "Cache-Control": "no-store" } });
    }

    // Normalise to a GET with no query string so HEAD and GET share one entry
    // and ?v=2 on an <img> can't fan out into a second cache key.
    const cacheKey = new Request(`${origin}${key}`, { method: "GET" });
    const cached = await cache.match(cacheKey);
    if (cached) {
      const headers = new Headers(cached.headers);
      headers.set("x-cache", "HIT");
      return new Response(request.method === "HEAD" ? null : cached.body, { status: cached.status, headers });
    }

    // A HEAD is an existence check, so it asks B2 for headers only and is never
    // stored -- a bodyless entry under the shared cache key would poison the GET.
    const outcome = await signAndFetch(sign, fetchImpl, env, key, request.method);
    if (outcome.error) {
      logger.error(`B2 read failed for ${key}: ${outcome.error}`);
      return new Response("bad gateway", { status: 502, headers: { "Cache-Control": "no-store" } });
    }

    const upstream = outcome.response;
    if (upstream.ok) {
      const headers = publicHeaders(upstream, { cacheControl: IMMUTABLE, cacheStatus: "MISS" });
      if (request.method === "HEAD") return new Response(null, { status: 200, headers });

      const response = new Response(upstream.body, { status: 200, headers });
      // Store the response, not the headers: the body streams to the client and
      // to the cache at the same time, so a miss costs one B2 read, not two.
      ctx.waitUntil?.(cache.put(cacheKey, response.clone()));
      return response;
    }

    if (upstream.status === 404) {
      return new Response("not found", {
        status: 404,
        headers: { "Cache-Control": NEGATIVE, "x-cache": "MISS" }
      });
    }

    // Never the signed request or its headers: the Authorization signature is a
    // credential. The status alone is enough to tell a 403 from a 500.
    logger.error(`B2 read failed for ${key}: status ${upstream.status}`);
    return new Response("bad gateway", { status: 502, headers: { "Cache-Control": "no-store" } });
  };
}

// A rejected fetch is a distinct outcome, not a Response: a network failure has
// no status to branch on, and Response rejects anything outside 200-599.
// `sign` is awaited because AwsClient#sign is async (WebCrypto), so a signer
// passed in as a plain function still works.
async function signAndFetch(sign, fetchImpl, env, key, method) {
  try {
    return { response: await fetchImpl(await sign(new Request(b2Url(env, key), { method }))) };
  } catch (error) {
    return { error };
  }
}

// The runtime calls this with the real fetch, caches.default and a live env
// (vars from wrangler.toml, secrets from `wrangler secret put`).
export default {
  fetch(request, env, ctx) {
    return createHandler({ env, fetchImpl: fetch, cache: caches.default })(request, ctx);
  }
};
