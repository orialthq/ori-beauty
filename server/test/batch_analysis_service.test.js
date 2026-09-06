import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdir, mkdtemp, readFile, readdir, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { createBatchAnalysisService } from "../src/batch_analysis_service.js";
import { buildAnalysisRequest } from "../src/analysis_service.js";
import { OpenAITransportError } from "../src/errors.js";
import { validateAnalyzeRequest } from "../src/request_validation.js";
import { makeValidAnalysis, makeValidRequest } from "./fixtures.js";

const id = (index) => createHash("sha256").update(String(index)).digest("hex");
const input = (index = 0) => validateAnalyzeRequest(makeValidRequest({ capture: { sourceApp: `app-${index}` } }));
const successRow = (requestId, overrides = {}) => ({
  custom_id: requestId,
  response: { status_code: 200, body: { status: "completed", output_text: JSON.stringify(makeValidAnalysis(overrides)) } },
  error: null,
});

function fakeTransport() {
  const uploads = [];
  const batches = new Map();
  const files = new Map();
  const deleted = [];
  let creates = 0;
  let polls = 0;
  return {
    uploads, batches, files, deleted,
    get creates() { return creates; },
    get polls() { return polls; },
    async uploadBatchFile(path) {
      const text = await readFile(path, "utf8");
      const fileId = `file_${uploads.length}`;
      uploads.push({ fileId, text, mode: (await stat(path)).mode & 0o777 });
      return fileId;
    },
    async createBatch(fileId, groupId) {
      creates += 1;
      const batch = { id: `batch_${creates}`, input_file_id: fileId, metadata: { local_group_id: groupId }, status: "in_progress" };
      batches.set(batch.id, batch);
      return batch;
    },
    async retrieveBatch(batchId) { polls += 1; return batches.get(batchId); },
    async listBatches() { return { data: [...batches.values()], has_more: false }; },
    async *downloadLines(fileId) { for (const row of files.get(fileId) ?? []) yield row; },
    async deleteFile(fileId) { deleted.push(fileId); },
  };
}

async function setup(t, options = {}) {
  const dataDir = await mkdtemp(join(tmpdir(), "luffi-batch-test-"));
  const transport = options.transport ?? fakeTransport();
  let time = 1_000_000;
  const instances = [];
  const start = async () => {
    const service = await createBatchAnalysisService({ dataDir, transport, autoStart: false, now: () => time, ...options });
    instances.push(service);
    return service;
  };
  t.after(async () => {
    for (const service of instances) await service.close();
    await rm(dataDir, { recursive: true, force: true });
  });
  return { dataDir, transport, start, advance: (ms = 30_001) => { time += ms; }, service: await start() };
}

async function task(service, requestId) {
  return (await service.status([requestId])).tasks[0];
}

test("durably queues 75 photos in real Responses JSONL and uploads one batch", async (t) => {
  const { service, transport, dataDir } = await setup(t);
  await Promise.all(Array.from({ length: 75 }, (_, i) => service.submit(id(i), input(i))));
  assert.equal(transport.creates, 0);
  assert.equal((await readdir(join(dataDir, "payloads"))).length, 75);
  await service.flush();
  assert.equal(transport.creates, 1);
  const lines = transport.uploads[0].text.trim().split("\n").map(JSON.parse);
  assert.equal(lines.length, 75);
  assert.deepEqual(lines[0], { custom_id: id(0), method: "POST", url: "/v1/responses", body: buildAnalysisRequest(input(0)) });
  assert.equal(transport.uploads[0].mode, 0o600);
  assert.equal((await readdir(join(dataDir, "payloads"))).length, 0);
  assert.equal(service.getStats().queuedBytes, 0);
  assert.equal((await stat(join(dataDir, "tasks", `${id(0)}.json`))).mode & 0o777, 0o600);
  assert.doesNotMatch(await readFile(join(dataDir, "tasks", `${id(0)}.json`), "utf8"), /imageBase64|data:image|\/9j/);
  assert.equal((await task(service, id(0))).status, "submitted");
});

test("correlates reversed output, preserves partial success, and deletes provider files", async (t) => {
  const { service, transport, advance } = await setup(t);
  for (let i = 0; i < 3; i++) await service.submit(id(i), input(i));
  await service.flush();
  const batch = [...transport.batches.values()][0];
  batch.status = "expired";
  batch.output_file_id = "output_1";
  batch.error_file_id = "error_1";
  transport.files.set("output_1", [successRow(id(1)), successRow(id(0))]);
  transport.files.set("error_1", [{ custom_id: id(2), error: { code: "batch_expired", message: "private detail" } }]);
  advance();
  await service.flush();
  const result = await service.status([id(0), id(1), id(2)]);
  assert.deepEqual(result.tasks.map((t) => t.status), ["completed", "completed", "expired"]);
  assert.equal(result.tasks[0].result.title.value, "된장찌개");
  assert.ok(Array.isArray(result.tasks[0].result.tags));
  assert.equal(result.tasks[0].result.filing, undefined);
  assert.deepEqual(result.tasks[2].error, { code: "BATCH_EXPIRED", retryable: true });
  assert.doesNotMatch(JSON.stringify(result), /private detail/);
  assert.deepEqual(new Set(transport.deleted), new Set(["file_0", "output_1", "error_1"]));
});

