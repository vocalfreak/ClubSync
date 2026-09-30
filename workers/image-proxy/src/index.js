import { AwsClient } from "aws4fetch";

// Only /<64 hex>.webp is served, so arbitrary paths never become B2 requests.
const KEY_PATTERN = /^\/[a-f0-9]{64}\.webp$/;

// Keys are content hashes, so the bytes at a key never change.
const IMMUTABLE = "public, max-age=31536000, immutable";

// Missing keys are cached briefly to protect B2, but not long: the fix is a rekey.
const NEGATIVE = "public, max-age=60";

const DEFAULT_TYPE = "image/webp";

// Builds the client-facing headers from a whitelist. B2 headers (x-amz-*, x-bz-*)
// are never forwarded. x-cache is set here so the cache can be verified with curl.
function publicHeaders(upstream, { cacheControl, cacheStatus }) {
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

// Wraps AwsClient#sign (async) in a plain function so tests can inject a fake.
function buildSigner(env) {
  const aws = new AwsClient({
    accessKeyId: env.B2_READ_KEY_ID,
    secretAccessKey: env.B2_READ_APP_KEY,
    service: "s3",
    region: env.B2_REGION
  });
  return (request) => aws.sign(request);
}

// Accepts a bare host or a full URL, matching whatever ObjectStore reads from .env.
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

    // Cache key is a plain GET with no query string, so HEAD and GET share an
    // entry and ?v=2 can't create duplicates.
    const cacheKey = new Request(`${origin}${key}`, { method: "GET" });
    const cached = await cache.match(cacheKey);
    if (cached) {
      const headers = new Headers(cached.headers);
      headers.set("x-cache", "HIT");
      return new Response(request.method === "HEAD" ? null : cached.body, { status: cached.status, headers });
    }

    // HEAD responses are never cached: a bodyless entry would break later GETs.
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
      // Clone so the body streams to the client and the cache with one B2 read.
      ctx.waitUntil?.(cache.put(cacheKey, response.clone()));
      return response;
    }

    if (upstream.status === 404) {
      return new Response("not found", {
        status: 404,
        headers: { "Cache-Control": NEGATIVE, "x-cache": "MISS" }
      });
    }

    // Log the status only: the signed request carries a credential.
    logger.error(`B2 read failed for ${key}: status ${upstream.status}`);
    return new Response("bad gateway", { status: 502, headers: { "Cache-Control": "no-store" } });
  };
}

// Returns { response } or { error }: a network failure has no status to branch on.
async function signAndFetch(sign, fetchImpl, env, key, method) {
  try {
    return { response: await fetchImpl(await sign(new Request(b2Url(env, key), { method }))) };
  } catch (error) {
    return { error };
  }
}

// Cloudflare calls this on every request. Vars come from wrangler.toml,
// secrets from `wrangler secret put`.
export default {
  fetch(request, env, ctx) {
    return createHandler({ env, fetchImpl: fetch, cache: caches.default })(request, ctx);
  }
};