import { randomUUID } from "node:crypto";
import { createServer } from "node:http";
import {
  DEFAULT_BODY_TIMEOUT_MS,
  DEFAULT_MAX_BODY_BYTES,
  DEFAULT_MAX_IMAGE_BYTES,
  MODEL,
  SCHEMA_VERSION,
} from "./constants.js";
import { AppError, normalizeError } from "./errors.js";
import { assertBatchRequestId } from "./batch_analysis_service.js";
import {
  validateAnalyzeRequest,
  validateEnrichPlaceRequest,
  validatePlanRecommendationRequest,
  validateResolvePlaceRequest,
  validateTagMergesRequest,
  validateTagSensesRequest,
} from "./request_validation.js";

export function createHttpServer({
  analysisService,
  batchAnalysisService = null,
  enrichmentService = null,
  placeResolutionService = null,
  recommendationService = null,
  tagMergeService = null,
  tagSenseService = null,
  // Reported by /health so a comparison run can confirm which provider answered
  // rather than inferring it from the labels.
  enrichmentModel = MODEL,
  analysisStatsEnabled = false,
  maxBodyBytes = DEFAULT_MAX_BODY_BYTES,
  maxImageBytes = DEFAULT_MAX_IMAGE_BYTES,
  bodyTimeoutMs = DEFAULT_BODY_TIMEOUT_MS,
} = {}) {
  if (!analysisService || typeof analysisService.analyze !== "function") {
    throw new Error("An analysisService is required");
  }
  if (
    placeResolutionService &&
    typeof placeResolutionService.resolve !== "function"
  ) {
    throw new Error("A placeResolutionService must expose resolve()");
  }
  if (enrichmentService && typeof enrichmentService.enrich !== "function") {
    throw new Error("An enrichmentService must expose enrich()");
  }
  if (
    recommendationService &&
    typeof recommendationService.recommend !== "function"
  ) {
    throw new Error("A recommendationService must expose recommend()");
  }
  if (tagMergeService && typeof tagMergeService.merge !== "function") {
    throw new Error("A tagMergeService must expose merge()");
  }
  if (tagSenseService && typeof tagSenseService.describe !== "function") {
    throw new Error("A tagSenseService must expose describe()");
  }

  return createServer(async (request, response) => {
    const requestId = randomUUID();
    setCommonHeaders(response, requestId);

    try {
      const url = new URL(request.url ?? "/", "http://localhost");

      if (url.pathname === "/health") {
        if (request.method !== "GET") {
          throw methodNotAllowed("GET");
        }
        const analysis =
          analysisStatsEnabled &&
          typeof analysisService.getStats === "function"
            ? analysisService.getStats()
            : null;
        return sendJson(response, 200, {
          status: "ok",
          service: "ori-capture-analysis",
          schemaVersion: SCHEMA_VERSION,
          model: MODEL,
          enrichmentModel,
          ...(analysis === null ? {} : { analysis }),
        });
      }

      if (url.pathname === "/v1/analyze") {
        if (request.method !== "POST") {
          throw methodNotAllowed("POST");
        }
        assertJsonContentType(request.headers["content-type"]);
        const body = await readJsonBody(request, {
          maxBodyBytes,
          timeoutMs: bodyTimeoutMs,
        });
        const input = validateAnalyzeRequest(body, { maxImageBytes });
        const result = await analysisService.analyze(input);
        if (process.env.TRUN_ON_DEBUG_LOG === "1") {
          // Opt-in and local only. Counts per facet, never the words: a tag is
          // the reader's own vocabulary once it lands in their library.
          const facets = {};
          for (const tag of result.tags) {
            facets[tag.facet] = (facets[tag.facet] ?? 0) + 1;
          }
          console.log(
            `[analyze] kind=${result.contentKind} ` +
              `place=${result.place.name === null ? "no" : "yes"} ` +
              `tags=${result.tags.length} ` +
              `facets=${
                Object.entries(facets)
                  .map(([facet, count]) => `${facet}:${count}`)
                  .join("|") || "-"
              }`,
          );
        }
        return sendJson(response, 200, result);
      }

      if (url.pathname === "/v1/analysis-tasks" || url.pathname === "/v1/analysis-tasks/status") {
        if (request.method !== "POST") throw methodNotAllowed("POST");
        if (!batchAnalysisService) {
          throw new AppError("BATCH_NOT_CONFIGURED", "묶음 분석을 사용할 수 없어요.", {
            httpStatus: 503, retryable: true,
          });
        }
        assertJsonContentType(request.headers["content-type"]);
        const isStatus = url.pathname.endsWith("/status");
        const body = await readJsonBody(request, {
          maxBodyBytes: isStatus ? 16 * 1024 : maxBodyBytes,
          timeoutMs: bodyTimeoutMs,
        });
        const allowed = isStatus ? ["requestIds"] : ["requestId", "input"];
        if (!body || typeof body !== "object" || Array.isArray(body) ||
            Object.keys(body).some((key) => !allowed.includes(key))) {
          throw new AppError("INVALID_REQUEST", "묶음 분석 요청 형식이 올바르지 않아요.", { httpStatus: 400 });
        }
        if (isStatus) {
          const result = await batchAnalysisService.status(body.requestIds);
          return sendJson(response, 200, result);
        }
        const id = assertBatchRequestId(body.requestId);
        const input = validateAnalyzeRequest(body.input, { maxImageBytes });
        const task = await batchAnalysisService.submit(id, input);
        return sendJson(response, 202, task);
      }

      if (url.pathname === "/v1/tag-merges") {
        if (request.method !== "POST") {
          throw methodNotAllowed("POST");
        }
        if (!tagMergeService) {
          throw new AppError(
            "TAG_MERGES_NOT_CONFIGURED",
            "태그 정리를 사용할 수 없어요.",
            { httpStatus: 503 },
          );
        }
        assertJsonContentType(request.headers["content-type"]);
        const body = await readJsonBody(request, {
          // 300 entries of 20 characters and a count fit in a few KiB; the
          // rest is headroom, not an invitation.
          maxBodyBytes: Math.min(maxBodyBytes, 32 * 1024),
          timeoutMs: bodyTimeoutMs,
        });
        const input = validateTagMergesRequest(body);
        // No pairs is the normal answer for a tidy library, so this is a 200
        // whenever the call ran at all.
        const result = await tagMergeService.merge(input);
        if (process.env.TRUN_ON_DEBUG_LOG === "1") {
          console.log(
            `[tag-merges] 태그=${input.vocabulary.length} ` +
              `합침=${result.merges.length}`,
          );
        }
        return sendJson(response, 200, result);
      }

      if (url.pathname === "/v1/tag-senses") {
        if (request.method !== "POST") {
          throw methodNotAllowed("POST");
        }
        if (!tagSenseService) {
          throw new AppError(
            "TAG_SENSES_NOT_CONFIGURED",
            "검색 낱말 생성을 사용할 수 없어요.",
            { httpStatus: 503 },
          );
        }
        assertJsonContentType(request.headers["content-type"]);
        const body = await readJsonBody(request, {
          // Same arithmetic as tag-merges: 300 tags of 20 characters and a
          // count fit in a few KiB; the rest is headroom, not an invitation.
          maxBodyBytes: Math.min(maxBodyBytes, 32 * 1024),
          timeoutMs: bodyTimeoutMs,
        });
        const input = validateTagSensesRequest(body);
        // Always a 200 when the call ran, and every requested tag appears in
        // `senses` even with zero words: the caller caches "asked, nothing
        // useful" per tag, and an absent tag would be re-asked forever.
        const result = await tagSenseService.describe(input);
        if (process.env.TRUN_ON_DEBUG_LOG === "1") {
          // Opt-in and local only. Counts, never the words: the dictionary is
          // built from the reader's own vocabulary.
          const answered = result.senses.filter(
            (sense) => sense.words.length > 0,
          ).length;
          const wordCount = result.senses.reduce(
            (total, sense) => total + sense.words.length,
            0,
          );
          console.log(
            `[tag-senses] 태그=${input.tags.length} ` +
              `답변=${answered} 낱말=${wordCount}`,
          );
        }
        return sendJson(response, 200, result);
      }

      if (url.pathname === "/v1/plan-recommendation") {
        if (request.method !== "POST") {
          throw methodNotAllowed("POST");
        }
        if (!recommendationService) {
          throw new AppError(
            "RECOMMENDATION_NOT_CONFIGURED",
            "추천을 사용할 수 없어요.",
            { httpStatus: 503 },
          );
        }
        assertJsonContentType(request.headers["content-type"]);
        const body = await readJsonBody(request, {
          maxBodyBytes,
          timeoutMs: bodyTimeoutMs,
        });
        const input = validatePlanRecommendationRequest(body);
        // Nothing matching is a normal answer, so this is a 200 whenever the
        // call ran at all. The caller reads `status` to tell the two apart.
        const result = await recommendationService.recommend(input);
        if (process.env.TRUN_ON_DEBUG_LOG === "1") {
          console.log(
            `[recommend] "${input.plan.title}" 후보=${input.candidates.length} ` +
              `→ ${result.status} 묶음=${result.groups.length} ` +
              `할일=${result.todoCount} 담김=${result.attachedCount}`,
          );
        }
        return sendJson(response, 200, result);
      }

      if (url.pathname === "/v1/enrich-place") {
        if (request.method !== "POST") {
          throw methodNotAllowed("POST");
        }
        if (!enrichmentService) {
          throw new AppError(
            "ENRICHMENT_NOT_CONFIGURED",
            "장소 보강을 사용할 수 없어요.",
            { httpStatus: 503 },
          );
        }
        assertJsonContentType(request.headers["content-type"]);
        const body = await readJsonBody(request, {
          maxBodyBytes: Math.min(maxBodyBytes, 8 * 1024),
          timeoutMs: bodyTimeoutMs,
        });
        const input = validateEnrichPlaceRequest(body);
        // Empty axes are a normal answer, so this is always a 200 when the
        // lookup ran at all.
        const enriched = await enrichmentService.enrich(input);
        if (process.env.TRUN_ON_DEBUG_LOG === "1") {
          // Opt-in and local only. Logs what was asked and how many labels came
          // back, never the page contents.
          console.log(
            `[enrich] "${input.name} ${input.searchArea ?? ""}".trim() ` +
              `matched=${enriched.matchedName ?? "-"} ` +
              `kind=${enriched.kind.length} ` +
              `access=${enriched.access.map((l) => l.value).join("|") || "-"}`,
          );
        }
        return sendJson(response, 200, enriched);
      }

      if (url.pathname === "/v1/resolve-place") {
        if (request.method !== "POST") {
          throw methodNotAllowed("POST");
        }
        if (!placeResolutionService) {
          throw new AppError(
            "PLACE_SEARCH_NOT_CONFIGURED",
            "장소 검색을 사용할 수 없어요.",
            { httpStatus: 503 },
          );
        }
        assertJsonContentType(request.headers["content-type"]);
        const body = await readJsonBody(request, {
          maxBodyBytes: Math.min(maxBodyBytes, 8 * 1024),
          timeoutMs: bodyTimeoutMs,
        });
        const input = validateResolvePlaceRequest(body);
        const resolution = await placeResolutionService.resolve(input);
        // A miss is a 200 with a null place. The client keeps its text search
        // instead of pinning a coordinate nobody verified.
        return sendJson(response, 200, {
          place: resolution.place,
          candidateCount: resolution.candidateCount,
        });
      }

      throw new AppError("NOT_FOUND", "요청한 경로를 찾을 수 없어요.", {
        httpStatus: 404,
      });
    } catch (error) {
      const normalized = normalizeError(error);
      return sendJson(response, normalized.httpStatus, {
        error: {
          code: normalized.code,
          message: normalized.message,
          retryable: normalized.retryable,
          requestId,
        },
      });
    }
  });
}

