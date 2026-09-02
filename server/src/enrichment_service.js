/// Fills the axes a screenshot cannot, in four steps with one model each side.
///
///   retrieve  (vision-grade model)  search, copy sentences out verbatim
///   identify  (code)               which business is this? refuse if unsure
///   judge     (cheap model)        those sentences → axis labels
///   verify    (code)               every quote must exist in the excerpts
///
/// The two model calls are deliberately different models. Retrieval needs a
/// provider whose index reaches Korean listing sites; judgment needs nothing but
/// Korean reading comprehension, so it runs on whatever is cheapest. Measured over
/// ten shops this reached 9/10 reproducibility on three runs of the same shop,
/// against 4/10 for the single-call version, and every quote it produced was a
/// real sentence from a real page.
///
/// Every failure resolves to empty axes rather than an exception. The capture is
/// already saved and already useful; losing a label is not worth losing that.

import { DEFAULT_ANALYSIS_TIMEOUT_MS, MODEL } from "./constants.js";
import {
  ACCESS_VALUES,
  ENRICHMENT_TEXT_FORMAT,
  RESERVATION_VALUES,
  WAITING_VALUE,
} from "./enrichment_schema.js";
import {
  BOOKING_HOSTS,
  RETRIEVAL_PROBES,
  buildRetrievalRequest,
} from "./enrichment_prompt.js";
import { buildJudgmentRequest } from "./judgment_prompt.js";
import { resolvePlaceIdentity } from "./place_identity.js";
import { OpenAITransportError } from "./errors.js";
import { normalizeTagValue } from "./tag_key.js";

const LABEL_AXES = Object.freeze(["kind", "access"]);
const MAX_LABELS_PER_AXIS = 4;
const MAX_EXCERPTS = 60;

/// access is a closed vocabulary, so a value outside the list is a model that
/// ignored the contract rather than a label worth keeping. kind stays open
/// because the world has more cuisines than any list would hold.
const AXIS_VOCABULARY = Object.freeze({ access: new Set(ACCESS_VALUES) });

/// One page is enough. These are facts a page states, the same way kind is.
const MIN_SOURCES = Object.freeze({ kind: 1, access: 1 });

/// Labels that cannot both be true of one place. The first kept wins, since the
/// model orders its own answer by confidence.
const CONTRADICTIONS = Object.freeze({ access: RESERVATION_VALUES });

export function createEnrichmentService({
  // One transport serves both halves unless a second is supplied.
  transport = null,
  retrievalTransport = transport,
  judgmentTransport = transport,
  retrievalModel = MODEL,
  judgmentModel = MODEL,
  judgmentEffort,
  judgmentMaxOutputTokens,
  probes = RETRIEVAL_PROBES,
  timeoutMs = DEFAULT_ANALYSIS_TIMEOUT_MS,
} = {}) {
  if (!retrievalTransport || typeof retrievalTransport.createResponse !== "function") {
    throw new Error("A transport with createResponse is required");
  }
  if (!judgmentTransport || typeof judgmentTransport.createResponse !== "function") {
    throw new Error("A judgment transport with createResponse is required");
  }

  return {
    async enrich({ name, searchArea }) {
      const shopName = typeof name === "string" ? name.trim() : "";
      const area = typeof searchArea === "string" ? searchArea.trim() : "";
      // An area on its own would return whichever shop the web likes best, so
      // the name is what makes this lookup meaningful at all.
      if (shopName.length === 0) {
        return emptyEnrichment();
      }
      const query = [shopName, area].filter((value) => value.length > 0).join(" ");

      const retrieved = await retrieve({
        transport: retrievalTransport,
        model: retrievalModel,
        query,
        probes,
        timeoutMs,
      });
      if (retrieved.excerpts.length === 0) {
        return emptyEnrichment();
      }

      // The gate. Attaching facts to the wrong shop is the one failure worse
      // than no facts at all, so an unresolved identity ends the lookup here
      // rather than letting the judge label somebody else's restaurant.
      const identity = resolvePlaceIdentity({
        name: shopName,
        searchArea: area || null,
        listings: retrieved.listings,
      });
      if (identity.resolvedName === null) {
        return { ...emptyEnrichment(), unresolvedReason: identity.reason };
      }

      const judged = await judgeWithRetry({
        transport: judgmentTransport,
        model: judgmentModel,
        effort: judgmentEffort,
        maxOutputTokens: judgmentMaxOutputTokens,
        resolvedName: identity.resolvedName,
        excerpts: retrieved.excerpts,
        timeoutMs,
      });

      const result = sanitizeEnrichment(judged, retrieved.excerpts);
      result.matchedName = identity.resolvedName;
      applyBookingPlatformRule(result, retrieved);
      return result;
    },
  };
}

// ── retrieve ────────────────────────────────────────────────────────────────

