import assert from "node:assert/strict";
import { once } from "node:events";
import test from "node:test";
import { createHttpServer } from "../src/http_app.js";
import { OpenAITransportError } from "../src/errors.js";
import { validateAnalysisResult } from "../src/result_validation.js";
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
    schemaVersion: "2.1",
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
  assert.deepEqual(received.vocabulary, []);
});

test("forwards the reader's vocabulary and rejects a malformed one", async (t) => {
  let received;
  const baseUrl = await startServer(t, {
    analysisService: {
      async analyze(input) {
        received = input;
        return makeValidAnalysis();
      },
    },
  });

  const accepted = await fetch(`${baseUrl}/v1/analyze`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(
      makeValidRequest({ vocabulary: [{ value: "맛집·카페", count: 41 }] }),
    ),
  });
  assert.equal(accepted.status, 200);
  assert.deepEqual(received.vocabulary, [{ value: "맛집·카페", count: 41 }]);

  const rejected = await fetch(`${baseUrl}/v1/analyze`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(
      makeValidRequest({ vocabulary: [{ value: "맛집·카페", count: "41" }] }),
    ),
  });
  assert.equal(rejected.status, 400);
  assert.equal((await rejected.json()).error.code, "INVALID_REQUEST");
});

test("the analyze debug log reads the flat tag list", async (t) => {
  // It used to read result.axes.kind, which no longer exists: with the flag
  // on, every successful analysis threw after the model had been paid.
  process.env.TRUN_ON_DEBUG_LOG = "1";
  t.after(() => delete process.env.TRUN_ON_DEBUG_LOG);
  const log = t.mock.method(console, "log", () => {});
  const baseUrl = await startServer(t, {
    analysisService: {
      async analyze() {
        return validateAnalysisResult(makeValidAnalysis());
      },
    },
  });

  const response = await fetch(`${baseUrl}/v1/analyze`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(makeValidRequest()),
  });

  assert.equal(response.status, 200);
  const line = log.mock.calls.find((call) => call.arguments[0].startsWith("[analyze]"));
  assert.match(line.arguments[0], /tags=2 facets=field:1\|kind:1/);
  // Counts only: the words are the reader's.
  assert.doesNotMatch(line.arguments[0], /국·찌개/);
});

test("tag merges answer 503 until a service is wired in", async (t) => {
  const baseUrl = await startServer(t);
  const response = await fetch(`${baseUrl}/v1/tag-merges`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      vocabulary: [
        { value: "스킨케어", count: 9 },
        { value: "스킨 케어", count: 1 },
      ],
    }),
  });

  assert.equal(response.status, 503);
  assert.equal((await response.json()).error.code, "TAG_MERGES_NOT_CONFIGURED");
});

test("tag merges validate the vocabulary and pass it through", async (t) => {
  let received;
  const baseUrl = await startServer(t, {
    tagMergeService: {
      async merge(input) {
        received = input;
        return {
          merges: [
            { from: "스킨 케어", into: "스킨케어", reason: "띄어쓰기·구분자만 다른 같은 말이에요." },
          ],
        };
      },
    },
  });
  const post = (body) =>
    fetch(`${baseUrl}/v1/tag-merges`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });

  const ok = await post({
    vocabulary: [
      { value: "스킨케어", count: 9 },
      { value: "스킨 케어", count: 1 },
    ],
  });
  assert.equal(ok.status, 200);
  assert.deepEqual(await ok.json(), {
    merges: [
      { from: "스킨 케어", into: "스킨케어", reason: "띄어쓰기·구분자만 다른 같은 말이에요." },
    ],
  });
  assert.deepEqual(received.vocabulary, [
    { value: "스킨케어", count: 9 },
    { value: "스킨 케어", count: 1 },
  ]);

  for (const body of [
    {},
    { vocabulary: [{ value: "스킨케어", count: 9 }] },
    { vocabulary: [{ value: "스킨케어", count: 9 }, { value: "뷰", count: 1 }] },
    { vocabulary: [{ value: "스킨케어", count: 9 }, { value: "뷰티", count: 1.5 }] },
    { vocabulary: [{ value: "스킨케어", count: 9 }, { value: "뷰티" }] },
    { vocabulary: [{ value: "스킨케어", count: 9 }, { value: "뷰티", count: 1 }], plan: {} },
  ]) {
    const response = await post(body);
    assert.equal(response.status, 400, JSON.stringify(body));
    assert.equal((await response.json()).error.code, "INVALID_REQUEST");
  }

  const tooBig = await post({
    vocabulary: Array.from({ length: 2_000 }, (_, index) => ({
      value: `태그${index}`,
      count: 1,
    })),
  });
  assert.equal(tooBig.status, 413);
  assert.equal((await tooBig.json()).error.code, "PAYLOAD_TOO_LARGE");
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
