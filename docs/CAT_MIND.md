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
