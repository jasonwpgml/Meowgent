# 말하는 고양이 (2026-10-28)

고양이가 진짜 AI로 말을 걸고, 대답하고, 사용자에게 묻는다. 평소에는 토큰을 쓰지 않는다. 결정론적 코드가 루프를 돌고, 로컬 Clef가 "지금 말 걸 만한가"를 판단한다. 그 판단을 통과했을 때만 고양이 전용 Codex 계정을 한 번 부른다.

코드: `brain/cat_mind.py`(루프·판단·Codex 호출, 테스트 `brain/test_mind.py`) · `collector/Sources/ActLog/MindBridge.swift`(앱 쪽: 말풍선 전달·단축키·켜고 끄기) · `MindChat.swift`(대화창) · `MindVoice.swift`(말로 하기) · `HotKey.swift` · `brain/mind_setup.sh`(Codex 계정 로그인)

## 흐름

```
actlog.db ─(자리 비움)─┐
brain.db ─(Clef 구간 판단)─┼─▶ cat_mind 루프 (1초/5초, 토큰 0)
mind/in ◀─ 앱 "💬 말 걸기" ─┘        │
                                    ├─ 말 걸어 옴 ─────────────────────────┐
                                    └─ 신호 → 간격·횟수 제한 → Clef 문지기 ─┤ (통과할 때만)
                                                                          ▼
                                    codex exec (CODEX_HOME=~/.codex-meowgent, 도구 꺼짐, JSON 답)
                                                                          │
              앱 말풍선 ◀─ mind/out ◀──────── say ────────────────────────┤
              얼굴 옆 ? ◀─ inbox/mind-*.json ◀─ ask + 보기 ───────────────┤
                                    mind/memory.json ◀─ remember ─────────┘
```

| 신호 | 조건 (기본값) | 한 번만 |
|---|---|---|
| 말 걸어 옴 | 대화창(⌃⌥M 또는 메뉴 "💬 고양이한테 말 걸기") 또는 `cat_mind.py say "…"` | 문지기 없이 바로 Codex, 급한 말풍선 |
| 막힘 | 진행 중인 구간의 Clef `stuck` ≥ 0.5, 8분 이상 | 구간마다 |
| 돌아옴 | 20분 넘게 자리를 비웠다가 돌아온 지 5분 안 | 돌아올 때마다 |
| 오래 쉬지 않음 | 5분 넘게 쉰 적 없이 90분 | 90분마다 |
| 늦은 밤 | 1~5시에 깨어 있음 | 하룻밤 |
| 딴짓 | 10~19시에 `leisure` 구간이 25분 이상 | 구간마다 |
| 작업 전환 | 10분 넘게 한 구간이 끝났고 Clef `switched` ≥ 0.6 | 구간마다 |
| 기록할 만한 순간 | Clef `notable` ≥ 0.6 | 구간마다 |
| 오래 조용함 | 고양이가 3시간 말이 없었고 사용자가 깨어 있음 → 궁금한 걸 묻는다 | 3시간마다 |

먼저 말 걸기는 15분 간격, 한 시간에 3번, 하루 24번까지다. 안 답한 고양이 질문이 2개 쌓이면 더 묻지 않는다. Clef가 꺼져 있으면 먼저 말 걸지 않는다. 사용자가 건 말에는 그대로 답한다.

### Clef 문지기

신호와 지금 상황을 `/v1/systemone`에 넣고 두 가지를 묻는다. 한 번에 1~2초 걸린다.
- `speak`: 곁에 있는 다정한 고양이라면 지금 한마디 건네겠는가. 확률이 0.5 이상이어야 통과한다.
- `mode`: chat(가볍게) · judge(의견·제안) · ask(질문) · quiet(가만히) 중 하나.

질문 문구에 따라 확률이 크게 달라진다. 2026-10-28에 같은 상황을 두 문구로 물어 비교했다.

| 상황 | "곁에 있는 고양이라면 한마디 하겠나" | "말 거는 게 방해보다 도움이 큰가" |
|---|---|---|
| 14분째 막힘 | 0.78 | 0.04 |
| 1시간 40분 비웠다 돌아옴 | 0.82 | 0.10 |
| 90분 쉬지 않음 | 0.54 | 0.04 |
| 업무 시간 YouTube 30분 | 0.22 | 0.04 |
| 회의(Zoom) 중, 오래 조용함 | 0.12 | 0.06 |
| 읽기 중, 오래 조용함 | 0.60 | 0.24 |

`mode`는 문구와 상관없이 그럴듯하게 나왔다: 막힘에는 judge, 돌아옴에는 chat, 회의 중에는 quiet였다. 문구를 고치면 이 표를 다시 재고 바꾼다.

### Codex

- 계정은 고양이 전용 `CODEX_HOME=~/.codex-meowgent`를 쓴다(지금은 imson1345). 평소 쓰는 `~/.codex`의 계정·설정·기록과 섞이지 않는다. `brain/mind_setup.sh`가 이 홈을 만들고 브라우저로 로그인시킨다.
- 이 홈의 `config.toml`은 셸·브라우저·플러그인·이미지·웹 검색 같은 도구를 모두 끈다. 실행 옵션은 `-s read-only`이다. 답은 `--output-schema`로 `{say, ask, choices, remember, need}` JSON 형식에 맞춰 받는다.
  - 처음엔 `--ephemeral`로 세션 기록을 남기지 않았다. 그런데 한도(rate_limits)는 세션 기록에만 남고 `codex exec --json`에는 안 나와서 기록을 남기게 바꿨다. 그 기록에는 보낸 프롬프트(활동 요약)가 들어 있으니 `~/.codex-meowgent/sessions`에 하루만 두고 지운다(`Codex.prune_sessions`, 한 시간마다).

