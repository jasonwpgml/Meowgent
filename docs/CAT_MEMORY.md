# 말하는 고양이 기억 설계 (계획, 2026-10-28)

목표: 고양이 프롬프트를 일정 크기 아래로 유지하면서 맥락을 이어 간다. 대화가 끝나면 원문은 내려놓되 다음 세 가지는 남긴다. 더 필요할 때는 AND에서 받아 온다.

1. 기본 성격 (`brain/persona.md`)
2. 사용자에 대한 정보
3. 직전 대화와 그 이전 맥락

지금 상태 (2026-10-29): 1단계(Meowgent만)를 만들었다. 대화 원문은 AI Archive Hub를 거쳐 AND에 쌓는다. 맥 쪽은 끝났고 데탑 허브에 파서를 넣는 일이 남았다(아래 "원문을 AND로").

## 조사 요약

| 무엇 | 배울 점 |
|---|---|
| Letta(MemGPT) | 항상 넣는 core 기억과 도구로 찾아오는 recall·archival 기억을 나눈다. 대화가 끝난 뒤 백그라운드로 정리한다("dreaming") |
| mem0 (2026-04 개편) | 사실을 덮어쓰지 않고 추가만 한다. 덮어쓰면 "예전엔 A, 지금은 B" 같은 정보가 사라지기 때문이다 |
| Zep/Graphiti | 바뀐 사실은 지우지 않고 `invalid_at`만 찍는다 |
| LangMem | 사실(semantic) · 대화 요약(episodic) · 규칙(procedural)을 나눈다. 대화가 끝난 뒤 따로 정리한다 |
| ChatGPT · Claude 앱 | 대화하면서, 또는 백그라운드에서 기억을 만든다. 사용자가 보고 고치고 지울 수 있다 |
| LongMemEval (논문) | 모든 걸 사실로만 압축하면 정보를 잃는다. 대화 원문은 검색용으로 남기고, 뽑은 사실은 검색 키로 덧붙인다 |
| 기억 오염 (MINJA, OWASP 2026 ASI06) | 웹·파일·창 제목에 섞인 지시가 기억에 들어가면 다음 대화까지 남는다. 사실은 사용자가 직접 쓴 말에서만 뽑는다 |

출처: docs.letta.com/configuration/memory · mem0.ai/blog/mem0-the-token-efficient-memory-algorithm · arxiv 2501.13956(Zep) · 2410.10813(LongMemEval) · 2402.17753(LoCoMo) · 2308.15022(재귀 요약) · 2304.03442(Generative Agents) · 2601.05504(기억 오염) · support.claude.com/en/articles/11817273

## 설계: 층마다 예산을 둔다

부를 때마다 Codex 기본 지시문으로 약 1만 1천 토큰이 고정으로 든다. 그 위에 얹는 고양이 프롬프트를 아래 예산으로 묶는다. 합계는 5~6천 토큰이고, 허락받아 가져오는 자료는 한 번에 1,500자를 넘지 않는다.

| 층 | 내용 | 예산 | 어디서 |
|---|---|---|---|
| L0 성격 | `persona.md` + 규칙. 자동 정리로는 바꾸지 않는다 | ~800 | Meowgent |
| L1 사용자 | 한 줄 사실 30~40개. 사실마다 `id`, `since`, `source`(어느 대화), `valid_to`를 단다 | ≤1,000 | Meowgent `mind/facts.json` |
| L2 이어지는 맥락 | 최근 대화 요약 3개 + 열린 일(약속, 나중에 하기로 한 것) | ≤800 | Meowgent `mind/episodes.jsonl` |
| L3 이번 대화 | 최근 10턴 원문 + 그보다 앞선 부분의 누적 요약 | ≤2,500 | Meowgent |
| L4 미리 찾기 | 사용자 말과 관련된 지난 대화 요약·사실 3개 (로컬 FTS5, 모델 호출 없음) | ≤600 | Meowgent `mind/memory.db` |
| L5 안내 | 더 찾을 수 있는 곳의 목록 (`need`의 `memory`·`and`) | ≤150 | 고정 |
| 필요할 때 | `need: memory`는 지난 대화 원문 검색, `need: and`는 AND 질의 | ≤1,500자 | 허락 후 |

넘치면 L1은 중요도 × 최근성 × 쓰인 횟수가 낮은 것부터 보관함으로 내린다. L3은 누적 요약을 늘리고 원문 턴을 줄인다. L0은 절대 자르지 않는다.

`need: memory`는 맥 안에서 끝나므로 허락 없이 바로 다시 답해도 된다. 다만 `need` 왕복은 Codex를 한 번 더 부르는 것이다. 그래서 싼 검색은 L4에서 미리 해서 넣고, `need`는 깊이 찾을 때만 쓴다.

## 대화가 끝나면 (30분 무응답)

답하는 길이 아니라 백그라운드에서 luna·low로 한 번 부른다.

