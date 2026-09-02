# Private local holdout eval

이 도구는 17개의 비공개 이미지 샘플을 로컬 분석 백엔드에 보내고,
`domain`, `contentKind`, `completeness`와 안전한 오류 코드 규칙, 그리고
운영자가 판정을 적어 둔 샘플에 한해 태그 품질을 평가합니다. 저장소에는
실제 JPG, 계정명, 캡션, URL, 레시피 본문을 넣지 않습니다.

태그 평가가 재는 원칙은 하나입니다. **이미 쓰는 말을 다시 쓰고, 맞는
말마다 밑에 두고, 근거 없는 태그는 붙이지 않는다.** 아래의 재현성,
어휘 건강, 어휘 전송 옵션은 모두 그 원칙의 한 면씩을 숫자로 만든
것입니다.

## 개인정보 경계

- 추적되는 manifest에는 `holdout-01` 같은 불투명 ID와 시나리오 enum만
  둡니다.
- 원본 파일명도 계정명이나 콘텐츠 제목 대신 `holdout-NN.jpg`를
  사용합니다.
- 실제 이미지, 선택적 공유 텍스트, 작업 manifest는
  `tool/evals/local/` 아래에만 둡니다. 이 폴더는 이 디렉터리의
  `.gitignore`에서 제외됩니다.
- 이미지에 계정명이나 저작권 있는 레시피가 보여도 이를 manifest나
  테스트 fixture로 옮겨 적지 않습니다.
- 실행기는 `localhost`, `127.0.0.1`, `::1` 주소만 허용합니다. 쿼리
  문자열이나 URL credential도 거부하며 HTTP redirect를 따라가지
  않습니다.
- API key, 이미지 bytes, 공유 텍스트, 백엔드 원문 응답은 stdout,
  stderr, aggregate JSON에 기록하지 않습니다.
- aggregate에는 불투명 sample ID, enum 판정, 제한된 오류 code만
  남습니다. 백엔드의 오류 message는 의도적으로 버립니다.
- 태그 값은 `expectedTags`를 적어 둔 샘플의 `tags_*` 판정에만
  key 형태로 남습니다. 그 외에는 개수와 비율만 기록하며, 백엔드가 돌려준
  태그 값이나 전송한 어휘 자체는 어디에도 쓰지 않습니다. 20자를 넘거나
  URL·줄바꿈이 섞인 응답 태그는 평가 전에 버립니다.

이 보호는 git 유출을 막기 위한 베이스라인입니다. 로컬 백엔드가 별도
로그를 남기는 경우에는 그 백엔드의 로그·보존 정책도 따로 확인해야
합니다.

## 로컬 폴더 준비

프로젝트 루트에서 다음 구조를 만듭니다.

```text
tool/evals/local/
├── manifest.json
└── samples/
    ├── holdout-01.jpg
    ├── ...
    └── holdout-17.jpg
```

```sh
mkdir -p tool/evals/local/samples
cp tool/evals/manifest.template.json tool/evals/local/manifest.json
```

비공개 JPG 17개를 로컬에서 `holdout-01.jpg`부터
`holdout-17.jpg`까지 매핑합니다. 번호와 시나리오의 관계는
`manifest.template.json` 순서를 따릅니다. 실제 계정명이나 제목을
파일명에 넣지 않습니다.

텍스트 내용을 manifest 자체에 넣는 필드는 지원하지 않습니다. 알 수
없는 필드가 있으면 manifest validation이 실패합니다.

### 기대 태그 (선택)

`expected`에 다음 두 필드를 추가로 적을 수 있습니다. 둘 다 없어도 되고,
`schemaVersion`은 그대로 `1`입니다. 템플릿에는 일부러 비워 두었으니
실제 화면을 보고 판정한 뒤 로컬 manifest에만 적습니다.

