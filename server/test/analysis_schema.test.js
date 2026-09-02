import assert from "node:assert/strict";
import test from "node:test";
import { ANALYSIS_SCHEMA, FIELD_VALUES } from "../src/analysis_schema.js";
import { buildOpenAIRequest } from "../src/prompt.js";

test("every Structured Outputs object is strict and requires every field", () => {
  const visit = (schema, path) => {
    if (!schema || typeof schema !== "object") {
      return;
    }

    const types = Array.isArray(schema.type) ? schema.type : [schema.type];
    if (types.includes("object")) {
      assert.equal(
        schema.additionalProperties,
        false,
        `${path} must reject additional properties`,
      );
      const propertyNames = Object.keys(schema.properties ?? {}).sort();
      assert.deepEqual(
        [...(schema.required ?? [])].sort(),
        propertyNames,
        `${path} must require every property`,
      );
      for (const [name, property] of Object.entries(schema.properties ?? {})) {
        visit(property, `${path}.properties.${name}`);
      }
    }

    if (schema.items) {
      visit(schema.items, `${path}.items`);
    }
    for (const [index, option] of (schema.anyOf ?? []).entries()) {
      visit(option, `${path}.anyOf[${index}]`);
    }
  };

  visit(ANALYSIS_SCHEMA, "root");
});

test("tag contract is bounded and required in schema 2.1", () => {
  const filing = ANALYSIS_SCHEMA.properties.filing;
  const kind = filing.properties.kinds.items.properties.value;
  assert.deepEqual(ANALYSIS_SCHEMA.properties.schemaVersion.enum, ["2.1"]);
  assert.equal(kind.minLength, 2);
  assert.equal(kind.maxLength, 20);
  assert.equal(new RegExp(kind.pattern, "u").test("카페·디저트"), true);
  assert.equal(new RegExp(kind.pattern, "u").test("스킨케어✨"), false);
  assert.ok(ANALYSIS_SCHEMA.required.includes("filing"));
  // Four slots, each bounded; the model answers per slot and the server
  // flattens. The client never sees `filing`.
  assert.deepEqual(Object.keys(filing.properties), [
    "fields",
    "areas",
    "kinds",
    "traits",
  ]);
  assert.deepEqual(
    Object.values(filing.properties).map((slot) => slot.maxItems),
    [3, 3, 4, 4],
  );
  // Only the fields slot is closed.
  assert.deepEqual(filing.properties.fields.items.properties.value, {
    type: "string",
    enum: ["뷰티", "건강·운동", "맛집·카페", "레시피", "장소", "생활·팁"],
  });
  assert.equal(filing.properties.areas.items.properties.value.enum, undefined);
  // Observations come first so the model reads before it names.
  for (const slot of Object.values(filing.properties)) {
    assert.deepEqual(Object.keys(slot.items.properties), [
      "observations",
      "value",
      "confidence",
      "evidenceIds",
    ]);
  }
  // The folder, its single child, and the flat list the model used to write
  // directly are all gone from the model-facing shape.
  assert.equal(ANALYSIS_SCHEMA.properties.primaryCategory, undefined);
  assert.equal(ANALYSIS_SCHEMA.properties.subcategory, undefined);
  assert.equal(ANALYSIS_SCHEMA.properties.axes, undefined);
  assert.equal(ANALYSIS_SCHEMA.properties.tags, undefined);
});

test("the instructions keep 맛집·카페 and 장소 from doubling up", () => {
  const request = buildOpenAIRequest({
    imageBase64: "AAAA",
    mimeType: "image/png",
    capture: { id: "c1" },
    textFormat: { type: "json_schema", name: "x", strict: true, schema: {} },
    model: "test-model",
  });
  const { instructions } = request;

  // The field list is closed and no longer carries 여행, which was the half
  // that invited itself onto every restaurant.
  for (const field of FIELD_VALUES) {
    assert.ok(
      instructions.includes(field),
      `instructions must name the field ${field}`,
    );
  }
  assert.equal(instructions.includes("여행·장소"), false);

  // 쇼핑 went the same way: it said what you would do about a thing rather
  // than what area it belongs to, so it stacked on 뷰티 rather than sorting
  // anything. A purchase with no matching area is meant to end up fieldless.
  assert.equal(FIELD_VALUES.includes("쇼핑"), false);
  assert.match(instructions, /no field for buying something/);

  // Taking 쇼핑 out left 가전 and 패션 captures with no field, and the model
  // reached for 생활·팁 instead on 4 of 6 runs. Saying what 생활·팁 is put
  // those back to no field at all, 6/6, which is the intended answer.
  assert.match(instructions, /생활·팁 is know-how for running a home or a day/);
  assert.match(instructions, /not something a person buys/);

  // And the boundary is stated, because closing the list of words does not by
  // itself say which word a place gets: measured before this rule, 여행·장소
  // landed on 12 of 16 runs over four restaurant captures — a coin flip.
  assert.match(instructions, /never both/);
  assert.match(instructions, /맛집·카페 and 장소 are told apart/);
});
