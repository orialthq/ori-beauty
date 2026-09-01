import assert from "node:assert/strict";
import { once } from "node:events";
import test from "node:test";
import { createHttpServer } from "../src/http_app.js";
import { OpenAITransportError } from "../src/errors.js";
import {
  makeValidAnalysis,
  makeValidRequest,
} from "./fixtures.js";

async function startServer(t, options = {}) {
  const server = createHttpServer({
    analysisService: {
      async analyze() {
        return makeValidAnalysis();
      },
    },
    ...options,
  });
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  t.after(() => new Promise((resolve) => server.close(resolve)));
  const address = server.address();
  return `http://127.0.0.1:${address.port}`;
}

test("health endpoint exposes only non-sensitive service metadata", async (t) => {
  const baseUrl = await startServer(t);
  const response = await fetch(`${baseUrl}/health`);
  const body = await response.json();

  assert.equal(response.status, 200);
  assert.deepEqual(body, {
    status: "ok",
    service: "ori-capture-analysis",
    schemaVersion: "2.0",
    model: "gpt-5.6-luna",
    enrichmentModel: "gpt-5.6-luna",
  });
  assert.match(response.headers.get("x-request-id"), /^[0-9a-f-]{36}$/);
  assert.equal(response.headers.get("cache-control"), "no-store");
});

test("validates and forwards a supported image without a paid call", async (t) => {
  let received;
  const expected = makeValidAnalysis();
  const baseUrl = await startServer(t, {
    analysisService: {
      async analyze(input) {
        received = input;
        return expected;
      },
    },
  });

  const response = await fetch(`${baseUrl}/v1/analyze`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(makeValidRequest()),
  });

  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), expected);
  assert.equal(received.mimeType, "image/jpeg");
  assert.equal(received.capture.id, "capture-001");
  assert.equal(received.capture.locale, "ko-KR");
});

test("rejects a MIME and file-signature mismatch before analysis", async (t) => {
  let calls = 0;
  const baseUrl = await startServer(t, {
    analysisService: {
      async analyze() {
        calls += 1;
        return makeValidAnalysis();
      },
    },
  });

  const response = await fetch(`${baseUrl}/v1/analyze`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(
      makeValidRequest({ image: { mimeType: "image/png" } }),
    ),
  });
  const body = await response.json();

  assert.equal(response.status, 400);
  assert.equal(body.error.code, "INVALID_IMAGE");
  assert.equal(body.error.retryable, false);
  assert.equal(calls, 0);
});

test("rejects images above the configured decoded-byte limit", async (t) => {
  const baseUrl = await startServer(t, { maxImageBytes: 3 });
  const response = await fetch(`${baseUrl}/v1/analyze`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(makeValidRequest()),
  });

  assert.equal(response.status, 413);
  assert.equal((await response.json()).error.code, "IMAGE_TOO_LARGE");
});

test("normalizes invalid JSON and content type errors", async (t) => {
  const baseUrl = await startServer(t);
  const invalidJson = await fetch(`${baseUrl}/v1/analyze`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: "{",
  });
  assert.equal(invalidJson.status, 400);
  assert.equal((await invalidJson.json()).error.code, "INVALID_JSON");

  const invalidType = await fetch(`${baseUrl}/v1/analyze`, {
    method: "POST",
    headers: { "Content-Type": "text/plain" },
    body: "{}",
  });
  assert.equal(invalidType.status, 415);
  assert.equal(
    (await invalidType.json()).error.code,
    "UNSUPPORTED_CONTENT_TYPE",
  );
});

test("maps upstream rate limits to a stable app error", async (t) => {
  const baseUrl = await startServer(t, {
    analysisService: {
      async analyze() {
        throw new OpenAITransportError("rate_limited", {
          retryable: true,
        });
      },
    },
  });

  const response = await fetch(`${baseUrl}/v1/analyze`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(makeValidRequest()),
  });
  const body = await response.json();

  assert.equal(response.status, 429);
  assert.equal(body.error.code, "UPSTREAM_RATE_LIMITED");
  assert.equal(body.error.retryable, true);
  assert.equal(typeof body.error.requestId, "string");
});
