import assert from "node:assert/strict";
import test from "node:test";
import { createRecommendationService } from "../src/recommendation_service.js";
import { validatePlanRecommendationRequest } from "../src/request_validation.js";

function transportAnswering(payload, { onRequest } = {}) {
  return {
    async createResponse(requestBody) {
      onRequest?.(requestBody);
      return { output_text: JSON.stringify(payload) };
    },
  };
}

const shelf = [
  { id: "a", name: "리쥬란 후기", tags: ["뷰티", "시술"] },
  { id: "b", name: "헤어 클리닉 후기", tags: ["뷰티"] },
];

const plan = { title: "결혼식 준비", area: null, scheduledAt: "2026-09-05" };

function task(overrides = {}) {
  return {
    title: "피부 시술 정하기",
    action: "예약",
    daysBefore: 21,
    note: "",
    selected: true,
    saved: [],
    ...overrides,
  };
}

function groups(items) {
  return { groups: [{ title: "할 일", note: "", items }] };
}

test("saved things ride inside a to-do rather than becoming to-dos", async () => {
  const service = createRecommendationService({
    transport: transportAnswering(
      groups([
        task({
          saved: [
            { id: "a", why: "시술 후기를 참고합니다" },
            { id: "b", why: "헤어 관리도 같이 봅니다" },
          ],
        }),
      ]),
    ),
  });

  const result = await service.recommend({ plan, candidates: shelf });

  assert.equal(result.status, "ready");
  assert.equal(result.todoCount, 1);
  assert.equal(result.attachedCount, 2);
  const todo = result.groups[0].items[0];
  assert.equal(todo.title, "피부 시술 정하기");
  assert.deepEqual(todo.saved.map((one) => one.id), ["a", "b"]);
  // The name is resolved from what we sent, never from what the model wrote.
  assert.equal(todo.saved[0].name, "리쥬란 후기");
});

test("an id we never sent is not attached, and its to-do survives", async () => {
  const service = createRecommendationService({
    transport: transportAnswering(
      groups([task({ saved: [{ id: "made-up", why: "그럴듯한 문장" }] })]),
    ),
  });

  const result = await service.recommend({ plan, candidates: shelf });

  assert.equal(result.todoCount, 1);
  assert.equal(result.attachedCount, 0);
  assert.deepEqual(result.groups[0].items[0].saved, []);
});

test("one saved thing lands on one to-do, not on every to-do it suits", async () => {
  // Asked without this, the model attached all three products to all three
  // to-dos: true of each in isolation, useless as a list. The first to-do to
  // claim it keeps it.
  const service = createRecommendationService({
    transport: transportAnswering(
      groups([
        task({ title: "무엇을 살지 정하기", saved: [{ id: "a", why: "고를 때" }] }),
        task({ title: "사기", saved: [{ id: "a", why: "살 때도" }] }),
      ]),
    ),
  });

  const result = await service.recommend({ plan, candidates: shelf });

  assert.equal(result.attachedCount, 1);
  assert.deepEqual(
    result.groups[0].items[0].saved.map((one) => one.id),
    ["a"],
  );
  assert.deepEqual(result.groups[0].items[1].saved, []);
});

test("a saved thing carries the name it was sent under", async () => {
  const service = createRecommendationService({
    transport: transportAnswering(
      groups([task({ saved: [{ id: "a", why: "시술 후기를 참고합니다" }] })]),
    ),
  });

  const result = await service.recommend({ plan, candidates: shelf });

  // Resolved here rather than taken from the answer, so a card never shows a
  // name the model wrote instead of the one in the library.
  assert.equal(result.groups[0].items[0].saved[0].name, "리쥬란 후기");
});

test("a to-do with nothing saved against it is still a to-do", async () => {
  const service = createRecommendationService({
    transport: transportAnswering(groups([task()])),
  });

  const result = await service.recommend({ plan, candidates: shelf });

  assert.equal(result.todoCount, 1);
  assert.equal(result.attachedCount, 0);
});

test("a to-do after the plan date is pulled back to the day itself", async () => {
  const service = createRecommendationService({
    transport: transportAnswering(groups([task({ daysBefore: -3 })])),
  });

  const result = await service.recommend({ plan, candidates: shelf });

  assert.equal(result.groups[0].items[0].daysBefore, 0);
});

test("an item with no title is dropped, and an empty group with it", async () => {
  const service = createRecommendationService({
    transport: transportAnswering({
      groups: [
        { title: "빈 묶음", note: "", items: [task({ title: "   " })] },
        { title: "살아남는 묶음", note: "", items: [task()] },
      ],
    }),
  });

  const result = await service.recommend({ plan, candidates: shelf });

  assert.equal(result.groups.length, 1);
  assert.equal(result.groups[0].title, "살아남는 묶음");
});