test("restart preserves pending images, successful results, and request idempotency", async (t) => {
  const { service, transport, start, advance } = await setup(t);
  await service.submit(id(0), input(0));
  await service.close();
  const resumed = await start();
  assert.equal((await resumed.submit(id(0), input(0))).status, "queued");
  await resumed.flush();
  const batch = [...transport.batches.values()][0];
  batch.status = "completed";
  batch.output_file_id = "output_1";
  transport.files.set("output_1", [successRow(id(0))]);
  advance();
  await resumed.flush();
  await resumed.close();
  const final = await start();
  assert.equal((await final.submit(id(0), input(0))).status, "completed");
  assert.equal((await final.submit(id(5), input(0))).status, "completed");
  assert.equal(transport.creates, 1);
  await assert.rejects(final.submit(id(0), input(1)), (e) => e.code === "REQUEST_ID_CONFLICT" && e.httpStatus === 409);
});

test("identical effective inputs with different request IDs share one paid line", async (t) => {
  const { service, transport } = await setup(t);
  await Promise.all([service.submit(id(0), input(0)), service.submit(id(1), input(0))]);
  await service.flush();
  assert.equal(transport.uploads[0].text.trim().split("\n").length, 1);
  const result = await service.status([id(0), id(1)]);
  assert.equal(result.tasks[0].status, result.tasks[1].status);
  assert.equal(service.getStats().deduplicated, 1);
});

test("a lost create response is reconciled by durable metadata without a second POST", async (t) => {
  const transport = fakeTransport();
  const realCreate = transport.createBatch;
  transport.createBatch = async (...args) => {
    await realCreate(...args);
    throw new OpenAITransportError("timeout", { retryable: true });
  };
  const { service, start, advance } = await setup(t, { transport });
  await service.submit(id(0), input(0));
  await service.flush();
  assert.equal((await task(service, id(0))).status, "submitted");
  assert.equal(service.getStats().recovered, 1);
  await service.close();
  const resumed = await start();
  advance();
  await resumed.flush();
  assert.equal(transport.creates, 1);
});

test("an uncertain unlisted submission stays fail-closed across restarts", async (t) => {
  const transport = fakeTransport();
  let attempts = 0;
  transport.createBatch = async () => {
    attempts++;
    throw new OpenAITransportError("upstream", { upstreamStatus: 502, retryable: true });
  };
  const { service, start, advance } = await setup(t, { transport });
  await service.submit(id(0), input(0));
  await service.flush();
  assert.equal((await task(service, id(0))).status, "submission_unknown");
  await service.close();
  const resumed = await start();
  advance();
  await resumed.flush();
  const result = await resumed.submit(id(0), input(0));
  assert.equal(result.status, "submission_unknown");
  assert.deepEqual(result.error, { code: "BATCH_SUBMISSION_UNKNOWN", retryable: false });
  assert.equal(attempts, 1);
});

test("crash marker before paid creation is not interpreted as permission to recreate", async (t) => {
  const { service, start, transport, dataDir, advance } = await setup(t);
  await service.submit(id(0), input(0));
  await service.flush();
  await service.close();
  const [filename] = (await readdir(join(dataDir, "groups"))).filter((name) => name.endsWith(".json"));
  const path = join(dataDir, "groups", filename);
  const group = JSON.parse(await readFile(path, "utf8"));
  group.state = "creating";
  delete group.batchId;
  await writeFile(path, JSON.stringify(group));
  const resumed = await start();
  advance();
  await resumed.flush();
  assert.equal((await task(resumed, id(0))).status, "in_progress");
  assert.equal(transport.creates, 1);
});

test("cancelled batches keep completed rows and cancel only unresolved photos", async (t) => {
  const { service, transport, advance } = await setup(t);
  await service.submit(id(0), input(0));
  await service.submit(id(1), input(1));
  await service.flush();
  const batch = [...transport.batches.values()][0];
  batch.status = "cancelled";
  batch.output_file_id = "output_1";
  transport.files.set("output_1", [successRow(id(1))]);
  advance();
  await service.flush();
  const result = await service.status([id(0), id(1)]);
  assert.deepEqual(result.tasks.map((t) => t.status), ["cancelled", "completed"]);
});

test("invalid model results fail validation and can be retried only with a new ID", async (t) => {
  const { service, transport, advance } = await setup(t);
  await service.submit(id(0), input(0));
  await service.flush();
  const batch = [...transport.batches.values()][0];
  batch.status = "completed";
  batch.output_file_id = "output_1";
  transport.files.set("output_1", [successRow(id(0), { schemaVersion: "wrong" })]);
  advance();
  await service.flush();
  assert.equal((await service.submit(id(0), input(0))).status, "failed");
  await service.submit(id(1), input(0));
  await service.flush();
  assert.equal(transport.creates, 2);
});