### Codex 한도와 피곤함 (2026-10-28)

- `cat_mind`는 Codex를 부를 때마다 가장 최근 세션 기록의 `rate_limits`를 읽어 `mind/quota.json`에 쓴다. 담는 값은 5시간 창·주간 창의 사용률과 리셋 시각, 요금제다. 한도 오류(usage limit·429 등)로 실패했는데 리셋 시각을 모르면 30분 동안 졸린 것으로 친다.
- 바닥나면(어느 창이든 100%) 리셋까지 Codex를 부르지 않는다. 먼저 말 걸기도 멈추고, 사용자가 말을 걸면 토큰 없이 "하암… Codex 한도를 다 써서 졸리다냥. HH:MM에 깨면 대답하겠다냥."이라고 답한다.
- 앱(`MindBridge`)은 `quota.json`을 2초마다 본다.
  - 피곤함(0~100)은 리셋이 안 지난 창 중 가장 많이 쓴 비율이다. 바닥나면 100이다.
  - 보이는 곳: 대화창 상태 줄, 메뉴바 메뉴의 "🔋 Codex 5시간 0% · 이번 주 16%", 고양이를 클릭했을 때와 마우스를 올렸을 때 나오는 글.
- 고양이(`pet/Sources/PetController+Tired.swift`):
  - 피곤함 80 이상이면 기분과 상관없이 나른한 얼굴을 한다.
  - 100이면 타자 칠 때 노트북 앞에서 꾸벅꾸벅 졸고(새벽 졸기와 같은 그림), 앉아 있을 때 하품을 자주 한다.
  - 바닥나면 "하암… HH:MM까지 잠깐 자겠다냥", 다시 차면 기지개를 켜며 "푹 잤다냥. 한도가 다시 찼다냥"이라고 한 번씩 말한다. 앱을 켰을 때 이미 그런 상태면 말하지 않는다.
- 2026-10-28 실측: imson1345(plus) 5시간 0% · 주간 16%. 가짜 `quota.json`(5시간 100%)을 넣었더니 2초 안에 졸기 시작 말, 되돌렸더니 깨는 말이 나왔다.
- 한 번 부를 때 Codex 기본 지시문 때문에 약 1만 1천~1만 5천 토큰을 쓴다.
- 성격은 `brain/persona.md`(똑똑하지만 도도하고 귀찮음 많은 고양이)를 `mind/persona.md`로 복사해 쓴다(`brain/install.sh`가 한다). 없으면 `DEFAULT_PERSONA`. 규칙 대사(앱 말풍선)는 따로 `pet/docs/CAT_VOICE.md`를 따른다. luna가 "있네다냥"처럼 어미를 섞어서 규칙에 어미 예시를 넣었다.

### 모델과 허락 (2026-10-28)

| 언제 | 모델 (`mind.json`) | 추론 | 실측 (같은 질문) |
|---|---|---|---|
| 먼저 말 걸 때 | `model` = gpt-6-luna | low | 4~7초 |
| 사용자가 말 걸었을 때 | `chat_model` = gpt-6.1-sol | medium | 8~12초 |
| 허락받았을 때 | `big_model` = gpt-6-astra | high | 23초 (medium 15초) |

- 프롬프트에 지금 모델·추론·로그인 계정(`auth.json`의 id_token 이메일)을 넣는다. 전엔 이걸 몰라서 "GPT-6.1 기반"이라고 지어냈다.
- 대화창 답은 400자까지, 먼저 말 걸 땐 80자. 일반 지식은 아는 대로 답한다. 사용자 활동·사정은 기록에 있는 것만 말한다.
- 고양이는 답에 `need: {tool, why}`를 넣어 더 필요한 걸 요청할 수 있다. `cat_mind`가 `inbox/mind-perm-*.json`(30분 유효)을 만들고, 대화창 아래와 얼굴 옆 ?에 버튼이 뜬다. 허락하면 같은 질문을 그 도구를 켜고 다시 답한다.

| tool | 켜는 것 | 보기 |
|---|---|---|
| `astra` | `big_model`·`big_effort`로 다시 답 | 이번만 · 항상 · 안 돼 |
| `web` | `-c web_search="live"` | 이번만 · 항상 · 안 돼 |
| `read` | `-c features.shell_tool=true`, 샌드박스 read-only (네트워크 없음) | 이번만 · 항상 · 안 돼 |
| `write` | 셸 + `-s workspace-write`, `--add-dir`는 `write_dirs`(데스크탑·문서·다운로드·dev)만 | 이번만 · 안 돼 (항상 없음) |

- 웹과 맥 읽기·쓰기는 같은 실행에서 둘 다 이번에 허락받았을 때만 같이 켠다. 읽은 내용이 검색어로 나가지 않게 하려는 것이다. 둘 다 항상 허락이면 웹만 켜고, 맥 읽기가 필요하면 다시 묻는다.
- 묻지 않고 바로 다시 답할 때(memory, 항상 허락한 astra)는 그 말에 앞서 받은 웹·맥 허락을 넘기지 않는다. 홈 전체 쓰기는 주지 않는다(`mind.json`·LaunchAgents·dotfile을 못 고치게).
- `allow`에 손으로 `write`를 적어도 무시한다.
- "항상 허락"은 `mind.json`의 `allow`에 남는다. web·read는 그 뒤로 대화마다 켜지고, astra는 sol이 요청하면 묻지 않고 넘긴다. 지우려면 `allow`에서 뺀다.
- 도구를 켠 실행엔 활동 기록을 `labels` 수준으로만 보낸다. 창 제목 속 글이 검색어나 명령으로 새어 나가지 않게 하려는 것이다. 도구 실행 제한 시간은 `tool_timeout_s`(300초).
- 2026-10-28 실측: 날씨 질문 → sol이 web 요청 / 웹 켜고 주가 질문 24초 / read 켜고 `ls` 10초.

