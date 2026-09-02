import { MODEL } from "./constants.js";
import { tagKey } from "./tag_key.js";
import { buildTagMergeRequest } from "./tag_merge_prompt.js";

/// The most pairs one answer carries. A reader confirming merges one by one
/// stops long before this, and a list longer than it is a model that got
/// enthusiastic rather than a library that needs it.
const MAX_MERGES = 30;

/// The one reason the server can give without asking anyone.
export const SAME_KEY_REASON = "띄어쓰기·구분자만 다른 같은 말이에요.";

/// Reason to fall back on when the model answered with a pair but no words
/// for it. The pair is still the model's; the reason is just not left blank.
const DEFAULT_MODEL_REASON = "같은 것을 다르게 쓴 태그예요.";
const MAX_REASON_LENGTH = 120;

/// The librarian: proposes which of the reader's tags are one word.
///
/// Two passes. The first is deterministic and pairs entries whose `tagKey` is
/// equal — 스킨케어 and 스킨 케어 — which needs no model and is never wrong.
/// The second asks the model about the rest: the pairs where the spelling
/// differs by more than a separator and a person would still say they are the
/// same thing.
///
/// The service proposes; the reader disposes. Nothing here rewrites a tag.
/// What it does guarantee is that every pair it returns names two words that
/// really are in the vocabulary sent, that the one with more captures under it
/// is the one that survives, and that no word is proposed for merging twice.
/// None of that can be asked of a prompt.
export function createTagMergeService({
  transport,
  model = MODEL,
  timeoutMs = 30_000,
} = {}) {
  if (!transport || typeof transport.createResponse !== "function") {
    throw new Error("A transport is required");
  }

  return {
    async merge({ vocabulary }) {
      const { merges, representatives } = pairSameKey(vocabulary);
      if (representatives.length < 2 || merges.length >= MAX_MERGES) {
        return { merges: merges.slice(0, MAX_MERGES) };
      }

      let parsed;
      try {
        const response = await withDeadline(
          (signal) =>
            transport.createResponse(
              buildTagMergeRequest({ vocabulary: representatives, model }),
              { signal },
            ),
          timeoutMs,
        );
        parsed = readJson(response);
      } catch (error) {
        // The deterministic pairs are already a useful answer. Losing them to
        // a model hiccup would make the librarian less reliable than no
        // librarian at all.
        if (merges.length > 0) {
          return { merges };
        }
        throw error;
      }

      return {
        merges: [
          ...merges,
          ...adoptModelPairs(parsed, representatives, merges),
        ].slice(0, MAX_MERGES),
      };
    },
  };
}

/// Pairs entries whose keys are equal, and returns what is left for the model.
///
/// Within a key group the entry with the highest count survives, ties going
/// to the earlier one in the request. The model only sees survivors: a word
/// already proposed for merging must not be proposed again under another
/// name, and sending it would invite exactly that.
function pairSameKey(vocabulary) {
  const groups = new Map();
  vocabulary.forEach((entry, index) => {
    const key = tagKey(entry.value);
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push({ ...entry, index });
  });

  const merges = [];
  const representatives = [];
  for (const group of groups.values()) {
    const into = group.reduce((best, entry) => (entry.count > best.count ? entry : best));
    representatives.push(into);
    for (const entry of group) {
      if (entry === into) continue;
      merges.push({ from: entry.value, into: into.value, reason: SAME_KEY_REASON });
    }
  }
  representatives.sort((a, b) => a.index - b.index);
  return { merges, representatives };
}

/// Keeps a model pair only when both words are ones we sent, then points it
/// at the word with more captures. The model was told which way to orient a
/// pair; this is what makes it true regardless.
function adoptModelPairs(parsed, representatives, existing) {
  const byValue = new Map(representatives.map((entry) => [entry.value, entry]));
  const claimed = new Set(existing.map((merge) => merge.from));
  const seenPairs = new Set();
  const merges = [];

  for (const raw of Array.isArray(parsed?.merges) ? parsed.merges : []) {
    const a = byValue.get(raw?.from);
    const b = byValue.get(raw?.into);
    if (!a || !b || a === b) continue;

    const [from, into] =
      b.count > a.count || (b.count === a.count && b.index < a.index)
        ? [a, b]
        : [b, a];
    const pairId = `${Math.min(a.index, b.index)}:${Math.max(a.index, b.index)}`;
    // One word merges into one place. A second destination for the same word
    // is a contradiction the reader would have to untangle, so the first
    // proposal keeps it.
    if (seenPairs.has(pairId) || claimed.has(from.value) || claimed.has(into.value)) {
      continue;
    }
    seenPairs.add(pairId);
    claimed.add(from.value);
    merges.push({ from: from.value, into: into.value, reason: reasonText(raw.reason) });
  }
  return merges;
}

function reasonText(value) {
  const trimmed = typeof value === "string" ? value.trim() : "";
  if (trimmed === "") return DEFAULT_MODEL_REASON;
  return Array.from(trimmed).slice(0, MAX_REASON_LENGTH).join("");
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
