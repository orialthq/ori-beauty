import assert from "node:assert/strict";
import { once } from "node:events";
import test from "node:test";
import { AppError, OpenAITransportError } from "../src/errors.js";
import { createHttpServer } from "../src/http_app.js";
import { validateTagSensesRequest } from "../src/request_validation.js";
import { buildTagSenseRequest } from "../src/tag_sense_prompt.js";
import { createTagSenseService } from "../src/tag_sense_service.js";

function transportAnswering(payload, { onRequest } = {}) {
  return {
    async createResponse(requestBody) {
      onRequest?.(requestBody);
      return { output_text: JSON.stringify(payload) };
    },
  };
}

const entry = (value, count) => ({ value, count });
const sense = (tag, words) => ({ tag, words });

test("the request takes 1 to 300 well-formed entries with exact keys", () => {
  const rejects = (body, pattern) =>
    assert.throws(
      () => validateTagSensesRequest(body),
      (error) =>
        error instanceof AppError &&
        error.code === "INVALID_REQUEST" &&
        error.httpStatus === 400 &&
        pattern.test(error.message),
    );

  rejects({}, /tags가 필요해요/);
  rejects({ tags: [] }, /1개 이상/);
  rejects({ tags: "닭발" }, /형식/);
  rejects({ tags: [entry("닭발", 3)], extra: true }, /지원하지 않는/);
  rejects({ tags: [entry("뷰", 1)] }, /value/);
  rejects({ tags: [entry("닭발", 0)] }, /count/);
  rejects({ tags: [entry("닭발", 1.5)] }, /count/);
  rejects({ tags: [{ value: "닭발", count: 1, ids: [] }] }, /지원하지 않는/);
  rejects(
    { tags: Array.from({ length: 301 }, (_, i) => entry(`태그${i}`, 1)) },
    /태그 수를 넘었어요/,
  );
});

test("exact duplicates collapse but spelling variants stay apart", () => {
  const input = validateTagSensesRequest({
    tags: [
      entry("스킨케어", 9),
      entry("스킨케어", 2),
      entry("스킨 케어", 1),
    ],
  });

  // The caller matches the answer back by exact value, so each spelling the
  // library actually holds keeps its own entry.
  assert.deepEqual(input.tags, [entry("스킨케어", 9), entry("스킨 케어", 1)]);
});

test("the batch goes to the model once, text only, effort low", async () => {
  let sent = null;
  const service = createTagSenseService({
    transport: transportAnswering(
      { senses: [] },
      { onRequest: (body) => (sent = body) },
    ),
  });

  await service.describe({
    tags: [entry("닭발", 3), entry("혼밥", 5), entry("스킨케어", 9)],
  });

  assert.equal(sent.store, false);
  assert.deepEqual(sent.reasoning, { effort: "low" });
  assert.equal(sent.tools, undefined);
  assert.equal(sent.text.format.type, "json_schema");
  assert.equal(sent.text.format.strict, true);
  const text = sent.input[0].content[0].text;
  assert.match(text, /- 닭발 \(3\)/);
  assert.match(text, /- 혼밥 \(5\)/);
  assert.match(text, /- 스킨케어 \(9\)/);
});

test("the prompt carries only names and counts", () => {
  const body = buildTagSenseRequest({
    tags: [entry("닭발", 3), entry("혼밥", 5)],
    model: "m",
  });

  assert.equal(
    body.input[0].content[0].text,
    "태그 (사용 횟수):\n- 닭발 (3)\n- 혼밥 (5)",
  );
});

test("the instructions demand words that tell tags apart", () => {
  // The first measured dictionary put 골목 on 18 of 65 tags — true of most
  // Seoul neighbourhoods, so it lit a quarter of the sky and filtered
  // nothing. The rule that a broadly-true word belongs only to the tags most
  // known for it is part of the contract, and losing it in a prompt edit
  // should fail loudly.
  const body = buildTagSenseRequest({ tags: [entry("닭발", 3)], model: "m" });

  assert.match(body.instructions, /두루 맞는 낱말은 아무 태그도 가려내지 못한다/);
  assert.match(body.instructions, /가장 이름난 한두 태그에만/);
});

