import { MODEL, SCHEMA_VERSION } from "./constants.js";
import {
  TAG_MAX_LENGTH,
  TAG_MIN_LENGTH,
  TAG_PATTERN_SOURCE,
} from "./tag_key.js";

const nullableString = {
  type: ["string", "null"],
};

const nullableInteger = {
  type: ["integer", "null"],
};

const confidence = {
  type: "number",
  minimum: 0,
  maximum: 1,
};

const evidenceIds = {
  type: "array",
  items: { type: "string" },
};

const strictObject = (properties) => ({
  type: "object",
  properties,
  required: Object.keys(properties),
  additionalProperties: false,
});

const tagValue = {
  type: "string",
  minLength: TAG_MIN_LENGTH,
  maxLength: TAG_MAX_LENGTH,
  pattern: TAG_PATTERN_SOURCE,
};

/// The one closed slot. Six words, every one of them answering the same
/// question — what part of a life this belongs to — so that a reader filtering
/// on it gets the same six words on every card. Closed because an open slot
/// here would coin 뷰티 today and 미용 tomorrow.
///
/// Two words were taken out, and both left for the same reason: they answered
/// a different question than the other six, so they stacked on top of them
/// instead of sorting between them.
///
/// 여행·장소 was one word whose 여행 half was the bug. Anywhere can be
/// somewhere a person travels to, so it invited itself onto every restaurant:
/// measured on four real place captures run four times each, 맛집·카페 landed
/// 16/16 while 여행·장소 landed 12/16, flipping on every single capture. Named
/// plainly 장소, it is told apart from 맛집·카페 by what you go there for,
/// which is a question a screenshot answers.
///
/// 쇼핑 answered what you would do about a thing (buy it), not what area it
/// belongs to, so an 올리브영 haul was 뷰티 and 쇼핑 every time. Unlike 여행 it
/// was stable (9/9 across purchase captures), and dropping it has a known,
/// accepted cost: a 가전 or 패션 purchase now has no field at all, because
/// nothing else here takes it. Those captures are still found by their kinds
/// (가전, 패션) and by search; they just do not answer "what part of my life".
export const FIELD_VALUES = Object.freeze([
  "뷰티",
  "건강·운동",
  "맛집·카페",
  "레시피",
  "장소",
  "생활·팁",
]);

/// Observations come before the value because structured output is generated
/// in schema order: listing what was read first makes the model decide from
/// the screenshot instead of choosing a word and justifying it afterwards. It
/// also shows the reader the basis, which is the only way to tell a
/// menu-grounded tag from one guessed off a shop name.
const tag = (value) =>
  strictObject({
    observations: {
      type: "array",
      maxItems: 12,
      items: { type: "string", minLength: 1, maxLength: 80 },
    },
    value,
    confidence,
    evidenceIds,
  });

const tagList = (maxItems, value = tagValue) => ({
  type: "array",
  maxItems,
  items: tag(value),
});

/// Four slots for generation, one flat list in storage.
///
/// Tagged as a single list, the model would give one capture an area word and
/// the next none, and file a 성수 cafe under 성수 on Monday and under nothing on
/// Tuesday. The slots are the questions almost every capture answers — what
/// part of life, where, what it is, what is notable about it — asked one at a
/// time so that none is silently skipped. They are not folders: the server
/// flattens them into `tags` and the reader never sees the slot, only a facet
/// on each tag. maxItems per slot is a guard against runaway output, not a
/// product limit.
const filing = strictObject({
  fields: tagList(3, { type: "string", enum: [...FIELD_VALUES] }),
  areas: tagList(3),
  kinds: tagList(4),
  traits: tagList(4),
});

export const ANALYSIS_SCHEMA = {
  type: "object",
  properties: {
    schemaVersion: {
      type: "string",
      enum: [SCHEMA_VERSION],
    },
    model: {
      type: "string",
      enum: [MODEL],
    },
    domain: {
      type: "string",
      enum: ["beauty", "food", "unknown"],
    },
    contentKind: {
      type: "string",
      enum: [
        "beauty_product",
        "recipe",
        "sauce_recipe",
        "commerce_product",
        "product_review",
        "menu_comparison",
        "place",
        "unknown",
      ],
    },
    filing,
    completeness: {
      type: "string",
      enum: [
        "complete",
        "partial",
        "conflicted",
        "needs_review",
        "unsupported",
      ],
    },
    title: strictObject({
      value: nullableString,
      status: {
        type: "string",
        enum: ["observed", "inferred", "missing"],
      },
      confidence,
      evidenceIds,
    }),
    place: strictObject({
      name: nullableString,
      address: nullableString,
      searchArea: {
        type: ["string", "null"],
        description:
          "The short location words a person would type next to the shop name in a map search, taken only from visible text: 성수, 가로수길, 홍대, 연남동. Keep the wording that appears on screen instead of converting it to an administrative district. Never a full address, building number, floor, or unit. Null when the screenshot shows no location.",
      },
      category: {
        type: ["string", "null"],
        enum: [
          "restaurant",
          "cafe",
          "beauty",
          "shopping",
          "lodging",
          "activity",
          "other",
          null,
        ],
      },
      confidence,
      evidenceIds,
    }),
    summary: {
      type: "string",
      description:
        "A single concise Korean sentence, ideally 20-45 characters, grounded in visible evidence and not repeating the title.",
    },
    evidence: {
      type: "array",
      items: strictObject({
        id: { type: "string" },
        text: { type: "string" },
        region: {
          type: "string",
          enum: [
            "image_text",
            "caption",
            "overlay",
            "product_panel",
            "menu",
            "unknown",
          ],
        },
        confidence,
      }),
    },
    ingredientGroups: {
      type: "array",
      items: strictObject({
        name: { type: "string" },
        ingredients: {
          type: "array",
          items: strictObject({
            name: { type: "string" },
            amount: nullableString,
            unit: nullableString,
            preparation: nullableString,
            optional: { type: "boolean" },
            originalText: { type: "string" },
            confidence,
            evidenceIds,
          }),
        },
      }),
    },
    steps: {
      type: "array",
      items: strictObject({
        order: { type: "integer" },
        instruction: { type: "string" },
        durationSeconds: nullableInteger,
        temperature: nullableString,
        evidenceIds,
      }),
    },
    facts: {
      type: "array",
      items: strictObject({
        label: { type: "string" },
        value: { type: "string" },
        confidence,
        evidenceIds,
      }),
    },
    conflicts: {
      type: "array",
      items: strictObject({
        field: { type: "string" },
        details: { type: "string" },
        evidenceIds,
      }),
    },
    warnings: {
      type: "array",
      items: { type: "string" },
    },
  },
  required: [
    "schemaVersion",
    "model",
    "domain",
    "contentKind",
    "filing",
    "completeness",
    "title",
    "place",
    "summary",
    "evidence",
    "ingredientGroups",
    "steps",
    "facts",
    "conflicts",
    "warnings",
  ],
  additionalProperties: false,
};

export const ANALYSIS_TEXT_FORMAT = Object.freeze({
  type: "json_schema",
  name: "ori_capture_analysis",
  strict: true,
  schema: ANALYSIS_SCHEMA,
});