### 대화 단위

`session_gap_s`(30분) 넘게 말이 끊기면 새 대화로 친다. 지난 대화는 원문 대신 요약으로만 이어진다. 기억 층·예산·정리는 비공개 문서 `pet/docs/CAT_MEMORY.md`에 있다.

### 생각 다듬기 (2026-11-04)

- **자리에 있을 때만 먼저 말 건다**: 키보드·마우스 입력이 `present_idle_s`(120초) 안에 없으면(자리 비움·잠자기·DarkWake) 먼저 말 걸지 않는다. 전엔 맥이 잠깐 깬 순간 생각을 시작했다가 다시 잠들어, 깨어난 뒤 16~18분 "시간 초과"로 끊기던 일이 7일에 12번 있었다.
- **잠든 시간은 생각 시간에 안 센다**: Codex 걸린 시간을 `time.monotonic()`(잠자기 동안 멈춤)으로 잰다.
- **연결이 잠깐 끊기면 한 번 다시**: 사용자 말에 답하다 네트워크 오류(Reconnecting·routing discovery failed …)면 한 번 더 묻고, 그래도 안 되면 "연결이 잘 안 된다냥"으로 끝낸다.
- **판단 기록** `mind/decisions.jsonl`(0600, 최근 3000줄): 판단마다 신호·내용·말할 확률·방식·결과(said·quiet·failed·timeout·limited·retry)·걸린 시간·한 말. 사용자 말은 넣지 않는다. 대시보드 "생각" 탭이 읽는다.
- **대화창**: 3초 넘게 생각하면 "생각 중이다냥 · 12초"처럼 몇 초째인지 보인다.

### 주간 개선 제안 (2026-11-04, 기본 꺼짐)

- `mind/improve.on`이 있을 때만(대시보드 "개선" 탭의 스위치, 켤 때 보내는 것을 보여 주고 묻는다) `improve_every_s`(7일)마다, `mind/improve.now`가 있으면 바로 한 번.
- 보내는 것(`improve_report`): 지난 7일 고양이 알림 통계(건수·하루 평균·한 시간 안 반복·2분 안 몰림·'냥' 없는 알림·종류별)와 두 번 이상 한 알림 문장(대화·작업 이름 ‘…’과 숫자는 가림, 고양이 대화 답은 뺌), 판단 통계, 지금 `phrases.json`의 문구·설정. 입력한 글·활동 기록·대화는 보내지 않는다.
- 답(`IMPROVE_SCHEMA`): phrase(문구 키·새 문구) · param(설정 키·숫자) · idea(한 줄). 모르는 키, 자리표시가 빠진 문구, 숫자가 아닌 설정은 버린다. `mind/improve/latest.json`(+ 날짜별 사본)에 status=new 로 남기고, 대시보드에서 [적용]하면 앱이 `phrases.json`만 바꾼다. 실패하면 6시간 뒤 다시.

### 말풍선 반응 기록 (2026-11-07, 실시간 업무 보조 0단계)

실시간 업무 보조(조사: `docs/reports/실시간 업무 보조 기능 조사.md`)의 첫 단계다. 언제 말을 걸지 학습하려면 먼저 사용자가 말풍선에 어떻게 반응했는지가 있어야 한다. 전에는 알림 1,037건에 반응 기록이 하나도 없었다.

- 앱(`Reactions.swift`)이 고양이 말풍선마다 id 를 붙여 데이터 폴더의 `reactions.jsonl`(0600, 최근 2만 줄)에 사건을 남긴다. 기록을 끈 "고양이만" 상태에서도 남는다(`notices.jsonl`과 같음). 밖으로 보내지 않는다.

  | 사건 `ev` | 뜻 |
  |---|---|
  | `shown` | 말풍선이 떴다 (글 160자까지 이 줄에만) |
  | `replied` | 눌러서·우클릭 "💬 이 말에 답하기"로 대화창을 열었다. 고양이가 먼저 건 말이 뜬 뒤 2분 안에 ⌃⌥M·메뉴로 대화창을 열어도 답한 것으로 친다(`via: chat`) |
  | `detail` | 자세히 보기를 열었다 (2초 올려 두기·누르기) |
  | `read` | 마우스를 올려 읽었지만 아무것도 안 하고 사라졌다 |
  | `ignored` | 손대지 않고 시간이 다 되어 사라졌다 |
  | `cut` | 다른 말에 밀려 사라졌다 |
  | `dropped` | 보여 줄 틈이 없어 기한이 지나 버렸다 |
  | `rejected` | 우클릭 "👎 지금은 필요 없다냥" (말풍선을 바로 닫는다) |
  | `muted` | 우클릭 "🔇 이런 말은 오늘 그만": 그 종류(`kind`)를 다가오는 아침 6시까지 끈다 |

  `shown` 이후 줄의 `after`는 말풍선이 뜬 뒤 몇 초 만에 그 일이 있었는지다. **무시가 많으면 시점 문제, 👎가 많으면 내용 문제**로 나눠 본다.
