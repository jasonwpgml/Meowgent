# 실시간 활동 수집기 + LLM 위키 설계 (v0.1, 2026-10-14)

> 맥에서 하는 모든 행동(앱·창 전환, 클릭한 버튼, 입력한 텍스트, 들어간 페이지, 활동량)을 로컬에서 실시간 수집하고,
> **Clef-flash**가 실시간으로 "지금 무슨 일을 하는지" 판단하고, **gemma4**가 주기적으로 위키를 정리해서
> 에이전트가 언제든 꺼내 쓰게 한다. 모든 데이터는 이 맥 밖으로 나가지 않는다.

---

## 0. 한눈에 보기

```
┌─────────────── Collector.app (Swift, 서명된 단일 앱, 모든 TCC 권한 보유) ───────────────┐
│ NSWorkspace  │ AXObserver      │ CGEventTap(listen-only) │ AppleScript │ Idle/Lock │
│ 앱 활성화     │ 창 제목·포커스   │ 키/클릭/스크롤 "횟수"     │ 브라우저 URL │ AFK       │
│              │ 입력창 값(한글)  │ + 클릭 위치 → AX 요소     │             │           │
└──────────────────────────────┬─────────────────────────────────────────────────┘
                               │ 프라이버시 필터 (차단 앱/도메인, 보안 필드, 시크릿 창) ← 디스크 기록 "전"
                               ▼
                 L0  raw events  (SQLite WAL, append-only)
                               │
        Worker (Python, TCC 권한 불필요, DB만 읽음)
                               ▼
                 L1  spans → episodes  (규칙 기반, LLM 없음)
                               │ 에피소드 종료 / 긴 에피소드는 60초마다
                               ▼
                 L2  Clef-flash  /v1/systemone  (~1~2초, 판단만)
                               │ → decisions 테이블 → now.md 를 "코드로" 즉시 렌더
                               ▼  30~60분마다 / 유휴 시
                 L3  gemma4:26b (Ollama)  → wiki/ 서술·패턴 분석 (출처 = episode id)
                               ▼
                 Agent: wiki 파일 직접 읽기 + MCP(get_now / timeline / search / project)
```

핵심 결정 5가지:
1. **수집은 손쉬운 사용(AX) 텍스트 중심**, 스크린샷은 AX가 비는 앱에만 쓰는 선택 기능 (실측 근거 §2).
2. **한글 입력은 키 이벤트가 아니라 입력창 값(AXValue)으로** 읽는다. 키 이벤트는 "활동량"으로만.
3. **Clef는 개별 이벤트가 아니라 "에피소드" 단위로** 판단한다. 질문은 한 요청에 묶는다.
4. **now.md는 LLM 생성이 아니라 Clef 판단 결과를 코드로 렌더** → 실시간이면서 환각 없음.
5. **권한은 서명된 Swift 앱 하나에 몰고**, LLM·분석은 권한 없는 별도 프로세스로 분리.

---

## 1. 목표 / 비목표

**목표**
- 실시간: 행동 후 수십 초 안에 "지금 무엇을, 어느 프로젝트에서, 얼마나 집중해서" 가 `now.md`·API에 반영
- 입력 텍스트 **내용까지** 저장 (채팅, 프롬프트, 문서 입력)
- 사후 분석 가능: 원본은 항상 남아서 나중에 다른 질문으로 재분석
- 에이전트(Claude Code, Codex, 로컬 에이전트)가 파일/MCP로 즉시 조회
- 저부하: 상시 CPU 수 % 이내, GPU는 판단 시에만

**비목표 (지금은)**
- 화면 녹화/영상 보관 (screenpipe·Rewind 류)
- 클라우드 동기화, 다중 기기
- Claude/Codex 대화 기록·git 수집 (이미 별도 수집 중 → 위키 단계에서 합류만)

---

## 2. 근거: 실측 + 조사

### 2.1 이 맥에서 Clef-flash 실측 (Q8_0, llama.cpp 0.6.0, `GGML_METAL_FUSION_DISABLE=1`)

