import { openAsBlob } from "node:fs";
import { OpenAITransportError } from "./errors.js";

const MAX_JSON_BYTES = 2 * 1024 * 1024;
const MAX_FILE_BYTES = 200 * 1024 * 1024;

// Files are streamed from disk by FormData/openAsBlob. Output JSONL is decoded
// one bounded line at a time; neither a 100-image input nor its output is loaded
// into one JavaScript string.
export function createOpenAIBatchTransport({
  apiKey,
  fetchImpl = globalThis.fetch,
  baseUrl = "https://api.openai.com/v1",
  timeoutMs = 120_000,
  maxFileBytes = MAX_FILE_BYTES,
  maxLineBytes = MAX_JSON_BYTES,
} = {}) {
  if (typeof apiKey !== "string" || !apiKey) {
    throw new Error("OPENAI_API_KEY is required");
  }
  if (typeof fetchImpl !== "function") throw new Error("fetch is required");

  async function request(path, { method = "GET", body, json = true } = {}) {
    const controller = new AbortController();
    let timer;
    try {
      const deadline = new Promise((_, reject) => {
        timer = setTimeout(() => {
          controller.abort();
          reject(new OpenAITransportError("timeout", { retryable: true }));
        }, timeoutMs);
        timer.unref?.();
      });
      const operation = (async () => {
        const response = await fetchImpl(`${baseUrl}${path}`, {
          method,
          headers: {
            Authorization: `Bearer ${apiKey}`,
            ...(body && json ? { "Content-Type": "application/json" } : {}),
          },
          ...(body ? { body: json ? JSON.stringify(body) : body } : {}),
          signal: controller.signal,
        });
        if (!response.ok) {
          await response.body?.cancel?.();
          throw statusError(response.status);
        }
        const chunks = [];
        for await (const chunk of boundedChunks(response, MAX_JSON_BYTES)) {
          chunks.push(chunk);
        }
        try {
          const value = JSON.parse(Buffer.concat(chunks).toString("utf8"));
          if (!value || typeof value !== "object" || Array.isArray(value)) {
            throw new Error("Expected an object");
          }
          return value;
        } catch {
          throw invalidResponse();
        }
      })();
      return await Promise.race([operation, deadline]);
    } catch (error) {
      throw transportError(error, controller.signal.aborted);
    } finally {
      clearTimeout(timer);
    }
  }

  return {
    async uploadBatchFile(filePath) {
      const file = await openAsBlob(filePath, { type: "application/jsonl" });
      if (file.size > maxFileBytes) throw invalidResponse();
      const form = new FormData();
      form.set("purpose", "batch");
      form.set("file", file, "luffi-analysis.jsonl");
      const result = await request("/files", {
        method: "POST", body: form, json: false,
      });
      if (!validRemoteId(result.id)) throw invalidResponse();
      return result.id;
    },

    createBatch(inputFileId, localGroupId) {
      return request("/batches", {
        method: "POST",
        body: {
          input_file_id: checkedId(inputFileId),
          endpoint: "/v1/responses",
          completion_window: "24h",
          metadata: { local_group_id: localGroupId },
        },
      });
    },

    retrieveBatch(batchId) {
      return request(`/batches/${checkedId(batchId)}`);
    },

    listBatches({ after, limit = 100 } = {}) {
      const query = new URLSearchParams({ limit: String(limit) });
      if (after) query.set("after", checkedId(after));
      return request(`/batches?${query}`);
    },

    deleteFile(fileId) {
      return request(`/files/${checkedId(fileId)}`, { method: "DELETE" });
    },

    async *downloadLines(fileId) {
      const controller = new AbortController();
      let timer;
      const deadline = new Promise((_, reject) => {
        timer = setTimeout(() => {
          controller.abort();
          reject(new OpenAITransportError("timeout", { retryable: true }));
        }, timeoutMs);
        timer.unref?.();
      });
      // The rejection is also observed while a consumer persists a yielded
      // result; no unhandled rejection when file processing reaches its limit.
      void deadline.catch(() => {});
      let iterator;
      try {
        const response = await Promise.race([
          fetchImpl(`${baseUrl}/files/${checkedId(fileId)}/content`, {
            headers: { Authorization: `Bearer ${apiKey}` },
            signal: controller.signal,
          }),
          deadline,
        ]);
        if (!response.ok) {
          await response.body?.cancel?.();
          throw statusError(response.status);
        }
        iterator = boundedChunks(response, maxFileBytes)[Symbol.asyncIterator]();
        let buffer = Buffer.alloc(0);
        while (true) {
          const { done, value } = await Promise.race([iterator.next(), deadline]);
          if (done) break;
          buffer = Buffer.concat([buffer, value]);
          let newline;
          while ((newline = buffer.indexOf(10)) >= 0) {
            if (newline > maxLineBytes) throw invalidResponse();
            const line = buffer.subarray(0, newline).toString("utf8").trim();
            buffer = buffer.subarray(newline + 1);
            if (line) yield parseLine(line);
          }
          if (buffer.length > maxLineBytes) throw invalidResponse();
        }
        const tail = buffer.toString("utf8").trim();
        if (tail) yield parseLine(tail);
      } catch (error) {
        throw transportError(error, controller.signal.aborted);
      } finally {
        clearTimeout(timer);
        controller.abort();
        // Do not let a broken transport that ignores abort hold the timeout
        // path hostage while its pending reader.next() never settles.
        void iterator?.return?.().catch(() => {});
      }
    },
  };
}

function parseLine(line) {
  try {
    const value = JSON.parse(line);
    if (!value || typeof value !== "object" || Array.isArray(value)) throw 0;
    return value;
  } catch {
    throw invalidResponse();
  }
}

async function* boundedChunks(response, maxBytes) {
  const length = Number(response.headers?.get?.("content-length"));
  if (Number.isFinite(length) && length > maxBytes) {
    await response.body?.cancel?.();
    throw invalidResponse();
  }
  if (!response.body?.getReader) {
    const bytes = Buffer.from(await response.text());
    if (bytes.length > maxBytes) throw invalidResponse();
    yield bytes;
    return;
  }
  const reader = response.body.getReader();
  let total = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      total += value.byteLength;
      if (total > maxBytes) throw invalidResponse();
      yield Buffer.from(value);
    }
  } finally {
    await reader.cancel().catch(() => {});
    reader.releaseLock();
  }
}

function validRemoteId(value) {
  return typeof value === "string" && /^[A-Za-z0-9_-]{1,200}$/.test(value);
}

function checkedId(value) {
  if (!validRemoteId(value)) throw invalidResponse();
  return value;
}

function invalidResponse() {
  return new OpenAITransportError("invalid_response", { retryable: true });
}

function transportError(error, timedOut) {
  if (error instanceof OpenAITransportError) return error;
  return new OpenAITransportError(timedOut ? "timeout" : "network", {
    retryable: true,
  });
}

function statusError(status) {
  const kind = status === 401 || status === 403 ? "authentication"
    : status === 429 ? "rate_limited"
    : status >= 400 && status < 500 ? "rejected" : "upstream";
  return new OpenAITransportError(kind, {
    upstreamStatus: status,
    retryable: status === 429 || status >= 500,
  });
}
