# Trun On capture analysis server

Flutter 앱과 OpenAI 사이에서 이미지 분석을 수행하는 로컬 프록시입니다. API
키는 앱이나 저장소에 포함하지 않으며, 요청 이미지·Base64·OpenAI 응답 내용도
로그에 남기지 않습니다.

## 요구 사항

- Node.js 20 이상
- macOS 개발 환경에서는 키체인 서비스 `ori-beauty-openai`, 계정
  `ori-beauty`에 저장된 OpenAI API 키

키체인 식별자는 기존 로컬 개발 환경과의 호환을 위해 현재 이름을 유지합니다.

외부 npm 의존성은 없습니다.

## 실행

저장된 키를 화면에 출력하지 않고 키체인에서 환경변수로 옮겨 실행합니다.

```sh
cd server
npm run dev
```

기본 주소는 `http://127.0.0.1:8787`입니다. Android 에뮬레이터에서는 호스트
루프백을 `http://10.0.2.2:8787`로 접근합니다.

직접 실행할 때는 `OPENAI_API_KEY`가 환경변수에 있어야 합니다.

```sh
cd server
npm start
```

`HOST`와 `PORT` 환경변수로 수신 주소를 바꿀 수 있습니다. 실제 기기에서 같은
Wi-Fi를 통해 개발 서버에 연결할 때만 `HOST=0.0.0.0`을 사용하고, 운영 환경에는
인증·TLS·요청 제한이 있는 별도 배포 계층을 두세요.

## API

모든 엔드포인트는 `Content-Type: application/json`을 요구하고, 오류는 항상 같은
형태로 돌려줍니다. 업스트림 응답 본문은 그대로 전달하지 않고 고정된 코드로만
바꿔 보냅니다.

```json
{
  "error": {
    "code": "INVALID_IMAGE",
    "message": "이미지 형식과 데이터가 일치하지 않아요.",
    "retryable": false,
    "requestId": "..."
  }
}
```

### `GET /health`

키나 사용자 콘텐츠를 노출하지 않는 상태 확인 응답입니다. `schemaVersion`,
분석 `model`, 장소 보강에 쓰는 `enrichmentModel`을 돌려줍니다.

### `POST /v1/analyze`

캡처 한 장을 읽어 구조화된 결과와 태그를 돌려줍니다. 본문 제한은 17 MiB,
이미지는 디코딩 기준 12 MiB입니다.

```json
{
  "image": {
    "mimeType": "image/jpeg",
    "base64": "<data URL 접두사 없이 순수 Base64>"
  },
  "capture": {
    "id": "capture-001",
    "sourceApp": "instagram",
    "sourceUrl": "https://www.instagram.com/p/example/",
    "capturedAt": "2026-07-31T12:00:00+09:00",
    "locale": "ko-KR"
  },
  "vocabulary": [
    { "value": "맛집·카페", "count": 41 },
    { "value": "성수", "count": 12 },
    { "value": "스킨케어", "count": 9 }
  ]
}
```

- `capture.id`만 필수이며 나머지 캡처 필드는 생략하거나 `null`로 보낼 수
  있습니다. 지원 형식은 JPEG, PNG, WEBP이며 실제 파일 시그니처와 MIME이
  일치해야 합니다.
- `vocabulary`는 선택이며, 사용자가 이미 쓰고 있는 태그와 사용 횟수입니다
  (최대 300개, `value`는 태그 규칙을 통과하는 2~20자, `count`는 1 이상의 정수).
  모델은 이 목록에 맞는 말이 있으면 그 표기를 그대로 다시 쓰고, 없을 때만
  새 말을 만듭니다. 띄어쓰기·구분자만 다른 항목은 앞의 것 하나로 접힙니다.
  모델에는 태그 이름과 횟수만 보내고, 어떤 캡처가 그 아래 있는지는 보내지
  않습니다.

성공 응답은 Flutter에서 바로 파싱할 수 있는 단일 객체입니다.

