import assert from "node:assert/strict";
import { mkdtemp, writeFile, rm } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import test from "node:test";
import { createOpenAIBatchTransport } from "../src/openai_batch_transport.js";
import { OpenAITransportError } from "../src/errors.js";

test("uploads JSONL as multipart purpose=batch and creates the real 24h contract", async (t) => {
  const directory = await mkdtemp(join(tmpdir(), "luffi-batch-transport-"));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const filePath = join(directory, "input.jsonl");
  const line = JSON.stringify({ custom_id: "capture-id", method: "POST", url: "/v1/responses", body: { model: "gpt-5.6-luna" } });
  await writeFile(filePath, `${line}\n`);
  const requests = [];
  const transport = createOpenAIBatchTransport({
    apiKey: "test-only-key", baseUrl: "https://example.invalid/v1",
    fetchImpl: async (url, options) => {
      requests.push({ url, options });
      if (url.endsWith("/files")) {
        assert.ok(options.body instanceof FormData);
        assert.equal(options.body.get("purpose"), "batch");
        assert.equal(await options.body.get("file").text(), `${line}\n`);
        assert.equal(options.headers["Content-Type"], undefined);
        return Response.json({ id: "file_123" });
      }
      return Response.json({ id: "batch_123", status: "validating" });
    },
  });
  assert.equal(await transport.uploadBatchFile(filePath), "file_123");
  await transport.createBatch("file_123", "local-group");
  assert.equal(requests[1].url, "https://example.invalid/v1/batches");
  assert.deepEqual(JSON.parse(requests[1].options.body), {
    input_file_id: "file_123", endpoint: "/v1/responses", completion_window: "24h",
    metadata: { local_group_id: "local-group" },
  });
  assert.equal(requests[1].options.headers.Authorization, "Bearer test-only-key");
});

test("streams split UTF-8 JSONL and accepts a final line without newline", async () => {
  const encoded = Buffer.from('{"custom_id":"1","value":"러피"}\n{"custom_id":"2"}');
  const transport = createOpenAIBatchTransport({
    apiKey: "test-only-key",
    fetchImpl: async () => new Response(new ReadableStream({
      start(controller) {
        for (let i = 0; i < encoded.length; i += 2) controller.enqueue(encoded.subarray(i, i + 2));
        controller.close();
      },
    })),
  });
  const lines = [];
  for await (const line of transport.downloadLines("file_1")) lines.push(line);
  assert.deepEqual(lines, [{ custom_id: "1", value: "러피" }, { custom_id: "2" }]);
});

test("bounds downloaded file and individual line sizes", async () => {
  for (const options of [{ maxFileBytes: 8 }, { maxLineBytes: 8 }]) {
    const transport = createOpenAIBatchTransport({
      apiKey: "test-only-key", ...options,
      fetchImpl: async () => new Response('{"private":"large-data"}\n'),
    });
    await assert.rejects(async () => {
      for await (const line of transport.downloadLines("file_1")) void line;
    }, (error) => error.kind === "invalid_response" && !error.message.includes("private"));
  }
});

test("preserves status for safe create rejection but never exposes provider details", async () => {
  const transport = createOpenAIBatchTransport({
    apiKey: "test-only-key",
    fetchImpl: async () => Response.json({ error: { message: "private provider text" } }, { status: 429 }),
  });
  await assert.rejects(transport.createBatch("file_1", "group"), (error) =>
    error instanceof OpenAITransportError && error.kind === "rate_limited" && error.upstreamStatus === 429 && !error.message.includes("private"));
});

test("bounds a create request even if injected fetch ignores abort", async () => {
  const keepAlive = setTimeout(() => {}, 1000);
  try {
    const transport = createOpenAIBatchTransport({ apiKey: "test-only-key", timeoutMs: 10, fetchImpl: () => new Promise(() => {}) });
    await assert.rejects(transport.createBatch("file_1", "group"), (error) => error.kind === "timeout");
  } finally { clearTimeout(keepAlive); }
});

test("bounds a stalled streamed output reader", async () => {
  const keepAlive = setTimeout(() => {}, 1000);
  try {
    const transport = createOpenAIBatchTransport({
      apiKey: "test-only-key", timeoutMs: 10,
      fetchImpl: async () => new Response(new ReadableStream({ start() {} })),
    });
    await assert.rejects(async () => {
      for await (const line of transport.downloadLines("file_1")) void line;
    }, (error) => error.kind === "timeout");
  } finally { clearTimeout(keepAlive); }
});
