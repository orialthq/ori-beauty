import { MODEL, SCHEMA_VERSION } from "../src/constants.js";

export const JPEG_BASE64 = Buffer.from([0xff, 0xd8, 0xff, 0xd9]).toString(
  "base64",
);

export function makeValidRequest(overrides = {}) {
  return {
    image: {
      mimeType: "image/jpeg",
      base64: JPEG_BASE64,
      ...overrides.image,
    },
    capture: {
      id: "capture-001",
      sourceApp: "instagram",
      sourceUrl: "https://www.instagram.com/p/example/",
      capturedAt: "2026-07-31T12:00:00+09:00",
      locale: "ko-KR",
      ...overrides.capture,
    },
  };
}

export function makeValidAnalysis(overrides = {}) {
  return {
    schemaVersion: SCHEMA_VERSION,
    model: MODEL,
    domain: "food",
    contentKind: "recipe",
    tags: [
      {
        observations: ["된장찌개"],
        value: "국·찌개",
        confidence: 0.95,
        evidenceIds: ["e1"],
      },
    ],
    completeness: "partial",
    title: {
      value: "된장찌개",
      status: "observed",
      confidence: 0.98,
      evidenceIds: ["e1"],
    },
    place: {
      name: null,
      address: null,
      searchArea: null,
      category: null,
      confidence: 0,
      evidenceIds: [],
    },
    summary: "화면에 보이는 된장찌개 레시피예요.",
    evidence: [
      {
        id: "e1",
        text: "된장찌개",
        region: "overlay",
        confidence: 0.99,
      },
      {
        id: "e2",
        text: "두부 1/2모",
        region: "caption",
        confidence: 0.95,
      },
    ],
    ingredientGroups: [
      {
        name: "기본 재료",
        ingredients: [
          {
            name: "두부",
            amount: "1/2",
            unit: "모",
            preparation: null,
            optional: false,
            originalText: "두부 1/2모",
            confidence: 0.95,
            evidenceIds: ["e2"],
          },
        ],
      },
    ],
    steps: [],
    facts: [],
    conflicts: [],
    warnings: ["조리 순서가 화면에 보이지 않아요."],
    ...overrides,
  };
}
