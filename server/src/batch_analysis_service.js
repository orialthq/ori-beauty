import { randomUUID } from "node:crypto";
import { mkdir, open, readFile, readdir, rename, stat, unlink, rmdir } from "node:fs/promises";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  buildAnalysisRequest, exactRequestKey, parseAnalysisResponse,
} from "./analysis_service.js";
import { AppError, OpenAITransportError, normalizeError } from "./errors.js";

const REQUEST_ID = /^[a-f0-9]{64}$/;
const GROUP_ID = /^[a-f0-9-]{36}$/;
const REMOTE_ID = /^[A-Za-z0-9_-]{1,200}$/;
const TERMINAL = new Set(["completed", "failed", "expired", "cancelled"]);
const UPSTREAM_TERMINAL = new Set(["completed", "failed", "expired", "cancelled"]);
const TASK_STATUSES = new Set(["queued", "submitted", "in_progress", "completed", "failed", "expired", "cancelled", "submission_unknown"]);
const GROUP_STATES = new Set(["prepared", "uploaded", "creating", "submission_unknown", "submitted", "terminal"]);
const DAY = 24 * 60 * 60 * 1000;

export function assertBatchRequestId(value) {
  if (typeof value !== "string" || !REQUEST_ID.test(value)) {
    throw new AppError("INVALID_REQUEST", "분석 요청 ID 형식이 올바르지 않아요.", {
      httpStatus: 400,
    });
  }
  return value;
}

/** One process owns this local store. Paid creation is preceded by a durable
 * `creating` state. A timeout or crash in that state is reconciled by metadata,
 * never by issuing another creation request. */
