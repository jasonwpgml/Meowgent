# Meowgent

맥 화면 위에 사는 도트 고양이. 타자를 치면 옆에서 노트북을 두드리고, Claude Code·Codex가 답을 끝내면 알려 주고, 사용량 한도와 리셋권을 대신 챙긴다. 켜 두면(옵트인) 맥에서 한 행동을 로컬에 기록해 "지금 무슨 일을 하는지"를 판단한다. 기록은 이 맥 밖으로 나가지 않는다. 말하는 고양이(선택)를 켜면 그때만 활동 요약을 사용자의 Codex 계정으로 보낸다([docs/CAT_MIND.md](docs/CAT_MIND.md)).

- 번들 ID `io.github.jasonwpgml.meowgent` · 실행 파일 `Meowgent.app` · macOS 14+
- 상시 비용: CPU 평균 0.3% 안팎(사용 중 중앙값 1.2%), 메모리 35MB (2026-10-25 실측)

## 구성

| 조각 | 위치 | 언어 | 역할 | 없어도 되나 |
|---|---|---|---|---|
| 앱 (수집기 + 고양이) | `collector/` | Swift | 메뉴바 앱. 행동 기록, 프라이버시 필터, SQLite 저장, 고양이 오버레이, 에이전트 로그 감시, 한도 알림, 단축키 힌트 | 본체 |
| brain | `brain/` | Python (표준 라이브러리만) | 기록을 작업 구간으로 묶어 Clef에 판단을 묻고 `now.md`·타임라인을 쓴다 | 없으면 고양이가 "판단기는 꺼져 있다"고 말할 뿐 |
| 말하는 고양이 | `brain/cat_mind.py` | Python (표준 라이브러리만) | 평소엔 규칙만 돌다가 일이 생기면 Clef에 말 걸지 묻고, 통과하면 고양이 전용 Codex 계정으로 말을 받아 온다 | 없으면 고양이가 말을 안 할 뿐 |
| Clef 판단 서버 | `tools/install_clef.sh` | llama-server | 구간마다 활동·프로젝트·집중도 분류 (GPU 3초, 메모리 6.4GB 상주) | 없어도 됨. GPU 없는 기기엔 넣지 않는다 |

앱 안에서 수집기와 고양이는 폴더로 나뉘어 있다. `collector/Sources/ActLog/`가 수집기(앱 전환·입력 텍스트·브라우저·클릭·클립보드·시스템 상태·저장), `collector/Sources/ActLog/Pet/`가 고양이(행동·물리·그리기·장난감·일과·알림·한도 규칙)다. 둘은 `main.swift`의 클로저 몇 개로만 연결된다.

## 저장소 구조

이 저장소(공개 예정)에는 수집기·brain·프라이버시 규칙이 있고, 고양이 코드와 원화는 비공개 저장소 `meowgent-pet`을 `pet/` 서브모듈로 끌어온다.

```
collector/        Swift 패키지. build.sh(개발 설치) · bundle.sh · release.sh(배포본) · setup-pet.sh(Pet 링크)
  Sources/ActLog/ 수집기 + AgentMonitor·QuotaWatch·QuotaRules·Journal (약 3,300줄, 공개)
  Sources/ActLog/Pet  → 심볼릭 링크 (setup-pet.sh 가 만든다): pet/Sources 또는 PetStub/Sources
  PetStub/        고양이 저장소가 없을 때 쓰는 빈 껍데기 PetController (고양이 없이 수집기만)
  Tests/          순수 로직 테스트 (한글 diff·마스킹·검색어·단축키 규칙·한도 규칙, pet 있으면 지형 계산도)
pet/              [서브모듈, 비공개] 고양이 행동·물리·그리기 약 5,300줄, 원화, CAT_MOTION·CAT_VOICE, 원화 잠금 도구
brain/            actlog_brain.py · cat_mind.py(말하는 고양이) · install.sh(launchd) · mind_setup.sh · test_brain.py · test_mind.py
assets/fonts/     갈무리11 (OFL)
assets/vendor/    Last tick 팩 (재배포 금지, git에 없음, 개발 빌드 전용)
assets/original-cat → pet/assets/original-cat 링크 (그림 작업 스크립트 호환용, git에 없음)
tools/            기록 보기(actlog_tail.py), Clef 설치, 아이콘 생성
docs/             아래 "문서" 참고. 고양이 쪽 문서·시제품·비교 이미지는 pet/docs (비공개)
```

고양이 저장소 없이 받았을 때: `collector/setup-pet.sh`가 자동으로 PetStub을 잇는다. 빌드는 되지만 고양이는 안 뜬다. 접근 권한이 있으면 `git submodule update --init`.

## 빠른 시작 (개발)

```bash
cd collector && ./build.sh        # swift build → ~/Applications/Meowgent.app 설치·실행
./Tests/run_logic.sh              # 로직 테스트
cd ../brain && ./install.sh       # (선택) brain 을 launchd 에 등록
../tools/install_clef.sh          # (선택) Clef 서버. GPU 있는 맥만
```

처음 실행하면 "고양이만 / 활동 기록도 켜기"를 묻는다. 기본은 고양이만이고 이때는 아무것도 저장하지 않는다. 기록을 켜면 macOS가 손쉬운 사용·입력 모니터링 권한을 묻는다. 무엇을 기록하고 무엇을 기록하지 않는지는 [collector/README.md](collector/README.md)에 표로 있다.