| 테스트 | 결과 |
|---|---|
| 활동 구간 4개 × 질문 4개 (활동/프로젝트/집중도/전환) | 프로젝트 4/4 정답(sample-app 0.99), 활동 3/4 (PR 리뷰를 coding 0.43로 애매하게 — 신뢰도로 걸러짐), 맥락 전환 4/4 |
| 지연 (짧은 state) | 질문 1개 ≈ 0.40s, 질문 4개 ≈ 0.92s |
| 지연 (state ~800토큰, 질문 4개) | 1.4 ~ 2.0s, 같은 요청 반복해도 줄지 않음 (요청 간 접두 캐시 효과 없음) |
| 이미지 입력 | **`images` (또는 `files`) 필드에 data URL** 로만 동작. `image`/`media` 필드는 무시됨, state 안 content-part는 base64가 텍스트로 들어가 17k 토큰 초과 오류 |
| 합성 UI 이미지 | "GitHub PR 화면" 0.98 정답, 4.7s |
| **실제 화면 캡처** (896px JPEG ≈ 936토큰, 2.9s / 1280px ≈ 1472토큰, 5.0s) | 큰 맥락(AI 대화 중 0.73, 한국어 있음 0.96)은 맞음, **"어떤 앱인가"는 틀림(editor 0.43)** |

→ 결론: 텍스트(AX) 기반 판단은 실시간용으로 충분히 정확·빠름. 이미지는 대략적인 분위기만 잡고 3~5초라 상시 판단엔 부적합.

### 2.2 조사에서 가져온 교훈

