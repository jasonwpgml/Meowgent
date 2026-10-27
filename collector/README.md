# Meowgent 앱 (수집기 + 고양이)

메뉴바에 떠 있으면서 고양이를 띄우고, 켜 두면 맥에서 하는 행동을 기록하는 앱. 번들 ID `io.github.jasonwpgml.meowgent`. 전체 설계는 [../DESIGN.md](../DESIGN.md).

## 활동 기록은 옵트인

처음 실행하면 "고양이만 / 활동 기록도 켜기"를 묻는다. 기본은 고양이만이고, 이때는 아래 표의 어떤 것도 저장하지 않는다 (고양이·단축키 힌트·사용량 리마인드는 동작).
메뉴바 › "활동 기록 켜기" / "활동 기록 끄기 (고양이만)"으로 바꾸며, 설정은 `recordingEnabled`(UserDefaults)에 남는다. 이미 기록이 있던 설치는 켠 상태를 유지한다.

## 무엇을 기록하나 (켰을 때)

| 종류 (`source`) | 내용 | 언제 |
|---|---|---|
| `app` | 앞에 나온 앱 | 앱 전환 |
| `window` | 창 제목, 문서 경로 | 창·제목 변경 |
| `browser` | 페이지 주소, 제목 (Chrome·Arc·Brave·Edge·Whale·Safari) | 탭·주소 변경, 5초마다 확인 |
| `search` | 검색어 (구글·네이버·다음·유튜브·깃허브 등) | 검색 결과 페이지 진입 |
| `text` | 입력한 글 (한글은 조합 완료된 상태로). AI에게 보낸 질문은 `kind: ai_prompt`, 붙여넣은 글이 섞이면 `pasted_chars` | Enter, 입력창 이동, 8초 멈춤 (AI 대화창은 Enter·이동 때만) |
| `ai_response` | AI 답변 (웹의 Gemini·구글 AI 모드·ChatGPT·Claude 등). 데스크톱 앱 답변은 기본 제외(AI hub가 수집) | 질문 후 답변이 다 나왔을 때 |
| `click` | 누른 버튼·링크·메뉴 이름 | 클릭 |
| `activity` | 1분간 키·클릭·스크롤 횟수, 마우스 이동 거리 | 1분마다 |
| `afk` | 자리 비움(3분 무입력), 화면 잠금, 잠자기 | 상태 변화 |
| `clipboard` | 복사한 글 (앞 5000자) | 복사 |
| `paste` | 붙여넣은 내용 + 붙여넣은 곳(앱·창·주소·입력창) | Cmd+V |
| `secure` | 다른 앱이 보안 입력을 켜서 키 횟수를 못 세는 구간 | 상태 변화 |
| `health` | 권한·탭 상태, DB 크기 | 1분마다 |

단축키 힌트용 기록은 DB가 아니라 `shortcuts.json`에 따로 둔다: 마우스로 한 동작(예: Chrome 뒤로 단추)별로 날짜별 마우스 횟수, 그 동작의 단축키를 키보드로 쓴 횟수, 힌트를 보여 준 날. 자세한 내용은 [../docs/SHORTCUT_HINTS.md](../docs/SHORTCUT_HINTS.md).

## 기록하지 않는 것
- 비밀번호 칸 (내용은 절대 읽지 않음)
- 비밀번호 관리자·키체인 앱이 앞에 있을 때의 내용
- 은행·증권·카드·결제·정부 사이트에서의 주소·입력·클릭 내용 (시간만 남음)
- 시크릿 창 (Chromium 계열: Chrome·Arc·Brave·Edge·Whale 등). **Safari는 개인 정보 보호 창을 구분할 방법이 없어 기본으로 Safari 페이지의 주소·내용을 기록하지 않는다.** config.json에 `"trustSafari": true`를 넣으면 기록하되 개인 정보 보호 창도 같이 기록된다
- 브라우저 주소를 못 읽는 동안 (자동화 권한을 거부했거나, 탭을 바꾼 직후 응답 전, 조회 실패): 그 사이 입력·복사·붙여넣기 내용은 저장하지 않는다 (모르면 막힌 것으로 본다)
- 비밀번호 칸에 포커스가 있거나 다른 앱이 보안 입력을 켠 동안의 복사·붙여넣기 내용
- 터미널 입력 (화면 전체가 섞이고 셸 기록이 따로 있음)
- API 키·토큰·카드번호·주민번호·"비밀번호: …" 형태는 저장 전에 `[REDACTED]`로 가림
- 키보드로 무슨 글자를 눌렀는지 (횟수와 Enter 여부만 본다). ⌘·⌃와 함께 누른 조합만 메모리에서 확인하고, 마우스로 해 본 동작의 단축키일 때만 그 동작의 횟수를 늘린다. 그 밖의 조합은 남기지 않는다

