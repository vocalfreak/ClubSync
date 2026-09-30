import { describe, expect, it, vi } from "vitest";
import { createHandler } from "../src/index.js";

const KEY = "a".repeat(64);
const PATH = `/${KEY}.webp`;
const HOST = "https://files.cyberjayahappenings.me";

const ENV = {
  B2_ENDPOINT: "https://s3.us-west-004.backblazeb2.com",
  B2_BUCKET: "test-bucket",
  B2_REGION: "us-west-004",
  B2_READ_KEY_ID: "key-id",
  B2_READ_APP_KEY: "app-key"
};

// The Cache API's shape, with the storage it was handed, so a test can assert
// what was stored and replay it as a hit.
class FakeCache {
  constructor() {
    this.store = new Map();
    this.puts = 0;
  }

  async match(request) {
    return this.store.get(cacheKeyOf(request)) ?? undefined;
  }

  async put(request, response) {
    this.puts += 1;
    this.store.set(cacheKeyOf(request), response);
  }
}

function cacheKeyOf(request) {
  const url = new URL(request.url);
  return `${request.method} ${url.origin}${url.pathname}`;
}

// Records the request the handler would have sent upstream, so the signed URL
// and method are assertable without a network.
function upstreamStub(response) {
  const calls = [];
  const fetchImpl = vi.fn(async (request) => {
    calls.push(request);
    return response;
  });
  return { calls, fetchImpl };
}

function bytesResponse(overrides = {}) {
  return new Response("webp-bytes", {
    status: 200,
    headers: {
      "content-type": "image/webp",
      "content-length": "10",
      etag: '"abc123"',
      "x-amz-request-id": "SECRET-LOOKING-INTERNALS",
      "x-bz-file-id": "4_z2f6f213a",
      server: "cloudflare"
    },
    ...overrides
  });
}

function run({ request, cache = new FakeCache(), fetchImpl, signer, ctx } = {}) {
  const handler = createHandler({
    env: ENV,
    fetchImpl,
    cache,
    signer: signer ?? ((r) => r),
    logger: { error: vi.fn() }
  });
  return handler(request ?? new Request(`${HOST}${PATH}`), ctx ?? { waitUntil: (p) => p });
}