1. **대화 기록**: 날짜, 주제, 150토큰 이내 요약, 열린 일. 원문은 `conversation.jsonl`에 그대로 두고 검색용으로 색인한다.
2. **사실 후보**: ADD 또는 SUPERSEDE. 근거가 된 사용자 말과 턴 id를 함께 남긴다. 옛 사실은 지우지 않고 `valid_to`만 찍는다. "이번 주 바쁨" 같은 상태는 `expires_at`을 단다.
3. **말투 지적**: "그렇게 부르지 마" 같은 직접 지적만 남긴다. 성격이나 규칙에 넣기 전에 사용자 승인을 받는다.

규칙은 세 가지다.
- 사실은 사용자가 직접 쓴 턴에서만 뽑는다. 고양이 말, 웹, 파일, 창 제목에서는 뽑지 않는다.
- "항상 ~해라" 같은 명령형 사실은 사용자가 "기억해"라고 했을 때만 남긴다.
- 비밀번호·키는 저장하지 않는다. 건강·금융은 묻고 저장한다.

**밤마다 정리**: 겹치는 사실을 합친다. 7일 지난 대화 요약은 주간 요약으로, 더 오래된 것은 월간 요약으로 접는다. 만료된 상태는 내린다.

## AND 연결

### 지금 AND에 있는 것 (2026-10-28 조사, 데탑 main efb17e3)

- 확인된 사용자 claim 31개(belief, preference, personal_fact, experience, skill). `wiki/people/owner.md`는 아직 없다.
- `neurodrive search` (FTS5, claim·세션·작업 기록·허브 메시지), `neurodrive ask` (로컬 Ollama 답 + 근거), `neurodrive mcp` (search · ask · get_session · timeline · propose). 모두 데탑에서만 돌고, 맥에는 등록돼 있지 않다.
- AI Archive Hub MCP(`search_sessions`, `get_session`)는 맥에서 지금 바로 쓸 수 있다.
- `conversation_sessions`(세션 요약)는 테이블만 있고 0행이다. 검색 색인은 10-26 이후 다시 만들지 않았다. 임베딩도 0개다.
- 맥 클론(`~/dev/ai/autonomous-neuro-drive`)은 뒤처져 있고 `data/`가 없다.

### 걸리는 것: 개인정보 규칙

AND 규칙은 기본이 `local_only`다. 원격 LLM으로 보내는 건 ADR-0013의 승인 범위(Claude CLI, spare-quota)만 허용된다. `sensitive`(건강, 금융, 관계)는 외부 전송 금지다. 그런데 고양이는 프롬프트를 Codex(OpenAI)로 보낸다. 그래서 **AND 내용을 고양이 프롬프트에 넣으려면 새 ADR과 사용자 결정이 먼저 필요하다.**

제안:
- 원문(claim, 허브 대화, 위키)은 보내지 않는다.
- 데탑 로컬 모델이 질문에 맞춰 만든 짧은 답(1,500자 이하, `sensitive` 제외)만 보낸다.
- 요청마다 허락받는다. `need: and`는 "이번만"과 "항상" 중에 고를 수 있게 한다.

### AND에 필요한 것

| # | 무엇 | 어디에 맞나 |
|---|---|---|
| A1 | ADR: "Meowgent 고양이 질의". 목적·장치·보낼 수 있는 것(로컬 모델이 만든 답만)·한도를 정한다 | ADR-0013 확장 |
| A2 | `sensitive` 등급 구현. 이게 없으면 A3·A4에서 거를 수 없다 | ADR-0016 §4 |
| A3 | `profile(max_chars)`: 확인된 소유자 claim으로 짧은 프로필을 결정적으로 만든다(`sensitive` 제외) | ADR-0016 + ADR-0021 F의 MCP·CLI |
| A4 | 고양이용 질의 명령 하나: `neurodrive ask --max-chars 1500 --exclude-sensitive --json`. 맥은 `ssh desk`로 이것만 부른다(허용 명령 하나) | `serve.py` / CLI |
| A5 | 최신으로 유지: `rebuild-search-index` 예약 작업, `summarize_session` 실제 실행 (지금 0행) | 데탑 예약 작업 |
| A6 | 되돌려 쓰기: 고양이 대화 요약·사실 후보를 AND 후보 큐(`learning_inbox_items`/inbox 제안)로 보내 승인받는다. claim 직접 쓰기는 ADR-0021 §2.4가 금지한다. 새 수집원이라 ADR이 따로 필요하다 | ADR-0010 / 0021 E |

고양이 Codex 세션 기록은 하루 뒤 지운다. 그래서 허브(`~/.codex/sessions`)를 거쳐 AND로 들어가는 길은 쓰지 않는다. 쓰려면 A6처럼 직접 보낸다.

데탑이 꺼져 있거나 ssh가 안 되면 고양이는 AND 없이 L0~L4로만 답한다.

## 단계