- 종류(`kind`): `mind:<신호>`(먼저 말 건 것, 예 `mind:long_focus`), `mind:chat`(사용자 말에 한 답), `mind:system`(앱이 낸 고양이 말), `agent`, `quota`, `resource`, `forward`, `secret`. 🔇 는 `mind:chat`·`mind:system`·`secret`(붙여넣은 키 경고)에는 없다.
- 끈 종류는 `muted.json`(`{"mind:stuck": 끝 시각}`)에 둔다. 앱은 그 종류의 알림을 내지 않고, cat_mind 는 그 신호가 와도 Clef·Codex 를 부르지 않고 판단 기록에 `outcome: muted`로 한 번만 남긴다.
- cat_mind 가 내는 말(`mind/out/*.json`)에 `id`(`m-<ms>`)가 붙고, 판단 기록 `decisions.jsonl`의 `sid`가 같은 값이다. 판단과 반응을 이 id 로 잇는다.
- 대시보드 "생각" 탭: 말한 판단 옆에 대표 반응("반응: 무시" 등, 강한 것부터 🔇 > 👎 > 답함 > 자세히 봄 > 읽기만 함 > 무시 > 밀림 > 못 보여 줌)을 보이고, 먼저 말 걸기의 말함·참음에는 라벨 버튼을 단다. 말했으면 "말한 게 맞다 / 괜히 말했다", 참았으면 "참은 게 맞다 / 말했어야 했다". 고른 쪽은 ✓, 다시 누르면 지운다. `mind/decision_labels.jsonl`(키 = sid, 없으면 시각)에 쌓이고 마지막 것이 이긴다. 다음 단계에서 '언제 말할지' 작은 판단기를 학습할 정답이다.
- 확인한 것: 실제 앱에서 cat_mind 말풍선 → `shown` → 9초 뒤 `ignored`. 우클릭 👎·🔇 와 생각 탭 버튼은 아직 사람 손으로 눌러 보지 않았다 (규칙은 `Tests/run_logic.sh`, cat_mind 쪽은 `brain/test_mind.py`).

## 밖으로 나가는 것 (켜 두면)

말하는 고양이를 켜 두면 고양이를 부를 때마다 아래 내용이 사용자의 Codex(OpenAI) 계정으로 간다. 이 기능 말고는 기록이 맥 밖으로 나가지 않는다.

| `share` (mind/mind.json) | 보내는 것 |
|---|---|
| `labels` | 앱 이름, Clef 판단(활동·프로젝트·집중·막힘), 시각과 길이 |
| `titles` (기본) | 위 + 창 제목(60자), 사이트 호스트 (내 컴퓨터 파일 경로는 뺀다) |
| `full` | 위 + 구간의 마지막 AI 질문·검색어 |

어느 단계에서든 보내지 않는 것: 입력한 글, 붙여넣은 내용, 클립보드, 전체 URL. 수집기가 막는 앱·사이트(은행, 비밀번호 칸, 시크릿 창 등)는 애초에 기록에 없다.
사용자가 건 말, 이번 대화(최근 10턴 + 앞부분 요약), 사용자에 대한 사실, 최근 대화 요약 3개, 이번 말과 관련 있어 보이는 옛 요약은 언제나 간다. 대화가 끝나면 그 대화 원문을 luna에 한 번 더 보내 정리한다.

허락한 도구를 켜면 더 나간다: `read`·`write`는 고양이가 읽은 파일 내용과 명령 결과가, `web`은 검색어가 OpenAI로 간다.

끄기: 고양이 메뉴나 메뉴바에서 "🧠 말하는 고양이 (Codex)"를 누른다. `mind/off` 파일이 생기고, 루프는 계속 돌지만 아무것도 읽지 않고 보내지도 않는다.

## 파일 (`~/Library/Application Support/Meowgent/mind/`, 폴더 0700 · 파일 0600)

| 파일 | 내용 |
|---|---|
| `mind.json` | 설정 (위 기본값, `cat_mind.py`의 `DEFAULT_CONFIG`) |
| `in/`, `out/` | 앱 ↔ 루프 메시지. 읽으면 지운다 |
| `conversation.jsonl` | 사용자·고양이 대화, 고양이 질문에 한 답. `keep_days`(30일) 지나고 내보내기·정리가 끝난 줄은 지운다 |
| `transcripts/` | 끝난 대화 하나당 파일 하나(`YYYYMMDD-HHMMSS.jsonl`). AI Archive Hub가 가져가 AND가 찾는다. 30일 뒤 지운다 |
| `facts.json` | 사용자에 대한 사실 (`id`, `since`, `source`, `evidence`, `expires_at`, `valid_to`). 예전 `memory.json`은 처음 실행 때 옮기고 `memory.json.old`로 둔다 |
| `episodes.jsonl` | 끝난 대화 요약 (주제, 요약, 남은 일) |
| `rules.json` | 사용자가 "남겨"를 고른 말투 규칙 |
| `state.json` | 이미 처리한 신호, 말한 시각, 자리 비움 상태, 대화 중 요약(`note`), 어디까지 내보내고 정리했는지 |
| `alive.json` | 10초마다 남기는 살아 있음 신호. 앱은 30초 넘게 신호가 없으면 "머리가 안 돌고 있다"고 말한다 |
| `thinking` | Codex 답을 기다리는 동안만 있다. 대화창의 "생각 중" |
| `decision_labels.jsonl` | 생각 탭에서 고른 판단 라벨 (맞다·아니다). 데이터 폴더의 `reactions.jsonl`·`muted.json`은 위 "말풍선 반응 기록" |
| `quota.json` | 고양이 Codex 계정의 한도 (5시간·주간 사용률, 리셋 시각, 한도 오류로 졸린 시각) |
| `persona.md` | 성격·말투 (`brain/persona.md` 복사본) |
| `work/` | Codex 실행 폴더 (스키마, 마지막 답, 오류 출력) |
| `mind.log` | 로그 |

