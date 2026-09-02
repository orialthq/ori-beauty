import assert from "node:assert/strict";
import test from "node:test";
import { AppError, OpenAITransportError } from "../src/errors.js";
import { validateTagMergesRequest } from "../src/request_validation.js";
import { buildTagMergeRequest } from "../src/tag_merge_prompt.js";
import {
  SAME_KEY_REASON,
  createTagMergeService,
} from "../src/tag_merge_service.js";

function transportAnswering(payload, { onRequest } = {}) {
  return {
    async createResponse(requestBody) {
      onRequest?.(requestBody);
      return { output_text: JSON.stringify(payload) };
    },
  };
}

const neverCalled = {
  async createResponse() {
    throw new Error("the model must not be asked");
  },
};

const entry = (value, count) => ({ value, count });

test("pairs spelling variants without asking the model", async () => {
  const service = createTagMergeService({ transport: neverCalled });

  const result = await service.merge({
    vocabulary: [entry("스킨 케어", 3), entry("스킨케어", 9), entry("스킨-케어", 1)],
  });

  // Everything shares one key, so nothing is left for the model to look at.
  assert.deepEqual(result.merges, [
    { from: "스킨 케어", into: "스킨케어", reason: SAME_KEY_REASON },
    { from: "스킨-케어", into: "스킨케어", reason: SAME_KEY_REASON },
  ]);
});

test("a same-key tie goes to the entry earlier in the request", async () => {
  const service = createTagMergeService({ transport: neverCalled });

  const result = await service.merge({
    vocabulary: [entry("카페 디저트", 4), entry("카페디저트", 4)],
  });

  assert.deepEqual(result.merges, [
    { from: "카페디저트", into: "카페 디저트", reason: SAME_KEY_REASON },
  ]);
});

test("the model sees only one spelling per word, with counts", async () => {
  let sent = null;
  const service = createTagMergeService({
    transport: transportAnswering({ merges: [] }, { onRequest: (b) => (sent = b) }),
  });

  await service.merge({
    vocabulary: [entry("스킨 케어", 3), entry("스킨케어", 9), entry("피부관리", 2)],
  });

  assert.equal(sent.store, false);
  assert.deepEqual(sent.reasoning, { effort: "low" });
  assert.equal(sent.tools, undefined);
  assert.equal(sent.text.format.type, "json_schema");
  assert.equal(sent.text.format.strict, true);
  const text = sent.input[0].content[0].text;
  assert.match(text, /- 스킨케어 \(9\)/);
  assert.match(text, /- 피부관리 \(2\)/);
  // The variant already paired must not be offered for a second merge.
  assert.doesNotMatch(text, /스킨 케어/);
});

test("model pairs are checked against the list and pointed at the bigger word", async () => {
  const service = createTagMergeService({
    transport: transportAnswering({
      merges: [
        // Backwards: the model put the more-used word in `from`.
        { from: "스킨케어", into: "피부관리", reason: "같은 뜻" },
        // Not in the list at all.
        { from: "피부 관리", into: "스킨케어", reason: "지어낸 표기" },
        { from: "스킨케어", into: "뷰티", reason: "목록에 없는 into" },
        // Same word twice.
        { from: "멕시칸", into: "멕시칸", reason: "자기 자신" },
        { from: "멕시코 음식", into: "멕시칸", reason: "" },
        // The same pair again, the other way round.
        { from: "멕시칸", into: "멕시코 음식", reason: "중복" },
      ],
    }),
  });

  const result = await service.merge({
    vocabulary: [
      entry("스킨케어", 9),
      entry("피부관리", 2),
      entry("멕시코 음식", 5),
      entry("멕시칸", 5),
    ],
  });

  assert.deepEqual(result.merges, [
    { from: "피부관리", into: "스킨케어", reason: "같은 뜻" },
    // Tie broken by request order, and the blank reason filled in.
    { from: "멕시칸", into: "멕시코 음식", reason: "같은 것을 다르게 쓴 태그예요." },
  ]);
});

test("a word is proposed for merging at most once", async () => {
  const service = createTagMergeService({
    transport: transportAnswering({
      merges: [
        { from: "피부관리", into: "스킨케어", reason: "같은 뜻" },
        { from: "피부관리", into: "뷰티", reason: "두 번째 목적지" },
      ],
    }),
  });

  const result = await service.merge({
    vocabulary: [entry("스킨케어", 9), entry("피부관리", 2), entry("뷰티", 20)],
  });

  assert.deepEqual(
    result.merges.map((merge) => [merge.from, merge.into]),
    [["피부관리", "스킨케어"]],
  );
});

