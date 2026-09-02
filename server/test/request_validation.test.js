import assert from "node:assert/strict";
import test from "node:test";
import { AppError } from "../src/errors.js";
import { validateAnalyzeRequest } from "../src/request_validation.js";
import { makeValidRequest } from "./fixtures.js";

test("normalizes optional capture metadata to null", () => {
  const result = validateAnalyzeRequest({
    ...makeValidRequest(),
    capture: { id: " capture-1 " },
  });

  assert.deepEqual(result.capture, {
    id: "capture-1",
    sourceApp: null,
    sourceUrl: null,
    capturedAt: null,
    locale: null,
  });
});

test("rejects unexpected request keys", () => {
  assert.throws(
    () =>
      validateAnalyzeRequest({
        ...makeValidRequest(),
        apiKey: "must-never-be-accepted",
      }),
    (error) =>
      error instanceof AppError && error.code === "INVALID_REQUEST",
  );
});

test("rejects a data URL instead of pure base64", () => {
  assert.throws(
    () =>
      validateAnalyzeRequest(
        makeValidRequest({
          image: {
            base64: "data:image/jpeg;base64,/9j/2Q==",
          },
        }),
      ),
    (error) => error instanceof AppError && error.code === "INVALID_IMAGE",
  );
});

test("a request without a vocabulary carries an empty one", () => {
  const result = validateAnalyzeRequest(makeValidRequest());

  assert.deepEqual(result.vocabulary, []);
});

test("normalizes the vocabulary and collapses spelling variants", () => {
  const result = validateAnalyzeRequest(
    makeValidRequest({
      vocabulary: [
        { value: "  맛집·카페 ", count: 41 },
        { value: "스킨케어", count: 9 },
        // Same key as the entry above: the first spelling is the library's.
        { value: "스킨 케어", count: 2 },
        { value: "스킨케어", count: 1 },
      ],
    }),
  );

  assert.deepEqual(result.vocabulary, [
    { value: "맛집·카페", count: 41 },
    { value: "스킨케어", count: 9 },
  ]);
});

test("rejects a malformed vocabulary", () => {
  const rejects = (vocabulary) =>
    assert.throws(
      () => validateAnalyzeRequest(makeValidRequest({ vocabulary })),
      (error) =>
        error instanceof AppError &&
        error.code === "INVALID_REQUEST" &&
        error.httpStatus === 400,
      JSON.stringify(vocabulary),
    );

  rejects("맛집·카페");
  rejects([{ value: "맛집·카페" }]);
  rejects([{ value: "맛집·카페", count: 0 }]);
  rejects([{ value: "맛집·카페", count: 1.5 }]);
  rejects([{ value: "맛집·카페", count: "1" }]);
  rejects([{ value: "뷰", count: 1 }]);
  rejects([{ value: "가".repeat(21), count: 1 }]);
  rejects([{ value: "맛집 추천!", count: 1 }]);
  rejects([{ value: "맛집·카페", count: 1, captureIds: ["c1"] }]);
  rejects(["맛집·카페"]);
  rejects(
    Array.from({ length: 301 }, (_, index) => ({
      value: `태그${index}`,
      count: 1,
    })),
  );
});

test("accepts a vocabulary at the cap", () => {
  const result = validateAnalyzeRequest(
    makeValidRequest({
      vocabulary: Array.from({ length: 300 }, (_, index) => ({
        value: `태그${index}`,
        count: 1,
      })),
    }),
  );

  assert.equal(result.vocabulary.length, 300);
});