test("nothing that fits is a real answer, not an error", async () => {
  const service = createRecommendationService({
    transport: transportAnswering({ groups: [] }),
  });

  const result = await service.recommend({ plan, candidates: shelf });

  assert.equal(result.status, "no_match");
});

test("an empty shelf still gets its to-dos", async () => {
  // Nothing saved is not a reason to skip the call. What a plan requires does
  // not depend on what the reader owns.
  const service = createRecommendationService({
    transport: transportAnswering(groups([task()])),
  });

  const result = await service.recommend({ plan, candidates: [] });

  assert.equal(result.status, "ready");
  assert.equal(result.todoCount, 1);
  assert.equal(result.attachedCount, 0);
});

test("more to-dos than a screen can hold are cut off", async () => {
  const many = Array.from({ length: 30 }, (_, index) =>
    task({ title: `할 일 ${index}` }),
  );
  const service = createRecommendationService({
    transport: transportAnswering(groups(many)),
  });

  const result = await service.recommend({ plan, candidates: shelf });

  assert.equal(result.todoCount, 20);
});

test("prose around the JSON is still read", async () => {
  const service = createRecommendationService({
    transport: {
      async createResponse() {
        return {
          output: [{ content: [{ text: JSON.stringify(groups([task()])) }] }],
        };
      },
    },
  });

  const result = await service.recommend({ plan, candidates: shelf });

  assert.equal(result.status, "ready");
});

test("every candidate is sent, in the order given", async () => {
  // The baseline deliberately does not filter or reorder. A change that starts
  // dropping candidates should fail here and be argued for.
  let sent = null;
  const service = createRecommendationService({
    transport: transportAnswering(groups([task()]), {
      onRequest: (body) => (sent = body),
    }),
  });

  await service.recommend({ plan, candidates: shelf });

  const text = sent.input[0].content[0].text;
  assert.ok(text.indexOf("id=a") < text.indexOf("id=b"));
  assert.ok(text.includes("결혼식 준비"));
});

test("a request without a title is rejected", () => {
  assert.throws(
    () =>
      validatePlanRecommendationRequest({
        plan: { title: "  " },
        candidates: [],
      }),
    /plan.title/,
  );
});

test("duplicate candidate ids are rejected", () => {
  assert.throws(
    () =>
      validatePlanRecommendationRequest({
        plan: { title: "결혼식 준비" },
        candidates: [
          { id: "a", name: "하나" },
          { id: "a", name: "둘" },
        ],
      }),
    /중복된 id/,
  );
});

test("optional candidate fields normalize to nulls and defaults", () => {
  const input = validatePlanRecommendationRequest({
    plan: { title: " 결혼식 준비 " },
    candidates: [{ id: " a ", name: " 리쥬란 후기 " }],
  });

  assert.equal(input.plan.title, "결혼식 준비");
  assert.deepEqual(input.candidates[0], {
    id: "a",
    name: "리쥬란 후기",
    folder: null,
    area: null,
    tags: [],
    saveCount: 1,
    lastSavedAt: null,
  });
});

test("a candidate's tags are accepted and reach the prompt", async () => {
  // The client sends `tags`; the server used to whitelist `labels`, so every
  // real request was a 400 and the one field the prompt reads never arrived.
  const input = validatePlanRecommendationRequest({
    plan: { title: "성수 데이트" },
    candidates: [
      {
        id: "a",
        name: "어니언 성수",
        folder: null,
        area: "성수",
        tags: [" 맛집·카페 ", "카페·디저트", ""],
        saveCount: 2,
        lastSavedAt: "2026-08-01T00:00:00.000Z",
      },
    ],
  });
  assert.deepEqual(input.candidates[0].tags, ["맛집·카페", "카페·디저트"]);

  let sent = null;
  const service = createRecommendationService({
    transport: transportAnswering(groups([task()]), {
      onRequest: (body) => (sent = body),
    }),
  });
  await service.recommend(input);

  assert.match(sent.input[0].content[0].text, /태그=맛집·카페·카페·디저트/);
});

test("a candidate still carrying `labels` is rejected as an unknown field", () => {
  assert.throws(
    () =>
      validatePlanRecommendationRequest({
        plan: { title: "성수 데이트" },
        candidates: [{ id: "a", name: "어니언 성수", labels: ["뷰티"] }],
      }),
    /지원하지 않는 필드/,
  );
});
