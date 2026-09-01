import assert from "node:assert/strict";
import test from "node:test";
import { validateAnalysisResult } from "../src/result_validation.js";
import { makeValidAnalysis } from "./fixtures.js";

function withTags(tags) {
  const result = makeValidAnalysis();
  result.tags = tags;
  return result;
}

const tag = (value, observations, confidence = 0.8) => ({
  observations,
  value,
  confidence,
  evidenceIds: ["e1"],
});

test("accepts several tags, each with what it observed", () => {
  const validated = validateAnalysisResult(
    withTags([
      tag("파스타", ["까르보나라 18,000", "봉골레 17,000"]),
      tag("와인바", ["글라스 와인 9,000"], 0.6),
      tag("성수", ["성수동 2가"]),
    ]),
  );

  assert.deepEqual(
    validated.tags.map((entry) => entry.value),
    ["파스타", "와인바", "성수"],
  );
  assert.deepEqual(validated.tags[0].quotes, [
    "까르보나라 18,000",
    "봉골레 17,000",
  ]);
  // Everything the screenshot pass produces is the model's suggestion.
  assert.deepEqual(
    validated.tags.map((entry) => entry.source),
    ["ai", "ai", "ai"],
  );
});

test("drops a tag that observed nothing", () => {
  // Without an observation the tag is a guess wearing a tag's clothes.
  const validated = validateAnalysisResult(withTags([tag("파스타", [])]));

  assert.deepEqual(validated.tags, []);
});

test("a capture with nothing observable comes back untagged", () => {
  // Not an error: 분류 필요 used to be a folder, and it is the absence of tags
  // now. The client has a place to show it.
  const validated = validateAnalysisResult(withTags([]));

  assert.deepEqual(validated.tags, []);
});

test("collapses a repeated tag rather than rejecting the analysis", () => {
  const validated = validateAnalysisResult(
    withTags([tag("성수", ["성수동 2가"]), tag("성수", ["성수역 2번 출구"])]),
  );

  assert.deepEqual(
    validated.tags.map((entry) => entry.value),
    ["성수"],
  );
});

test("rejects a tag that would file only this capture", () => {
  assert.throws(() =>
    validateAnalysisResult(withTags([tag("리스토란테 오늘 #맛집", ["메뉴"])])),
  );
});

test("rejects runaway tag counts", () => {
  const many = Array.from({ length: 13 }, (_, index) =>
    tag(`분류${index}`, ["메뉴"]),
  );

  assert.throws(() => validateAnalysisResult(withTags(many)));
});
