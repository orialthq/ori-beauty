import { TAG_PATTERN_SOURCE } from "./tag_key.js";

const citations = {
  type: "array",
  minItems: 1,
  maxItems: 4,
  items: { type: "string", minLength: 8, maxLength: 400 },
};

/// A label found on the web rather than on the screen.
///
/// `quote` and `citations` are both required. A label nobody can trace back to a
/// sentence on a page is indistinguishable from a guess, and the whole point of
/// this pass is that the reader can check it.
function webLabel(values = null) {
  return {
    type: "object",
    properties: {
      quote: { type: "string", minLength: 2, maxLength: 200 },
      value: values
        ? { type: "string", enum: values }
        : {
            type: "string",
            minLength: 2,
            maxLength: 20,
            pattern: TAG_PATTERN_SOURCE,
          },
      confidence: { type: "number", minimum: 0, maximum: 1 },
      citations,
    },
    required: ["quote", "value", "confidence", "citations"],
    additionalProperties: false,
  };
}

/// What it takes to get in the door: how the place is entered, and whether
/// people queue for it.
///
/// A closed list on purpose. An open axis fragments a saved list into a hundred
/// one-item cards, and it re-opens the door to the model phrasing the same fact
/// three different ways on three different runs.
///
/// 웨이팅 있음 sits on the same axis rather than its own because it answers the
/// same question — what do I have to do to eat here tonight — and it overlaps
/// the others: a place can take bookings and still have a queue for walk-ins.
/// There is deliberately no 웨이팅 없음. Nobody writes that a place has no
/// queue, so its absence from the web is not evidence of anything.
export const ACCESS_VALUES = Object.freeze([
  "예약 필수",
  "예약 가능",
  "예약 없이",
  "웨이팅 있음",
]);

/// The one access value that is a pattern over time rather than a stated policy,
/// so it carries the higher bar that occasion used to.
export const WAITING_VALUE = "웨이팅 있음";

export const RESERVATION_VALUES = Object.freeze([
  "예약 필수",
  "예약 가능",
  "예약 없이",
]);

/// There was a 인원 axis here — 혼밥 가능 / 단체 가능 / 소규모만 — and it was
/// retired after measurement, not after an argument.
///
/// Over ten shops 단체 가능 came back true for all ten, and enriching the
/// evidence made it worse rather than better: more sentences meant a higher
/// chance of finding the word 단체 somewhere. The labels were not wrong — most
/// Seoul restaurants really do seat a group and really do seat one person. A
/// label true of every card cannot filter a saved list, which is the only thing
/// an axis is for. 혼밥 가능 alone sat at 6/10 and had no second value to pair
/// with, so the axis went rather than shipping half of it.

export const ENRICHMENT_SCHEMA = {
  type: "object",
  properties: {
    // The place the search actually landed on, so the client can tell whether
    // the results describe the shop it asked about.
    matchedName: { type: ["string", "null"], maxLength: 120 },
    kind: { type: "array", maxItems: 4, items: webLabel() },
    access: { type: "array", maxItems: 2, items: webLabel(ACCESS_VALUES) },
  },
  required: ["matchedName", "kind", "access"],
  additionalProperties: false,
};

export const ENRICHMENT_TEXT_FORMAT = {
  type: "json_schema",
  name: "trun_on_place_enrichment",
  strict: true,
  schema: ENRICHMENT_SCHEMA,
};
