import { MODEL } from "./constants.js";
import { OpenAITransportError } from "./errors.js";
import { tagKey } from "./tag_key.js";
import { buildTagSenseRequest } from "./tag_sense_prompt.js";

const MAX_WORDS_PER_TAG = 8;
const MAX_WORD_LENGTH = 12;

/// The lexicographer: for each of the reader's tags, the words a person would
/// type when looking for things filed under it (닭발 → 매운, 야식, 술안주).
///
/// One model call for the whole batch; the caller runs it offline and matches
/// the words locally per keystroke. The model proposes, and this pass keeps
/// only what the design can guarantee: a `tag` is adopted only when it is
/// exactly one we sent, and every word survives the one-way rule — a word
/// that names another tag in the request would quietly turn "word finds tag"
/// into "tag expands to tag", which is the one thing this dictionary must
/// never do. Words redundant with their own tag's name are dropped too,
/// because typing the tag's name already finds the tag without any help.
export function createTagSenseService({
  transport,
  model = MODEL,
  timeoutMs = 30_000,
} = {}) {
  if (!transport || typeof transport.createResponse !== "function") {
    throw new Error("A transport is required");
  }

  return {
    async describe({ tags }) {
      const response = await withDeadline(
        (signal) =>
          transport.createResponse(buildTagSenseRequest({ tags, model }), {
            signal,
          }),
        timeoutMs,
      );
      const parsed = readJson(response);
      if (!parsed || !Array.isArray(parsed.senses)) {
        // Unlike the librarian, an unreadable answer here must not become an
        // empty one: the caller caches "asked, nothing useful" per tag and
        // would never ask again. A retryable failure is the honest shape.
        throw new OpenAITransportError("invalid_response", { retryable: true });
      }
      return { senses: adoptModelSenses(parsed.senses, tags) };
    },
  };
}

/// Adopts the model's entries against the request and answers for every tag.
///
/// A `tag` that is not exactly one we sent is dropped — the model does not get
/// to invent vocabulary — and the first entry for a tag wins. The answer then
/// lists every requested tag in request order, with an empty word list where
/// the model had nothing: absence and "nothing useful" must be the same thing
/// to the caller, or an absent tag would be re-asked forever.
function adoptModelSenses(rawSenses, tags) {
  const keyByValue = new Map(tags.map((entry) => [entry.value, tagKey(entry.value)]));
  const valuesByKey = new Map();
  for (const [value, key] of keyByValue) {
    if (!valuesByKey.has(key)) valuesByKey.set(key, []);
    valuesByKey.get(key).push(value);
  }

  const wordsByValue = new Map();
  for (const raw of rawSenses) {
    if (!keyByValue.has(raw?.tag) || wordsByValue.has(raw.tag)) {
      continue;
    }
    wordsByValue.set(
      raw.tag,
      adoptWords(raw.words, raw.tag, keyByValue.get(raw.tag), valuesByKey),
    );
  }

  return tags.map(({ value }) => ({
    tag: value,
    words: wordsByValue.get(value) ?? [],
  }));
}

/// Keeps a word only when it earns its place in the dictionary: readable,
/// short, not another tag's name, not a restatement of its own tag's name,
/// and said once. Comparison is by `tagKey`, the same equality every other
/// pass uses, so 야 식 cannot smuggle 야식 past the one-way rule.
function adoptWords(rawWords, tagValue, ownKey, valuesByKey) {
  const seen = new Set();
  const words = [];
  for (const raw of Array.isArray(rawWords) ? rawWords : []) {
    if (words.length >= MAX_WORDS_PER_TAG) break;
    if (typeof raw !== "string") continue;
    const word = raw.trim();
    if (word === "" || Array.from(word).length > MAX_WORD_LENGTH) continue;
    const key = tagKey(word);
    if (key === "" || seen.has(key)) continue;
    // The one-way rule, enforced: a sense word must never be a different
    // tag's name, or typing that tag would surface this one.
    const sameKeyTags = valuesByKey.get(key);
    if (sameKeyTags && sameKeyTags.some((value) => value !== tagValue)) {
      continue;
    }
    if (isRedundantWithOwnName(key, ownKey)) continue;
    seen.add(key);
    words.push(word);
  }
  return words;
}

/// Equal to the tag's own name, or a ≥2-character prefix of it either way
/// round (매운맛 next to 매운) — name matching already finds those, so the
/// word would spend one of the tag's eight slots on nothing.
function isRedundantWithOwnName(wordKey, ownKey) {
  if (wordKey === ownKey) return true;
  const overlap = Math.min(Array.from(wordKey).length, Array.from(ownKey).length);
  return (
    overlap >= 2 && (wordKey.startsWith(ownKey) || ownKey.startsWith(wordKey))
  );
}

function readJson(response) {
  const raw =
    typeof response?.output_text === "string" && response.output_text
      ? response.output_text
      : allOutputText(response);
  if (!raw) return null;
  try {
    const value = JSON.parse(raw.trim());
    return value && typeof value === "object" ? value : null;
  } catch {
    return null;
  }
}

function allOutputText(response) {
  const output = Array.isArray(response?.output) ? response.output : [];
  const chunks = [];
  for (const item of output) {
    for (const part of Array.isArray(item?.content) ? item.content : []) {
      if (typeof part?.text === "string") chunks.push(part.text);
    }
  }
  return chunks.join("");
}

async function withDeadline(run, timeoutMs) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  timer.unref?.();
  try {
    return await run(controller.signal);
  } finally {
    clearTimeout(timer);
  }
}