```json
{
  "schemaVersion": "2.1",
  "model": "gpt-5.6-luna",
  "domain": "food",
  "contentKind": "place",
  "tags": [
    {
      "value": "맛집·카페",
      "facet": "field",
      "source": "ai",
      "confidence": 0.9,
      "evidenceIds": ["e2"],
      "quotes": ["아메리카노 5,000", "크루아상 4,500"],
      "citations": []
    },
    {
      "value": "성수",
      "facet": "area",
      "source": "ai",
      "confidence": 0.85,
      "evidenceIds": ["e3"],
      "quotes": ["성수동 2가"],
      "citations": []
    },
    {
      "value": "카페·디저트",
      "facet": "kind",
      "source": "ai",
      "confidence": 0.9,
      "evidenceIds": ["e2"],
      "quotes": ["아메리카노 5,000", "크루아상 4,500"],
      "citations": []
    },
    {
      "value": "웨이팅",
      "facet": "trait",
      "source": "ai",
      "confidence": 0.7,
      "evidenceIds": ["e4"],
      "quotes": ["웨이팅 30분"],
      "citations": []
    }
  ],
  "completeness": "complete",
  "title": {
    "value": "어니언 성수",
    "status": "observed",
    "confidence": 0.98,
    "evidenceIds": ["e1"]
  },
  "place": {
    "name": "어니언 성수",
    "address": null,
    "searchArea": "성수",
    "category": "cafe",
    "confidence": 0.9,
    "evidenceIds": ["e1", "e3"]
  },
  "summary": "성수동의 크루아상이 유명한 카페예요.",
  "evidence": [
    { "id": "e1", "text": "어니언 성수", "region": "overlay", "confidence": 0.99 },
    { "id": "e2", "text": "아메리카노 5,000", "region": "menu", "confidence": 0.95 },
    { "id": "e3", "text": "성수동 2가", "region": "caption", "confidence": 0.9 },
    { "id": "e4", "text": "웨이팅 30분", "region": "caption", "confidence": 0.8 }
  ],
  "ingredientGroups": [],
  "steps": [],
  "facts": [],
  "conflicts": [],
  "warnings": []
}
```

태그:

- `tags`는 평평한 목록입니다. 상하 관계가 없고, 캡처는 맞는 모든 말 아래에
  들어갑니다. 최대 12개이며, 관찰한 것이 없는 캡처는 빈 배열로 옵니다.
- 모델은 네 칸(`fields`, `areas`, `kinds`, `traits`)으로 나눠 태그를 만들고,
  서버가 그 순서대로 하나의 목록으로 펼칩니다. 칸은 거의 모든 캡처에 있는
  종류의 말(생활 영역·지역·무엇인지·특성)을 빠뜨리지 않게 하려는 장치일 뿐이며,
  저장 구조에는 남지 않습니다. 각 태그의 `facet`이 그 출처를
  `field | area | kind | trait`로 표시합니다.
- `field`는 닫힌 목록입니다: `뷰티 | 건강·운동 | 맛집·카페 | 레시피 | 쇼핑 |
  여행·장소 | 생활·팁`. 나머지 칸은 열려 있습니다.
- `value`는 2~20자의 재사용 가능한 한글 중심 이름입니다. 브랜드·상품·장소·
  메뉴처럼 한 캡처에만 맞는 이름은 쓰지 않습니다.
- `quotes`는 모델이 그 태그의 근거로 화면에서 읽은 문구이고, `source`는 항상
  `ai`입니다. `citations`는 웹 근거가 붙는 자리로, 분석 단계에서는 비어
  있습니다.
- 띄어쓰기·구분자·대소문자만 다른 태그는 같은 태그로 봅니다(`스킨케어` =
  `스킨 케어` = `스킨-케어`). 칸을 가로질러 같은 키의 태그는 앞의 것 하나로
  접히고, 요청의 `vocabulary`에 같은 키의 항목이 있으면 그 표기로 바꿔
  돌려줍니다.

분류 enum:

