import {
  DEFAULT_ANALYSIS_TIMEOUT_MS,
  MODEL,
} from "./constants.js";
import { ANALYSIS_TEXT_FORMAT } from "./analysis_schema.js";
import { OpenAITransportError } from "./errors.js";
import { buildOpenAIRequest } from "./prompt.js";
import { validateAnalysisResult } from "./result_validation.js";

export function createAnalysisService({
  transport,
  timeoutMs = DEFAULT_ANALYSIS_TIMEOUT_MS,
} = {}) {
  if (!transport || typeof transport.createResponse !== "function") {
    throw new Error("A transport with createResponse is required");
  }

  return {
    async analyze(input) {
      const controller = new AbortController();
      let timeout;

      try {
        const requestBody = buildOpenAIRequest({
          ...input,
          textFormat: ANALYSIS_TEXT_FORMAT,
          model: MODEL,
        });
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
          transport.createResponse(requestBody, {
            signal: controller.signal,
          }),
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
        return applyDeterministicCompletenessGuards(
          validateAnalysisResult(parsed),
        );
      } catch (error) {
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
    },
  };
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
