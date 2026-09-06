import { createHash } from "node:crypto";
import {
  DEFAULT_ANALYSIS_TIMEOUT_MS,
  MODEL,
} from "./constants.js";
import { ANALYSIS_TEXT_FORMAT } from "./analysis_schema.js";
import { OpenAITransportError } from "./errors.js";
import { buildOpenAIRequest } from "./prompt.js";
import { validateAnalysisResult } from "./result_validation.js";

const MAX_CONCURRENT_UPSTREAM_REQUESTS = 4;
const MAX_QUEUED_UPSTREAM_REQUESTS = 8;
const DEFAULT_QUEUE_TIMEOUT_MS = 30_000;
const ANALYSIS_CACHE_TTL_MS = 24 * 60 * 60 * 1000;
const ANALYSIS_CACHE_MAX_ENTRIES = 256;

export function createAnalysisService({
  transport,
  timeoutMs = DEFAULT_ANALYSIS_TIMEOUT_MS,
  now = Date.now,
  maxConcurrent = MAX_CONCURRENT_UPSTREAM_REQUESTS,
  maxQueued = MAX_QUEUED_UPSTREAM_REQUESTS,
  queueTimeoutMs = DEFAULT_QUEUE_TIMEOUT_MS,
  cacheTtl = ANALYSIS_CACHE_TTL_MS,
  cacheMax = ANALYSIS_CACHE_MAX_ENTRIES,
} = {}) {
  if (!transport || typeof transport.createResponse !== "function") {
    throw new Error("A transport with createResponse is required");
  }
  if (typeof now !== "function") {
    throw new Error("now must be a function");
  }
  assertPositiveInteger(maxConcurrent, "maxConcurrent");
  assertPositiveInteger(maxQueued, "maxQueued");
  assertPositiveInteger(queueTimeoutMs, "queueTimeoutMs");
  assertPositiveInteger(cacheTtl, "cacheTtl");
  assertPositiveInteger(cacheMax, "cacheMax");

  const cache = new Map();
  const inFlight = new Map();
  const waiters = [];
  let activeUpstreamRequests = 0;
  let highWater = 0;
  const counters = {
    requests: 0,
    cacheHits: 0,
    cacheMisses: 0,
    cacheExpirations: 0,
    cacheEvictions: 0,
    inFlightHits: 0,
    upstreamRequests: 0,
    upstreamSuccesses: 0,
    upstreamFailures: 0,
    queueRejections: 0,
    queueTimeouts: 0,
    inputTokens: 0,
    cachedInputTokens: 0,
    outputTokens: 0,
    reasoningTokens: 0,
  };

  function acquireUpstreamSlot() {
    if (activeUpstreamRequests < maxConcurrent && waiters.length === 0) {
      activeUpstreamRequests += 1;
      highWater = Math.max(highWater, activeUpstreamRequests);
      return Promise.resolve(releaseUpstreamSlot);
    }

    if (waiters.length >= maxQueued) {
      counters.queueRejections += 1;
      return Promise.reject(
        new OpenAITransportError("rate_limited", { retryable: true }),
      );
    }

    return new Promise((resolve, reject) => {
      const waiter = { resolve, reject, timeout: undefined };
      waiter.timeout = setTimeout(() => {
        const index = waiters.indexOf(waiter);
        if (index === -1) {
          return;
        }
        waiters.splice(index, 1);
        counters.queueTimeouts += 1;
        reject(new OpenAITransportError("timeout", { retryable: true }));
      }, queueTimeoutMs);
      waiter.timeout.unref?.();
      waiters.push(waiter);
    });
  }

  function releaseUpstreamSlot() {
    const next = waiters.shift();
    if (next) {
      // Transfer the occupied slot directly so a newly arriving request cannot
      // jump ahead of a waiter between microtasks.
      clearTimeout(next.timeout);
      next.resolve(releaseUpstreamSlot);
      return;
    }
    activeUpstreamRequests -= 1;
  }

  function removeExpiredCacheEntries(currentTime) {
    for (const [key, entry] of cache) {
      if (entry.expiresAt > currentTime) {
        continue;
      }
      cache.delete(key);
      counters.cacheExpirations += 1;
    }
  }

  function readCache(key, currentTime) {
    const entry = cache.get(key);
    if (!entry) {
      counters.cacheMisses += 1;
      return undefined;
    }
    if (entry.expiresAt <= currentTime) {
      cache.delete(key);
      counters.cacheExpirations += 1;
      counters.cacheMisses += 1;
      return undefined;
    }

    cache.delete(key);
    cache.set(key, entry);
    counters.cacheHits += 1;
    return cloneAnalysis(entry.value);
  }

  function writeCache(key, value, currentTime) {
    removeExpiredCacheEntries(currentTime);
    cache.delete(key);
    while (cache.size >= cacheMax) {
      const oldestKey = cache.keys().next().value;
      cache.delete(oldestKey);
      counters.cacheEvictions += 1;
    }
    cache.set(key, {
      expiresAt: currentTime + cacheTtl,
      value: cloneAnalysis(value),
    });
  }

  async function runAnalysis(input, requestBody) {
    const releaseUpstreamSlot = await acquireUpstreamSlot();
    const controller = new AbortController();
    let timeout;

    try {
      counters.upstreamRequests += 1;
      const transportPromise = Promise.resolve().then(() =>
        transport.createResponse(requestBody, {
          signal: controller.signal,
        }),
      );
      void transportPromise.then(
        (response) => {
          accumulateUsage(counters, response?.usage);
          releaseUpstreamSlot();
        },
        () => {
          releaseUpstreamSlot();
        },
      );
      const deadline = new Promise((_, reject) => {
        timeout = setTimeout(() => {
          controller.abort();
          reject(
            new OpenAITransportError("timeout", {
              retryable: true,
            }),
          );
        }, timeoutMs);
        timeout.unref?.();
      });
      const response = await Promise.race([
        transportPromise,
        deadline,
      ]);
      const outputText = extractOutputText(response);

      let parsed;
      try {
        parsed = JSON.parse(outputText);
      } catch (error) {
        throw new OpenAITransportError("invalid_response", {
          cause: error,
          retryable: true,
        });
      }
      const result = applyDeterministicCompletenessGuards(
        validateAnalysisResult(parsed, { vocabulary: input.vocabulary }),
      );
      counters.upstreamSuccesses += 1;
      return result;
    } catch (error) {
      counters.upstreamFailures += 1;
      if (
        controller.signal.aborted &&
        !(error instanceof OpenAITransportError)
      ) {
        throw new OpenAITransportError("timeout", {
          cause: error,
          retryable: true,
        });
      }
      throw error;
    } finally {
      clearTimeout(timeout);
    }
  }

  return {
    async analyze(input) {
      counters.requests += 1;
      const requestBody = buildOpenAIRequest({
        ...input,
        textFormat: ANALYSIS_TEXT_FORMAT,
        model: MODEL,
      });
      const key = exactRequestKey(requestBody);
      const cached = readCache(key, now());
      if (cached !== undefined) {
        return cached;
      }

      const existing = inFlight.get(key);
      if (existing) {
        counters.inFlightHits += 1;
        return cloneAnalysis(await existing);
      }

      const execution = runAnalysis(input, requestBody)
        .then((result) => {
          writeCache(key, result, now());
          return result;
        })
        .finally(() => {
          inFlight.delete(key);
        });
      inFlight.set(key, execution);
      return cloneAnalysis(await execution);
    },

    getStats() {
      removeExpiredCacheEntries(now());
      return {
        ...counters,
        maxActive: maxConcurrent,
        maxQueued,
        queueTimeoutMs,
        highWater,
        activeUpstreamRequests,
        queuedUpstreamRequests: waiters.length,
        inFlightRequests: inFlight.size,
        cacheEntries: cache.size,
      };
    },
  };
}

