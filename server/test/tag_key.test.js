import assert from "node:assert/strict";
import test from "node:test";
import {
  TAG_PATTERN,
  TAG_PATTERN_SOURCE,
  normalizeTagValue,
  tagKey,
} from "../src/tag_key.js";

test("spelling variants share one key", () => {
  // Mirrors lib/domain/tag_key.dart: the app and the server must agree on
  // which spellings are one word, or a merge proposed here would not apply
  // there.
  const variants = ["스킨케어", "스킨 케어", "스킨-케어", "스킨·케어", "스킨ㆍ케어"];
  assert.deepEqual(
    new Set(variants.map(tagKey)),
    new Set(["스킨케어"]),
  );
  assert.equal(tagKey("Skin Care"), "skincare");
  assert.equal(tagKey("2~5만원"), tagKey("2-5만원"));
  assert.equal(tagKey("카페 & 디저트"), tagKey("카페/디저트"));
  assert.equal(tagKey("카페＋디저트"), tagKey("카페+디저트"));
});

test("different words keep different keys", () => {
  // Synonyms are the librarian's call, not the key's.
  assert.notEqual(tagKey("카페"), tagKey("커피숍"));
  assert.notEqual(tagKey("카페"), tagKey("카페·디저트"));
});

test("the JSON-schema pattern and the RegExp are one definition", () => {
  assert.equal(TAG_PATTERN.source, TAG_PATTERN_SOURCE);
  assert.equal(TAG_PATTERN.test("카페·디저트"), true);
  assert.equal(TAG_PATTERN.test("스킨케어✨"), false);
});

test("normalizeTagValue collapses whitespace and rejects the rest", () => {
  assert.equal(normalizeTagValue("  건강   루틴  "), "건강 루틴");
  assert.equal(normalizeTagValue("뷰"), null);
  assert.equal(normalizeTagValue("가".repeat(21)), null);
  assert.equal(normalizeTagValue("스킨케어 추천!"), null);
  assert.equal(normalizeTagValue(42), null);
});
