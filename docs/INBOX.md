# 고양이 ! · ? 항목 (inbox)

고양이 얼굴 오른쪽에 작게 뜨는 표시. 테두리 없는 빨강·노랑 글자, 높이 9pt.

| 표시 | 뜻 | 예 |
|---|---|---|
| 빨강 `!` | 급하게 확인할 일 | 오늘 마감인 이력서, 답해야 하는 메일 |
| 노랑 `!` | 덜 급한 확인할 일 | 다음 주 일정 |
| 빨강 `?` | 답을 기다리며 멈춰 있는 질문 | AND·그록봇·spare 작업 승인 |
| 노랑 `?` | 천천히 답해도 되는 질문 | brain이 판단 못 한 작업 구간 |

넷 다 있으면 `!?!?` (빨강 ! · 빨강 ? · 노랑 ! · 노랑 ?) 순서로 붙는다. 우클릭 메뉴의 "❗ 확인할 것 n개 · ❓ 물어볼 것 n개" 줄 안에 항목이 뜨고, 거기서 확인·답한다. 여러 개를 한꺼번에 답할 때는 대시보드(📋, [collector/README.md](../collector/README.md#대시보드))의 질문 탭: 같은 `source`·같은 선택지 id 목록인 질문은 한 묶음으로 보여 한 번에 답한다. 새 빨강 항목은 말풍선으로 한 번 알려 준다.

## 넣는 법

`~/Library/Application Support/Meowgent/inbox/<id>.json` 에 파일 하나를 놓는다. 고양이는 10초마다 읽는다. 쓸 때는 임시 파일에 쓰고 이름을 바꾼다(반쯤 쓴 파일을 읽지 않게). 파일 권한은 0600.

```json
{
  "id": "and-resume-toss",
  "kind": "todo",
  "level": "yellow",
  "text": "토스 ML 이력서 마감",
  "detail": "채용 페이지에서 제출",
  "source": "and",
  "due": 1793000000,
  "url": "https://example.com/apply",
  "created": 1792900000
}
```

| 필드 | 필수 | 뜻 |
|---|---|---|
| `text` | ✓ | 메뉴에 보일 한 줄 |
| `kind` | | `todo`(!, 기본) 또는 `ask`(?) |
| `level` | | `red` 또는 `yellow`(기본) |
| `id` | | 없으면 파일 이름 |
| `detail`, `source` | | 하위 메뉴에 보일 설명·보낸 곳 |
| `due` | | 마감(유닉스 초). **24시간 안으로 들어오면 노랑이어도 빨강으로 올린다** |
| `expires` | | 이 시각이 지나면 안 보인다. 없고 `due`가 있으면 마감 24시간 뒤 |
| `url` | | http(s)만. 하위 메뉴에 "열어 보기" |
| `choices` | | `ask` 선택지. 문자열 또는 `{"id", "label"}` |
| `multi` | | `true`면 여러 개 고르는 질문 (체크 상자). 묶음으로 합치지 않는다 |
| `forward` | | `"grokbot"`이면 이 할일을 Grok Bot에도 넘긴다 (아래). `todo`만 |

## 답 받기

확인하거나 답하면 파일이 `inbox/done/<같은 이름>.json` 으로 옮겨지고 두 필드가 붙는다.

- `answer`: `todo`는 `"done"`, `ask`는 고른 선택지의 `id` 또는 직접 적은 글, 넘기면 `null`
- `answers`: `multi` 질문이면 고른 id 목록 (`answer`는 "A, B")
- `resolved`: 답한 시각

만든 쪽이 `done/` 을 읽어 답을 가져간다. 같은 `id`로 다시 묻지 않으려면 `done/`에 그 이름이 있는지 본다.

## 지금 넣는 곳

- **brain** (`brain/actlog_brain.py` `ask_unclear`): 최근 3일 중 10분 넘는 구간인데 프로젝트를 모르면(신뢰도 0.4 미만 또는 "새 작업") 노랑 `?`로 묻는다. 안 답한 질문은 5개까지만 쌓는다(`brain.json`의 `ask_min_s`·`ask_open_max`). 답은 `brain.db`의 `labels` 표에 모아 둔다. 아직 판단에 다시 쓰지는 않는다.

일정·메일(!)과 AND·그록봇(?)은 아직 넣는 쪽이 없다. 각자 위 형식으로 파일을 놓으면 된다.

## Grok Bot으로 넘기기

`"forward": "grokbot"`이 붙은 할일(`todo`)은 고양이에 뜨는 것과 함께 Grok Bot 자동화(루틴) 웹훅으로도 간다. 코드: `collector/Sources/ActLog/InboxForward.swift`(보내기) · `InboxForwardRules.swift`(판단, 테스트 있음).

- **켜기**: Grok Bot에서 웹훅으로 시작하는 루틴을 만들고, 루틴 화면의 Webhook 칸에 나오는 POST 주소와 키를 `{ "url": "...", "key": "..." }`로 적어 둔다. 기본 위치는 데이터 폴더의 `grokbot-webhook.json`(0600)이다. 다른 파일을 쓰려면 `defaults write io.github.jasonwpgml.meowgent grokbotWebhookFile <경로>`. 파일이 없거나 주소가 https가 아니면 보내지 않는다. 이 맥 안의 시험 서버(`http://127.0.0.1`)는 예외다.
- **보내는 것**: `POST <url>`, `Authorization: Bearer <key>`, 본문 JSON `{context, source:"meowgent", kind:"todo", id, text, detail, due, url, level, from, machine, created}`. `context`는 사람이 읽는 몇 줄이고, Grok Bot 앱이 웹훅 루틴을 시험할 때 보내는 모양과 같다. 글은 키·카드번호를 가리고(`Privacy.redact`), 제목 300자·설명 2000자에서 자른다. 활동 기록·코드는 보내지 않는다.
- **언제**: 10초마다 읽어서 아직 안 보낸 것을 보낸다. 한 번에 3개, 한 시간에 30개까지 보낸다. 웹훅 한 번이 Grok Bot 사용량을 쓰기 때문이다. 고양이가 꺼져 있었으면 켜질 때 보낸다. 확인해서 `done/`으로 옮긴 뒤에는 보내지 않는다.
- **결과**: `inbox-forward.json`에 항목 id별로 `sent`(보낸 시각), `run`(Grok Bot 실행 id), `tries`, `error`가 남는다. inbox 파일은 건드리지 않는다. 200을 받았다는 건 Grok Bot이 실행을 시작했다는 뜻일 뿐이고, 결과는 그 봇 채팅에서 본다.
- **실패하면**: 1분, 5분, 15분, 30분, 1시간, 2시간, 그 뒤로는 4시간마다 다시 보낸다. 400·401·403·404는 키나 루틴 문제라서 30분부터 시작한다. 10번 실패하면 멈추고 고양이가 한 번 알린다. 메뉴바 메뉴에 "📮 Grok Bot 전달" 줄이 나온다.
- **다른 에이전트가 쓰는 법**: Agent Hub 스킬 `grokbot-todo`(`scripts/add-todo.mjs`)가 이 파일을 만들어 준다.