## 설치

```bash
brain/mind_setup.sh          # 고양이 전용 Codex 홈 만들기 + 로그인 (한 번)
brain/install.sh             # brain + cat_mind 를 launchd 에 등록 (com.jason.meowgent.mind)
python3 brain/cat_mind.py status
python3 brain/cat_mind.py say "안녕"
python3 -I brain/test_mind.py
```

상시 비용: CPU 0.1%, 메모리 22MB (2026-10-28 실측).

---

## 대화창 · 말로 하기 (2026-10-28, 2-1·2-2 구현)

- 고양이가 먼저 건 말풍선을 우클릭(또는 Control 클릭)하면 “이 말에 답하기…”가 뜬다. 선택하면 기존 대화창과 입력칸이 열린다. 말풍선 위에 마우스를 둔 동안은 사라지거나 다음 알림으로 바뀌지 않는다. 일반 알림의 자세히 보기와 고양이 몸체의 메뉴는 그대로다.

- **⌃⌥M** 짧게 누르기: 대화창 열기·닫기. 길게(0.35초) 누르기: 누르는 동안 듣고, 떼면 받아 적은 글을 1초 뒤 보낸다. 그 1초 안에 글을 고치면 안 보낸다. 메뉴 "💬 고양이한테 말 걸기"와 창의 🎤 버튼(누르면 듣기, 다시 누르면 끝)도 있다.
  - 계획의 ⌃⌥Space는 쓰지 않는다. 이 맥에서 macOS "다음 입력 소스 선택"으로 켜져 있어서, 누를 때마다 한/영이 바뀐다. ⌘Space는 Raycast가 쓴다. 바꾸려면 `MindBridge.hotKeyCode/hotKeyMods`를 고친다.
- 창은 떠 있는 패널이다. 모든 데스크톱에서 보이고, 위치를 기억하고, Esc로 닫는다. `conversation.jsonl`을 그대로 보여 주고, 고양이 질문(`inbox/mind-*`)의 보기는 버튼으로 나온다.
- 글래스 디자인 (2026-10-28):
  - 창 테두리·신호등 버튼이 없다. 창 뒤는 완전히 투명하고, 모서리 22px 둥근 유리판 하나만 있다. macOS 26은 `NSGlassEffectView`(Liquid Glass), 그 전은 `NSVisualEffectView`(HUD) 위에 어두운 층을 깐다.
  - 머리: 도트 고양이 얼굴 · 이름 "냥이"(갈무리11) · 상태 한 줄(생각 중 / 듣는 중 / Codex 한도) · ⚙︎ · ×. 머리를 잡고 끌면 창이 움직인다.
  - 말풍선: 고양이는 옅은 유리, 나는 크림색 반투명. 말풍선이 옅어지면(50% 미만) 내 글자를 밝은 색으로 바꿔 늘 읽히게 한다.
  - 입력: 알약 모양 칸 안에 🎤·보내기 동그란 버튼. 듣는 동안 🎤는 빨간 ■로 바뀌어 숨 쉬듯 깜빡인다.
  - ⚙︎ 설정 (UserDefaults): 유리 진하기 `chatGlassTint` 0~0.75(기본 0.35), 말풍선 진하기 `chatBubble` 0.2~1(기본 0.7), 유리 종류 `chatGlassStyle` 맑게(clear, 기본)/보통(regular).
  - 맑은 유리는 뒤가 밝으면 글자가 안 보여서 Apple 문서대로 어두운 색을 입힌다(`tintColor`). 실제 화면에서 진하기 35%, 어두운 배경 위 모습은 확인했다. 슬라이더를 끝까지 움직였을 때와 밝은 배경 위 모습은 아직 사람 눈으로 확인하지 않았다.
  - 처음엔 앱을 앞으로 가져오지 않는 Spotlight 방식이었다. 그런데 단축키로 열면 키보드가 창으로 안 넘어와서 입력한 글이 뒤의 앱으로 갔다. 지금은 열 때 앱을 앞으로 가져오고, 닫을 때 원래 앱으로 돌려준다.
- 말로 하기: macOS 26이면 `SpeechAnalyzer` + `SpeechTranscriber`(ko-KR, 받아 적는 중인 글을 입력칸에 실시간으로 보여 줌, `MindBridge.voiceHints`로 "냥이"·프로젝트 이름을 힌트로 넣음)를 쓰고, 그 이전 버전은 `SFSpeechRecognizer` 기기 안 인식을 쓴다. 소리는 저장하거나 보내지 않는다.
- 권한: `Info.plist`에 마이크·음성 인식 설명을 넣었고, 배포용 `Meowgent.entitlements`에 `com.apple.security.device.audio-input`을 넣었다. 처음 말할 때 macOS가 마이크(와 음성 인식) 권한을 묻는다.
- 확인 안 된 것: 실제 마이크로 한국어를 받아 적는 품질과 속도. 권한 창을 사람이 눌러야 해서 자동으로 시험하지 못했다.

## 다음 단계 계획: 시키면 하기 (2-3) 이후

사용자 요청 (2026-10-28): 말 거는 버튼을 누르면 채팅창이 뜬다. 거기에 글을 적거나, 마이크를 열고 실제로 말하면 전사해서 알아듣는다. 시킨 일은 그대로 한다.

### 조사 결과 (2026-10-28, 이 맥 = macOS 26)