키체인에 "ActLog Local Signing" 자체 서명 인증서가 있으면 다시 빌드해도 권한이 유지된다. 없으면 임시 서명이라 빌드마다 권한을 다시 켜야 한다.

## 데이터 위치

`~/Library/Application Support/Meowgent/` (옛 `ActLog`는 같은 곳을 가리키는 심볼릭 링크)

| 파일 | 내용 |
|---|---|
| `actlog.db` | 원본 이벤트 (SQLite WAL, 0600) |
| `mind/` | 말하는 고양이 설정·대화·기억 (docs/CAT_MIND.md) |
| `brain.db`, `wiki/now.md`, `wiki/timeline/` | brain 판단 결과 |
| `config.json` | 차단 앱·도메인 추가분, 텍스트 커밋 간격 등 |
| `shortcuts.json`, `notices.jsonl`, `memos.jsonl`, `feedback.jsonl`, `reset_passes.json` | 단축키 힌트 기록, 고양이 알림·메모·피드백, 직접 적은 리셋권 |
| `actlog.log` | 앱 로그 (5MB 넘으면 교체) |

말하는 고양이를 켜지 않았다면 외부 통신은 날씨 하나뿐이다. 고양이 햇살과 창밖 날씨를 위해 30분마다 Open-Meteo에 좌표(소수 한 자리)만 보낸다. `defaults write io.github.jasonwpgml.meowgent petWeather -bool false`로 끈다.

## 배포와 공개 범위

- 배포 절차는 [docs/RELEASE.md](docs/RELEASE.md). `collector/release.sh`가 임시 서명 zip 또는 Developer ID DMG(공증)를 만든다. 배포본엔 원화·갈무리 글꼴·`LICENSES.md`만 들어가고 팩 그림·brain·Clef·tools는 빠진다.
- 공개 범위 (2026-10-25 결정): **수집기·프라이버시 필터·저장·brain은 공개, 고양이(`pet/`)·원화·행동/말투 문서는 비공개.** 사용자 데이터를 만지는 부분은 코드로 검증할 수 있게 열고, 고양이의 행동과 그림은 가린다. 배포 바이너리는 둘을 합쳐 빌드하고 심볼을 뗀다. 원화는 번들에 PNG 로 들어가지 않고 `.sprite`(AES-GCM)로 잠겨 들어간다. 화면 스크린샷으로 픽셀을 복원하는 것까지는 막지 못한다.
- **이 저장소의 git 이력에는 분리 전 고양이 코드와 원화가 남아 있다.** 공개 저장소는 이 이력을 그대로 올리지 말고, 분리 이후 커밋만 남긴 사본(`git filter-repo` 또는 새 저장소에 스쿼시)으로 만든다. 절차는 docs/RELEASE.md.
- 윈도우 이식은 설계서만 있다: [docs/WINDOWS_PORT.md](docs/WINDOWS_PORT.md). 지금 코드는 전부 맥 API(손쉬운 사용, CGEventTap, NSPanel, launchd)라 윈도우에선 돌지 않는다.

## 문서

| 문서 | 내용 |
|---|---|
| [collector/README.md](collector/README.md) | 앱 사용법, 기록하는 것/안 하는 것, 권한, 데이터 |
| [docs/RELEASE.md](docs/RELEASE.md) | 배포 절차, 공증, 공개 전 체크리스트 |
| [docs/WINDOWS_PORT.md](docs/WINDOWS_PORT.md) | 윈도우 이식 모듈 대응표·스택 비교·단계 |
| [docs/REMINDERS.md](docs/REMINDERS.md) | 한도·리셋권, 맥 상태(CPU·메모리·발열·에너지) 알림 규칙과 피로 줄이기 근거 |
| [docs/SHORTCUT_HINTS.md](docs/SHORTCUT_HINTS.md) | 단축키 힌트 조사와 규칙 |
| `pet/docs/CAT_MOTION.md` | 고양이다운 자세·움직임 기준 (비공개 저장소) |
| `pet/docs/CAT_VOICE.md` | 고양이 말투·성격 기준 (비공개 저장소) |
| [docs/CAT_MIND.md](docs/CAT_MIND.md) | 말하는 고양이: 루프·Clef 문지기·Codex, 밖으로 나가는 것, 대화창·음성·실행 계획 |
| [docs/RESEARCH.md](docs/RESEARCH.md) | 시작 전 조사: 오버레이 방식, 그림, 말 거는 규칙 |
| [DESIGN.md](DESIGN.md) | 2026-10-14 원래 설계. L3 위키·MCP는 만들지 않았고 지금 구조는 이 README가 정본 |

## 라이선스

이 저장소(수집기·프라이버시 필터·저장·brain·문서)는 [Apache License 2.0](LICENSE)이다. © 2026 JSonJh (https://github.com/jasonwpgml). 가져다 쓸 때는 LICENSE와 NOTICE의 저작권·출처 표기를 남겨야 한다.
고양이(`pet/` 서브모듈: 행동·말투·원화)는 이 라이선스에 포함되지 않는 비공개 저작물이며, 배포 앱 안에만 컴파일·암호화된 형태로 들어간다. 들어 있거나 참고한 외부 저작물(갈무리11 OFL, WindowPet·DesktopPetMac MIT, mmar/Cat 0BSD, 참고 사진 저작자)은 [collector/LICENSES.md](collector/LICENSES.md)에 있고 앱 메뉴 "Meowgent 정보 › 라이선스 보기"로도 열린다.