test("deterministic pairs come first and the answer is capped at thirty", async () => {
  const vocabulary = [];
  for (let index = 0; index < 20; index += 1) {
    vocabulary.push(entry(`단어${index}`, 10), entry(`단어 ${index}`, 1));
  }
  for (let index = 0; index < 20; index += 1) {
    vocabulary.push(entry(`표기${index}`, 3), entry(`이름${index}`, 2));
  }
  const service = createTagMergeService({
    transport: transportAnswering({
      merges: Array.from({ length: 20 }, (_, index) => ({
        from: `이름${index}`,
        into: `표기${index}`,
        reason: "같은 뜻",
      })),
    }),
  });

  const result = await service.merge({ vocabulary });

  assert.equal(result.merges.length, 30);
  assert.equal(result.merges[0].reason, SAME_KEY_REASON);
  assert.equal(result.merges[19].reason, SAME_KEY_REASON);
  assert.equal(result.merges[20].reason, "같은 뜻");
});

test("a failing model still returns the deterministic pairs", async () => {
  const service = createTagMergeService({
    transport: {
      async createResponse() {
        throw new OpenAITransportError("upstream", { retryable: true });
      },
    },
  });

  const result = await service.merge({
    vocabulary: [entry("스킨 케어", 3), entry("스킨케어", 9), entry("피부관리", 2)],
  });

  assert.deepEqual(result.merges, [
    { from: "스킨 케어", into: "스킨케어", reason: SAME_KEY_REASON },
  ]);
});

test("a failing model with nothing deterministic to return is an error", async () => {
  const service = createTagMergeService({
    transport: {
      async createResponse() {
        throw new OpenAITransportError("rate_limited", { retryable: true });
      },
    },
  });

  await assert.rejects(
    service.merge({ vocabulary: [entry("스킨케어", 9), entry("피부관리", 2)] }),
    (error) =>
      error instanceof OpenAITransportError && error.kind === "rate_limited",
  );
});

test("an unreadable model answer is an empty answer, not an error", async () => {
  const service = createTagMergeService({
    transport: { async createResponse() { return { output_text: "{" }; } },
  });

  const result = await service.merge({
    vocabulary: [entry("스킨케어", 9), entry("피부관리", 2)],
  });

  assert.deepEqual(result.merges, []);
});

test("the prompt carries only names and counts", () => {
  const body = buildTagMergeRequest({
    vocabulary: [entry("맛집·카페", 41), entry("성수", 12)],
    model: "m",
  });

  assert.equal(body.input[0].content[0].text, "태그 (사용 횟수):\n- 맛집·카페 (41)\n- 성수 (12)");
});

test("the request needs at least two well-formed entries", () => {
  const rejects = (body, pattern) =>
    assert.throws(
      () => validateTagMergesRequest(body),
      (error) =>
        error instanceof AppError &&
        error.code === "INVALID_REQUEST" &&
        error.httpStatus === 400 &&
        pattern.test(error.message),
    );

  rejects({}, /vocabulary가 필요해요/);
  rejects({ vocabulary: [entry("스킨케어", 9)] }, /2개 이상/);
  rejects({ vocabulary: [entry("스킨케어", 9), entry("스킨케어", 3)] }, /2개 이상/);
  rejects({ vocabulary: "스킨케어" }, /형식/);
  rejects({ vocabulary: [entry("스킨케어", 9), entry("뷰", 1)] }, /value/);
  rejects({ vocabulary: [entry("스킨케어", 9), entry("뷰티", 0)] }, /count/);
  rejects({ vocabulary: [entry("스킨케어", 9), { value: "뷰티", count: 1, ids: [] }] }, /지원하지 않는/);
  rejects({ vocabulary: [], extra: true }, /지원하지 않는/);
});

test("the request keeps spelling variants apart for the deterministic pass", () => {
  const input = validateTagMergesRequest({
    vocabulary: [entry("스킨 케어", 3), entry("스킨케어", 9)],
  });

  assert.deepEqual(input.vocabulary, [entry("스킨 케어", 3), entry("스킨케어", 9)]);
});
