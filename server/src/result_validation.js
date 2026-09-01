import { MODEL, SCHEMA_VERSION } from "./constants.js";
import { OpenAITransportError } from "./errors.js";

const DOMAINS = new Set(["beauty", "food", "unknown"]);
const CONTENT_KINDS = new Set([
  "beauty_product",
  "recipe",
  "sauce_recipe",
  "commerce_product",
  "product_review",
  "menu_comparison",
  "place",
  "unknown",
]);
const COMPLETENESS = new Set([
  "complete",
  "partial",
  "conflicted",
  "needs_review",
  "unsupported",
]);
const TITLE_STATUSES = new Set(["observed", "inferred", "missing"]);
const REGIONS = new Set([
  "image_text",
  "caption",
  "overlay",
  "product_panel",
  "menu",
  "unknown",
]);
const TAG_MIN_LENGTH = 2;
const TAG_MAX_LENGTH = 20;
const TAG_PATTERN =
  /^[가-힣ㄱ-ㅎㅏ-ㅣA-Za-z0-9]+(?:[ ·ㆍ&/+＋~-][가-힣ㄱ-ㅎㅏ-ㅣA-Za-z0-9]+)*$/u;
const EVIDENCE_REPAIR_WARNING =
  "일부 정보는 확인이 필요해요.";
const ROOT_KEYS = new Set([
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
]);

function invalid(message) {
  return new OpenAITransportError("invalid_response", {
    cause: new Error(message),
    retryable: true,
  });
}

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function assertExactKeys(object, keys, path) {
  if (!isObject(object)) {
    throw invalid(`${path} is not an object`);
  }
  const actual = Object.keys(object);
  if (
    actual.length !== keys.size ||
    actual.some((key) => !keys.has(key))
  ) {
    throw invalid(`${path} has unexpected keys`);
  }
}

function assertString(value, path, { nullable = false, nonEmpty = true } = {}) {
  if (nullable && value === null) {
    return;
  }
  if (
    typeof value !== "string" ||
    (nonEmpty && value.trim().length === 0)
  ) {
    throw invalid(`${path} is not a valid string`);
  }
}

function assertConfidence(value, path) {
  if (!Number.isFinite(value) || value < 0 || value > 1) {
    throw invalid(`${path} is not a confidence`);
  }
}

function sanitizeTagName(value) {
  assertString(value, "tag");
  const sanitized = value.normalize("NFKC").trim().replace(/\s+/gu, " ");
  const length = Array.from(sanitized).length;
  if (
    length < TAG_MIN_LENGTH ||
    length > TAG_MAX_LENGTH ||
    !TAG_PATTERN.test(sanitized)
  ) {
    throw invalid("tag must be a reusable 2-20 character label");
  }
  return sanitized;
}

const MAX_TAGS = 12;

function sanitizeTag(tag, path) {
  assertExactKeys(
    tag,
    new Set(["observations", "value", "confidence", "evidenceIds"]),
    path,
  );
  const value = sanitizeTagName(tag.value);
  assertConfidence(tag.confidence, `${path}.confidence`);
  assertStringArray(tag.evidenceIds, `${path}.evidenceIds`);
  assertStringArray(tag.observations, `${path}.observations`, {
    nonEmptyItems: true,
  });
  const quotes = tag.observations.map((text) => text.trim()).filter(Boolean);
  // A tag the model could not observe anything for is a guess wearing a tag's
  // clothes, so it does not survive.
  if (quotes.length === 0) return null;
  return {
    value,
    source: "ai",
    confidence: tag.confidence,
    evidenceIds: tag.evidenceIds,
    quotes,
    citations: [],
  };
}

/// Rebuilds the model's tags into the shape the client stores.
///
/// The model reports what it observed; the quotes and the source are derived
/// here. Keeping the derivation on this side means the same observations always
/// produce the same tags, whatever the model felt like that run.
///
/// A repeated name is dropped rather than rejected: two tags with one name is
/// the model saying the same thing twice, which costs the reader nothing to
/// have collapsed. Deciding that two *different* names mean one thing is not
/// this pass's job.
function sanitizeTags(value) {
  if (!Array.isArray(value)) {
    throw invalid("tags is not an array");
  }
  if (value.length > MAX_TAGS) {
    throw invalid("tags has too many entries");
  }
  const seen = new Set();
  const tags = [];
  value.forEach((tag, index) => {
    const sanitized = sanitizeTag(tag, `tags[${index}]`);
    if (!sanitized || seen.has(sanitized.value)) return;
    seen.add(sanitized.value);
    tags.push(sanitized);
  });
  return tags;
}

