import assert from "node:assert/strict";
import test from "node:test";
import { validateAnalysisResult } from "../src/result_validation.js";
import { makeFiling, makeTag, makeValidAnalysis } from "./fixtures.js";

function withFiling(slots) {
  return makeValidAnalysis({ filing: makeFiling(slots) });
}

const tag = (value, observations, confidence = 0.8) =>
  makeTag(value, observations, confidence, ["e1"]);

test("accepts several tags, each with what it observed", () => {
  const validated = validateAnalysisResult(
    withFiling({
      kinds: [
        tag("파스타", ["까르보나라 18,000", "봉골레 17,000"]),
        tag("와인바", ["글라스 와인 9,000"], 0.6),
      ],
      areas: [tag("성수", ["성수동 2가"])],
    }),
  );

  assert.deepEqual(
    validated.tags.map((entry) => entry.value),
    ["성수", "파스타", "와인바"],
  );
  assert.deepEqual(validated.tags[1].quotes, [
    "까르보나라 18,000",
    "봉골레 17,000",
  ]);
  // Everything the screenshot pass produces is the model's suggestion.
  assert.deepEqual(
    validated.tags.map((entry) => entry.source),
    ["ai", "ai", "ai"],
  );
  // The slots are gone from the answer; the reader sees one flat list.
  assert.equal(validated.filing, undefined);
});

test("flattens the slots in order and stamps each tag with its facet", () => {
  const validated = validateAnalysisResult(
    withFiling({
      traits: [tag("웨이팅", ["웨이팅 30분"])],
      kinds: [tag("카페·디저트", ["아메리카노", "크루아상"])],
      areas: [tag("성수", ["성수동 2가"])],
      fields: [tag("맛집·카페", ["아메리카노"])],
    }),
  );

  assert.deepEqual(
    validated.tags.map((entry) => [entry.value, entry.facet]),
    [
      ["맛집·카페", "field"],
      ["성수", "area"],
      ["카페·디저트", "kind"],
      ["웨이팅", "trait"],
    ],
  );
  assert.deepEqual(Object.keys(validated.tags[0]), [
    "value",
    "facet",
    "source",
    "confidence",
    "evidenceIds",
    "quotes",
    "citations",
  ]);
});

test("drops a tag that observed nothing", () => {
  // Without an observation the tag is a guess wearing a tag's clothes.
  const validated = validateAnalysisResult(
    withFiling({ kinds: [tag("파스타", [])] }),
  );

  assert.deepEqual(validated.tags, []);
});

test("a capture with nothing observable comes back untagged", () => {
  // Not an error: 분류 필요 used to be a folder, and it is the absence of tags
  // now. The client has a place to show it.
  const validated = validateAnalysisResult(withFiling({}));

  assert.deepEqual(validated.tags, []);
});

test("collapses a repeated tag rather than rejecting the analysis", () => {
  const validated = validateAnalysisResult(
    withFiling({
      areas: [tag("성수", ["성수동 2가"]), tag("성수", ["성수역 2번 출구"])],
    }),
  );

  assert.deepEqual(
    validated.tags.map((entry) => entry.value),
    ["성수"],
  );
});

test("collapses the same word across slots by key, first slot wins", () => {
  // 스킨케어 in kinds and 스킨 케어 in traits is one word said twice.
  const validated = validateAnalysisResult(
    withFiling({
      fields: [tag("뷰티", ["토너"])],
      kinds: [tag("스킨케어", ["토너", "세럼"])],
      traits: [tag("스킨 케어", ["토너"]), tag("스킨-케어", ["세럼"])],
    }),
  );

  assert.deepEqual(
    validated.tags.map((entry) => [entry.value, entry.facet]),
    [
      ["뷰티", "field"],
      ["스킨케어", "kind"],
    ],
  );
});

test("rejects a field outside the closed list", () => {
  // The seven fields are the one slot every card must agree on. A new word
  // there is the model ignoring the contract, not a new shelf.
  assert.throws(() =>
    validateAnalysisResult(withFiling({ fields: [tag("미용", ["토너"])] })),
  );
});

test("accepts every word on the closed field list", () => {
  const validated = validateAnalysisResult(
    withFiling({
      fields: [tag("레시피", ["재료"]), tag("건강·운동", ["단백질 20g"])],
    }),
  );

  assert.deepEqual(
    validated.tags.map((entry) => entry.value),
    ["레시피", "건강·운동"],
  );
});

test("rejects a tag that would file only this capture", () => {
  assert.throws(() =>
    validateAnalysisResult(
      withFiling({ kinds: [tag("리스토란테 오늘 #맛집", ["메뉴"])] }),
    ),
  );
});

test("rejects unexpected filing slots", () => {
  const result = withFiling({});
  result.filing.folders = [];

  assert.throws(() => validateAnalysisResult(result));
});

test("rejects runaway counts within one slot", () => {
  const many = Array.from({ length: 5 }, (_, index) =>
    tag(`분류${index}`, ["메뉴"]),
  );

  assert.throws(() => validateAnalysisResult(withFiling({ kinds: many })));
});

test("keeps at most twelve tags after flattening, dropping the tail", () => {
  // Every slot filled to its ceiling adds up to fourteen; the list one card
  // can show stops at twelve, and the least essential slot is the one cut.
  const words = (prefix, count) =>
    Array.from({ length: count }, (_, index) =>
      tag(`${prefix}${index}`, ["메뉴"]),
    );
  const validated = validateAnalysisResult(
    withFiling({
      fields: [tag("뷰티", ["토너"]), tag("레시피", ["재료"]), tag("생활·팁", ["팁"])],
      areas: words("지역", 3),
      kinds: words("종류", 4),
      traits: words("특성", 4),
    }),
  );

  assert.equal(validated.tags.length, 12);
  assert.deepEqual(
    validated.tags.slice(-2).map((entry) => entry.value),
    ["특성0", "특성1"],
  );
});

test("rewrites a tag to the library's spelling when the key matches", () => {
  const validated = validateAnalysisResult(
    withFiling({
      fields: [tag("뷰티", ["토너"])],
      kinds: [tag("스킨 케어", ["토너", "세럼"]), tag("메이크업", ["립"])],
    }),
    {
      vocabulary: [
        { value: "스킨케어", count: 9 },
        { value: "맛집·카페", count: 41 },
      ],
    },
  );

  assert.deepEqual(
    validated.tags.map((entry) => entry.value),
    ["뷰티", "스킨케어", "메이크업"],
  );
});

test("prunes a tag's dangling evidence and routes the result to review", () => {
  const result = makeValidAnalysis({
    completeness: "complete",
    filing: makeFiling({
      kinds: [makeTag("국·찌개", ["된장찌개"], 0.9, ["e1", "ghost"])],
    }),
    warnings: [],
  });

  const validated = validateAnalysisResult(result);

  assert.deepEqual(validated.tags[0].evidenceIds, ["e1"]);
  assert.equal(validated.completeness, "needs_review");
  assert.deepEqual(validated.warnings, ["일부 정보는 확인이 필요해요."]);
});