export async function createBatchAnalysisService({
  transport,
  analysisService = null,
  dataDir = fileURLToPath(new URL("../.local/batch-jobs", import.meta.url)),
  now = Date.now,
  debounceMs = 5_000,
  pollIntervalMs = 30_000,
  maxGroupTasks = 100,
  maxJsonlBytes = 180 * 1024 * 1024,
  maxPendingTasks = 1_000,
  maxRecords = 10_000,
  maxQueuedBytes = 2 * 1024 * 1024 * 1024,
  resultRetentionMs = 7 * DAY,
  autoStart = true,
} = {}) {
  for (const method of ["uploadBatchFile", "createBatch", "retrieveBatch", "listBatches", "downloadLines"]) {
    if (typeof transport?.[method] !== "function") throw new Error(`Batch transport requires ${method}`);
  }
  for (const [name, value] of Object.entries({ debounceMs, pollIntervalMs, maxGroupTasks,
    maxJsonlBytes, maxPendingTasks, maxRecords, maxQueuedBytes, resultRetentionMs })) {
    if (!Number.isSafeInteger(value) || value <= 0) throw new Error(`${name} must be positive`);
  }
  if (maxGroupTasks > 100 || maxJsonlBytes > 180 * 1024 * 1024) {
    throw new Error("Batch group exceeds the local safety limit");
  }
  dataDir = resolve(dataDir);
  const paths = {
    tasks: join(dataDir, "tasks"), payloads: join(dataDir, "payloads"),
    results: join(dataDir, "results"), groups: join(dataDir, "groups"),
    lock: join(dataDir, ".lock"),
  };
  const tasks = new Map();
  const groups = new Map();
  let queuedBytes = 0;
  let mutationTail = Promise.resolve();
  let tickPromise = null;
  let timer = null;
  let stopped = false;
  let closePromise = null;
  let lastMaintenance = 0;
  const lockToken = randomUUID();
  const counters = { submissions: 0, deduplicated: 0, recovered: 0, pollErrors: 0 };

  const exclusive = (operation) => {
    const result = mutationTail.then(operation);
    mutationTail = result.catch(() => {});
    return result;
  };
  const taskPath = (id) => join(paths.tasks, `${id}.json`);
  const payloadPath = (id) => join(paths.payloads, `${id}.jsonl`);
  const resultPath = (id) => join(paths.results, `${id}.json`);
  const groupPath = (id) => join(paths.groups, `${id}.json`);
  const inputPath = (id) => join(paths.groups, `${id}.jsonl`);
  const saveTask = (task) => atomicJson(taskPath(task.requestId), task);
  const saveGroup = (group) => atomicJson(groupPath(group.id), group);
  const resolvedTask = (task) => task?.aliasOf ? tasks.get(task.aliasOf) : task;

  async function publicTask(task, requestId = task?.requestId) {
    if (!task) return { requestId, status: "missing" };
    const actual = resolvedTask(task);
    if (!actual) throw storageError();
    const value = {
      requestId, status: actual.status,
      createdAt: new Date(task.createdAt).toISOString(),
      updatedAt: new Date(actual.updatedAt).toISOString(),
      ...(actual.error ? { error: structuredClone(actual.error) } : {}),
    };
    if (actual.status === "completed") {
      value.result = await readJson(resultPath(actual.requestId), 2 * 1024 * 1024);
    }
    return value;
  }

  function schedule(delay = pollIntervalMs) {
    if (!autoStart || stopped || timer) return;
    timer = setTimeout(() => {
      timer = null;
      void tick().catch(() => { counters.pollErrors += 1; });
    }, delay);
    timer.unref?.();
  }

  async function dropPayload(task) {
    await unlinkIfExists(payloadPath(task.requestId));
    queuedBytes = Math.max(0, queuedBytes - (task.requestBytes ?? 0));
    task.requestBytes = 0;
    await saveTask(task);
  }

  async function setTaskFailure(task, status, code, retryable) {
    task.status = status;
    task.error = { code, retryable };
    task.updatedAt = now();
    delete task.vocabulary;
    await saveTask(task);
    await dropPayload(task);
  }

  async function completeTask(task, result) {
    await atomicJson(resultPath(task.requestId), result);
    task.status = "completed";
    task.updatedAt = now();
    task.completedAt = now();
    delete task.error;
    delete task.vocabulary;
    await saveTask(task);
  }

  async function submit(requestId, input) {
    assertBatchRequestId(requestId);
    const requestBody = buildAnalysisRequest(input);
    const key = exactRequestKey(requestBody);
    return exclusive(async () => {
      if (stopped) throw unavailable();
      const existing = tasks.get(requestId);
      if (existing) {
        if (existing.key !== key) {
          throw new AppError("REQUEST_ID_CONFLICT", "다른 분석에 사용한 요청 ID예요.", { httpStatus: 409 });
        }
        return publicTask(existing);
      }
      if (tasks.size >= maxRecords) throw queueFull();
      const task = { requestId, key, status: "queued", createdAt: now(), updatedAt: now(), requestBytes: 0 };
      const matching = [...tasks.values()].find((candidate) => !candidate.aliasOf && candidate.key === key &&
        (!TERMINAL.has(candidate.status) || candidate.status === "completed"));
      if (matching) {
        task.aliasOf = matching.requestId;
        await saveTask(task);
        tasks.set(requestId, task);
        counters.deduplicated += 1;
        return publicTask(task);
      }
      const cached = analysisService?.getCachedResult?.(requestBody);
      if (cached) {
        await completeTask(task, cached);
        tasks.set(requestId, task);
        counters.deduplicated += 1;
        return publicTask(task);
      }
      const pendingCount = [...tasks.values()].filter((t) => !t.aliasOf && !TERMINAL.has(t.status)).length;
      if (pendingCount >= maxPendingTasks) throw queueFull();
      const line = `${JSON.stringify({ custom_id: requestId, method: "POST", url: "/v1/responses", body: requestBody })}\n`;
      task.requestBytes = Buffer.byteLength(line);
      if (task.requestBytes > maxJsonlBytes) {
        throw new AppError("IMAGE_TOO_LARGE", "이 이미지는 묶음 분석으로 보낼 수 없어요.", { httpStatus: 413 });
      }
      if (queuedBytes + task.requestBytes > maxQueuedBytes) throw queueFull();
      task.vocabulary = input.vocabulary ?? [];
      // Payload precedes the durable receipt: a successful HTTP response always
      // means the image can survive a server restart without a phone re-upload.
      await atomicWrite(payloadPath(requestId), line);
      await saveTask(task);
      tasks.set(requestId, task);
      queuedBytes += task.requestBytes;
      clearTimeout(timer);
      timer = null;
      const queuedCount = [...tasks.values()].filter((t) => !t.aliasOf && !t.groupId && t.status === "queued").length;
      schedule(queuedCount >= maxGroupTasks ? 1 : debounceMs);
      return publicTask(task);
    });
  }

  async function prepareGroup(forceSubmit) {
    return exclusive(async () => {
      const queued = [...tasks.values()].filter((task) => !task.aliasOf && !task.groupId && task.status === "queued");
      if (!forceSubmit && queued.length < maxGroupTasks &&
          (!queued.length || now() - queued[0].createdAt < debounceMs)) return null;
      const selected = [];
      let bytes = 0;
      for (const task of tasks.values()) {
        if (task.aliasOf || task.groupId || task.status !== "queued") continue;
        if (selected.length >= maxGroupTasks || bytes + task.requestBytes > maxJsonlBytes) break;
        selected.push(task);
        bytes += task.requestBytes;
      }
      if (!selected.length) return null;
      const group = { id: randomUUID(), state: "prepared", requestIds: selected.map((t) => t.requestId),
        createdAt: now(), updatedAt: now(), lastCheckedAt: 0 };
      // Group membership is durable before any network activity. On restart it
      // repairs a crash halfway through the individual membership writes.
      await saveGroup(group);
      groups.set(group.id, group);
      for (const task of selected) {
        task.groupId = group.id;
        await saveTask(task);
      }
      return group;
    });
  }

  async function buildInputFile(group) {
    const temporary = `${inputPath(group.id)}.${randomUUID()}.tmp`;
    const handle = await open(temporary, "wx", 0o600);
    let bytes = 0;
    try {
      for (const id of group.requestIds) {
        const line = await readFile(payloadPath(id));
        bytes += line.length;
        if (bytes > maxJsonlBytes) throw storageError();
        await handle.writeFile(line);
      }
      await handle.sync();
    } finally {
      await handle.close();
    }
    await rename(temporary, inputPath(group.id));
    await syncDirectory(paths.groups);
  }

  async function acceptRemoteBatch(group, remote) {
    if (!REMOTE_ID.test(remote?.id ?? "")) throw new OpenAITransportError("invalid_response", { retryable: true });
    await exclusive(async () => {
      group.batchId = remote.id;
      group.state = "submitted";
      group.updatedAt = now();
      group.lastCheckedAt = 0;
      await saveGroup(group);
      for (const id of group.requestIds) {
        const task = tasks.get(id);
        if (TERMINAL.has(task.status)) continue;
        task.status = "submitted";
        task.updatedAt = now();
        delete task.error;
        await saveTask(task);
      }
    });
  }

  async function submitGroup(group) {
    if (group.state === "prepared") {
      await buildInputFile(group);
      let inputFileId;
      try {
        inputFileId = await transport.uploadBatchFile(inputPath(group.id));
      } catch (error) {
        if (definitiveRejection(error)) {
          await failGroup(group, normalizeError(error));
        }
        // Uploading a file does not create a paid model job. A lost upload
        // receipt can be retried; only batch creation must fail closed.
        throw error;
      }
      await exclusive(async () => {
        group.inputFileId = inputFileId;
        group.state = "uploaded";
        group.updatedAt = now();
        await saveGroup(group);
      });
    }
    if (group.state !== "uploaded") return;
    await exclusive(async () => {
      // This is repeatable even if the process stopped between the durable
      // upload receipt and the removal of its individual local image copies.
      for (const id of group.requestIds) await dropPayload(tasks.get(id));
      await unlinkIfExists(inputPath(group.id));
      group.state = "creating";
      group.updatedAt = now();
      await saveGroup(group);
    });
    try {
      counters.submissions += 1;
      const remote = await transport.createBatch(group.inputFileId, group.id);
      await acceptRemoteBatch(group, remote);
    } catch (error) {
      if (definitiveRejection(error)) {
        await failGroup(group, normalizeError(error));
      } else {
        await markSubmissionUnknown(group);
        // Even a 5xx can arrive after the server created the batch. Reconcile
        // by the persisted metadata key; never retry POST /batches here.
        await recoverUnknown(group);
      }
    }
  }

  async function failGroup(group, error) {
    await exclusive(async () => {
      for (const id of group.requestIds) {
        const task = tasks.get(id);
        if (!TERMINAL.has(task.status)) await setTaskFailure(task, "failed", error.code, error.retryable);
      }
      group.state = "terminal";
      group.updatedAt = now();
      group.cleanupFiles = [group.inputFileId].filter(Boolean);
      await saveGroup(group);
      await unlinkIfExists(inputPath(group.id));
    });
  }

  async function markSubmissionUnknown(group) {
    await exclusive(async () => {
      group.state = "submission_unknown";
      group.updatedAt = now();
      await saveGroup(group);
      for (const id of group.requestIds) {
        const task = tasks.get(id);
        if (TERMINAL.has(task.status)) continue;
        task.status = "submission_unknown";
        task.error = { code: "BATCH_SUBMISSION_UNKNOWN", retryable: false };
        task.updatedAt = now();
        await saveTask(task);
      }
    });
  }

  async function recoverUnknown(group) {
    group.lastCheckedAt = now();
    await saveGroup(group);
    let after;
    const matches = [];
    // A bounded reconciliation scan deliberately does not interpret "not
    // found" as permission to charge again. The operator can inspect older
    // provider batches if this store was offline beyond the recent 2,000 jobs.
    for (let page = 0; page < 20; page += 1) {
      const listing = await transport.listBatches({ after, limit: 100 });
      if (!Array.isArray(listing?.data)) throw new OpenAITransportError("invalid_response", { retryable: true });
      for (const remote of listing.data) {
        if (remote?.metadata?.local_group_id === group.id && remote.input_file_id === group.inputFileId) {
          matches.push(remote);
        }
      }
      if (!listing.has_more) break;
      const next = listing.last_id ?? listing.data.at(-1)?.id;
      if (!REMOTE_ID.test(next ?? "") || next === after) break;
      after = next;
    }
    if (matches.length === 1) {
      await acceptRemoteBatch(group, matches[0]);
      counters.recovered += 1;
    }
  }

  async function processResultRow(group, row) {
    if (!REQUEST_ID.test(row?.custom_id ?? "") || !group.requestIds.includes(row.custom_id)) {
      throw new OpenAITransportError("invalid_response", { retryable: true });
    }
    const task = tasks.get(row.custom_id);
    if (TERMINAL.has(task.status)) return;
    if (row.error || row.response?.status_code !== 200) {
      const expired = row.error?.code === "batch_expired";
      const rejected = [400, 401, 403, 404, 422].includes(row.response?.status_code);
      await exclusive(() => setTaskFailure(task, expired ? "expired" : "failed",
        expired ? "BATCH_EXPIRED" : "BATCH_ITEM_FAILED", !rejected));
      return;
    }
    let result;
    try {
      result = parseAnalysisResponse(row.response.body, task.vocabulary);
    } catch (error) {
      const safeError = normalizeError(error);
      await exclusive(() => setTaskFailure(task, "failed", safeError.code, safeError.retryable));
      return;
    }
    await exclusive(() => completeTask(task, result));
  }

  async function pollGroup(group) {
    group.lastCheckedAt = now();
    await saveGroup(group);
    const remote = await transport.retrieveBatch(group.batchId);
    if (remote.id !== group.batchId) throw new OpenAITransportError("invalid_response", { retryable: true });
    if (!UPSTREAM_TERMINAL.has(remote.status)) {
      if (!["validating", "in_progress", "finalizing", "cancelling"].includes(remote.status)) {
        throw new OpenAITransportError("invalid_response", { retryable: true });
      }
      const status = remote.status === "validating" ? "submitted" : "in_progress";
      await exclusive(async () => {
        for (const id of group.requestIds) {
          const task = tasks.get(id);
          if (TERMINAL.has(task.status) || task.status === status) continue;
          task.status = status;
          task.updatedAt = now();
          await saveTask(task);
        }
      });
      return;
    }
    const fileIds = [...new Set([remote.output_file_id, remote.error_file_id].filter(Boolean))];
    for (const fileId of fileIds) {
      for await (const row of transport.downloadLines(fileId)) {
        await processResultRow(group, row);
      }
    }
    await exclusive(async () => {
      for (const id of group.requestIds) {
        const task = tasks.get(id);
        if (TERMINAL.has(task.status)) continue;
        const status = remote.status === "expired" || remote.status === "cancelled" ? remote.status : "failed";
        const code = remote.status === "completed" ? "BATCH_RESULT_MISSING"
          : `BATCH_${remote.status.toUpperCase()}`;
        await setTaskFailure(task, status, code, true);
      }
      group.state = "terminal";
      group.updatedAt = now();
      group.cleanupFiles = [...new Set([group.inputFileId, ...fileIds].filter(Boolean))];
      await saveGroup(group);
    });
  }

  async function cleanupGroupFiles(group) {
    if (!transport.deleteFile || !group.cleanupFiles?.length) return;
    if (group.cleanupAttemptAt && now() - group.cleanupAttemptAt < 30 * 60 * 1000) return;
    group.cleanupAttemptAt = now();
    await saveGroup(group);
    for (const id of [...group.cleanupFiles]) {
      try {
        await transport.deleteFile(id);
      } catch (error) {
        if (error?.upstreamStatus !== 404) continue;
      }
      group.cleanupFiles = group.cleanupFiles.filter((candidate) => candidate !== id);
      await saveGroup(group);
    }
  }

  async function maintain() {
    if (lastMaintenance && now() - lastMaintenance < 60 * 60 * 1000) return;
    await exclusive(async () => {
      for (const task of tasks.values()) {
        if (!task.aliasOf && TERMINAL.has(task.status) && task.status !== "completed") {
          await unlinkIfExists(resultPath(task.requestId));
        }
        if (task.aliasOf || task.status !== "completed" || now() - task.completedAt < resultRetentionMs) continue;
        // Keep a small receipt so an old request ID cannot silently trigger a
        // second paid batch after result retention expires.
        await setTaskFailure(task, "expired", "BATCH_RESULT_EXPIRED", false);
        await unlinkIfExists(resultPath(task.requestId));
      }
      lastMaintenance = now();
    });
  }

  async function tickOnce(forceSubmit) {
    await maintain();
    // Old unresolved creation states are handled before new submissions.
    for (const group of groups.values()) {
      if (stopped) return;
      try {
        if (group.state === "creating") await markSubmissionUnknown(group);
        if (group.state === "submission_unknown" && now() - group.lastCheckedAt >= pollIntervalMs) {
          await recoverUnknown(group);
        }
        if (group.state === "submitted" && (!group.lastCheckedAt || now() - group.lastCheckedAt >= pollIntervalMs)) {
          await pollGroup(group);
        }
        if (group.state === "terminal") await cleanupGroupFiles(group);
      } catch {
        counters.pollErrors += 1;
      }
    }
    // Only one group upload/create runs at once. Each iteration reads at most
    // one screenshot into RAM while creating a bounded JSONL file on disk.
    while (!stopped) {
      const group = [...groups.values()].find((g) => g.state === "prepared" || g.state === "uploaded") ?? await prepareGroup(forceSubmit);
      if (!group) break;
      try {
        await submitGroup(group);
      } catch {
        counters.pollErrors += 1;
        break;
      }
    }
  }

  function tick(forceSubmit = false) {
    if (stopped) return Promise.resolve();
    if (tickPromise) return tickPromise;
    tickPromise = tickOnce(forceSubmit).finally(() => {
      tickPromise = null;
      schedule();
    });
    return tickPromise;
  }

  async function initialize() {
    await mkdir(dataDir, { recursive: true, mode: 0o700 });
    await acquireLock(paths.lock, lockToken);
    try {
      for (const path of [paths.tasks, paths.payloads, paths.results, paths.groups]) {
        await mkdir(path, { recursive: true, mode: 0o700 });
      }
      for (const filename of await readdir(paths.tasks)) {
        if (!/^[a-f0-9]{64}\.json$/.test(filename)) continue;
        if (tasks.size >= maxRecords) throw storageError();
        const task = await readJson(join(paths.tasks, filename), 128 * 1024);
        if (task.requestId !== filename.slice(0, -5) || !REQUEST_ID.test(task.key ?? "") ||
            !TASK_STATUSES.has(task.status) || !Number.isFinite(task.createdAt) || !Number.isFinite(task.updatedAt) ||
            (task.aliasOf && !REQUEST_ID.test(task.aliasOf)) ||
            (task.groupId && !GROUP_ID.test(task.groupId))) throw storageError();
        tasks.set(task.requestId, task);
      }
      for (const filename of await readdir(paths.groups)) {
        if (!/^[a-f0-9-]{36}\.json$/.test(filename)) continue;
        const group = await readJson(join(paths.groups, filename), 128 * 1024);
        if (group.id !== filename.slice(0, -5) || !GROUP_STATES.has(group.state) || !Array.isArray(group.requestIds) ||
            group.requestIds.length > maxGroupTasks ||
            new Set(group.requestIds).size !== group.requestIds.length ||
            (["uploaded", "creating", "submission_unknown", "submitted"].includes(group.state) && !REMOTE_ID.test(group.inputFileId ?? "")) ||
            (group.state === "submitted" && !REMOTE_ID.test(group.batchId ?? "")) ||
            group.requestIds.some((id) => !REQUEST_ID.test(id) || !tasks.has(id))) throw storageError();
        groups.set(group.id, group);
        for (const id of group.requestIds) {
          const task = tasks.get(id);
          if (task.groupId && task.groupId !== group.id) throw storageError();
          task.groupId = group.id;
          if (group.state === "submitted" && task.status === "queued") task.status = "submitted";
          await saveTask(task);
        }
      }
      let restoredQueuedBytes = 0;
      for (const task of tasks.values()) {
        if (task.aliasOf && (!tasks.has(task.aliasOf) || tasks.get(task.aliasOf).aliasOf)) throw storageError();
        if (task.groupId && !groups.has(task.groupId)) throw storageError();
        const needsImage = !task.aliasOf && task.status === "queued" &&
          (!task.groupId || groups.get(task.groupId)?.state === "prepared");
        if (needsImage) {
          const info = await stat(payloadPath(task.requestId));
          if (info.size !== task.requestBytes) throw storageError();
          restoredQueuedBytes += info.size;
        } else if (task.requestBytes) {
          await dropPayload(task);
        }
      }
      queuedBytes = restoredQueuedBytes;
      for (const group of groups.values()) {
        if (group.state === "creating") await markSubmissionUnknown(group);
        if (group.state !== "prepared") await unlinkIfExists(inputPath(group.id));
      }
      // Interrupted writes have no durable receipt. Removing only known temp
      // files and unreferenced payloads avoids retaining abandoned screenshots.
      for (const path of [paths.tasks, paths.payloads, paths.results, paths.groups]) {
        for (const filename of await readdir(path)) {
          if (filename.endsWith(".tmp") || (path === paths.payloads &&
              /^[a-f0-9]{64}\.jsonl$/.test(filename) && !tasks.has(filename.slice(0, -6))) ||
              (path === paths.results && /^[a-f0-9]{64}\.json$/.test(filename) &&
               (!tasks.has(filename.slice(0, -5)) || tasks.get(filename.slice(0, -5)).status !== "completed"))) {
            await unlinkIfExists(join(path, filename));
          }
        }
      }
      schedule(debounceMs);
    } catch (error) {
      await releaseLock(paths.lock, lockToken);
      throw error;
    }
  }

  await initialize();
  return {
    submit,
    async status(requestIds) {
      if (!Array.isArray(requestIds) || !requestIds.length || requestIds.length > 100 ||
          new Set(requestIds).size !== requestIds.length) {
        throw new AppError("INVALID_REQUEST", "확인할 분석 요청은 1~100개여야 해요.", { httpStatus: 400 });
      }
      requestIds.forEach(assertBatchRequestId);
      // Phone polling never waits for provider network calls. A single-flight
      // background tick uses the same 30-second minimum as scheduled polling.
      void tick().catch(() => { counters.pollErrors += 1; });
      return exclusive(async () => ({ tasks: await Promise.all(requestIds.map((id) => publicTask(tasks.get(id), id))) }));
    },
    async flush() {
      await tickPromise;
      return tick(true);
    },
    getStats() {
      const counts = {};
      for (const task of tasks.values()) {
        const status = resolvedTask(task)?.status ?? "missing";
        counts[status] = (counts[status] ?? 0) + 1;
      }
      return { ...counters, counts, queuedBytes, groups: groups.size, maxGroupTasks,
        maxJsonlBytes, maxPendingTasks, maxRecords, resultRetentionMs };
    },
    close() {
      if (closePromise) return closePromise;
      stopped = true;
      clearTimeout(timer);
      closePromise = (async () => {
        await tickPromise;
        await mutationTail;
        await releaseLock(paths.lock, lockToken);
      })();
      return closePromise;
    },
  };
}