| 항목 | 결과 |
|---|---|
| 음성 인식 1순위: `SpeechAnalyzer` + `SpeechTranscriber` (macOS 26) | `ko-KR` 모델이 이미 설치돼 있다. 기기 안에서 돌고 무료다. TTS로 만든 6초 한국어 문장을 0.1~0.3초에 받아 적었다. 숫자·띄어쓰기는 맞았지만 "냥이야"를 "양이야"로 들었다. 받아 적는 중인 글(volatile)도 실시간으로 나온다. 사람 목소리로는 아직 재 보지 않았다 |
| 대체: `SFSpeechRecognizer` (`requiresOnDeviceRecognition`) | `ko-KR` 기기 안 인식이 된다. macOS 14~25용 |
| whisper.cpp | 설치돼 있지 않다. 한국어에 쓰려면 large-v3-turbo(1.6GB)가 필요하다. 위 둘로 부족할 때만 쓴다 |
| Codex 음성 (`gpt-realtime`, `/voice`) | `codex exec`로는 쓸 수 없고, app-server(실험 기능)에만 있다. ChatGPT 로그인만으로 쓸 수 있는지 확인하지 못했다. 쓰지 않는다 |
| 권한 | `Info.plist`에 `NSMicrophoneUsageDescription`(필수)과 `NSSpeechRecognitionUsageDescription`(보험)을 넣는다. 배포본은 Hardened Runtime이라 `com.apple.security.device.audio-input` 권한이 꼭 필요하다(빠지면 배포본에서만 마이크가 조용히 막힌다). SpeechAnalyzer는 `#available(macOS 26)`으로 감싼다 |
| Codex 답 스트리밍 | `codex exec --json`은 답을 완성된 뒤 한 번에 준다(`item.completed`). 글자 단위 스트리밍은 app-server에만 있다. `turn.started`에서 "생각 중"을 띄우는 것으로 충분하다 |
| 로컬 의도 분류 | Clef 객관식 질문으로 1~2초. 시험 문장 6개 중 5개를 맞혔다. 지금 Clef 서버는 글을 만들지 못하므로 "10분", "3시" 같은 인자는 정규식이나 `NSDataDetector`로 뽑는다 |

### 단계

**2-1 대화창** (앱, 공개 쪽 `MindBridge`) — 구현됨, 위 "대화창 · 말로 하기" 참고. 아래는 처음 계획
- 지금의 `NSAlert` 입력창을 `NSPanel`로 바꾼다. 옵션은 `.nonactivatingPanel`, `canBecomeKey`, `.floating`, `.canJoinAllSpaces`. 쓰던 앱의 포커스를 빼앗지 않고 고양이 옆에 뜬다.
- 창에 `conversation.jsonl`의 최근 대화를 말풍선 목록으로 보여 준다. 고양이 질문(`inbox/mind-*`)의 보기는 버튼으로 붙인다.
- 단축키 ⌃⌥Space로 연다(Carbon `RegisterEventHotKey`, 추가 권한 없음). 고양이를 클릭했을 때 나오는 메뉴의 "💬 말 걸기"도 이 창을 연다.
- 루프가 Codex를 부르는 동안 `alive.json`의 `busy`를 보고 "생각 중…"을 띄운다. 고양이 쪽 귀 쫑긋·생각 풍선은 `pet/`에 hook을 하나 추가한다.

**2-2 음성** (앱) — 구현됨
- 창의 🎤 버튼, 또는 ⌃⌥Space를 길게 누르고 있으면 듣는다(누르는 동안 말하기).
- 받아 적는 중인 글을 입력칸에 흐리게 보여 준다. 키를 떼면 확정하고, 1초 안에 고치지 않으면 보낸다.
- 엔진은 macOS 26이면 SpeechTranscriber, 아니면 SFSpeechRecognizer 기기 안 인식이다. 오디오는 맥 밖으로 나가지 않고, 받아 적은 글만 위 대화 경로로 간다.
- 인식 문맥에 "냥이, 고양이, Meowgent, 프로젝트 이름"을 넣어 오인식을 줄인다.

**2-3 시키면 하기** (루프 + 앱)

> 2026-11-04 1차 구현됨 — 아래 "시키면 하기 · 되묻기 (구현)"을 본다. 아래 표는 처음 계획이다.
- 모델에게 셸을 주지 않는다. 답 형식에 `actions: [{tool, args}]`를 추가하고, `tool`은 정해진 목록(enum)으로 고정한다.
- 루프가 형식을 검사하고, 실행은 앱의 고정 코드가 맡는다. 실행 결과는 다음 대화에 기록한다.

| 도구 | 실행 | 먼저 묻기 |
|---|---|---|
| open_app · open_url(https만) · search | `NSWorkspace` | 아니오 |
| memo · todo | 기존 `memos.jsonl` (`PetJournal`) | 아니오 |
| timer | 고양이 안 타이머 → 시간 되면 말풍선 | 아니오 |
| reminder | EventKit (권한 창 한 번) | 처음만 |
| music | AppleScript `Music` playpause/next | 아니오 |
| shortcut | 사용자가 허용 목록에 넣은 단축어만 `shortcuts run` | 예 |
| coding_task | 허용한 저장소에서만 별도 `codex exec -C <repo> --worktree -s workspace-write` 또는 AgentHub 디스패치. 끝나면 말풍선으로 알린다 | 늘 |

- 묻는 방법: 말풍선의 "할까냥? 예/아니오" 또는 대화창 버튼. 음성으로 시킨 일은 한 단계 더 엄격하게 본다(받아 적기 오류가 있을 수 있으니 실행 전에 적은 글을 보여 준다).
- 빠른 길: 단순 명령(앱 열기, 타이머, 메모)은 Clef 객관식 분류와 정규식 인자 추출로 Codex 없이 2초 안에 실행한다. 나머지만 Codex로 보낸다.