| 단계 | 내용 | AND 필요 |
|---|---|---|
| 1 ✅ | Meowgent만: `facts.json` · 대화 끝 정리 · `episodes.jsonl` · L3 누적 요약 · L4 미리 찾기 · 층별 예산 · `need: memory` · 말투 규칙 · 원문 내보내기 · 테스트 | 아니오 |
| 2 | 평가 세트: LongMemEval의 다섯 능력(추출, 여러 대화에 걸친 추론, 시간, 바뀐 사실, 모르면 모른다)으로 30문항. 기억 끔 / 전체 기록 / 이 설계를 비교 | 아니오 |
| 3 | AND 읽기: A1~A5 + Meowgent `need: and` | 예 |
| 4 | AND 쓰기: A6 | 예 |
| 5 | 대화창에 "기억" 화면: 보기·고치기·잊기·잠깐 끄기 | 아니오 |

## 1단계에서 만든 것 (2026-10-29)

계획과 다른 점: L4는 FTS5 대신 글자 두 개씩 겹치는 비율로 찾는다. 기록이 수백 개 수준이라 색인 없이 충분하고, 한국어 조사·띄어쓰기에 덜 민감하다. 나중에 느려지면 FTS5 trigram으로 바꾼다.

- **층별 예산**: `mind.json`의 `budget`(글자 수). facts 1,500 · recent 1,200 · prefetch 900 · session 4,000 · recall 1,500.
- **L3 누적 요약**: 대화 답 JSON에 `note`를 받는다. 따로 부르지 않고 답할 때 같이 쓴다. 이번 대화가 10턴을 넘으면 앞부분은 `note`로만 들어간다.
- **대화 끝 정리** (`start_digest`, 30분 무응답 뒤 Codex가 쉬고 있을 때): luna·low가 `DIGEST_SCHEMA`(요약, 주제, 남은 일, 사실 후보, 말투 지적)로 답한다. 처음 실행하면 이틀 치까지만 거슬러 정리한다. 실패하면 10분 뒤 다시 한다.
- **받는 규칙** (`Memory.apply_digest`): 근거(`evidence`)가 그 대화의 사용자 말에 글자 그대로 있어야 한다. 사용자가 "기억"이라고 하지 않았는데 들어온 명령형 사실("항상 ~해라")은 버린다. 숫자 6자리 이상·키·비밀번호가 들어간 사실도 버린다. 같은 사실이 이미 있으면 넣지 않는다. 바뀐 사실은 옛 것에 `valid_to`를 찍는다.
- **말투 지적**: 근거가 맞으면 "🗒 말투 규칙으로 남길까냥?"(남겨 / 됐어)을 묻는다. 남기면 `rules.json`에 들어가 L0 바로 아래에 붙는다.
- **`need: memory`**: 맥 안에서 찾으므로 묻지 않고 바로 다시 답한다. 찾는 범위는 옛 요약 전부, 끝난 사실, 이번 대화 전의 원문이다. 최대 8개, 1,500자.
- **원문**: 끝난 대화는 `transcripts/`에 파일 하나로 쓴다. Codex 한도와 상관없이 1분마다 내보낸다. 맥에는 30일만 둔다.
- **대화창**: 최근 7일 안에서 60개까지만 보여 준다. 말풍선마다 시각이 붙고, 오늘이 아니면 날짜도 붙는다. 잘렸으면 맨 위에 "더 지난 대화는 AND(AI Archive Hub)에 있다냥"이 뜬다.

### 원문을 AND로

맥의 AI Archive Hub push(`com.ai-archive-hub.push`)는 이 맥의 Claude·Codex 세션을 데탑 허브로 보낸다. 허브는 도구마다 파서가 있다. 데탑 AND는 허브 메시지를 `search_index`의 `hub_message`로 찾는다. 그래서 허브에 `meowgent` 도구를 더하면 고양이 대화 원문이 AND 검색에 들어간다.

- 필요한 변경: 허브 `src/aihub/sources/meowgent.py`(파서), `sources/__init__.py`(등록), `config.py`(`Source("meowgent", ~/Library/Application Support/Meowgent/mind/transcripts)`), 테스트. 맥 클론에서 테스트까지 통과시켰다.
- **순서가 중요하다.** 데탑 허브의 `receive`는 모르는 도구가 든 묶음을 통째로 거절한다. 맥이 먼저 `meowgent`를 보내면 Claude·Codex 세션 push까지 막힌다. 그래서 데탑 저장소(`D:\Projects\ai-archive-hub`, GitHub origin)에 먼저 넣고, 그다음 맥 config에 Source를 더한다. 맥 클론은 데탑보다 뒤처져 있고 remote가 없다.
- push 트리거(`WatchPaths`)에 `transcripts/`를 더하면 바로바로 간다. 더하지 않아도 Claude·Codex 세션이 바뀔 때 같이 간다.

## 정할 것

- AND 내용을 OpenAI로 보내도 되는가. 제안은 "로컬 모델이 만든 짧은 답만, 요청마다 허락"이다.
- AND 쪽 작업(A1~A6)을 어디서 할 것인가. 데탑 세션에서 AND 재구조화가 진행 중이니 거기서 하는 게 맞다.