function exactRequestKey(requestBody) {
  const requestWithoutInlineImageBytes = JSON.stringify(
    requestBody,
    (property, value) => {
      if (
        property === "image_url" &&
        typeof value === "string" &&
        value.startsWith("data:image/")
      ) {
        return `sha256:${createHash("sha256").update(value).digest("hex")}`;
      }
      return value;
    },
  );
  return createHash("sha256")
    .update(requestWithoutInlineImageBytes)
    .digest("hex");
}

function cloneAnalysis(value) {
  return structuredClone(value);
}

function accumulateUsage(counters, usage) {
  const values = [
    ["inputTokens", usage?.input_tokens],
    ["cachedInputTokens", usage?.input_tokens_details?.cached_tokens],
    ["outputTokens", usage?.output_tokens],
    ["reasoningTokens", usage?.output_tokens_details?.reasoning_tokens],
  ];
  for (const [counter, value] of values) {
    if (typeof value === "number" && Number.isFinite(value)) {
      counters[counter] += value;
    }
  }
}

function assertPositiveInteger(value, name) {
  if (!Number.isSafeInteger(value) || value <= 0) {
    throw new Error(`${name} must be a positive integer`);
  }
}

// A capture used to be filed in one folder, and a restaurant filed under
// 건강·운동 was worth stopping the reader over: the single choice was either
// right or wrong. Tags are not exclusive, so the model no longer has to pick
// between 맛집·카페 and anything else — it emits both — and the guard that
// checked the folder against the content kind has nothing left to catch.