- `domain`: `beauty | food | unknown`
- `contentKind`: `beauty_product | recipe | sauce_recipe |
  commerce_product | product_review | menu_comparison | place | unknown`
- `completeness`: `complete | partial | conflicted | needs_review |
  unsupported`
- `place.category`: `restaurant | cafe | beauty | shopping | lodging |
  activity | other | null`

서버는 결과의 모든 `evidenceIds`(제목·장소·태그·재료·단계·사실·충돌)가 실제
`evidence[].id`를 참조하는지 확인합니다. 없는 id는 제거하고, 그런 경우
`completeness`를 `needs_review`로 낮추며 경고를 더합니다. 구조가 잘못된 모델
응답은 앱으로 전달하지 않습니다.

### `POST /v1/tag-merges`

사서 역할입니다. 사용자의 태그 목록에서 같은 것을 다르게 쓴 쌍을 제안합니다.
본문 제한은 32 KiB이며, `vocabulary`는 `/v1/analyze`와 같은 규칙에 더해 2개
이상이어야 합니다. 띄어쓰기·구분자만 다른 항목은 여기서는 접지 않습니다.
그 쌍을 찾는 것이 이 엔드포인트의 일이기 때문입니다.

```json
{
  "vocabulary": [
    { "value": "스킨케어", "count": 9 },
    { "value": "스킨 케어", "count": 1 },
    { "value": "피부관리", "count": 2 },
    { "value": "카페", "count": 30 },
    { "value": "카페·디저트", "count": 12 }
  ]
}
```

```json
{
  "merges": [
    { "from": "스킨 케어", "into": "스킨케어", "reason": "띄어쓰기·구분자만 다른 같은 말이에요." },
    { "from": "피부관리", "into": "스킨케어", "reason": "같은 뜻으로 쓰는 말이에요." }
  ]
}
```

- 키가 같은 쌍(첫 번째)은 모델 없이 서버가 짝지어 줍니다. 나머지는 모델에
  이름과 횟수만 보여 주고 묻습니다. `카페`와 `카페·디저트`처럼 넓이가 다른
  쌍이나 `을지로`와 `종로`처럼 관련만 있는 쌍은 제안하지 않습니다.
- 모든 쌍은 `into`가 사용 횟수가 더 많은 쪽(같으면 요청에서 앞선 쪽)이 되도록
  정렬되고, 목록에 없는 말·자기 자신·중복은 버려지며, 한 말은 한 번만
  제안됩니다. 최대 30쌍입니다.
- 빈 `merges`는 정상 응답입니다. 모델 호출이 실패해도 서버가 찾은 쌍은 그대로
  돌려줍니다. 서비스가 없으면 503 `TAG_MERGES_NOT_CONFIGURED`입니다.
- 제안일 뿐입니다. 어떤 태그도 여기서 바뀌지 않으며, 사용자의 태그가
  최종입니다.

### `POST /v1/tag-senses`

사전 편찬자 역할입니다. 태그마다, 그 태그 아래에 모인 것을 찾고 싶은 사람이
검색창에 칠 만한 낱말을 만들어 줍니다(닭발 → 매운, 야식, 술안주). 앱은 이
사전을 태그마다 한 번 미리 만들어 두고, 입력 중에는 서버를 부르지 않고
기기에서만 맞춰 봅니다. 본문 제한은 32 KiB이며, `tags`는 `/v1/analyze`의
`vocabulary`와 같은 규칙으로 1개 이상 300개 이하입니다. 표기만 다른 항목은
접지 않습니다. 응답을 표기 그대로 되돌려 받아야 하기 때문입니다.

```json
{
  "tags": [
    { "value": "닭발", "count": 3 },
    { "value": "야식", "count": 7 },
    { "value": "성수동", "count": 2 }
  ]
}
```

```json
{
  "senses": [
    { "tag": "닭발", "words": ["매운", "술안주", "매콤한"] },
    { "tag": "야식", "words": ["밤에", "출출"] },
    { "tag": "성수동", "words": [] }
  ]
}
```