function queueFull() {
  return new AppError("BATCH_QUEUE_FULL", "묶음 분석 대기열이 가득 찼어요. 잠시 후 다시 시도해 주세요.", {
    httpStatus: 429, retryable: true,
  });
}

function unavailable() {
  return new AppError("BATCH_NOT_AVAILABLE", "묶음 분석 서버를 다시 연결하고 있어요.", { httpStatus: 503, retryable: true });
}

function storageError() {
  return new AppError("BATCH_STORAGE_ERROR", "저장된 분석 작업을 확인할 수 없어요.", { httpStatus: 503 });
}

function definitiveRejection(error) {
  return error instanceof OpenAITransportError && error.upstreamStatus >= 400 && error.upstreamStatus < 500;
}

async function atomicJson(path, value) {
  return atomicWrite(path, JSON.stringify(value));
}

async function atomicWrite(path, value) {
  const temporary = `${path}.${randomUUID()}.tmp`;
  const handle = await open(temporary, "wx", 0o600);
  try {
    await handle.writeFile(value);
    await handle.sync();
  } finally {
    await handle.close();
  }
  await rename(temporary, path);
  await syncDirectory(resolve(path, ".."));
}

async function syncDirectory(path) {
  const directory = await open(path, "r");
  try { await directory.sync(); } finally { await directory.close(); }
}