function applyDeterministicCompletenessGuards(result) {
  if (
    result.completeness !== "complete" ||
    !["recipe", "sauce_recipe"].includes(result.contentKind)
  ) {
    return result;
  }
  const hasBareMeasuredAmount = result.ingredientGroups.some(
    (group) =>
      !isExplicitRatioGroup(group) &&
      group.ingredients.some(
        (ingredient) =>
          ingredient.unit === null &&
          ingredient.amount !== null &&
          isBareNumericAmount(ingredient.amount),
      ),
  );
  if (!hasBareMeasuredAmount) {
    return result;
  }
  const warning = "단위가 없는 수량이 있어 확인이 필요해요.";
  return {
    ...result,
    completeness: "partial",
    warnings: result.warnings.includes(warning)
      ? result.warnings
      : [...result.warnings, warning],
  };
}

function isBareNumericAmount(value) {
  return /^[0-9]+(?:[./][0-9]+)?(?:\s*[-~–]\s*[0-9]+(?:[./][0-9]+)?)?$/.test(
    value.trim(),
  );
}

function isExplicitRatioGroup(group) {
  return (
    /비율|ratio/i.test(group.name) ||
    group.ingredients.some((ingredient) =>
      /[0-9]\s*:\s*[0-9]/.test(ingredient.originalText),
    )
  );
}

function extractOutputText(response) {
  if (!response || typeof response !== "object") {
    throw new OpenAITransportError("invalid_response", {
      retryable: true,
    });
  }

  if (response.status === "incomplete") {
    const reason = response.incomplete_details?.reason;
    if (reason === "content_filter") {
      throw new OpenAITransportError("rejected", { retryable: false });
    }
    throw new OpenAITransportError("invalid_response", { retryable: true });
  }

  if (response.error) {
    throw new OpenAITransportError("upstream", { retryable: true });
  }

  if (typeof response.output_text === "string" && response.output_text) {
    return response.output_text;
  }

  for (const output of response.output ?? []) {
    if (output?.type !== "message") {
      continue;
    }
    for (const content of output.content ?? []) {
      if (content?.type === "refusal") {
        throw new OpenAITransportError("rejected", { retryable: false });
      }
      if (content?.type === "output_text" && typeof content.text === "string") {
        return content.text;
      }
    }
  }

  throw new OpenAITransportError("invalid_response", {
    retryable: true,
  });
}