```json
"expected": {
  "domain": "food",
  "kind": "recipe",
  "completeness": "partial",
  "requiredErrorCodes": [],
  "allowedErrorCodes": [],
  "forbiddenErrorCodes": ["internal_error"],
  "expectedTags": ["국·찌개", "레시피"],
  "forbiddenTags": ["성수"]
}
```

- `expectedTags`: 이 샘플이 달고 있어야 하는 태그 전체. `국·찌개`,
  `레시피`, `성수`처럼 라이브러리에서 쓰는 일반 낱말이라 콘텐츠가
  아닙니다. 빈 배열은 "태그가 없어야 한다"는 뜻이고, 필드 자체가 없으면
  이 샘플의 태그 판정은 아예 하지 않습니다.
- `forbiddenTags`: 붙으면 안 되는 태그. `expectedTags`가 있는 샘플에서만
  쓸 수 있습니다.

값은 태그 모양이어야 합니다: 앞뒤 공백 없이 2~20자, `#`·줄바꿈·`://`
없음. 비교는 `lib/domain/tag_key.dart`의 `tagKey`로 하므로 `국·찌개`와
`국 찌개`, `국찌개`는 같은 태그입니다. 한 태그를 두 표기로 적거나,
기대와 금지에 같은 태그를 적으면 validation이 실패합니다.

## 백엔드 계약

기본 endpoint는 `http://127.0.0.1:8787/v1/analyze`이며 앱과 같은 다음 JSON을
POST 합니다.

```json
{
  "image": {
    "mimeType": "image/jpeg",
    "base64": "<local bytes>"
  },
  "capture": {
    "id": "holdout-01",
    "sourceApp": "private-eval",
    "sourceUrl": null,
    "capturedAt": null,
    "locale": "ko-KR"
  },
  "vocabulary": [{"value": "레시피", "count": 12}]
}
```

`vocabulary`는 `--vocabulary`나 `--grow-vocabulary`를 줬을 때만, 그리고
항목이 하나 이상일 때만 실립니다. 빈 어휘는 필드를 생략한 요청과
같습니다.

응답은 분석 객체를 최상위에 제공해야 합니다. `tags`는 선택이며, 각
항목에서 `value`와 `confidence`만 읽습니다 (`facet`, `evidenceIds`,
`quotes` 등은 무시).

```json
{
  "domain": "food",
  "contentKind": "recipe",
  "completeness": "complete",
  "tags": [
    {"value": "레시피", "source": "ai", "confidence": 0.92}
  ]
}
```

지원 enum:

- domain: `food`
- contentKind: `recipe`, `sauce_recipe`, `commerce_product`,
  `product_review`, `menu_comparison`
- completeness: `complete`, `partial`, `conflicted`, `needs_review`

사람이 근거 화면을 다시 확인해도 두 판정이 모두 안전한 경계 사례만
`allowedCompleteness`로 보조 판정을 허용합니다. 기본 `completeness`는
선호 판정이고, 이 필드는 모델 결과를 사후에 맞추는 용도로 사용하지
않습니다.

## 실행

```sh
export ORI_EVAL_ENDPOINT=http://127.0.0.1:8787/v1/analyze
dart run tool/evals/run_local_eval.dart
```

인증이 필요한 로컬 백엔드에서는 key를 환경 변수로만 전달합니다.
값은 `Authorization: Bearer` 헤더로 보내며 출력이나 결과 파일에
기록하지 않습니다.

```sh
export ORI_EVAL_API_KEY='local-only-secret'
dart run tool/evals/run_local_eval.dart
```

특정 샘플만 다시 실행할 수 있습니다. 전체 manifest는 여전히 17개
시나리오를 모두 포함해야 합니다.

```sh
dart run tool/evals/run_local_eval.dart --sample holdout-06
```

기본 결과는 gitignore된 `tool/evals/reports/latest.json`에 생성됩니다.
종료 코드는 모두 통과하면 `0`, 평가 실패가 하나라도 있으면 `1`입니다.
설정·입력 오류에는 별도 non-zero 코드가 사용됩니다.

