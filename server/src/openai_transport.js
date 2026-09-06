import {
  DEFAULT_MAX_UPSTREAM_BODY_BYTES,
  DEFAULT_OPENAI_TIMEOUT_MS,
} from "./constants.js";
import { OpenAITransportError } from "./errors.js";

export function createOpenAITransport({
  apiKey,
  fetchImpl = globalThis.fetch,
  baseUrl = "https://api.openai.com/v1",
  timeoutMs = DEFAULT_OPENAI_TIMEOUT_MS,
  maxResponseBytes = DEFAULT_MAX_UPSTREAM_BODY_BYTES,
} = {}) {
  if (typeof apiKey !== "string" || apiKey.length === 0) {
    throw new Error("OPENAI_API_KEY is required");
  }
  if (typeof fetchImpl !== "function") {
    throw new Error("A fetch implementation is required");
  }

  return {
    async createResponse(requestBody, { signal } = {}) {
      const timeoutController = new AbortController();
      let timeout;

      const combinedController = new AbortController();
      const abortCombined = () => combinedController.abort();
      signal?.addEventListener("abort", abortCombined, { once: true });
      timeoutController.signal.addEventListener("abort", abortCombined, {
        once: true,
      });
      if (signal?.aborted) {
        combinedController.abort();
      }

      try {
        const deadline = new Promise((_, reject) => {
          timeout = setTimeout(() => {
            timeoutController.abort();
            reject(
              new OpenAITransportError("timeout", {
                retryable: true,
              }),
            );
          }, timeoutMs);
          timeout.unref?.();
        });
        const operation = (async () => {
          const response = await fetchImpl(`${baseUrl}/responses`, {
            method: "POST",
            headers: {
              Authorization: `Bearer ${apiKey}`,
              "Content-Type": "application/json",
            },
            body: JSON.stringify(requestBody),
            signal: combinedController.signal,
          });
          const responseText = await readBoundedText(response, maxResponseBytes);
          return { response, responseText };
        })();
        const { response, responseText } = await Promise.race([
          operation,
          deadline,
        ]);

        let responseJson = null;
        if (responseText.length > 0) {
          try {
            responseJson = JSON.parse(responseText);
          } catch (error) {
            throw new OpenAITransportError("invalid_response", {
              cause: error,
              retryable: true,
            });
          }
        }

        if (!response.ok) {
          throw mapUpstreamStatus(response.status);
        }
        if (!responseJson || typeof responseJson !== "object") {
          throw new OpenAITransportError("invalid_response", {
            retryable: true,
          });
        }
        return responseJson;
      } catch (error) {
        if (error instanceof OpenAITransportError) {
          throw error;
        }
        if (
          combinedController.signal.aborted ||
          error?.name === "AbortError" ||
          error?.name === "TimeoutError"
        ) {
          throw new OpenAITransportError("timeout", {
            cause: error,
            retryable: true,
          });
        }
        throw new OpenAITransportError("network", {
          cause: error,
          retryable: true,
        });
      } finally {
        clearTimeout(timeout);
        signal?.removeEventListener("abort", abortCombined);
      }
    },
  };
}

function mapUpstreamStatus(status) {
  if (status === 401 || status === 403) {
    return new OpenAITransportError("authentication", {
      upstreamStatus: status,
      retryable: false,
    });
  }
  if (status === 429) {
    return new OpenAITransportError("rate_limited", {
      upstreamStatus: status,
      retryable: true,
    });
  }
  if (status === 400 || status === 404 || status === 422) {
    return new OpenAITransportError("rejected", {
      upstreamStatus: status,
      retryable: false,
    });
  }
  return new OpenAITransportError("upstream", {
    upstreamStatus: status,
    retryable: status >= 500,
  });
}

async function readBoundedText(response, maxBytes) {
  const contentLength = Number(response.headers?.get?.("content-length"));
  if (Number.isFinite(contentLength) && contentLength > maxBytes) {
    throw new OpenAITransportError("invalid_response", {
      retryable: true,
    });
  }

  if (!response.body?.getReader) {
    const text = await response.text();
    if (Buffer.byteLength(text) > maxBytes) {
      throw new OpenAITransportError("invalid_response", {
        retryable: true,
      });
    }
    return text;
  }

  const reader = response.body.getReader();
  const chunks = [];
  let total = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) {
      break;
    }
    total += value.byteLength;
    if (total > maxBytes) {
      await reader.cancel();
      throw new OpenAITransportError("invalid_response", {
        retryable: true,
      });
    }
    chunks.push(value);
  }
  return Buffer.concat(chunks.map((chunk) => Buffer.from(chunk))).toString(
    "utf8",
  );
}