/// Runs every probe at once and unions what comes back.
///
/// Collection is not repeatable: two runs of the same query overlap by only
/// 19-46%, because the search picks different pages each time. Unioning is the
/// answer rather than the problem — a probe that failed contributes nothing
/// instead of failing the lookup, and the caller may union across visits too.
async function retrieve({ transport, model, query, probes, timeoutMs }) {
  const settled = await Promise.all(
    probes.map((probe) =>
      withDeadline(
        (signal) =>
          transport.createResponse(buildRetrievalRequest({ query, model, probe }), {
            signal,
          }),
        timeoutMs,
      )
        .then((response) => readJson(response))
        .catch(() => null),
    ),
  );

  const seen = new Set();
  const excerpts = [];
  const listings = [];
  for (const parsed of settled) {
    if (!parsed) continue;
    for (const item of Array.isArray(parsed.listings) ? parsed.listings : []) {
      if (typeof item?.nameOnPage === "string" && typeof item?.url === "string") {
        listings.push({ url: item.url, nameOnPage: item.nameOnPage, addressOnPage: item.addressOnPage ?? null });
      }
    }
    for (const item of Array.isArray(parsed.excerpts) ? parsed.excerpts : []) {
      if (typeof item?.text !== "string" || typeof item?.url !== "string") continue;
      const text = item.text.trim();
      const key = collapse(text);
      if (key.length < 2 || seen.has(key) || excerpts.length >= MAX_EXCERPTS) continue;
      seen.add(key);
      excerpts.push({ url: item.url, text });
    }
  }
  return { excerpts, listings };
}

// ── judge ───────────────────────────────────────────────────────────────────

/// One retry, because the judging model occasionally answers with prose and no
/// object at all. Twice is where it stops: a lookup nobody is waiting on is not
/// worth a third call.
async function judgeWithRetry(options) {
  const first = await judgeOnce(options).catch(() => null);
  if (first !== null) return first;
  return judgeOnce(options).catch(() => null);
}

async function judgeOnce({
  transport,
  model,
  effort,
  maxOutputTokens,
  resolvedName,
  excerpts,
  timeoutMs,
}) {
  const response = await withDeadline(
    (signal) =>
      transport.createResponse(
        buildJudgmentRequest({
          resolvedName,
          excerpts,
          model,
          textFormat: ENRICHMENT_TEXT_FORMAT,
          ...(effort === undefined ? {} : { effort }),
          ...(maxOutputTokens === undefined ? {} : { maxOutputTokens }),
        }),
        { signal },
      ),
    timeoutMs,
  );
  return readJson(response);
}

// ── verify and shape ────────────────────────────────────────────────────────

function emptyEnrichment() {
  return { matchedName: null, kind: [], access: [] };
}

/// Drops anything the model returned that the contract does not allow, and
/// anything it cannot show a real sentence for.
function sanitizeEnrichment(raw, excerpts) {
  const result = emptyEnrichment();
  if (!raw || typeof raw !== "object") {
    return result;
  }
  // Every excerpt, collapsed, so a quote can be checked by containment. A label
  // whose quote is not in here was invented, and inventing evidence is the one
  // thing this whole two-step shape exists to make detectable.
  const haystack = collapse(excerpts.map((excerpt) => excerpt.text).join("\n"));
  const excerptUrls = new Set(excerpts.map((excerpt) => excerpt.url));

  for (const axis of LABEL_AXES) {
    const labels = Array.isArray(raw[axis]) ? raw[axis] : [];
    const seen = new Set();
    const vocabulary = AXIS_VOCABULARY[axis] ?? null;
    const exclusive = CONTRADICTIONS[axis] ?? [];
    for (const label of labels) {
      if (result[axis].length >= MAX_LABELS_PER_AXIS) break;
      const value = normalizeLabel(label?.value);
      if (value === null || seen.has(value)) continue;
      if (vocabulary !== null && !vocabulary.has(value)) continue;
      // One place cannot both require a booking and refuse one.
      if (
        exclusive.includes(value) &&
        [...seen].some((kept) => exclusive.includes(kept))
      ) {
        continue;
      }

      const quote =
        typeof label?.quote === "string" ? label.quote.trim().slice(0, 200) : "";
      if (quote.length < 2 || !haystack.includes(collapse(quote))) continue;

      // Independence is by site, so two links into one blog do not count twice.
      const sources = distinctSources(label?.citations).filter((url) =>
        excerptUrls.has(url),
      );
      const required = value === WAITING_VALUE ? 1 : MIN_SOURCES[axis];
      if (sources.length < required) continue;

      seen.add(value);
      result[axis].push({
        value,
        confidence: clampConfidence(label?.confidence),
        quote,
        citations: sources,
      });
    }
  }
  return result;
}