**2-4 더 살아 있는 느낌** (선택)
- 고양이가 직접 말하는 것: `AVSpeechSynthesizer` 한국어 음성으로 말풍선을 읽는다(끌 수 있게).
- 대화가 이어지면 `codex exec resume`으로 세션을 이어 Codex 기본 지시문을 매번 다시 보내지 않게 할 수 있다(토큰 절약). 지금은 대화 12줄을 직접 넣는다.

### 정해야 할 것
- coding_task를 허용할 저장소 목록, 단축어 허용 목록
- 고양이가 소리 내 말하기를 기본으로 켤지

---

## 시키면 하기 · 되묻기 (2026-11-04 구현)

대화로 앱을 다루고, 애매하면 고양이가 되묻고, 코딩은 다른 에이전트에게 맡긴다. 코드: `brain/cat_mind.py`(답 형식·검사), `brain/code_tasks.py`(코딩 작업), `MindBridge.swift`(실행), `MindChat.swift`·`Dashboard.swift`(버튼·체크 상자·작업 탭).

### 답 형식에 더한 것 (`SCHEMA`)

| 필드 | 뜻 |
|---|---|
| `choices` | 보기 0~6개 (전엔 4개) |
| `multi` | 여러 개 골라도 되는 질문(하고 싶은 것 고르기·투표). 앱은 체크 상자와 "n개 고르기"로 보이고 `answer`에 "A, B", `answers`에 목록을 붙인다 |
| `actions` | 사용자가 시킨 일 0~3개 `{tool, arg, detail, agent}`. 대화 답에서만 쓰고, 먼저 말 걸 땐 빈 배열 |

### 되묻기

- 프롬프트 규칙: 말이 애매하거나 여러 뜻이면 짐작하지 말고 `ask`로 되묻는다. 보기가 있으면 `choices`, 여러 개 골라도 되면 `multi`.
- 대화 중 되물은 질문은 `inbox/mind-chat-*.json`(`followup: true`, 6시간)으로 간다. 먼저 묻는 질문 수 제한(`ask_open_max`)에 안 세고, 새로 되물으면 앞의 것은 지운다.
- 버튼(대화창·대시보드·고양이 메뉴)으로 답하면 cat_mind가 그 답으로 이어서 대답한다. 대화창에 글로 답하면 그 말이 질문의 답이 되고(`via: "chat"`), 그 말에는 평소처럼 답한다.
- 2026-11-04 실측: 대시보드에서 "코딩"을 고르자 8.7초 뒤 "오늘 저녁은 코딩이다냥…"으로 이어서 답했다.

### 시키면 하기 (`actions`)

cat_mind가 검사하고, 앱의 정해진 코드만 실행한다. 고양이 답은 창 제목처럼 남이 쓴 글을 보고 나오므로, 남의 글이 시킬 수 있는 위험한 일(낯선 주소 열기, 기록 끄기)은 사용자가 직접 한 말을 근거로만 바로 한다. 되물은 질문에 버튼으로 답한 경우 질문 글(고양이가 쓴 글)은 근거로 치지 않는다. 결과는 `mind/act/done/`으로 돌아와 대화 기록에 "(한 일) …"로 남는다(다음 답이 무엇을 했는지 안다).