- 방향은 한쪽뿐입니다. 낱말이 태그를 찾는 것이지, 태그가 다른 태그로
  넓어지는 것이 아닙니다. 그래서 다른 태그의 이름과 같은 낱말(키 기준)은
  서버가 버립니다. 자기 태그 이름과 겹치는 낱말도 버립니다. 이름 검색이
  이미 찾아 주기 때문입니다.
- 낱말은 태그당 최대 8개, 12자 이하이며, 상호명·브랜드명·사람 이름이 아닌
  다시 쓸 수 있는 검색 낱말만 남습니다.
- 요청한 모든 태그가 응답에 나타납니다. 쓸 만한 낱말이 없으면 빈 `words`로
  옵니다. 앱이 "물어봤지만 없음"을 캐시하고 다시 묻지 않기 위해서입니다.
- 서비스가 없으면 503 `TAG_SENSES_NOT_CONFIGURED`, 모델 응답을 읽을 수
  없으면 502 `INVALID_MODEL_RESPONSE`입니다.

### `POST /v1/plan-recommendation`

계획을 할 일로 쪼개고, 사용자가 저장한 것을 그 할 일 안에 담습니다.

```json
{
  "plan": { "title": "성수 데이트", "area": "성수", "scheduledAt": "2026-09-05" },
  "candidates": [
    {
      "id": "c1",
      "name": "어니언 성수",
      "folder": null,
      "area": "성수",
      "tags": ["맛집·카페", "카페·디저트", "성수"],
      "saveCount": 2,
      "lastSavedAt": "2026-08-01T00:00:00.000Z"
    }
  ]
}
```

`plan.title`과 각 후보의 `id`·`name`만 필수이고, 후보는 최대 300개입니다.
응답은 `{ status: "ready" | "no_match", groups, todoCount, attachedCount }`이며,
`groups[].items[].saved[].id`는 반드시 보낸 후보의 id입니다. 서비스가 없으면
503 `RECOMMENDATION_NOT_CONFIGURED`입니다.

### `POST /v1/enrich-place`

웹 검색으로 장소의 종류와 예약·웨이팅 정보를 보강합니다. 본문 제한은 8 KiB.

```json
{ "name": "어니언 성수", "searchArea": "성수" }
```

응답은 `{ matchedName, kind: [label], access: [label] }`이며, 각 label은
`{ value, quote, confidence, citations }`입니다. 빈 축은 정상 응답이고,
서비스가 없으면 503 `ENRICHMENT_NOT_CONFIGURED`입니다.

### `POST /v1/resolve-place`

카카오 로컬 검색으로 장소 좌표를 찾습니다. `KAKAO_REST_API_KEY`가 있을 때만
켜지며, 본문 제한은 8 KiB.

```json
{ "name": "어니언 성수", "address": null }
```

`name`과 `address` 중 하나는 필요합니다. 응답은 `{ place, candidateCount }`이고,
못 찾으면 `place`가 `null`인 200입니다. 서비스가 없으면 503
`PLACE_SEARCH_NOT_CONFIGURED`입니다.

## OpenAI 요청 정책

- Responses API의 `gpt-5.6-luna`
- 모든 모델 요청에 `store: false`
- 분석: 이미지 `detail: original`, `reasoning.effort: medium`
- 태그 정리·계획 추천: 텍스트만, `reasoning.effort: low`
- strict JSON Schema Structured Outputs
- 이미지 속 문구를 명령이 아닌 신뢰하지 않는 원문으로 취급
- 캡처 ID·전체 URL·쿼리·수집 시각은 모델에 보내지 않고, 정규화된 출처
  앱·호스트·locale만 출처 문맥으로 전달
- 사용자 태그는 이름과 횟수만 전달하고 로그에는 개수만 남김

## 테스트

```sh
cd server
npm test
```

테스트는 의존성 주입된 가짜 transport/fetch만 사용하므로 OpenAI API를 호출하거나
비용을 발생시키지 않습니다.
