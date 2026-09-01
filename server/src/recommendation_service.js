import { MODEL } from "./constants.js";
import { buildRecommendationRequest } from "./recommendation_prompt.js";

/// The most to-dos one plan can come back with.
///
/// A screen the reader has to check boxes on stops being usable long before a
/// model stops being willing to add rows.
const MAX_ITEMS = 20;

/// Asks the model to break a plan into to-dos drawn from what the reader saved.
///
/// The service adds no judgment of its own — grouping, actions, deadlines, and
/// what to fill in are all the model's. On the way back it does the one thing a
/// prompt cannot guarantee: checks that every id came from the list we sent.
///
/// That check is not tuning. A model that answers with a plausible id we never
/// sent would put something on the reader's plan that is not in their library,
/// and no wording in the instructions makes that impossible. An item whose id
/// does not check out is simply not attached; the to-do it was meant for stays,
/// because what a plan requires does not depend on what the reader owns.
export function createRecommendationService({
  transport,
  model = MODEL,
  timeoutMs = 60_000,
} = {}) {
  if (!transport || typeof transport.createResponse !== "function") {
    throw new Error("A transport is required");
  }

  return {
    async recommend({ plan, candidates }) {
      const response = await withDeadline(
        (signal) =>
          transport.createResponse(
            buildRecommendationRequest({ plan, candidates, model }),
            { signal },
          ),
        timeoutMs,
      );

      const parsed = readJson(response);
      if (!parsed || !Array.isArray(parsed.groups)) {
        return { status: "no_match", groups: [], todoCount: 0, attachedCount: 0 };
      }

      const byId = new Map(candidates.map((one) => [one.id, one]));
      const claimed = new Set();
      const groups = [];
      let todoCount = 0;
      let attachedCount = 0;

      for (const rawGroup of parsed.groups) {
        const items = [];
        for (const raw of Array.isArray(rawGroup?.items) ? rawGroup.items : []) {
          if (todoCount >= MAX_ITEMS) break;
          const title = text(raw?.title);
          if (!title) continue;
          todoCount += 1;

          // Every id is checked against the list we sent. A plausible one the
          // model invented would put something on the reader's plan that is not
          // in their library, and no wording in the instructions prevents that.
          const saved = [];
          for (const entry of Array.isArray(raw?.saved) ? raw.saved : []) {
            const candidate = byId.get(entry?.id);
            // One saved thing belongs to one to-do. Asked without this, the
            // model attached all three products to all three to-dos — true of
            // each in isolation, and useless as a list. The first to-do to
            // claim it keeps it, and since to-dos come back roughly in the
            // order they happen, that is the one where the deciding is done.
            if (!candidate || claimed.has(entry.id)) continue;
            claimed.add(entry.id);
            saved.push({
              id: entry.id,
              // Resolved here so a card never has to reach back into a library
              // that may have changed since.
              name: candidate.name,
              why: text(entry?.why),
            });
            attachedCount += 1;
          }

          items.push({
            title,
            action: text(raw?.action),
            // Negative would mean "after the plan", which nothing in the flow
            // can show. Clamped rather than dropped: the to-do is still real.
            daysBefore: Math.max(0, integer(raw?.daysBefore)),
            note: text(raw?.note),
            selected: raw?.selected !== false,
            saved,
          });
        }
        if (items.length === 0) continue;
        groups.push({
          title: text(rawGroup?.title) || "할 일",
          note: text(rawGroup?.note),
          items,
        });
      }

      if (groups.length === 0) {
        return { status: "no_match", groups: [], todoCount: 0, attachedCount: 0 };
      }

      return { status: "ready", groups, todoCount, attachedCount };
    },
  };
}

function text(value) {
  return typeof value === "string" ? value.trim() : "";
}

function integer(value) {
  return Number.isInteger(value) ? value : 0;
}

/// One provider answers with the structured output alone. Another narrates and
/// then answers, so the JSON is one of several output items.
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