| tool | 실행 | 검사 |
|---|---|---|
| `open_app` | 앱 목록(`AppIndex`)에서 Finder 이름·파일 이름이 같은 앱, 없으면 앞이 같은 앱 | 60자 이하, `/` 없음 |
| `open_url` | 기본 브라우저 | `https://호스트[:포트][/…]` 모양만(호스트 칸에 `@`·`\` 없음). 사용자가 한 말 속 도메인과 호스트 전체가 같거나 그 하위 주소가 아니면 "이거 할까냥?"을 먼저 묻는다. "유튜브"·"깃허브"처럼 이름으로 부른 사이트는 `SITE_NAMES`에 적힌 호스트만(하위 주소는 적은 것만) 같은 대우. 말에 있는 사이트여도, 호스트 뒤(경로·쿼리·`#`)를 `%xx`까지 다 풀고 `。`·`．` 같은 점 모양을 `.`로 바꾼 뒤 `.` `:` `@` `\` `//`나 redirect·/url·/amp 같은 넘겨주기 낱말이 있으면 묻는다(금지 주소 목록이 아니라, 다른 호스트를 적을 수 있는 글자를 막는다) |
| `command` | 앱이 `mind/commands.json`에 남긴 기능 (대시보드·탭, 런처, 클립보드, 리소스, 기록 멈추기·다시, 고양이 숨기기·재주 등) | 목록에 있는 id만. 종료·권한·삭제는 목록에 넣지 않았다. 기록 멈추기·고양이 숨기기는 말에 "멈·쉬·꺼·숨…"이 없으면 먼저 묻는다 |
| `timer` | N분 뒤 말풍선 | 0~1440분. 앱을 끄면 사라진다 |
| `todo` | `inbox/mind-todo-*.json` 확인할 일 (얼굴 옆 ! · 대시보드) | 비어 있지 않음 |
| `code` | 아래 코딩 작업 | 늘 먼저 묻는다 |

### 코딩 맡기기 (`code_tasks.py`)

1. `code`가 오면 바로 하지 않고 "🛠 <저장소>에서 이 일을 맡길까냥?"을 묻는다. 보기는 설치된 도구(고양이 추천을 맨 앞, 나머지는 `code_agents` 순서)와 "안 돼".
2. 도구를 고르면 저장소에 `meowgent/<id>` 브랜치로 worktree(`mind/tasks/<id>/wt`)를 만들고 그 안에서 CLI를 백그라운드로 돌린다. 실행 방식은 Agent Hub `agent-job.sh`와 같다.

| 도구 | 실행 |
|---|---|
| Claude Code | `claude -p … --output-format json --permission-mode acceptEdits` + 확인용 명령(`git diff/status/log`, `swift build`, `python3 -I`, `ls`)만 허용 |
| Codex | `codex exec --sandbox workspace-write -C <worktree> -o last.txt` (고양이 계정이 아니라 평소 `~/.codex`) |
| Cursor | `cursor-agent -p --trust --force --workspace <worktree>` |
| Grok | `grok -p … --always-approve --cwd <worktree>` |

   - **샌드박스**: Codex는 자체 `workspace-write`. Claude Code·Cursor·Grok은 자동 승인으로 돌아서 `sandbox-exec`로 감싼다.
     - 쓰기: worktree(그 안의 `.git` 연결 파일은 빼고)·임시 폴더·`~/Library/Caches`·도구가 대화 기록을 남기는 폴더(Cursor `~/.cursor/projects`·`chats`, Grok `~/.grok/sessions`·`logs`, Claude는 없음)만. 저장소 `.git`(hook·설정), `~/.gitconfig`, 도구 설정·hook·플러그인·스킬·실행 파일은 못 쓴다. 밖에서 다시 돌 때 실행되는 곳이라서다.
     - 읽기: `~/.ssh`·`~/.aws`·`~/.gnupg`·`~/.config/gh`·`~/.codex*` 같은 키 폴더와 Meowgent 데이터 폴더(활동 기록·대화)는 막는다. 데이터 폴더 안의 worktree와 그리로 가는 상위 폴더 목록만 연다. 저장소 코드와 나머지 파일 읽기, 인터넷(모델 API)은 막지 않는다. 키체인도 막지 않는다(도구 로그인에 쓴다).
     - 규칙 순서: 뒤에 온 같은 종류 규칙이 이긴다. `file-read-data`로 막은 것은 `file-read-data`로만 풀린다. 경로는 실제 경로로 풀어 쓴다(`/var` → `/private/var`).
   - **커밋 단계**(샌드박스 밖): 시작 때 기록한 git 폴더를 `GIT_DIR`·`GIT_WORK_TREE`로 못 박고, `core.hooksPath=/dev/null`·`core.fsmonitor=false`·`GIT_CONFIG_NOSYSTEM`·`--no-verify`로 돌린다. worktree의 `.git` 연결 파일이 시작 때와 다르면 커밋하지 않는다.
   - 확인 질문의 설명에 맡길 일 전체(1500자까지)를 보여 주고, 에이전트에게도 같은 글을 넘긴다.
   - 합치기는 사용자가 고른다. 합친 코드(빌드 스크립트·`.envrc` 등)는 그 뒤 사용자 환경에서 돌 수 있으니, 합치기 전에 브랜치를 보는 게 좋다.
   - 2026-11-04 실측: 샌드박스 안에서 `.git` 연결 파일·저장소 hook·worktree git 폴더·`~/.gitconfig`·`~/.claude`·`~/.grok` 설정 쓰기, `~/.ssh`·데이터 폴더 읽기가 모두 "Operation not permitted". 작업 폴더 안의 `git status`·읽기·쓰기는 된다. Claude Code는 홈에 아무것도 못 써도 작업을 끝냈다. Cursor는 `projects`, Grok은 `sessions`를 못 쓰면 시작을 못 해서 그 폴더만 열었다. 이 프로필로 진짜 세 도구가 동시에 파일 하나씩 만들어 커밋까지 끝냈고, 저장소에 심어 둔 pre-commit hook은 돌지 않았다.
3. 에이전트에겐 커밋·푸시·브랜치 바꾸기·되돌리기 어려운 일을 하지 말고, 끝에 "바꾼 것 / 확인한 것 / 확인 못 한 것"을 쓰라고 한다. 끝나면 cat_mind가 worktree에서 커밋하고 말풍선으로 요약한다.
4. 바뀐 파일이 있으면 "합치기 · 그대로 두기 · 버리기"를 묻는다. 합치기는 저장소가 시작 때 브랜치에 있고 커밋 안 한 변경이 없을 때만 `--no-ff`로 합친다. 충돌이면 되돌리고 브랜치를 남긴다. **푸시는 하지 않는다.**
5. 대시보드 "작업" 탭(⌘6): 하는 중·끝난 작업, 요약, 브랜치, 폴더 열기·기록 보기·멈추기(`mind/tasks/<id>/cancel`). 대화창 상태 줄에 "🛠 Claude Code · Meowgent 작업 중 · 3분째".

설정(`mind.json`): `code_repos`(이름→경로, 비면 `install.sh`가 남긴 이 저장소 하나), `code_agents`(보기 순서), `code_max_running`(2), `code_timeout_s`(3600).

- 2026-11-04 실측: 임시 저장소에서 진짜 Claude Code·Cursor·Grok으로 파일 하나 만들기 → 모두 끝, 커밋 1개씩, 요약 3줄. Codex는 플래그만 확인했고 실제로 돌려 보지 않았다.
- worktree엔 서브모듈(`pet/`)이 안 따라온다. Meowgent 저장소 작업은 `setup-pet.sh`가 빈 껍데기로 빌드한다.

### 아직 안 한 것

- 도구 고르는 우선순위(일 종류·남은 한도별). 지금은 고양이 추천 + 고정 순서이고, 사용자와 나중에 정한다.
- 빠른 길(Codex 없이 Clef·정규식으로 앱 열기·타이머), 단축어·미리 알림·음악, 음성으로 시킨 일 한 번 더 확인.
- 작업 결과를 다른 모델이 검토하기, 합친 뒤 푸시.