test("a tag the model invented is dropped; duplicates keep the first entry", async () => {
  const service = createTagSenseService({
    transport: transportAnswering({
      senses: [
        sense("족발", ["야들야들"]),
        sense("닭발", ["매운"]),
        sense("닭발", ["두번째"]),
      ],
    }),
  });

  const result = await service.describe({ tags: [entry("닭발", 3)] });

  assert.deepEqual(result.senses, [sense("닭발", ["매운"])]);
});

test("a word that names another request tag is dropped, compared by key", async () => {
  const service = createTagSenseService({
    transport: transportAnswering({
      senses: [
        // 야식 is a tag of its own, and 야 식 is the same word by key: keeping
        // either would make 야식 surface 닭발 — tag expanding to tag.
        sense("닭발", ["매운", "야식", "야 식", "술안주"]),
        sense("야식", ["밤에", "출출"]),
      ],
    }),
  });

  const result = await service.describe({
    tags: [entry("닭발", 3), entry("야식", 7)],
  });

  assert.deepEqual(result.senses, [
    sense("닭발", ["매운", "술안주"]),
    sense("야식", ["밤에", "출출"]),
  ]);
});

test("a word redundant with its own tag's name is dropped", async () => {
  const service = createTagSenseService({
    transport: transportAnswering({
      senses: [
        // 닭 발 equals 닭발 by key; 닭 is a one-character prefix and stays.
        sense("닭발", ["닭 발", "닭", "매운"]),
        // 매운 is a two-character prefix of 매운맛 — name matching covers it.
        sense("매운맛", ["매운", "매운맛집", "얼큰한"]),
      ],
    }),
  });

  const result = await service.describe({
    tags: [entry("닭발", 3), entry("매운맛", 4)],
  });

  assert.deepEqual(result.senses, [
    sense("닭발", ["닭", "매운"]),
    sense("매운맛", ["얼큰한"]),
  ]);
});

test("words are trimmed, deduped by key, length-capped and at most eight", async () => {
  const service = createTagSenseService({
    transport: transportAnswering({
      senses: [
        sense("혼밥", [
          "  혼자  ",
          "   ",
          "",
          "혼자",
          "혼 자",
          "아주아주아주아주아주아주아", // 13 characters
          42,
          "조용히",
          "간단히",
          "빨리",
          "부담없이",
          "한끼",
          "점심",
          "저녁",
          "든든",
          "넘치는아홉번째",
        ]),
      ],
    }),
  });

  const result = await service.describe({ tags: [entry("혼밥", 5)] });

  assert.deepEqual(result.senses, [
    sense("혼밥", [
      "혼자",
      "조용히",
      "간단히",
      "빨리",
      "부담없이",
      "한끼",
      "점심",
      "저녁",
    ]),
  ]);
});

test("every requested tag answers, words or not", async () => {
  const service = createTagSenseService({
    transport: transportAnswering({
      senses: [sense("닭발", ["매운"]), sense("혼밥", [])],
    }),
  });

  const result = await service.describe({
    tags: [entry("닭발", 3), entry("혼밥", 5), entry("성수동", 2)],
  });

  // 혼밥 answered empty and 성수동 was skipped entirely; both come back as
  // "asked, nothing useful" so the caller caches the emptiness.
  assert.deepEqual(result.senses, [
    sense("닭발", ["매운"]),
    sense("혼밥", []),
    sense("성수동", []),
  ]);
});

test("an unreadable model answer is a clean retryable failure, not emptiness", async () => {
  const service = createTagSenseService({
    transport: {
      async createResponse() {
        return { output_text: '물론이죠! {"senses": []}' };
      },
    },
  });

  // An empty answer would be cached per tag and never asked again, so a
  // broken one must fail loudly instead.
  await assert.rejects(
    service.describe({ tags: [entry("닭발", 3)] }),
    (error) =>
      error instanceof OpenAITransportError &&
      error.kind === "invalid_response" &&
      error.retryable === true,
  );
});