### 재현성: `--repeat N`

같은 샘플을 N번(1~20) 분석합니다. 매 실행에 같은 판정을 적용하고,
모든 실행이 통과해야 샘플이 통과합니다. N ≥ 2이면 실행 간 태그 key
집합의 쌍별 Jaccard 유사도 평균을 샘플마다 `tagReproducibility`로,
그 평균을 `totals.tagReproducibility`로 기록합니다.
`docs/PLACE_ENRICHMENT.md`가 라벨 재현성을 9/10처럼 잰 것과 같은
질문입니다.

```sh
dart run tool/evals/run_local_eval.dart --repeat 5
```

### 어휘 보내기: `--vocabulary`, `--grow-vocabulary`

`--vocabulary <path>`는 로컬 JSON 파일을 읽어 모든 요청의 최상위
`vocabulary`로 보냅니다. 파일 형식은 `[{"value": "레시피", "count": 12}]`
이며 항목 300개 이하, `value`는 태그 모양(2~20자), `count`는 양의 정수,
같은 `value` 중복 불가입니다. 경로는 샘플 파일과 같은 규칙을 따릅니다:
프로젝트 루트 기준 상대 경로여야 하고 `..`, 절대 경로, URL은
거부합니다. `tool/evals/local/` 아래에 두면 git에 들어가지 않습니다.

`--grow-vocabulary`는 그 파일(없으면 빈 어휘)에서 시작해, 샘플 하나의
실행이 모두 끝날 때마다 그 샘플 **첫 실행**의 태그 값을 어휘에 더합니다.
값(표기)별로 count를 1 올리며, 한 샘플에 같은 값이 두 번 있어도 1만
더합니다. 300개를 넘으면 count가 가장 낮은 항목부터, 같은 count면 오래된
항목부터 버립니다. 실행 순서대로 라이브러리가 자라는 상황을 흉내 내는
것이라, "이미 있는 말을 다시 쓰는가"를 가장 직접적으로 재는 방법입니다.
`--repeat`와 함께 쓰면 한 샘플의 N번 실행은 모두 같은 어휘를 받습니다.

```sh
dart run tool/evals/run_local_eval.dart \
  --vocabulary tool/evals/local/vocabulary.json --grow-vocabulary
```

어휘 파일이나 자라난 어휘의 값은 출력에 쓰지 않습니다. 처음 항목 수만
`vocabulary.initialEntries`로 남깁니다.

## Aggregate JSON

결과에는 전체 pass/fail 수, 시나리오별 집계, 어휘 건강 수치, 필드별
판정만 포함됩니다.

```json
{
  "schemaVersion": 1,
  "repeat": 3,
  "totals": {
    "samples": 17,
    "passed": 15,
    "failed": 2,
    "tagReproducibility": 0.81
  },
  "byScenario": {
    "recipe_partial_mixed_text": {
      "total": 1,
      "passed": 1,
      "failed": 0
    }
  },
  "vocabulary": {
    "sent": true,
    "grown": true,
    "initialEntries": 40,
    "samples": 17,
    "tags": 61,
    "distinctKeys": 23,
    "singletonKeys": 9,
    "singletonRatio": 0.39,
    "meanTagsPerSample": 3.59,
    "spellingVariants": 1,
    "weakTags": 4
  },
  "results": [
    {
      "sampleId": "holdout-01",
      "scenario": "recipe_partial_mixed_text",
      "passed": true,
      "runs": 3,
      "tagReproducibility": 1.0,
      "checks": [],
      "extraRuns": [{"run": 2, "passed": true, "checks": []}]
    }
  ]
}
```

### 판정 (`checks`)