function assertStringArray(value, path, { nonEmptyItems = true } = {}) {
  if (!Array.isArray(value)) {
    throw invalid(`${path} is not an array`);
  }
  value.forEach((item, index) =>
    assertString(item, `${path}[${index}]`, { nonEmpty: nonEmptyItems }),
  );
}

export function validateAnalysisResult(result) {
  assertExactKeys(result, ROOT_KEYS, "result");

  if (result.schemaVersion !== SCHEMA_VERSION || result.model !== MODEL) {
    throw invalid("schema version or model mismatch");
  }
  if (!DOMAINS.has(result.domain)) {
    throw invalid("invalid domain");
  }
  if (!CONTENT_KINDS.has(result.contentKind)) {
    throw invalid("invalid content kind");
  }
  result.tags = sanitizeTags(result.tags);
  if (!COMPLETENESS.has(result.completeness)) {
    throw invalid("invalid completeness");
  }
  assertString(result.summary, "summary", { nonEmpty: false });

  assertExactKeys(
    result.title,
    new Set(["value", "status", "confidence", "evidenceIds"]),
    "title",
  );
  assertString(result.title.value, "title.value", { nullable: true });
  if (!TITLE_STATUSES.has(result.title.status)) {
    throw invalid("invalid title status");
  }
  if (
    (result.title.status === "missing" && result.title.value !== null) ||
    (result.title.status !== "missing" && result.title.value === null)
  ) {
    throw invalid("title status and value mismatch");
  }
  assertConfidence(result.title.confidence, "title.confidence");
  assertStringArray(result.title.evidenceIds, "title.evidenceIds");

  assertExactKeys(
    result.place,
    new Set([
      "name",
      "address",
      "searchArea",
      "category",
      "confidence",
      "evidenceIds",
    ]),
    "place",
  );
  assertString(result.place.name, "place.name", { nullable: true });
  assertString(result.place.address, "place.address", { nullable: true });
  assertString(result.place.searchArea, "place.searchArea", {
    nullable: true,
  });
  const placeCategories = new Set([
    "restaurant",
    "cafe",
    "beauty",
    "shopping",
    "lodging",
    "activity",
    "other",
  ]);
  if (
    result.place.category !== null &&
    !placeCategories.has(result.place.category)
  ) {
    throw invalid("place.category is invalid");
  }
  assertConfidence(result.place.confidence, "place.confidence");
  assertStringArray(result.place.evidenceIds, "place.evidenceIds");
  const hasPlace = result.place.name !== null || result.place.address !== null;
  if (
    (!hasPlace &&
      (result.place.category !== null ||
        result.place.confidence !== 0 ||
        result.place.evidenceIds.length > 0)) ||
    (hasPlace && result.place.category === null)
  ) {
    throw invalid("place fields are inconsistent");
  }

  if (!Array.isArray(result.evidence)) {
    throw invalid("evidence is not an array");
  }
  const evidenceIdSet = new Set();
  result.evidence.forEach((item, index) => {
    const path = `evidence[${index}]`;
    assertExactKeys(
      item,
      new Set(["id", "text", "region", "confidence"]),
      path,
    );
    assertString(item.id, `${path}.id`);
    assertString(item.text, `${path}.text`);
    if (!REGIONS.has(item.region)) {
      throw invalid(`${path}.region is invalid`);
    }
    assertConfidence(item.confidence, `${path}.confidence`);
    if (evidenceIdSet.has(item.id)) {
      throw invalid(`duplicate evidence id: ${item.id}`);
    }
    evidenceIdSet.add(item.id);
  });

  const referenceLists = [
    ["title.evidenceIds", result.title.evidenceIds],
    ["place.evidenceIds", result.place.evidenceIds],
  ];

  if (!Array.isArray(result.ingredientGroups)) {
    throw invalid("ingredientGroups is not an array");
  }
  result.ingredientGroups.forEach((group, groupIndex) => {
    const groupPath = `ingredientGroups[${groupIndex}]`;
    assertExactKeys(group, new Set(["name", "ingredients"]), groupPath);
    assertString(group.name, `${groupPath}.name`);
    if (!Array.isArray(group.ingredients)) {
      throw invalid(`${groupPath}.ingredients is not an array`);
    }
    group.ingredients.forEach((ingredient, ingredientIndex) => {
      const path = `${groupPath}.ingredients[${ingredientIndex}]`;
      assertExactKeys(
        ingredient,
        new Set([
          "name",
          "amount",
          "unit",
          "preparation",
          "optional",
          "originalText",
          "confidence",
          "evidenceIds",
        ]),
        path,
      );
      assertString(ingredient.name, `${path}.name`);
      assertString(ingredient.amount, `${path}.amount`, { nullable: true });
      assertString(ingredient.unit, `${path}.unit`, { nullable: true });
      assertString(ingredient.preparation, `${path}.preparation`, {
        nullable: true,
      });
      if (typeof ingredient.optional !== "boolean") {
        throw invalid(`${path}.optional is not a boolean`);
      }
      assertString(ingredient.originalText, `${path}.originalText`);
      assertConfidence(ingredient.confidence, `${path}.confidence`);
      assertStringArray(ingredient.evidenceIds, `${path}.evidenceIds`);
      referenceLists.push([`${path}.evidenceIds`, ingredient.evidenceIds]);
    });
  });

  if (!Array.isArray(result.steps)) {
    throw invalid("steps is not an array");
  }
  result.steps.forEach((step, index) => {
    const path = `steps[${index}]`;
    assertExactKeys(
      step,
      new Set([
        "order",
        "instruction",
        "durationSeconds",
        "temperature",
        "evidenceIds",
      ]),
      path,
    );
    if (!Number.isInteger(step.order) || step.order < 1) {
      throw invalid(`${path}.order is invalid`);
    }
    assertString(step.instruction, `${path}.instruction`);
    if (
      step.durationSeconds !== null &&
      (!Number.isInteger(step.durationSeconds) || step.durationSeconds < 0)
    ) {
      throw invalid(`${path}.durationSeconds is invalid`);
    }
    assertString(step.temperature, `${path}.temperature`, { nullable: true });
    assertStringArray(step.evidenceIds, `${path}.evidenceIds`);
    referenceLists.push([`${path}.evidenceIds`, step.evidenceIds]);
  });

  for (const [key, keys] of [
    ["facts", new Set(["label", "value", "confidence", "evidenceIds"])],
    ["conflicts", new Set(["field", "details", "evidenceIds"])],
  ]) {
    if (!Array.isArray(result[key])) {
      throw invalid(`${key} is not an array`);
    }
    result[key].forEach((item, index) => {
      const path = `${key}[${index}]`;
      assertExactKeys(item, keys, path);
      if (key === "facts") {
        assertString(item.label, `${path}.label`);
        assertString(item.value, `${path}.value`);
        assertConfidence(item.confidence, `${path}.confidence`);
      } else {
        assertString(item.field, `${path}.field`);
        assertString(item.details, `${path}.details`);
      }
      assertStringArray(item.evidenceIds, `${path}.evidenceIds`);
      referenceLists.push([`${path}.evidenceIds`, item.evidenceIds]);
    });
  }

  assertStringArray(result.warnings, "warnings");

  let repairedEvidenceReferences = false;
  for (const [, ids] of referenceLists) {
    const validIds = ids.filter((id) => evidenceIdSet.has(id));
    if (validIds.length !== ids.length) {
      ids.splice(0, ids.length, ...validIds);
      repairedEvidenceReferences = true;
    }
  }

  if (repairedEvidenceReferences) {
    if (!new Set(["unsupported", "conflicted"]).has(result.completeness)) {
      result.completeness = "needs_review";
    }
    if (!result.warnings.includes(EVIDENCE_REPAIR_WARNING)) {
      result.warnings.push(EVIDENCE_REPAIR_WARNING);
    }
  }

  return result;
}