test("a transport failure passes through untouched", async () => {
  const service = createTagSenseService({
    transport: {
      async createResponse() {
        throw new OpenAITransportError("rate_limited", { retryable: true });
      },
    },
  });

  await assert.rejects(
    service.describe({ tags: [entry("닭발", 3)] }),
    (error) =>
      error instanceof OpenAITransportError && error.kind === "rate_limited",
  );
});

// --- HTTP wiring ---

async function startServer(t, options = {}) {
  const server = createHttpServer({
    analysisService: {
      async analyze() {
        throw new Error("the analysis service must not be asked");
      },
    },
    ...options,
  });
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  t.after(() => new Promise((resolve) => server.close(resolve)));
  const address = server.address();
  return `http://127.0.0.1:${address.port}`;
}

const post = (baseUrl, body) =>
  fetch(`${baseUrl}/v1/tag-senses`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });

test("tag senses answer 503 until a service is wired in", async (t) => {
  const baseUrl = await startServer(t);
  const response = await post(baseUrl, { tags: [entry("닭발", 3)] });

  assert.equal(response.status, 503);
  assert.equal((await response.json()).error.code, "TAG_SENSES_NOT_CONFIGURED");
});

test("only POST reaches the tag senses endpoint", async (t) => {
  const baseUrl = await startServer(t, {
    tagSenseService: {
      async describe() {
        throw new Error("must not be reached");
      },
    },
  });
  const response = await fetch(`${baseUrl}/v1/tag-senses`);

  assert.equal(response.status, 405);
  assert.equal((await response.json()).error.code, "METHOD_NOT_ALLOWED");
});

test("tag senses validate the tags and pass the result through", async (t) => {
  let received;
  const baseUrl = await startServer(t, {
    tagSenseService: {
      async describe(input) {
        received = input;
        return { senses: [sense("닭발", ["매운", "야식"]), sense("혼밥", [])] };
      },
    },
  });

  const response = await post(baseUrl, {
    tags: [entry("닭발", 3), entry("닭발", 1), entry("혼밥", 5)],
  });

  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), {
    senses: [sense("닭발", ["매운", "야식"]), sense("혼밥", [])],
  });
  assert.deepEqual(received.tags, [entry("닭발", 3), entry("혼밥", 5)]);
});

test("the tag senses body is capped at 32 KiB", async (t) => {
  const baseUrl = await startServer(t, {
    tagSenseService: {
      async describe() {
        throw new Error("must not be reached");
      },
    },
  });

  const response = await post(baseUrl, {
    tags: Array.from({ length: 2_000 }, (_, i) => entry(`태그${i}`, 1)),
  });

  assert.equal(response.status, 413);
  assert.equal((await response.json()).error.code, "PAYLOAD_TOO_LARGE");
});

test("a broken model answer maps to a fixed error code", async (t) => {
  const baseUrl = await startServer(t, {
    tagSenseService: createTagSenseService({
      transport: {
        async createResponse() {
          return { output_text: "낱말은 다음과 같아요: 매운, 야식" };
        },
      },
    }),
  });

  const response = await post(baseUrl, { tags: [entry("닭발", 3)] });

  assert.equal(response.status, 502);
  const body = await response.json();
  assert.equal(body.error.code, "INVALID_MODEL_RESPONSE");
  assert.equal(body.error.retryable, true);
});

test("the tag senses debug log carries counts, never words", async (t) => {
  process.env.TRUN_ON_DEBUG_LOG = "1";
  t.after(() => delete process.env.TRUN_ON_DEBUG_LOG);
  const log = t.mock.method(console, "log", () => {});
  const baseUrl = await startServer(t, {
    tagSenseService: {
      async describe() {
        return {
          senses: [sense("닭발", ["매운", "야식"]), sense("혼밥", [])],
        };
      },
    },
  });

  const response = await post(baseUrl, {
    tags: [entry("닭발", 3), entry("혼밥", 5)],
  });

  assert.equal(response.status, 200);
  const line = log.mock.calls.find((call) =>
    call.arguments[0].startsWith("[tag-senses]"),
  );
  assert.match(line.arguments[0], /태그=2 답변=1 낱말=2/);
  assert.doesNotMatch(line.arguments[0], /매운|닭발/);
});