function setCommonHeaders(response, requestId) {
  response.setHeader("Content-Type", "application/json; charset=utf-8");
  response.setHeader("Cache-Control", "no-store");
  response.setHeader("X-Content-Type-Options", "nosniff");
  response.setHeader("X-Request-Id", requestId);
}

function sendJson(response, status, value) {
  if (response.writableEnded) {
    return;
  }
  response.statusCode = status;
  response.end(JSON.stringify(value));
}

function methodNotAllowed(allowedMethod) {
  return new AppError(
    "METHOD_NOT_ALLOWED",
    `${allowedMethod} 요청만 지원해요.`,
    { httpStatus: 405 },
  );
}

function assertJsonContentType(contentType) {
  if (
    typeof contentType !== "string" ||
    !contentType.toLowerCase().startsWith("application/json")
  ) {
    throw new AppError(
      "UNSUPPORTED_CONTENT_TYPE",
      "Content-Type은 application/json이어야 해요.",
      { httpStatus: 415 },
    );
  }
}

async function readJsonBody(request, { maxBodyBytes, timeoutMs }) {
  const contentLength = Number(request.headers["content-length"]);
  if (Number.isFinite(contentLength) && contentLength > maxBodyBytes) {
    throw new AppError("PAYLOAD_TOO_LARGE", "요청 용량이 너무 커요.", {
      httpStatus: 413,
    });
  }

  const chunks = [];
  let bytes = 0;
  let timer;

  try {
    const timeoutPromise = new Promise((_, reject) => {
      timer = setTimeout(
        () =>
          reject(
            new AppError(
              "REQUEST_TIMEOUT",
              "이미지 업로드 시간이 초과됐어요.",
              { httpStatus: 408, retryable: true },
            ),
          ),
        timeoutMs,
      );
      timer.unref?.();
    });

    const readPromise = (async () => {
      for await (const chunk of request) {
        bytes += chunk.length;
        if (bytes > maxBodyBytes) {
          throw new AppError(
            "PAYLOAD_TOO_LARGE",
            "요청 용량이 너무 커요.",
            { httpStatus: 413 },
          );
        }
        chunks.push(chunk);
      }
      return Buffer.concat(chunks).toString("utf8");
    })();

    const raw = await Promise.race([readPromise, timeoutPromise]);
    if (raw.length === 0) {
      throw new AppError(
        "INVALID_JSON",
        "JSON 요청 본문이 필요해요.",
        { httpStatus: 400 },
      );
    }
    try {
      return JSON.parse(raw);
    } catch (error) {
      throw new AppError(
        "INVALID_JSON",
        "JSON 형식이 올바르지 않아요.",
        { httpStatus: 400, cause: error },
      );
    }
  } finally {
    clearTimeout(timer);
  }
}