async function readJson(path, maxBytes) {
  const info = await stat(path);
  if (info.size > maxBytes) throw storageError();
  try { return JSON.parse(await readFile(path, "utf8")); } catch { throw storageError(); }
}

async function unlinkIfExists(path) {
  try { await unlink(path); } catch (error) { if (error.code !== "ENOENT") throw error; }
}

async function acquireLock(path, token) {
  let recoveryGuard = false;
  try {
    try {
      await mkdir(path, { mode: 0o700 });
    } catch (error) {
      if (error.code !== "EEXIST") throw error;
      // Serialize stale-owner replacement. Without this guard, two processes
      // could both observe a dead PID and the second could unlink the first's
      // newly acquired lock. An abandoned recovery guard fails closed.
      try {
        await mkdir(`${path}.recovering`, { mode: 0o700 });
        recoveryGuard = true;
      } catch {
        throw new Error("Another process is recovering the Batch store lock");
      }
      const owner = await readJson(join(path, "owner.json"), 1024);
      if (!Number.isSafeInteger(owner.pid) || owner.pid <= 0) throw storageError();
      let alive = true;
      try { process.kill(owner.pid, 0); } catch (probe) { if (probe.code === "ESRCH") alive = false; }
      if (alive) throw new Error("Another process owns the Batch store");
      await unlinkIfExists(join(path, "owner.json"));
      await rmdir(path);
      await mkdir(path, { mode: 0o700 });
    }
    await atomicJson(join(path, "owner.json"), { pid: process.pid, token });
  } finally {
    if (recoveryGuard) await rmdir(`${path}.recovering`);
  }
}

async function releaseLock(path, token) {
  const owner = await readJson(join(path, "owner.json"), 1024);
  if (owner.token !== token) throw storageError();
  await unlinkIfExists(join(path, "owner.json"));
  await rmdir(path);
}