/// A page on a booking platform answers the booking question by existing.
///
/// Applied only when the judge found no booking policy of its own, so a page that
/// says 예약 필수 is never downgraded to 예약 가능 by the mere presence of a
/// listing. The evidence here is the URL, not a sentence, so it is not subject to
/// the quote check — there is nothing to have invented.
function applyBookingPlatformRule(result, retrieved) {
  if (result.access.some((label) => RESERVATION_VALUES.includes(label.value))) {
    return;
  }
  const urls = [...retrieved.excerpts, ...retrieved.listings].map((item) => item.url);
  const bookingUrl = distinctSources(urls).find((url) => {
    try {
      const host = new URL(url).host;
      return BOOKING_HOSTS.some((booking) => host === booking || host.endsWith(`.${booking}`));
    } catch {
      return false;
    }
  });
  if (!bookingUrl) return;
  let host = bookingUrl;
  try {
    host = new URL(bookingUrl).host.replace(/^www\./u, "");
  } catch {}
  result.access.unshift({
    value: "예약 가능",
    confidence: 0.9,
    quote: `${host} 예약 페이지`,
    citations: [bookingUrl],
  });
}

// ── plumbing ────────────────────────────────────────────────────────────────

async function withDeadline(run, timeoutMs) {
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
    return await Promise.race([run(controller.signal), deadline]);
  } finally {
    clearTimeout(timer);
  }
}

function readJson(response) {
  if (!response || typeof response !== "object" || response.error) {
    throw new OpenAITransportError("invalid_response", { retryable: true });
  }
  if (response.status === "incomplete") {
    throw new OpenAITransportError("invalid_response", { retryable: true });
  }
  const text =
    typeof response.output_text === "string" && response.output_text
      ? response.output_text
      : allOutputText(response);
  const parsed = jsonFrom(text);
  if (parsed === null) {
    throw new OpenAITransportError("invalid_response", { retryable: true });
  }
  return parsed;
}

/// Every message the model emitted, joined in order.
///
/// Taking the first one was wrong. A provider that narrates its search puts a
/// dozen message items in `output` — "I'll search for this place." first, the
/// answer last — so reading the first read the narration and threw away a
/// perfectly good reply.
function allOutputText(response) {
  const output = Array.isArray(response.output) ? response.output : [];
  const parts = [];
  for (const item of output) {
    if (item?.type !== "message") continue;
    for (const content of item.content ?? []) {
      if (typeof content?.text === "string" && content.text) {
        parts.push(content.text);
      }
    }
  }
  if (parts.length === 0) {
    throw new OpenAITransportError("invalid_response", { retryable: true });
  }
  return parts.join("\n");
}

/// Reads the object out of a reply that may not be only the object.
///
/// One provider answers with the structured output alone. Another narrates and
/// puts the object in a fenced block at the end, ignoring the schema format it
/// was given. Both are the same answer, so both are accepted.
function jsonFrom(text) {
  if (typeof text !== "string" || text.trim().length === 0) return null;

  const direct = tryParse(text);
  if (direct !== null) return direct;

  const fences = [...text.matchAll(/```(?:json)?\s*([\s\S]*?)```/gu)].map(
    (match) => match[1],
  );
  for (const block of fences.reverse()) {
    const parsed = tryParse(block);
    if (parsed !== null) return parsed;
  }
  return tryParse(balancedObject(text));
}

function tryParse(candidate) {
  if (typeof candidate !== "string" || candidate.trim().length === 0) return null;
  try {
    const value = JSON.parse(candidate.trim());
    return value !== null && typeof value === "object" ? value : null;
  } catch {
    return null;
  }
}

/// The first brace-balanced object in the text, ignoring braces inside strings.
function balancedObject(text) {
  const start = text.indexOf("{");
  if (start < 0) return null;
  let depth = 0;
  let inString = false;
  let escaped = false;
  for (let index = start; index < text.length; index++) {
    const char = text[index];
    if (escaped) {
      escaped = false;
      continue;
    }
    if (char === "\\") {
      escaped = true;
      continue;
    }
    if (char === '"') {
      inString = !inString;
      continue;
    }
    if (inString) continue;
    if (char === "{") depth++;
    else if (char === "}" && --depth === 0) return text.slice(start, index + 1);
  }
  return null;
}

function collapse(value) {
  return String(value).replace(/\s+/gu, "").replace(/["'`]/gu, "");
}

function normalizeLabel(value) {
  return normalizeTagValue(value);
}

function clampConfidence(value) {
  if (typeof value !== "number" || Number.isNaN(value)) return 0;
  return Number(Math.min(1, Math.max(0, value)).toFixed(2));
}

function distinctSources(values) {
  if (!Array.isArray(values)) return [];
  const byHost = new Map();
  for (const value of values) {
    const url = httpsUrl(value);
    if (url === null) continue;
    const host = new URL(url).host;
    if (!byHost.has(host)) byHost.set(host, url);
  }
  return [...byHost.values()];
}

function httpsUrl(value) {
  if (typeof value !== "string" || value.length === 0) return null;
  try {
    const url = new URL(value);
    return url.protocol === "https:" ? url.toString() : null;
  } catch {
    return null;
  }
}