각 판정에는 `name`, `passed`, `gating`, `expected`, `actual`이 있고, 일부는
`metrics`를 더 가집니다. `gating: false`인 판정은 실패해도 샘플을
떨어뜨리지 않습니다. 샘플의 `passed`는 gating 판정과 실행기 오류만
봅니다.

`expectedTags`가 있는 샘플에만 붙는 태그 판정:

| name | gating | 통과 조건 |
| --- | --- | --- |
| `tags_recall` | 예 | 기대 태그의 key가 모두 실제 태그 key에 있음 |
| `tags_forbidden` | 예 | 금지 태그의 key가 하나도 없음 |
| `tags_precision` | 아니오 | 실제 태그 key가 모두 기대 태그 안에 있음 |

`tags_precision`이 gating이 아닌 이유: 라이브러리의 말은 manifest보다
빨리 자라므로, 운영자가 적지 않은 맞는 태그 하나는 실패가 아닙니다.
다만 숫자는 보여야 합니다. 이 판정의 `metrics`에 `precision`(실제 태그
중 기대에 있는 비율, 태그가 없으면 1)과 `recall`(기대 태그 중 실제로
붙은 비율, 기대가 빈 배열이면 1)이 0~1로 들어갑니다. `expected`와
`actual`은 정렬된 key 목록입니다.

### 재현성

- `results[].runs`: 그 샘플을 분석한 횟수.
- `results[].tagReproducibility`: 실행 간 태그 key 집합의 쌍별 Jaccard
  평균. 1이면 매번 같은 태그, 0이면 매번 전혀 다른 태그. 두 실행 모두
  태그가 없으면 1로 봅니다. 실행이 1회이거나 어느 실행이든 백엔드에
  닿지 못했으면 `null`입니다 (판정 실패는 상관없음 — 모델의 일관성을
  재는 숫자지 정답률이 아닙니다).
- `results[].extraRuns`: 2회차 이후 실행의 판정. 최상위 `checks`는 항상
  1회차입니다.
- `totals.tagReproducibility`: 값이 있는 샘플들의 평균. 없으면 `null`.

### 어휘 건강 (`vocabulary`)

백엔드에 닿은 샘플들의 **첫 실행** 태그만으로 셉니다. 값은 쓰지 않고
개수와 비율만 씁니다.

- `sent`, `grown`, `initialEntries`: 이번 실행이 어휘를 보냈는지, 키웠는지,
  처음 몇 항목으로 시작했는지.
- `samples`: 셈에 들어간 샘플 수. `tags`: 그 샘플들의 태그 총수.
- `distinctKeys`: 서로 다른 태그 key 수.
- `singletonKeys`: 딱 한 샘플에만 붙은 key 수. `singletonRatio`는 그
  비율. 높을수록 폴더가 아니라 라벨에 가깝다는 뜻이고, 어휘를 보내면
  내려가야 합니다.
- `meanTagsPerSample`: 샘플당 평균 태그 수. "맞는 말마다 밑에 둔다"의
  크기입니다.
- `spellingVariants`: 같은 key인데 두 가지 이상 표기로 온 key 수 —
  `멕시코 음식` / `멕시코음식` 같은 경우. 어휘를 보내면 0이 목표입니다.
- `weakTags`: `confidence`가 0.5 미만이거나 없는 태그 수. "근거 없는
  태그"의 근사치입니다.

## 테스트

mock backend 테스트에는 실제 이미지나 텍스트를 사용하지 않습니다. 태그
테스트에 쓰는 낱말도 `레시피`, `국·찌개`, `성수` 같은 일반어뿐입니다.

```sh
flutter test test/evals
flutter analyze --fatal-infos
```

## Git ignore

`tool/evals/.gitignore`가 `local/`과 `reports/`를 막으므로 현재 구조에는
루트 `.gitignore` 변경이 필요 없습니다. 비공개 샘플이나 결과 경로를
이 디렉터리 밖으로 옮긴다면 루트 `.gitignore`에도 해당 경로를
추가해야 합니다.
