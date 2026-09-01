/// The plan tab's recommendation.
///
/// A plan is broken into the things it requires, and whatever the reader saved
/// is put *inside* those requirements rather than becoming requirements itself.
///
/// That nesting is the whole design. Asked for a flat list, the model shapes the
/// plan around whatever happens to be in the library: three cosmetics came back
/// as three to-dos — "리쥬란 후기 보기" — when reading a review is not a task, it
/// is material for deciding what to buy. What a plan needs does not depend on
/// what the reader owns, so the shape has to say so.
///
/// One call rather than two. The order is enforced by the schema instead: a
/// saved thing has nowhere to go until a task exists to hold it.
///
/// The model is not asked to do arithmetic. It says "seven days before" and the
/// app turns that into a date, because a model asked for 2026-08-13 will
/// sometimes hand back a Tuesday that is a Wednesday.
const RECOMMENDATION_INSTRUCTIONS = `너는 사용자의 계획을 할 일로 쪼개고, 사용자가 저장해둔 것을 그 할 일 안에 담는다.

먼저 할 일을 정한다:
- 이 계획에 필요한 일이 무엇인지만 생각해서 할 일을 만든다.
- 저장물 목록을 보고 할 일을 만들지 않는다. 저장한 게 없어도 필요한 일은 필요하고,
  저장한 게 많아도 할 일이 그만큼 늘어나지는 않는다.
- 할 일은 사용자가 실제로 하는 행동이어야 한다. "무엇을 살지 정하기"는 할 일이지만
  "○○ 후기 보기"는 그 결정을 위한 재료일 뿐이라 할 일이 아니다.
- 비슷한 성격끼리 묶고, 묶음마다 왜 묶였는지 짧게 적는다.

그 다음 저장물을 담는다:
- 각 할 일에 그 일에 쓰일 저장물을 saved에 담는다.
- 저장물마다 why를 한 문장 적는다. 왜 이 할 일에 쓰이는지.
- 저장물 하나는 가장 잘 맞는 할 일 **한 곳에만** 담는다. 여러 할 일에 되풀이하지 않는다.
  같은 제품이 "무엇을 살지 정하기"와 "사기" 양쪽에 걸리면, 그것을 실제로 고르는
  할 일에만 담는다.
- 맞는 할 일이 없는 저장물은 담지 않는다. 억지로 끼워넣지 않는다.
- 담길 게 없는 할 일은 saved를 빈 배열로 둔다. 그래도 할 일은 남는다.
- id는 반드시 저장물 목록에 있는 것만 쓴다. 지어내지 않는다.

각 할 일에 붙일 것:
- action: 사용자가 할 행동을 두 글자 안팎으로. 예약, 구매, 보기, 준비, 확인 같은 말.
- daysBefore: 계획 날짜보다 며칠 전에 해야 하는지. 당일이면 0. 예약이나 배송처럼
  미리 해야 하는 일은 그만큼 앞선 숫자를 넣는다.
- note: 이 일이 왜 필요한지 한 문장. 없으면 빈 문자열.
- selected: 기본으로 체크해 둘지. 확실히 필요한 것만 true.`;

const SAVED_SCHEMA = {
  type: "object",
  properties: {
    id: { type: "string" },
    why: { type: "string" },
  },
  required: ["id", "why"],
  additionalProperties: false,
};

const TASK_SCHEMA = {
  type: "object",
  properties: {
    title: { type: "string" },
    action: { type: "string" },
    daysBefore: { type: "integer" },
    note: { type: "string" },
    selected: { type: "boolean" },
    // Empty is the common case and a correct one. A task with nothing saved
    // against it is still a task.
    saved: { type: "array", maxItems: 5, items: SAVED_SCHEMA },
  },
  required: ["title", "action", "daysBefore", "note", "selected", "saved"],
  additionalProperties: false,
};

const RECOMMENDATION_SCHEMA = {
  type: "object",
  properties: {
    groups: {
      type: "array",
      maxItems: 4,
      items: {
        type: "object",
        properties: {
          title: { type: "string" },
          note: { type: "string" },
          items: { type: "array", maxItems: 8, items: TASK_SCHEMA },
        },
        required: ["title", "note", "items"],
        additionalProperties: false,
      },
    },
  },
  required: ["groups"],
  additionalProperties: false,
};

export const RECOMMENDATION_TEXT_FORMAT = {
  type: "json_schema",
  name: "trun_on_plan_recommendation",
  strict: true,
  schema: RECOMMENDATION_SCHEMA,
};

/// One line per candidate rather than nested JSON.
///
/// The list is the bulk of the prompt and grows with everything the reader
/// keeps, so its shape is where the tokens are. Empty fields are dropped rather
/// than sent as nulls for the model to read past.
function candidateLine(candidate) {
  const parts = [`id=${candidate.id}`, `이름=${candidate.name}`];
  if (candidate.area) parts.push(`지역=${candidate.area}`);
  if (candidate.tags?.length) parts.push(`태그=${candidate.tags.join("·")}`);
  if (candidate.saveCount > 1) parts.push(`저장=${candidate.saveCount}번`);
  if (candidate.lastSavedAt) parts.push(`마지막저장=${candidate.lastSavedAt}`);
  return `- ${parts.join(" | ")}`;
}

function planLines(plan) {
  const lines = [`계획: ${plan.title}`];
  if (plan.area) lines.push(`장소: ${plan.area}`);
  if (plan.scheduledAt) lines.push(`계획 날짜: ${plan.scheduledAt}`);
  return lines.join("\n");
}

export function buildRecommendationRequest({ plan, candidates, model }) {
  return {
    model,
    store: false,
    reasoning: { effort: "low" },
    max_output_tokens: 6_000,
    instructions: RECOMMENDATION_INSTRUCTIONS,
    input: [
      {
        role: "user",
        content: [
          {
            type: "input_text",
            text: `${planLines(plan)}\n\n저장한 것:\n${
              candidates.length === 0
                ? "(아직 저장한 것이 없다. 할 일만 만들고 saved는 모두 빈 배열로 둔다.)"
                : candidates.map(candidateLine).join("\n")
            }`,
          },
        ],
      },
    ],
    text: { format: RECOMMENDATION_TEXT_FORMAT },
  };
}