| 출처 | 교훈 → 설계 반영 |
|---|---|
| **ActivityWatch** | 이벤트 = `{ts, duration, data}`, 같은 data의 heartbeat를 `pulsetime` 안에서 병합. AFK 구간과 교집합 후 집계 → §5 spans |
| **screenpipe** | 이벤트 트리거 캡처, AX 우선·OCR은 AX 빌 때만. Electron 앱에서 AX 트리가 비어 전체 OCR로 빠지며 CPU 147% (#3002). **입력 텍스트가 포커스 지연 때문에 엉뚱한 앱에 귀속** (#7580) → §4.6 타임스탬프 귀속 |
| **Shadow** (Swift) | CGEventTap + 클릭 위치 AX 요소(role/title/identifier), 보안 필드는 탭 단계에서 폐기, CPU <3% |
| **Dayflow** | 15분 배치로 LLM 요약 → 로컬 모델에선 호출 수 폭증·GPU 부담 → 우리는 Clef(판단)와 gemma(서술) 분리 |
| **MS Recall** | 정규식 PII 필터는 신용카드·비밀번호 목록을 놓침 → **앱/도메인 차단을 1차 방어**, 정규식은 2차 |
| **TypeSafe(Jev) 문서** | 질문은 한 요청에 묶기(13개 묶음 9.6배 빠름), 옵션엔 설명 필수, "기타" 옵션, 숫자는 코드에서 구간화해서 이름으로, state는 작게, **첫 옵션 편향** → 순서 고정 + 순열 테스트, confidence ≠ 정확도 → 내 데이터로 임계값 보정 |
| **TypeSafe Twitch 필터 쿡북** | 스트림 실시간 분류: 고정 맥락 + 항목 1개 + 질문 3개, 임계값은 코드에, (state, questions) 해시로 캐시 |
| **confidence routing 패턴** | 신뢰도 < 0.6 은 상위 모델로 에스컬레이션, 위험도별 임계값 |
| **llama.cpp #30064 / PR #30100** | Homebrew 0.6.0 Metal 퓨전 버그로 Clef Q8 확률이 평평해짐 → 업데이트 전까지 `GGML_METAL_FUSION_DISABLE=1` 필수 |
| 공백 지대 | Clef/Jev로 화면·활동을 분류하는 공개 프로젝트는 없음 (screenpipe의 Clef 연동 PR #7449는 미병합 종료) |

---

## 3. 구성 요소와 프로세스

| 프로세스 | 언어 | 역할 | 권한 |
|---|---|---|---|
| `Collector.app` | Swift (LSUIElement 메뉴바 앱) | L0 수집 + 프라이버시 필터 + SQLite 기록, 메뉴바에서 일시정지/상태 표시 | 손쉬운 사용, 입력 모니터링, 자동화(브라우저), (선택) 화면 기록 |
| `worker` | Python (uv) | L1 세션화, L2 Clef 호출, now.md 렌더, L3 gemma 위키 작업 스케줄 | 없음 (DB 읽기만) |
| `clef` | llama-server :8010 | 판단 | 없음 |
| `ollama` | gemma4:26b | 위키 서술 (필요할 때만 로드, `keep_alive: 0`) | 없음 |
| `wiki-mcp` | Python | 에이전트용 조회 API | 없음 |

**왜 Swift 단일 앱인가:** TCC 권한은 "책임 프로세스"의 실행 파일·서명에 묶인다. Swift 앱이 띄운 Python 자식은 권한을 물려받지 못하고(Apple 포럼 확인), ad-hoc 서명은 빌드마다 cdhash가 바뀌어 **설정에 체크는 돼 있는데 실제로는 권한이 사라지는** 문제가 생긴다. → Xcode의 무료 "Apple Development" 인증서로 서명, 번들 ID·경로 고정, `SMAppService`로 로그인 시 자동 실행.

**메모리 예산 (32GB):** Clef-flash ~10GB 상주 + Collector/Worker ~0.3GB. gemma4 (16GB)는 L3 작업 때만 올렸다 내림. 둘이 겹치는 순간 ~26GB라 L3는 유휴 시간 또는 사용자 확인 후 실행.

---

## 4. L0 수집기 상세

### 4.1 소스별 수집 방법

| 소스 | API | 트리거 | 기록 내용 |
|---|---|---|---|
| 앱 전환 | `NSWorkspace.didActivateApplicationNotification` | 이벤트 | bundle id, pid, 앱 이름 (Electron도 안정적 — AX로 앱 판별하지 말 것) |
| 창 제목 | `AXObserver`: `kAXFocusedWindowChangedNotification`, `kAXTitleChangedNotification` | 이벤트 | 창 제목, 문서 경로(`AXDocument`) |
| 클릭 대상 | CGEventTap(listen-only) mouseDown → **탭 밖 큐에서** `AXUIElementCopyElementAtPosition` | 클릭마다 | role/subrole/title/description/identifier, 가장 가까운 "누를 수 있는" 조상까지 올라감 → `button "Commit"` |
| 입력 텍스트 | `AXObserver`: `kAXFocusedUIElementChangedNotification` → 포커스 요소에 `kAXValueChangedNotification` | 값 변경 시 diff, **커밋**: Enter / 포커스 이동 / 1.5s 정지 | 커밋된 텍스트 조각 (한글 조합 완료 상태) |
| 키·마우스 활동량 | CGEventTap(listen-only) | 1분 집계 | 키 수, 클릭 수, 스크롤 양, 마우스 이동 거리 (내용·좌표는 저장 안 함) |
| 브라우저 URL | AppleScript (Chrome/Arc: `URL of active tab of front window`, Safari: `URL of front document`), 실패 시 AX `AXURL` | 앱/탭/제목 변경 시 | url, 페이지 제목, 시크릿 여부 |
| 유휴/잠금 | `CGEventSourceSecondsSinceLastEventType`, 화면 잠금·잠자기 알림 | 5s 폴링 + 이벤트 | AFK 상태 (경계는 마지막 입력 시각으로 소급) |
| 클립보드 (선택) | `NSPasteboard.changeCount` 폴링 | 변경 시 | 복사된 텍스트 앞 500자 (차단 앱에서 복사한 건 버림) |
| 스크린샷 (Phase 4, 선택) | ScreenCaptureKit 스틸 | AX 텍스트가 빈 앱에서 창 전환 시만 | 저장 안 함 → OCR/Clef 판단 후 폐기 |

### 4.2 한글 입력 처리 (가장 중요한 디테일)
- CGEventTap은 IME 이전 키(자모·영문 배열)만 본다 → **텍스트 복원에 쓰지 않는다.**
- 포커스된 입력 요소의 `AXValue`를 값 변경 알림마다 읽고, 직전 값과 diff 해서 "추가된 텍스트"를 누적.
- 조합 중(marked text) 상태가 섞이지 않게 **커밋 시점에만 기록**: Enter, 포커스 이동, 1.5초 입력 정지.
- 웹 콘텐츠는 알림이 입력창이 아닌 `AXWebArea`에서 오므로 **앱 요소 단위로 옵저버 등록**.
- 긴 문서 편집기(VS Code 등)는 `AXValue`가 파일 전체라 diff 비용이 큼 → 값 길이 > 20k면 `AXSelectedTextRange` 주변 ±500자만 diff.
- AX 값을 못 읽는 앱(일부 Electron·게임): 키 수만 기록하고 `text_unavailable` 표시.

### 4.3 Electron / Chromium 앱
- 앱 활성화 시 그 앱 요소에 `AXManualAccessibility = true` 설정 (문서화된 방법). 성능 영향이 있다고 Electron 문서가 경고하므로 **실제로 쓰는 앱에만, 처음 활성화될 때 1회**.
- 트리는 비동기로 만들어지므로 비어 있으면 1초 뒤 1회 재시도.
- 그래도 비면 그 앱은 "AX 불가 목록"에 올리고 OCR 폴백 후보로.

### 4.4 보안 입력과 비밀번호
- 역할이 `AXSecureTextField`인 요소의 값은 **절대 읽지 않음** (탭 단계에서 폐기).
- `IsSecureEventInputEnabled()` 를 폴링해 켜져 있으면 키 활동 수집 공백을 `secure_gap` 이벤트로 명시.
- 앱이 보안 입력을 놓지 않는 버그(2026 Cursor 사례)가 있어 공백이 길면 메뉴바에 경고 + 범인 PID 표시(`ioreg`의 `kCGSSessionSecureInputPID`).

### 4.5 이벤트 탭 안정성
- 탭 콜백에서는 **큐에 넣기만** 한다. AX 조회·DB 쓰기는 별도 큐.
- `kCGEventTapDisabledByTimeout` / `ByUserInput` 수신 시 즉시 재활성화 + 로그.
- AX 호출이 권한이 있어도 빈 값을 주는 경우가 있으므로(Timing 개발자 보고) 1분마다 헬스체크: `AXIsProcessTrusted()`, 최근 N분 AX 성공률 → 메뉴바 상태 아이콘.

### 4.6 귀속(attribution) 규칙
- screenpipe #7580 교훈: 이벤트 처리 시점의 "현재 포커스"로 귀속하면 틀린다.
- 모든 이벤트에 **발생 시각의 단조 시계 값**을 찍고, 앱/창 귀속은 L1에서 "그 시각에 활성이던 앱 스팬"으로 사후 결정.

### 4.7 프라이버시 필터 (디스크 기록 전)
1. 차단 앱: 비밀번호 관리자(1Password, 키체인 접근), 은행·증권 앱 → 해당 앱 활성 중 이벤트는 `{app, start, end}`만 남기고 내용 폐기
2. 차단 도메인: 은행, 결제, 의료 등 → URL·제목·입력 내용 폐기
3. 시크릿/비공개 창 → 전체 폐기
4. 정규식 마스킹 (2차): API 키·토큰 패턴(`sk-…`, `ghp_…`, JWT, AWS 키 등), 카드번호(Luhn), 주민번호 형태
5. 메뉴바 "일시정지 15분/1시간/수동 재개" + 전역 단축키

---

## 5. 저장 스키마 (SQLite WAL, `~/Library/Application Support/ActLog/actlog.db`, 권한 0600)

```sql
-- L0 원본 이벤트 (append-only)
CREATE TABLE events (
  id        INTEGER PRIMARY KEY,
  ts        REAL NOT NULL,          -- unix epoch (UTC)
  mono      INTEGER NOT NULL,       -- 단조 시계 ns, 순서·귀속용
  source    TEXT NOT NULL,          -- app|window|click|text|activity|browser|afk|clipboard|secure|health
  app       TEXT, pid INTEGER, window TEXT, url TEXT,
  payload   TEXT NOT NULL,          -- JSON (클릭: {role,title,id}, 텍스트: {field,text,commit_reason} …)
  privacy   TEXT NOT NULL DEFAULT 'none'  -- none|masked|blocked|secure_gap
);
CREATE INDEX events_ts ON events(ts);

-- L1 상태 스팬 (heartbeat 병합 결과)
CREATE TABLE spans (
  id INTEGER PRIMARY KEY, kind TEXT,          -- window|browser|afk|field
  start REAL, end REAL, key TEXT, data TEXT   -- key = 병합 기준 해시
);

-- L1 에피소드 (판단 단위)
CREATE TABLE episodes (
  id INTEGER PRIMARY KEY, start REAL, end REAL, status TEXT,   -- open|closed
  app TEXT, title TEXT, url TEXT, domain TEXT,
  summary TEXT        -- Clef에 넣은 압축 state(JSON) 그대로 보관 → 재현·재판단 가능
);

-- L2 판단 결과 (질문별 1행, 재판단 시 버전 추가)
CREATE TABLE decisions (
  episode_id INTEGER, ts REAL, qset_version TEXT, question TEXT,
  answer TEXT, confidence REAL, probs TEXT, model TEXT,
  PRIMARY KEY (episode_id, qset_version, question)
);

-- 사용자 교정 (보정·평가용 라벨)
CREATE TABLE labels (episode_id INTEGER, question TEXT, answer TEXT, ts REAL);

CREATE VIRTUAL TABLE text_fts USING fts5(text, content='', tokenize='trigram'); -- 한국어 부분일치 검색
```

**보존 정책:** 원본 입력 텍스트·클릭 14일 → 이후 에피소드 요약만, 에피소드·판단 180일, 위키 무기한. 용량 예상: 스크린샷 없이 하루 수십 MB 수준 (Shadow 보고 200~600MB/일은 영상 포함).

---

## 6. L1 세션화 (규칙 기반)

- **스팬:** ActivityWatch heartbeat 방식. 같은 `{app, window}`가 `pulsetime`(창 2s) 안에 다시 오면 기존 스팬 연장.
- **AFK 교집합:** 비-AFK 구간과 겹치는 부분만 활동으로 인정, 5초 이하 틈은 메움(flood).
- **에피소드 경계:**
  - 앱 또는 도메인 변경이 **20초 이상 유지**될 때 (Cmd-Tab 왔다갔다 흡수)
  - AFK 3분 이상, 화면 잠금, 잠자기
  - 같은 앱이라도 창 제목의 "프로젝트성 토큰"(레포명, 파일 경로 루트, 문서명)이 바뀔 때
- **긴 에피소드:** 열린 상태로 60초마다 "롤링 요약"을 만들어 L2에 보냄 → 실시간성 확보. 닫힐 때 최종 판단 1회.
- **에피소드 요약(state) 만들기 — Clef 입력은 작고 이름 붙인 값으로:**

```json
{
  "time": "14:30-14:52 (22분)",
  "app": "Code", "window": "collector/main.swift — actlog",
  "url": null, "domain": null,
  "clicks": ["menu 'Run'", "button 'Build'"],
  "typed": {"amount": "많음 (1,830자)", "samples": ["CGEvent.tapCreate(tap: .cgSessionEventTap", "…"]},
  "activity_level": "높음", "idle": "거의 없음", "switches": "없음",
  "previous": "14:21-14:30 Claude / 활동 수집기 설계 대화"
}
```
  - 숫자는 코드에서 구간화해 이름으로 (TypeSafe 권장: 숫자 비교는 모델이 약함)
  - 텍스트 샘플은 최근 커밋 3~5개, 각 200자 이내 → state 1k 토큰 이하 유지 (지연 1~2s)

---

## 7. L2 Clef 판단 레이어

### 7.1 서버
```bash
GGML_METAL_FUSION_DISABLE=1 llama-server -hf ggml-org/Clef-Flash-GGUF:Q8_0 \
  --port 8010 -c 8192 -b 8192 -ub 8192
```
- 이미 라우터용으로 같은 설정이 떠 있음 → **공유** (슬롯 4개). 라우터 요청과 경합 시 수집기 요청은 대기열로.
- 텍스트 전용이면 `-ub 8192`로 충분. 스크린샷 폴백을 켜면 이미지 ~1k 토큰 + state라 여유 있음.
- Homebrew가 PR #30100 포함 버전으로 올라오면 환경변수 제거 후 `decide.py`로 회귀 확인.

### 7.2 질문 세트 (한 요청에 묶음, 버전 관리: `qset_version`)

| id | 타입 | 내용 | 비고 |
|---|---|---|---|
| `activity` | choice | coding / agent_chat / reading / writing / communication / design / meeting / admin / leisure / other | 각 옵션 설명 필수 |
| `project` | choice | **위키 `projects/` 목록에서 동적 생성** + `none`(개인·잡무) + `other`(새 프로젝트일 수 있음) | 옵션 순서는 이름순 고정 (순서가 바뀌면 다른 질문) |
| `focus` | score | 산만함 → 보통 → 깊은 집중 | 낮은 것부터 |
| `switched` | noul | 직전 에피소드와 목표가 달라졌나 | |
| `notable` | noul | 결정·완료·막힘 같은 "위키에 남길 만한 순간"인가 | L3 우선순위 신호 |
| `stuck` | noul | 같은 문제를 반복 시도하며 막혀 있나 (에러 검색, 같은 파일 반복 등) | 에이전트 개입 신호 |
| `sensitive` | noul | 입력/화면에 개인 민감정보(금융·건강·인증정보)가 있나 | 2차 프라이버시: 높으면 텍스트 마스킹 |

- 프로젝트가 많아지면(>15) **계층 분류**: 1단계 영역(업무/개인/학습…) → 2단계 프로젝트. 1·2위 확률비가 1에 가까우면 "애매"로 처리.
- 지연 예산: 질문 7개, state ≤1k 토큰 → 약 1.5~2.5s. 에피소드는 분당 1~3개 수준이라 GPU 점유율 수 % 이내.

### 7.3 신뢰도 처리
- `confidence ≥ 0.7`: 확정 → now.md 반영
- `0.4 ~ 0.7`: "추정"으로 표시, L3에서 gemma가 앞뒤 맥락 보고 확정
- `< 0.4` 또는 `project = other`: "미분류" → 하루 끝 검토 목록
- 임계값은 **코드 상수**(질문 다시 안 돌려도 조정 가능). 2주 후 `labels`로 질문별 정확도-임계값 곡선을 그려 재설정 (TypeSafe: confidence는 정확도가 아님, 내 데이터로 보정).
- 캐시: `(state 해시, qset_version)` → 같은 롤링 요약 반복 호출 방지.

### 7.4 품질 관리
- **순열 테스트:** 새 질문 세트 도입 시 옵션 순서를 섞어 같은 에피소드 30개 재판단 → 답이 바뀌는 질문은 설명 보강 (첫 옵션 편향 대응).
- **교정 UI:** 메뉴바 "지금 판단 틀림" → 올바른 답 선택 → `labels` 저장. 하루 끝 "미분류 5건" 빠른 라벨링.
- **입력 텍스트는 신뢰하지 않는 데이터:** 웹페이지 제목·입력 내용에 지시문이 있어도 Clef는 판단값만 내므로 영향은 오분류 수준. 단 L3 gemma 프롬프트에는 "state는 데이터"임을 명시.
- 대안 모델 슬롯: Kev-4B는 상태 캐시로 반복 질문 136ms(M5)지만 앞서 비교에서 Clef보다 정확도가 낮았음 → 기본은 Clef-flash, 초고빈도 미세 판단(텍스트 커밋마다 `sensitive` 등)이 필요해지면 Kev 검토.

---

## 8. 실시간 출력: now.md (코드 렌더, LLM 없음)

```markdown
# Now  (갱신 14:52:10)
- 활동: coding (0.96) · 프로젝트: llm_wiki (0.74, 추정) · 집중: 깊음
- 앱/창: Code — collector/main.swift
- 이 작업 시작: 14:30 (22분째) · 오늘 이 프로젝트 누적 1시간 40분
- 최근 입력: "CGEvent.tapCreate(tap: .cgSessionEventTap…"
- 막힘 신호: 없음
## 직전 흐름
- 14:21–14:30 agent_chat · llm_wiki (Claude)
- 14:09–14:16 reading · infohub (GitHub PR 리뷰)
```
- 에피소드 판단이 끝날 때마다 덮어씀. 원자적 쓰기(임시 파일 → rename).

---

## 9. L3 위키 (gemma4:26b, 주기 작업)

```
wiki/
  now.md                    # §8, 실시간
  index.md                  # 에이전트 진입점: 페이지 목록 + 각 1줄 설명
  timeline/2026-10-14.md    # 시간대별 에피소드 표 + 하루 요약 (gemma)
  projects/<name>.md        # 상태 / 최근 한 일 / 결정 / 막힌 점 / 다음 할 일 (gemma, 고정 스키마)
  patterns.md               # 주간: 시간대별 집중도, 전환 빈도, 방해 요인 (코드 집계 + gemma 해석)
  inbox.md                  # 미분류·새 프로젝트 후보
```
- 실행: 30~60분마다 또는 AFK 10분 이상일 때. `notable`/`stuck` 에피소드 우선.
- 입력: 해당 기간 에피소드(요약+판단) + 기존 페이지 → 출력: 갱신된 페이지 전체. 문장마다 `[ep:1234]` 출처.
- 고정 섹션 스키마를 벗어나면 거부하고 재시도 (26B 모델 안정화).
- wiki/는 git 저장소 → 매 갱신 커밋 → 잘못되면 되돌리기, 변화 추적.
- 이미 별도로 수집 중인 Claude/Codex 대화·git 기록은 `projects/` 갱신 시 같은 기간 것을 함께 입력으로 합류.
- Ollama `keep_alive: 0` 으로 작업 후 즉시 언로드.

---

## 10. 에이전트 접근

1. **파일:** 전역 `~/.claude/CLAUDE.md`(및 Codex AGENTS.md)에 "작업 맥락: `~/wiki/index.md`, 현재 상황: `~/wiki/now.md`" 한 줄.
2. **MCP (`wiki-mcp`, 로컬 stdio):**
   - `get_now()` → now.md + 최근 에피소드 5개
   - `get_timeline(from, to, project?)` → 에피소드 + 판단
   - `search(query, days?)` → FTS (입력 텍스트·창 제목·URL) — **원본 텍스트 노출 범위는 설정으로 제한**
   - `get_project(name)` → projects 페이지
3. 쓰기는 MCP로 허용하지 않음 (에이전트가 위키를 오염시키지 않게). 메모 추가만 `add_note(text)` 별도 허용.

---

## 11. 위험과 대응

| 위험 | 대응 |
|---|---|
| Electron 앱 AX 트리 비어 CPU 폭증 (screenpipe #3002) | `AXManualAccessibility` 지연 설정, 실패 앱은 AX 불가 목록, OCR은 창 전환 시 1회만 |
| 입력이 엉뚱한 앱에 귀속 (#7580) | 단조 시계 타임스탬프 + L1 사후 귀속 (§4.6) |
| 다른 앱이 보안 입력을 안 놓아 키 수집 중단 | `secure_gap` 기록 + 메뉴바 경고 |
| 재빌드마다 권한 풀림 | Apple Development 서명, 번들 ID 고정, `codesign -d -r-` 확인 |
| 탭이 타임아웃으로 꺼짐 | 콜백 최소화 + 재활성화 |
| Clef Metal 버그로 확률 평평 | 환경변수, 업데이트 후 회귀 테스트 |
| Clef 첫 옵션 편향·한국어 정확도 저하 | 옵션 설명, 순서 고정, 순열 테스트, 라벨로 임계값 보정 |
| gemma 로드 시 메모리 부족 | L3는 유휴 시간에만, 실행 전 여유 메모리 확인 후 연기 |
| 민감정보 누출 | 차단 앱·도메인 1차, 보안 필드 미수집, 정규식 2차, Clef `sensitive` 3차, 보존 기간, 로컬 전용 |
| 남의 메시지(받은 채팅)까지 저장 | 입력 텍스트는 "내가 친 것"만 (포커스 입력창 diff), 화면의 받은 메시지는 수집 대상 아님 |

---

## 12. 단계별 구현 계획

| 단계 | 내용 | 완료 기준 |
|---|---|---|
| **P1 수집기** (2~3일) | Swift 메뉴바 앱: 앱/창/URL/AFK/활동량/클릭 AX/입력 텍스트(한글), 프라이버시 필터, SQLite, 헬스체크 | 하루 사용 후: 한글 입력이 조합 완료 상태로 저장, 비밀번호 필드 0건, CPU 평균 < 3% |
| **P2 실시간 판단** (2일) | Worker: spans/episodes, Clef 질문 세트, now.md, 교정 메뉴 | 행동 후 60초 안에 now.md 반영, 하루치 에피소드 수동 검수 정확도 측정 |
| **P3 위키 + MCP** (2일) | gemma 주기 작업, wiki git, wiki-mcp, CLAUDE.md 연결 | Claude Code에서 "지금 뭐 하고 있었지?"에 정확히 답함 |
| **P4 보강** | 라벨 기반 임계값 보정, 순열 테스트, OCR/Clef 비전 폴백(AX 불가 앱), 주간 패턴 리포트 | 미분류 비율 < 10% |

---

## 13. 결정이 필요한 것

1. **차단 앱/도메인 초기 목록** — 은행·증권·비밀번호 관리자 외에 빼고 싶은 것 (예: 특정 메신저 대화방)
2. **입력 텍스트 보존 기간** — 기본 14일 제안
3. **위키 위치** — `~/wiki` 제안 (Obsidian으로도 열 수 있게 일반 마크다운)
4. **Apple Development 인증서** — Xcode에 Apple ID 로그인 필요 (무료). 없으면 ad-hoc 서명 + 재빌드 시 권한 재부여로 시작 가능

---

## 출처
- ActivityWatch 이벤트·heartbeat: https://docs.activitywatch.net/en/latest/buckets-and-events.html , https://docs.activitywatch.net/en/latest/examples/working-with-data.html
- screenpipe 구조·이슈: https://docs.screenpipe.com/architecture , https://github.com/screenpipe/screenpipe/issues/3002 , https://github.com/screenpipe/screenpipe/issues/7580 , Clef 연동 PR https://github.com/screenpipe/screenpipe/pull/7449
- Shadow: https://github.com/ghostwright/shadow
- Dayflow: https://cdn.jsdelivr.net/gh/jerryzliu/dayflow@main/README.md
- MS Recall 필터 한계: https://www.tomsguide.com/computing/windows-operating-systems/microsoft-recall-caught-capturing-credit-card-and-social-security-numbers-despite-reassurances-it-wont
- Input Monitoring/탭 권한: https://developer.apple.com/forums/thread/707680 , 보안 입력 누수: https://forum.cursor.com/t/cursor-leaks-secure-event-input-breaks-all-system-wide-input-taps-until-quit-or-screen-lock/167585
- Electron AXManualAccessibility: https://docs.w3cub.com/electron/tutorial/accessibility
- TCC·서명: https://docs.openclaw.ai/platforms/mac/signing.md , https://developer.apple.com/forums/thread/805245
- Clef: https://blog.cloudflare.com/clef-decision-models/ , llama.cpp server README(systemone, files/images), Metal 버그 https://github.com/ggml-org/llama.cpp/issues/30064 , https://github.com/ggml-org/llama.cpp/pull/30100
- TypeSafe(Jev) 문서: https://docs.typesafe.ai/primitives , https://docs.typesafe.ai/confidence , https://docs.typesafe.ai/patterns/confidence-routing.md , https://docs.typesafe.ai/cookbooks/twitch_chat_filter.md , https://docs.typesafe.ai/cookbooks/hierarchical_classification.md
- Kev 상태 캐시: https://github.com/jaredpalmer/kev
- 로컬 결정 모델 벤치: https://akitaonrails.com/en/2026/10/10/which-jev-like-ai-decision-classifier-model-is-best/