describe("image proxy handler", () => {
  describe("input validation", () => {
    it.each([
      ["a directory traversal attempt", "/../../etc/passwd"],
      ["a path that is not a hex digest", "/not-a-key.webp"],
      ["a key with the wrong extension", `/${KEY}.jpg`],
      ["a nested path", `/file/${KEY}.webp`],
      ["an uppercase digest", `/${KEY.toUpperCase()}.webp`],
      ["a short digest", `/${"a".repeat(63)}.webp`],
      ["a key with a trailing slash", `${PATH}/`]
    ])("404s %s without asking B2 for anything", async (_label, path) => {
      const { calls, fetchImpl } = upstreamStub(bytesResponse());

      const response = await run({ request: new Request(`${HOST}${path}`), fetchImpl });

      expect(response.status).toBe(404);
      expect(fetchImpl).not.toHaveBeenCalled();
      expect(calls).toEqual([]);
    });

    it.each(["POST", "PUT", "DELETE", "PATCH", "OPTIONS"])("405s a %s without asking B2", async (method) => {
      const { fetchImpl } = upstreamStub(bytesResponse());

      const response = await run({ request: new Request(`${HOST}${PATH}`, { method }), fetchImpl });

      expect(response.status).toBe(405);
      expect(response.headers.get("Allow")).toBe("GET, HEAD");
      expect(fetchImpl).not.toHaveBeenCalled();
    });
  });

  describe("cache miss", () => {
    it("fetches the key from B2 path-style and streams it back", async () => {
      const { calls, fetchImpl } = upstreamStub(bytesResponse());

      const response = await run({ fetchImpl });

      expect(response.status).toBe(200);
      expect(calls).toHaveLength(1);
      expect(calls[0].url).toBe(`https://s3.us-west-004.backblazeb2.com/test-bucket/${KEY}.webp`);
      expect(calls[0].method).toBe("GET");
      await expect(response.text()).resolves.toBe("webp-bytes");
    });

    it("tolerates a bare host in B2_ENDPOINT", async () => {
      const { calls, fetchImpl } = upstreamStub(bytesResponse());
      const handler = createHandler({
        env: { ...ENV, B2_ENDPOINT: "s3.us-west-004.backblazeb2.com" },
        fetchImpl,
        cache: new FakeCache(),
        signer: (r) => r,
        logger: { error: vi.fn() }
      });

      await handler(new Request(`${HOST}${PATH}`), {});

      expect(calls[0].url).toBe(`https://s3.us-west-004.backblazeb2.com/test-bucket/${KEY}.webp`);
    });

    it("returns a year-long immutable cache-control and an x-cache MISS", async () => {
      const { fetchImpl } = upstreamStub(bytesResponse());

      const response = await run({ fetchImpl });

      expect(response.headers.get("Cache-Control")).toBe("public, max-age=31536000, immutable");
      expect(response.headers.get("x-cache")).toBe("MISS");
    });

    it("stores the response in the cache for the next visitor", async () => {
      const cache = new FakeCache();
      const { fetchImpl } = upstreamStub(bytesResponse());
      const waitUntil = vi.fn();

      await run({ cache, fetchImpl, ctx: { waitUntil } });

      expect(waitUntil).toHaveBeenCalledOnce();
      expect(cache.puts).toBe(1);
    });

    it("forwards only whitelisted headers, never B2's own", async () => {
      const { fetchImpl } = upstreamStub(bytesResponse());

      const response = await run({ fetchImpl });

      expect(response.headers.get("Content-Type")).toBe("image/webp");
      expect(response.headers.get("Content-Length")).toBe("10");
      expect(response.headers.get("ETag")).toBe('"abc123"');
      expect(response.headers.get("Access-Control-Allow-Origin")).toBe("*");
      expect([...response.headers.keys()].some((h) => h.startsWith("x-amz-"))).toBe(false);
      expect(response.headers.get("x-amz-request-id")).toBeNull();
      expect(response.headers.get("x-bz-file-id")).toBeNull();
      expect(response.headers.get("server")).toBeNull();
    });

    it("falls back to image/webp when B2 sends no usable content type", async () => {
      const { fetchImpl } = upstreamStub(
        new Response("bytes", { status: 200, headers: { "content-type": "application/octet-stream" } })
      );

      const response = await run({ fetchImpl });

      expect(response.headers.get("Content-Type")).toBe("image/webp");
    });

    it("ignores the query string and does not fan out into a second cache key", async () => {
      const cache = new FakeCache();
      const { calls, fetchImpl } = upstreamStub(bytesResponse());

      await run({ request: new Request(`${HOST}${PATH}?v=2&cb=123`), cache, fetchImpl });
      const second = await run({ request: new Request(`${HOST}${PATH}`), cache, fetchImpl });

      expect(calls).toHaveLength(1);
      expect(second.headers.get("x-cache")).toBe("HIT");
    });
  });

  describe("cache hit", () => {
    it("serves the stored response with x-cache HIT and no B2 call", async () => {
      const cache = new FakeCache();
      const first = upstreamStub(bytesResponse());
      await run({ cache, fetchImpl: first.fetchImpl });

      const { calls, fetchImpl } = upstreamStub(bytesResponse());
      const response = await run({ cache, fetchImpl });

      expect(response.status).toBe(200);
      expect(response.headers.get("x-cache")).toBe("HIT");
      expect(await response.text()).toBe("webp-bytes");
      expect(fetchImpl).not.toHaveBeenCalled();
      expect(calls).toEqual([]);
    });

    it("answers a HEAD from the cache without sending a body", async () => {
      const cache = new FakeCache();
      await run({ cache, fetchImpl: upstreamStub(bytesResponse()).fetchImpl });

      const response = await run({ cache, request: new Request(`${HOST}${PATH}`, { method: "HEAD" }) });

      expect(response.status).toBe(200);
      expect(response.headers.get("x-cache")).toBe("HIT");
      expect(response.headers.get("Content-Length")).toBe("10");
      await expect(response.text()).resolves.toBe("");
    });
  });

  describe("HEAD on a miss", () => {
    it("asks B2 with HEAD, returns headers only, and stores nothing", async () => {
      const cache = new FakeCache();
      const { calls, fetchImpl } = upstreamStub(bytesResponse());

      const response = await run({ cache, request: new Request(`${HOST}${PATH}`, { method: "HEAD" }), fetchImpl });

      expect(calls[0].method).toBe("HEAD");
      expect(response.status).toBe(200);
      expect(response.headers.get("x-cache")).toBe("MISS");
      expect(response.headers.get("Content-Length")).toBe("10");
      expect(await response.text()).toBe("");
      expect(cache.puts).toBe(0);
    });
  });

  describe("B2 failures", () => {
    it("404s a well-formed key that does not exist, cached briefly", async () => {
      const { fetchImpl } = upstreamStub(new Response("nope", { status: 404 }));

      const response = await run({ fetchImpl });

      expect(response.status).toBe(404);
      expect(response.headers.get("Cache-Control")).toBe("public, max-age=60");
      expect(response.headers.get("x-cache")).toBe("MISS");
    });

    it.each([403, 400, 500, 503])("502s a B2 %i and never leaks upstream headers", async (status) => {
      const { fetchImpl } = upstreamStub(new Response("denied", { status }));

      const response = await run({ fetchImpl });

      expect(response.status).toBe(502);
      expect(response.headers.get("Cache-Control")).toBe("no-store");
      expect(response.headers.get("x-amz-request-id")).toBeNull();
      await expect(response.text()).resolves.toBe("bad gateway");
    });

    it("502s a network failure instead of throwing", async () => {
      const fetchImpl = vi.fn(async () => {
        throw new TypeError("fetch failed");
      });
      const logger = { error: vi.fn() };
      const handler = createHandler({
        env: ENV,
        fetchImpl,
        cache: new FakeCache(),
        signer: (r) => r,
        logger
      });

      const response = await handler(new Request(`${HOST}${PATH}`), {});

      expect(response.status).toBe(502);
      expect(logger.error).toHaveBeenCalledOnce();
    });

    it("logs the status but not the signature when a read fails", async () => {
      const logger = { error: vi.fn() };
      const signer = (request) => new Request(request, { headers: { authorization: "AWS4-HMAC-SHA256 Credential=abc" } });
      const handler = createHandler({
        env: ENV,
        fetchImpl: vi.fn(async () => new Response("no", { status: 403 })),
        cache: new FakeCache(),
        signer,
        logger
      });

      await handler(new Request(`${HOST}${PATH}`), {});

      expect(logger.error).toHaveBeenCalledOnce();
      expect(logger.error.mock.calls[0].join(" ")).not.toContain("AWS4-HMAC-SHA256");
      expect(logger.error.mock.calls[0].join(" ")).toContain("403");
    });
  });

  describe("signing", () => {
    it("signs the B2 request with SigV4 for the configured region", async () => {
      const { calls, fetchImpl } = upstreamStub(bytesResponse());
      const handler = createHandler({
        env: ENV,
        fetchImpl,
        cache: new FakeCache(),
        logger: { error: vi.fn() }
      });

      await handler(new Request(`${HOST}${PATH}`), {});

      const auth = calls[0].headers.get("authorization");
      expect(auth).toMatch(/^AWS4-HMAC-SHA256 Credential=key-id/);
      expect(auth).toContain("/us-west-004/s3/aws4_request");
    });
  });
});