차단 목록은 `~/Library/Application Support/ActLog/config.json`에서 고칠 수 있음 (메뉴 → 설정 파일 열기). 고친 뒤 메뉴 → 다시 시작.

## 설치·업데이트
```bash
./build.sh
```
`~/Applications/Meowgent.app`에 설치하고 실행한다. 고양이 코드·원화는 비공개 `../pet/` 서브모듈에서 오고(`setup-pet.sh`가 링크), 원화는 AES로 잠긴 `.sprite`로 번들에 들어간다. 개발 빌드에는 팩 그림(assets/vendor)도 들어간다.

배포본(팩 그림 제외, 심볼 제거)은 `./release.sh` → `dist/`. Developer ID가 있으면 `SIGN_ID`·`NOTARY_PROFILE`을 주면 DMG 공증까지 한다. 자세한 절차는 [../docs/RELEASE.md](../docs/RELEASE.md).

처음 실행하면 macOS가 두 가지 권한을 묻는다: **손쉬운 사용**, **입력 모니터링**.
시스템 설정에서 Meowgent를 켠 뒤 메뉴바 아이콘 → **Meowgent 다시 시작**.
브라우저를 처음 쓸 때는 "Meowgent가 Chrome을 제어하려고 합니다" 창이 뜬다 → 허용 (주소를 읽기 위해).

> 키체인의 "ActLog Local Signing" 인증서로 서명하므로 다시 빌드해도 권한이 유지된다.
> 인증서가 없는 맥에서는 임시 서명이 되어 **빌드마다 권한을 다시 켜야 한다** (설정에서 −로 지우고 +로 다시 추가).

메뉴바 아이콘: `◉` 기록 중 · `◎` 권한 필요 · `◌` 일시정지

## 기록 보기
```bash
python3 tools/actlog_tail.py -f              # 실시간으로 따라가기
python3 tools/actlog_tail.py -s text,search  # 입력한 글과 검색어만
python3 tools/actlog_tail.py --stats         # 오늘 종류별 건수, DB 크기
```

## 데이터
- `~/Library/Application Support/Meowgent/actlog.db` (SQLite, 본인만 읽기 가능). 옛 경로 `…/ActLog`는 같은 곳을 가리키는 심볼릭 링크(brain·tools가 그대로 읽는다)
- 지우는 기능은 아직 없음 (오래 보관). 크기는 `--stats`로 확인.
- 말하는 고양이(`brain/cat_mind.py`, 선택)를 켜면 고양이를 부를 때마다 활동 요약(앱·창 제목·판단, 입력한 글은 빼고)과 사용자가 건 말이 사용자의 Codex 계정으로 간다. 범위와 끄는 법은 [docs/CAT_MIND.md](../docs/CAT_MIND.md).
- 그 밖에 외부로 보내는 것은 날씨 조회 하나뿐: 고양이 햇살을 맑은 날에만 띄우려고 30분마다 [Open-Meteo](https://open-meteo.com)에 좌표(소수 한 자리, 약 10km 단위)만 보낸다. 기록·입력 내용은 보내지 않는다.
  위치 바꾸기: `defaults write com.jason.actlog petLat -float 37.5; defaults write com.jason.actlog petLon -float 127.0` · 끄기: `defaults write com.jason.actlog petWeather -bool false` (그땐 해 뜨고 지는 시간만 본다)

## 점검
```bash
./Tests/run_logic.sh   # 한글 diff, 마스킹, 검색어 추출, 차단 도메인
```
