import { MODEL, SCHEMA_VERSION } from "./constants.js";

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

const LABEL_PATTERN =
  "^[가-힣ㄱ-ㅎㅏ-ㅣA-Za-z0-9]+(?:[ ·ㆍ&/+＋~-][가-힣ㄱ-ㅎㅏ-ㅣA-Za-z0-9]+)*$";

const labelValue = {
  type: "string",
  minLength: 2,
  maxLength: 20,
  pattern: LABEL_PATTERN,
};

/// One axis of the saved library. A capture may carry several labels on the same
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
    // Flat and unbounded: a capture belongs under every word that fits it,
    // and there is no folder above them to pick first. maxItems is a guard
    // against runaway output, not a product limit.
    //
    // Observations come before the value because structured output is
    // generated in schema order: listing what was read first makes the model
    // decide from the screenshot instead of choosing a word and justifying it
    // afterwards. It also shows the reader the basis, which is the only way to
    // tell a menu-grounded tag from one guessed off a shop name.
    tags: {
      type: "array",
      maxItems: 12,
      items: strictObject({
        observations: {
          type: "array",
          maxItems: 12,
          items: { type: "string", minLength: 1, maxLength: 80 },
        },
        value: labelValue,
        confidence,
        evidenceIds,
      }),
    },
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
    "tags",
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