test("splits files by byte bound before upload without dropping photos", async (t) => {
  const lineBytes = Buffer.byteLength(JSON.stringify({ custom_id: id(0), method: "POST", url: "/v1/responses", body: buildAnalysisRequest(input(0)) })) + 1;
  const { service, transport } = await setup(t, { maxJsonlBytes: lineBytes * 2 + 5 });
  for (let i = 0; i < 5; i++) await service.submit(id(i), input(i));
  await service.flush();
  assert.deepEqual(transport.uploads.map((u) => u.text.trim().split("\n").length), [2, 2, 1]);
  assert.ok(transport.uploads.every((u) => Buffer.byteLength(u.text) <= lineBytes * 2 + 5));
});

test("limits disk queue and receipts and rejects a second store owner", async (t) => {
  const { service, transport, dataDir } = await setup(t, { maxPendingTasks: 1, maxRecords: 2 });
  await service.submit(id(0), input(0));
  await assert.rejects(service.submit(id(1), input(1)), (e) => e.code === "BATCH_QUEUE_FULL");
  await assert.rejects(createBatchAnalysisService({ transport, dataDir, autoStart: false }), /Another process/);
});

test("frequent client polling does not bypass debounce or create repeated provider polls", async (t) => {
  const { service, transport, advance } = await setup(t);
  await service.submit(id(0), input(0));
  for (let i = 0; i < 5; i++) await task(service, id(0));
  assert.equal(transport.creates, 0);
  advance(5_001);
  await service.flush();
  await service.flush();
  assert.equal(transport.polls, 1);
  for (let i = 0; i < 5; i++) await task(service, id(0));
  await service.flush();
  assert.equal(transport.polls, 1);
});

test("retention removes analysis content but keeps a receipt that prevents recharging", async (t) => {
  const { service, transport, dataDir, advance } = await setup(t, { resultRetentionMs: 1 });
  await service.submit(id(0), input(0));
  await service.flush();
  const batch = [...transport.batches.values()][0];
  batch.status = "completed";
  batch.output_file_id = "output_1";
  transport.files.set("output_1", [successRow(id(0))]);
  advance();
  await service.flush();
  advance(3_600_001);
  await service.flush();
  const result = await service.submit(id(0), input(0));
  assert.equal(result.status, "expired");
  assert.deepEqual(result.error, { code: "BATCH_RESULT_EXPIRED", retryable: false });
  assert.deepEqual(await readdir(join(dataDir, "results")), []);
  assert.equal(transport.creates, 1);
});

test("status validates correlation IDs and missing records are explicit", async (t) => {
  const { service } = await setup(t);
  assert.deepEqual((await service.status([id(0)])).tasks, [{ requestId: id(0), status: "missing" }]);
  for (const ids of [[], [id(0), id(0)], ["../private"], Array.from({ length: 101 }, (_, i) => id(i))]) {
    await assert.rejects(service.status(ids), (e) => e.code === "INVALID_REQUEST");
  }
});

test("restart finishes interrupted private input and expired-result cleanup", async (t) => {
  const { service, dataDir, start } = await setup(t);
  await service.submit(id(0), input(0));
  await service.flush();
  await service.close();
  const [groupFile] = (await readdir(join(dataDir, "groups"))).filter((name) => name.endsWith(".json"));
  const abandonedJsonl = join(dataDir, "groups", groupFile.replace(/\.json$/, ".jsonl"));
  await writeFile(abandonedJsonl, "private screenshot from interrupted deletion");
  const taskFile = join(dataDir, "tasks", `${id(0)}.json`);
  const receipt = JSON.parse(await readFile(taskFile, "utf8"));
  receipt.status = "expired";
  receipt.error = { code: "BATCH_RESULT_EXPIRED", retryable: false };
  await writeFile(taskFile, JSON.stringify(receipt));
  await writeFile(join(dataDir, "results", `${id(0)}.json`), JSON.stringify(makeValidAnalysis()));
  const resumed = await start();
  assert.equal((await task(resumed, id(0))).status, "expired");
  assert.equal((await readdir(join(dataDir, "groups"))).includes(groupFile.replace(/\.json$/, ".jsonl")), false);
  assert.deepEqual(await readdir(join(dataDir, "results")), []);
});

test("concurrent stale-lock recovery admits at most one new server owner", async (t) => {
  const { service, dataDir, start } = await setup(t);
  await service.close();
  await mkdir(join(dataDir, ".lock"));
  await writeFile(join(dataDir, ".lock", "owner.json"), JSON.stringify({ pid: 2_147_483_647, token: "dead" }));
  const outcomes = await Promise.allSettled([start(), start()]);
  assert.equal(outcomes.filter((outcome) => outcome.status === "fulfilled").length, 1);
  assert.equal(outcomes.filter((outcome) => outcome.status === "rejected").length, 1);
});
