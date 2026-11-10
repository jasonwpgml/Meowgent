// 순수 로직 점검: swiftc로 수집기 소스와 함께 컴파일해서 실행 (tests/run_logic.sh)
import Foundation
var failed = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    print((ok ? "PASS " : "FAIL ") + name + (ok ? "" : "  → " + detail))
    if !ok { failed += 1 }
}

// diff: 한글 조합 완료 상태끼리 비교
var d = TextCapture.diff(old: "안녕", new: "안녕하세요 반가워요")
check("diff 뒤에 추가", d.0 == "하세요 반가워요" && d.1 == 0, "\(d)")
d = TextCapture.diff(old: "오늘 회의 정리", new: "오늘 오후 회의 정리")
check("diff 가운데 삽입", d.0 == "오후 " && d.1 == 0, "\(d)")
d = TextCapture.diff(old: "abc def", new: "abc xyz")
check("diff 교체", d.0 == "xyz" && d.1 == 3, "\(d)")
d = TextCapture.diff(old: "보낼 메시지", new: "")
check("diff 비우기", d.0 == "" && d.1 == 6, "\(d)")

// 마스킹
var r = Privacy.redact("키는 sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123 이거")
check("API 키 마스킹", r.1 && !r.0.contains("abcdefghij"), r.0)
r = Privacy.redact("카드 4111 1111 1111 1111 로 결제")
check("카드번호(Luhn) 마스킹", r.1 && r.0.contains("[REDACTED:card]"), r.0)
r = Privacy.redact("주문번호 1234567890123 확인")
check("Luhn 실패 숫자는 유지", !r.0.contains("card"), r.0)
r = Privacy.redact("주민번호 900101-1234567")
check("주민번호 마스킹", r.0.contains("[REDACTED:rrn]"), r.0)
r = Privacy.redact("비밀번호: hunter2!! 입니다")
check("비밀번호 문구 마스킹", !r.0.contains("hunter2"), r.0)
r = Privacy.redact("그냥 평범한 문장 2026년 10월 14일")
check("평범한 문장 유지", !r.1, r.0)

// 검색어 추출
func q(_ u: String) -> String { Privacy.searchQuery(from: u).map { "\($0.engine):\($0.query)" } ?? "nil" }
check("google", q("https://www.google.com/search?q=clef+decision+model&hl=ko") == "google:clef decision model", q("https://www.google.com/search?q=clef+decision+model&hl=ko"))
check("google.co.kr", q("https://www.google.co.kr/search?q=%EB%A7%A5%EB%B6%81") == "google:맥북", q("https://www.google.co.kr/search?q=%EB%A7%A5%EB%B6%81"))
check("naver", q("https://search.naver.com/search.naver?where=nexearch&query=%EC%A0%90%EC%8B%AC") == "naver:점심")
check("youtube", q("https://www.youtube.com/results?search_query=swift+cgeventtap") == "youtube:swift cgeventtap")
check("github", q("https://github.com/search?q=AXObserver&type=code") == "github:AXObserver")
check("검색 아닌 페이지", q("https://github.com/ggml-org/llama.cpp") == "nil")

// 구글 AI 모드, AI 대화 판별
check("구글 AI 모드", q("https://www.google.com/search?q=%EA%B5%AC%EA%B8%80%EB%B4%87&udm=50&aep=10") == "google_ai_mode:구글봇")
check("AI: 구글 AI 모드", Privacy.aiChat(url: "https://www.google.com/search?q=x&udm=50", bundle: "com.google.Chrome") == "google_ai_mode")
check("AI: 일반 구글 검색은 아님", Privacy.aiChat(url: "https://www.google.com/search?q=x", bundle: "com.google.Chrome") == nil)
check("AI: gemini", Privacy.aiChat(url: "https://gemini.google.com/app/abc", bundle: "com.google.Chrome") == "gemini")
check("AI: Claude 앱", Privacy.aiChat(url: nil, bundle: "com.anthropic.claudefordesktop") == "claude")
check("AI: 일반 사이트 아님", Privacy.aiChat(url: "https://github.com/", bundle: "com.google.Chrome") == nil)

// AI 답변 추출
let before = "메뉴 새 채팅\n이전 질문\n이전 답변\nGemini는 실수를 할 수 있습니다"
let after = "메뉴 새 채팅\n이전 질문\n이전 답변\n구글 봇은 어떻게 돌아다녀?\n구글봇은 링크를 따라 크롤링합니다.\n사이트맵도 씁니다.\nGemini는 실수를 할 수 있습니다"
var ans = AIResponseCapture.extractAnswer(before: before, after: after, prompt: "구글 봇은 어떻게 돌아다녀?")
check("AI 답변: 질문 뒤·꼬리말 앞만", ans == "구글봇은 링크를 따라 크롤링합니다.\n사이트맵도 씁니다.", ans)
ans = AIResponseCapture.extractAnswer(before: "", after: "Google AI 모드\n봇이 있어?\n네, Googlebot이 있습니다.", prompt: "봇이 있어?")
check("AI 답변: 새 페이지(이전 글 없음)", ans == "네, Googlebot이 있습니다.", ans)

check("AI 답변: 자리표시 문자 제거", AIResponseCapture.extractAnswer(before: "", after: "질문\n\u{FFFC}답변\u{FFFC}입니다", prompt: "질문") == "답변입니다")

// 주소의 로그인 코드·토큰 가리기
let kakao = Privacy.sanitize(url: "https://example.com/auth/kakao?code=h42MIz7Ijp&state=https%3A%2F%2Fexample.com%2Fme")!
check("OAuth code 가림", !kakao.contains("h42MIz7Ijp") && kakao.contains("code=REDACTED"), kakao)
let normal = "https://www.google.com/search?q=swift&hl=ko"
check("일반 주소는 그대로", Privacy.sanitize(url: normal) == normal, Privacy.sanitize(url: normal) ?? "")
let frag = Privacy.sanitize(url: "https://app.example.com/cb#access_token=abc.def&expires=3600")!
check("#access_token 가림", !frag.contains("abc.def"), frag)
check("카카오 로그인 화면 차단", Privacy.isBlocked(url: "https://accounts.kakao.com/login/?continue=x"))

// 차단 도메인
check("은행 하위 도메인 차단", Privacy.isBlocked(url: "https://obank.kbstar.com/quics?page=C0"))
check("비슷한 이름은 통과", !Privacy.isBlocked(url: "https://notkbstar.com/"))
check("일반 사이트 통과", !Privacy.isBlocked(url: "https://github.com/"))

// 한도·리셋권 알림 (QuotaRules)
var seoul = Calendar(identifier: .gregorian)
seoul.timeZone = TimeZone(identifier: "Asia/Seoul")!
let qNow = seoul.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 19, minute: 0))!   // 토요일 저녁
func win(_ name: String, used: Double, mins: Int, resetIn: TimeInterval, age: TimeInterval = 60, provider: String = "codex", account: String? = nil) -> Quota.Window {
    Quota.Window(provider: provider, name: name, key: "\(provider):\(name)", usedPercent: used, minutes: mins,
                 resetsAt: qNow.addingTimeInterval(resetIn), capturedAt: qNow.addingTimeInterval(-age), account: account)
}
func keys(_ r: [Quota.Reminder]) -> [String] { r.map { String($0.key.split(separator: ":").last!) } }
let H = 3600.0, D = 86400.0

var qr = Quota.reminders(windows: [win("Codex 주간", used: 40, mins: 10080, resetIn: 20 * H)], credits: [], now: qNow, cal: seoul)
check("주간 하루 안 리셋 + 60% 남음 → 남는다 알림", keys(qr) == ["waste-d1"] && qr[0].text.contains("60% 남았는데"), "\(qr.map(\.text))")
qr = Quota.reminders(windows: [win("Codex 주간", used: 70, mins: 10080, resetIn: 5 * H)], credits: [], now: qNow, cal: seoul)
check("6시간 안 리셋 + 30% 남음 → 막판 알림", keys(qr) == ["waste-h6"], "\(keys(qr))")
qr = Quota.reminders(windows: [win("Grok 주간", used: 0, mins: 10080, resetIn: 5 * H, provider: "grok")], credits: [], now: qNow, cal: seoul)
check("손 안 댄 서비스는 막판 알림 대신 하루 전 알림만", keys(qr) == ["waste-d1"], "\(keys(qr))")
qr = Quota.reminders(windows: [win("Codex 주간", used: 40, mins: 10080, resetIn: 20 * H, age: 8 * H)], credits: [], now: qNow, cal: seoul)
check("오래된 값(8시간)이면 사용률 알림 안 함", qr.isEmpty, "\(keys(qr))")
qr = Quota.reminders(windows: [win("Claude 5시간", used: 20, mins: 300, resetIn: 30 * 60, provider: "claude")], credits: [], now: qNow, cal: seoul)
check("5시간 창은 남아도 알리지 않음", qr.isEmpty, "\(keys(qr))")

qr = Quota.reminders(windows: [win("Claude 5시간", used: 92, mins: 300, resetIn: 2 * H, provider: "claude")], credits: [], now: qNow, cal: seoul)
check("5시간 92% → 급한 알림 1개", keys(qr) == ["high90"] && qr[0].urgent, "\(keys(qr))")
qr = Quota.reminders(windows: [win("Codex 주간", used: 96, mins: 10080, resetIn: 3 * D)], credits: [], now: qNow, cal: seoul)
check("주간 96% → 가장 높은 단계(95)만", keys(qr) == ["high95"], "\(keys(qr))")

// 리셋권 (이 계정의 지문 id는 테스트용 가짜 값)
let acct = "acct-96fdbd26c2b4"
func credit(_ id: String, expiresIn: TimeInterval, grantedAgo: TimeInterval = 20 * D) -> Quota.Credit {
    Quota.Credit(provider: "codex", account: acct, accountLabel: nil, id: id, title: "전체 재설정",
                 grantedAt: qNow.addingTimeInterval(-grantedAgo), expiresAt: qNow.addingTimeInterval(expiresIn), capturedAt: qNow)
}
qr = Quota.reminders(windows: [win("Codex 주간", used: 100, mins: 10080, resetIn: 2 * D, account: acct)],
                     credits: [credit("c1", expiresIn: 20 * D)], now: qNow, cal: seoul)
check("한도 다 씀 + 리셋권 있음 → 리셋권 안내", qr.first?.text.contains("리셋권 1장") == true && qr.first?.urgent == true, "\(qr.map(\.text))")
qr = Quota.reminders(windows: [win("Codex 주간", used: 68, mins: 10080, resetIn: 5 * D, account: acct)],
                     credits: [credit("c2", expiresIn: 20 * H)], now: qNow, cal: seoul)
check("리셋권 하루 안 만료 → 급함 + 지금 쓰라는 조언", qr.first?.key == "credit:c2:d1" && qr.first?.urgent == true && qr.first!.text.contains("68% 썼으니"), "\(qr.map(\.text))")
qr = Quota.reminders(windows: [], credits: [credit("c3", expiresIn: 2.5 * D)], now: qNow, cal: seoul)
check("리셋권 사흘 안 만료 → 급하지 않은 알림", qr.first?.key == "credit:c3:d3" && qr.first?.urgent == false, "\(keys(qr))")
qr = Quota.reminders(windows: [], credits: [credit("c4", expiresIn: 28 * D, grantedAgo: 2 * D)], now: qNow, cal: seoul)
check("새 리셋권 받음", keys(qr) == ["new"], "\(keys(qr))")
qr = Quota.reminders(windows: [], credits: [credit("c5", expiresIn: -H)], now: qNow, cal: seoul)
check("만료된 리셋권은 무시", qr.isEmpty)

// 리셋됐다 / 속도
let wBefore = win("Codex 주간", used: 97, mins: 10080, resetIn: -10 * 60)
let wAfter = Quota.Window(provider: "codex", name: "Codex 주간", key: wBefore.key, usedPercent: 0, minutes: 10080,
                         resetsAt: qNow.addingTimeInterval(7 * D - 10 * 60), capturedAt: qNow)
qr = Quota.reminders(windows: [wAfter], credits: [], previous: [wBefore.key: wBefore], now: qNow, cal: seoul)
check("많이 쓰던 창이 새로 채워지면 알림", keys(qr) == ["reset"], "\(keys(qr))")
qr = Quota.reminders(windows: [win("Codex 주간", used: 60, mins: 10080, resetIn: 4 * D)], credits: [], now: qNow, cal: seoul)
check("3일 만에 60% → 이 속도면 바닥 경고", keys(qr) == ["pace"], "\(keys(qr))")
let ex = Quota.exhaustAt(win("x", used: 60, mins: 10080, resetIn: 4 * D), now: qNow)!
check("바닥 예상 시각 = 2일 뒤", abs(ex.timeIntervalSince(qNow) - 2 * D) < 60, "\(ex)")

// 브리핑 · 글자
let dg = Quota.digest(windows: [win("Codex 주간", used: 40, mins: 10080, resetIn: 4 * D)], credits: [credit("c6", expiresIn: 6 * D)], now: qNow, cal: seoul) ?? ""
check("브리핑에 남은 양·하루 권장량·리셋권", dg.contains("60% 남음") && dg.contains("하루 15%씩") && dg.contains("리셋권 1장"), dg)
check("브리핑: 챙길 것 없으면 nil", Quota.digest(windows: [], credits: [], now: qNow, cal: seoul) == nil)
check("시각: 내일", Quota.whenText(qNow.addingTimeInterval(7 * H), now: qNow, cal: seoul) == "내일 오전 2:00", Quota.whenText(qNow.addingTimeInterval(7 * H), now: qNow, cal: seoul))
check("시각: 요일", Quota.whenText(qNow.addingTimeInterval(3 * D), now: qNow, cal: seoul).hasPrefix("화 "), Quota.whenText(qNow.addingTimeInterval(3 * D), now: qNow, cal: seoul))
check("시각: 날짜", Quota.whenText(qNow.addingTimeInterval(10 * D), now: qNow, cal: seoul).hasPrefix("10/27(화)"), Quota.whenText(qNow.addingTimeInterval(10 * D), now: qNow, cal: seoul))
check("남은 시간 글자", Quota.relText(3 * H + 12 * 60) == "3시간 12분" && Quota.relText(2 * D + 4 * H) == "2일 4시간" && Quota.relText(40 * 60) == "40분")
check("창 이름", Quota.periodName(300) == "5시간" && Quota.periodName(10080) == "주간" && Quota.periodName(43200) == "월")

#if HAS_PET
// ! · ? 항목: 마감 하루 안이면 빨강으로 올리고, 지난 건 내린다
let nowTs = 1_000_000.0
func mk(_ o: [String: Any]) -> PetMark? { PetMark.parse(o, id: "f", now: nowTs) }
check("항목 기본값", mk(["text": "메일 확인"]).map { !$0.ask && !$0.red && $0.id == "f" } == true)
check("빈 글은 버림", mk(["text": "  "]) == nil)
check("모르는 kind 는 버림", mk(["text": "x", "kind": "note"]) == nil)
check("마감 하루 안이면 빨강", mk(["text": "이력서", "level": "yellow", "due": nowTs + 3600])?.red == true)
check("마감 멀면 노랑 유지", mk(["text": "이력서", "level": "yellow", "due": nowTs + 3 * 86400])?.red == false)
check("마감 하루 지나면 내림", mk(["text": "이력서", "due": nowTs - 25 * 3600]) == nil)
check("expires 지나면 내림", mk(["text": "x", "expires": nowTs - 1]) == nil)
check("http 아닌 주소는 버림", mk(["text": "x", "url": "file:///etc/passwd"])?.url == nil)
let ch = mk(["text": "x", "kind": "ask", "choices": ["a", ["id": "b", "label": "비"]]])?.choices ?? []
check("선택지 두 형식", ch == [.init(id: "a", label: "a"), .init(id: "b", label: "비")], "\(ch)")
let ordered = [mk(["text": "노랑", "created": 1.0])!, mk(["text": "빨강 늦게", "level": "red", "created": 5.0])!,
               mk(["text": "빨강 마감", "level": "red", "due": nowTs + 7200])!].sorted(by: PetMark.order).map(\.text)
check("빨강·마감 먼저", ordered == ["빨강 마감", "빨강 늦게", "노랑"], "\(ordered)")

// 빈자리: 고양이 몸(가운데 ± 50, 높이 100)이 창과 안 겹치는 바닥 구간
var ts = TerrainScan(floor: Platform(y: 0, x0: 0, x1: 1000, windowID: nil), platforms: [], frontCoversScreen: false,
                     windows: [CGRect(x: 200, y: 50, width: 300, height: 400), CGRect(x: 700, y: 300, width: 200, height: 200)])
var fs = ts.freeSpans(on: ts.floor, halfWidth: 50, height: 100)
check("빈자리: 바닥까지 내려온 창 양옆만 빔, 높이 떠 있는 창은 무시", fs == [0...150, 550...1000], "\(fs)")
let top = Platform(y: 450, x0: 220, x1: 480, windowID: 1)
ts.windows.append(CGRect(x: 400, y: 420, width: 300, height: 300))
fs = ts.freeSpans(on: top, halfWidth: 50, height: 100)
check("빈자리: 창 위에선 밟은 창은 빼고 뒤 창만 피함", fs == [220...350], "\(fs)")
ts.windows = [CGRect(x: -10, y: 0, width: 1100, height: 900)]
check("빈자리: 꽉 찬 화면이면 없음", ts.freeSpans(on: ts.floor, halfWidth: 50, height: 100).isEmpty)
#endif

// 단축키 표기: 메뉴(AX)와 키보드가 같은 글자가 되어야 "써 봤는지"를 센다
check("메뉴 ⌘[", Keys.menu(char: "[", virtualKey: nil, modifiers: 0) == "⌘[")
check("메뉴 ⇧⌘T (대문자 + ⇧ 비트)", Keys.menu(char: "T", virtualKey: nil, modifiers: Keys.axShift) == "⇧⌘T")
check("메뉴 { → ⇧⌘[", Keys.menu(char: "{", virtualKey: nil, modifiers: 0) == "⇧⌘[")
check("메뉴 ⌘⌫ (제어 문자)", Keys.menu(char: "\u{8}", virtualKey: nil, modifiers: 0) == "⌘⌫")
check("메뉴 ⌃← (⌘ 없음, 가상 키)", Keys.menu(char: nil, virtualKey: 123, modifiers: Keys.axControl | Keys.axNoCommand) == "⌃←")
check("메뉴 fn 조합(⌘·⌃ 없음)은 버림", Keys.menu(char: "F", virtualKey: nil, modifiers: Keys.axNoCommand) == nil)
check("키보드 ⌘[", Keys.chord(keyCode: 33, control: false, option: false, shift: false, command: true) == "⌘[")
check("키보드 ⇧⌘T", Keys.chord(keyCode: 17, control: false, option: false, shift: true, command: true) == "⇧⌘T")
check("키보드 그냥 타자는 nil", Keys.chord(keyCode: 0, control: false, option: true, shift: true, command: false) == nil)
check("⌘+ 는 ⌘= 로도 누른다", Keys.variants("⌘+") == ["⌘=", "⇧⌘="], "\(Keys.variants("⌘+"))")

// 클릭 → 단축키 규칙
let chromeMenu = [MenuShortcut(title: "새 탭", keys: "⌘T"), MenuShortcut(title: "뒤로", keys: "⌘["), MenuShortcut(title: "닫기", keys: "⌘W")]
let claudeMenu = [MenuShortcut(title: "세션 닫기", keys: "⌘W"), MenuShortcut(title: "창 닫기", keys: "⇧⌘W"),
                  MenuShortcut(title: "사이드바 숨기기", keys: "⌘B"), MenuShortcut(title: "확대", keys: "⌘+")]
func hk(_ c: ShortcutClick, _ menu: [MenuShortcut] = [], running: Bool = true) -> String {
    ShortcutRules.hint(for: c, menu: menu, spacesKeys: true, spotlight: "⌘Space", isRunning: { _ in running })?.keys ?? "nil"
}
let chrome = "com.google.Chrome", claudeApp = "com.anthropic.claudefordesktop"
check("Chrome 뒤로 단추 → ⌘[", hk(ShortcutClick(bundle: chrome, role: "AXButton", label: "뒤로"), chromeMenu) == "⌘[")
check("웹 페이지 속 뒤로 단추는 말 안 함", hk(ShortcutClick(bundle: chrome, role: "AXButton", label: "뒤로", inWeb: true), chromeMenu) == "nil")
check("Claude 창 닫기 단추 → ⇧⌘W (⌘W는 세션 닫기)", hk(ShortcutClick(bundle: claudeApp, role: "AXButton", subrole: "AXCloseButton"), claudeMenu) == "⇧⌘W")
check("Claude 대화상자 닫기 단추는 말 안 함", hk(ShortcutClick(bundle: claudeApp, role: "AXButton", label: "닫기", inWeb: true), claudeMenu + [MenuShortcut(title: "닫기", keys: "⌘W")]) == "nil")
check("이름 일부만 같으면 말 안 함 (이미지 확대 ≠ 확대)", hk(ShortcutClick(bundle: claudeApp, role: "AXButton", label: "이미지 확대: Read", inWeb: true), claudeMenu) == "nil")
check("Electron 앱 웹 안의 정확히 같은 이름은 됨", hk(ShortcutClick(bundle: claudeApp, role: "AXButton", label: "사이드바 숨기기", inWeb: true), claudeMenu) == "⌘B")
check("메뉴에 없는 창 단추는 말 안 함", hk(ShortcutClick(bundle: claudeApp, role: "AXButton", subrole: "AXMinimizeButton"), claudeMenu) == "nil")
check("켜진 앱 Dock 아이콘 → ⌘⇥", hk(ShortcutClick(bundle: "com.apple.dock", role: "AXDockItem", subrole: "AXApplicationDockItem", label: "Slack")) == "⌘⇥")
check("꺼진 앱 Dock 아이콘 → Spotlight", hk(ShortcutClick(bundle: "com.apple.dock", role: "AXDockItem", subrole: "AXApplicationDockItem", label: "Slack"), running: false) == "⌘Space")
check("Mission Control 데스크톱 → ⌃← ⌃→", hk(ShortcutClick(bundle: "com.apple.dock", role: "AXButton", label: "ChatGPT 및 Claude")) == "⌃← ⌃→")
check("Mission Control 앱 이름 하나는 말 안 함", hk(ShortcutClick(bundle: "com.apple.dock", role: "AXButton", label: "Google Chrome")) == "nil")
check("Chrome 주소창 → ⌘L", hk(ShortcutClick(bundle: chrome, role: "AXTextField", label: "주소창 및 검색창")) == "⌘L")
check("웹 페이지의 주소 입력칸은 말 안 함", hk(ShortcutClick(bundle: chrome, role: "AXTextField", label: "배송 주소", inWeb: true)) == "nil")
check("Chrome 탭 → ⌃⇥ · ⌘1~9", hk(ShortcutClick(bundle: chrome, role: "AXRadioButton", subrole: "AXTabButton", label: "새 탭")) == "⌃⇥ · ⌘1~9")
check("우클릭 메뉴 항목 → 적힌 단축키", hk(ShortcutClick(bundle: chrome, role: "AXMenuItem", label: "붙여넣기", menuKeys: "⌘V")) == "⌘V")
check("단축키 없는 메뉴 항목은 말 안 함", hk(ShortcutClick(bundle: chrome, role: "AXMenuItem", label: "환경설정")) == "nil")

// 언제 보여 줄지: 같은 날 3번째 마우스, 하루 한 번, 단축키 3번 쓰면 끝
var ledger = ShortcutLedger()
let back = ShortcutHint(id: "\(chrome)|⌘[", keys: "⌘[", title: "뒤로", accepts: ["⌘["], scope: chrome)
let t0 = Date(timeIntervalSince1970: 1_800_000_000)
check("마우스 1·2번째는 안 보임", !ledger.noteMouse(back, day: "d1", now: t0) && !ledger.noteMouse(back, day: "d1", now: t0))
check("3번째에 보임", ledger.noteMouse(back, day: "d1", now: t0))
ledger.markShown(back.id, day: "d1", now: t0)
check("같은 날 다시는 안 보임", !ledger.noteMouse(back, day: "d1", now: t0.addingTimeInterval(600)))
check("다른 앱에서 누른 ⌘[ 는 안 셈", ledger.noteChord("⌘[", frontBundle: "com.apple.finder", day: "d1").isEmpty)
for _ in 0..<3 { _ = ledger.noteChord("⌘[", frontBundle: chrome, day: "d1") }
_ = ledger.noteMouse(back, day: "d2", now: t0.addingTimeInterval(86400)); _ = ledger.noteMouse(back, day: "d2", now: t0.addingTimeInterval(86400))
check("단축키를 3번 쓰면 다음 날에도 안 보임", !ledger.noteMouse(back, day: "d2", now: t0.addingTimeInterval(86400)))
var l2 = ShortcutLedger()
let tab = ShortcutHint(id: "x|⌘T", keys: "⌘T", title: "새 탭", accepts: ["⌘T"], scope: "x")
for _ in 0..<2 { _ = l2.noteMouse(tab, day: "d1", now: t0) }
l2.entries[tab.id]!.muted = true
check("끈 힌트는 안 보임", !l2.noteMouse(tab, day: "d1", now: t0))
l2.prune(keeping: ["d9"])
check("오래된 날짜 정리", l2.entries[tab.id]!.mouse.isEmpty)

// 브라우저 주소를 모르는 동안은 막힌 것으로 본다 (자동화 권한 거부·응답 전·Safari)
do {
    var snap = Snapshot()
    check("기본은 안 막힘", !snap.blocked)
    snap.urlUnknown = true
    check("주소 모르면 막힘", snap.blocked)
    snap.urlUnknown = false; snap.incognito = true
    check("시크릿 창은 막힘", snap.blocked)
}

// 맥 상태: 뒤에서 오래 쓰는 앱만, 같은 일은 한 번만
do {
    let base = Date(timeIntervalSince1970: 1_000_000)
    func app(_ name: String, cpu: Double = 1, watts: Double = 0, mem: UInt64 = 0, front: Bool = false) -> Resource.App {
        Resource.App(key: "/Applications/\(name).app", name: name, cpu: cpu, watts: watts, memBytes: mem, front: front)
    }
    func sample(_ apps: [Resource.App], cpu: Double = 20, pressure: Int = 0, thermal: Int = 0,
                battery: Resource.Battery? = nil, gpu: Double? = nil) -> Resource.Sample {
        Resource.Sample(at: base, cpu: cpu, cores: 10, apps: apps, memUsed: 50, pressure: pressure, swapBytes: 0,
                        thermal: thermal, battery: battery, watts: nil, gpu: gpu)
    }
    func keys(_ s: Resource.Sample, ignored: Set<String> = []) -> [String] { Resource.alerts(s, ignored: ignored).map(\.key) }

    check("뒤에 있는 앱 CPU", keys(sample([app("Chrome", cpu: 140)])) == ["cpu:/Applications/Chrome.app"])
    check("앞에 있는 앱은 말 안 함", keys(sample([app("Xcode", cpu: 300, front: true)], cpu: 95)).isEmpty)
    check("무시한 앱은 말 안 함", keys(sample([app("Docker", cpu: 200)]), ignored: ["/Applications/Docker.app"]).isEmpty)
    check("여럿이 나눠 꽉 채움", keys(sample([app("A", cpu: 60), app("B", cpu: 50)], cpu: 90)) == ["cpu:total"])
    check("메모리 빠듯·심각", keys(sample([], pressure: 1)) == ["memory:tight"] && keys(sample([], pressure: 2)) == ["memory:critical"])
    check("발열 serious 부터", keys(sample([], thermal: 1)).isEmpty && keys(sample([], thermal: 2)) == ["thermal:serious"])
    let onBat = Resource.Battery(percent: 60, onBattery: true, charging: false, minutesLeft: 45, lowPower: false)
    let k = keys(sample([app("Slack", watts: 3)], battery: onBat))
    check("배터리: 전기 먹는 앱·빨리 닳음", k == ["energy:/Applications/Slack.app", "energy:drain"], "\(k)")
    let plugged = Resource.Battery(percent: 15, onBattery: false, charging: true, minutesLeft: nil, lowPower: false)
    check("충전 중엔 에너지 알림 없음", keys(sample([app("Slack", watts: 3)], battery: plugged)).isEmpty)
    var low = onBat; low.percent = 8; low.minutesLeft = nil
    check("배터리 10% 아래는 급함", Resource.alerts(sample([], battery: low)).map { "\($0.key) \($0.urgent)" } == ["battery:10 true"])
    check("GPU: 앞 앱이 제일 바쁘면 말 안 함", keys(sample([app("Game", cpu: 150, front: true)], gpu: 99)).isEmpty
          && keys(sample([app("Game", cpu: 5)], gpu: 99)) == ["gpu:busy"])

    // hold · 한 번만 · 30초 끊김은 이어진 것으로 · 1시간 쿨다운
    var tr = Resource.Tracker()
    let hog = Resource.alerts(sample([app("Chrome", cpu: 140)]))
    check("처음엔 기다림", tr.due(hog, now: base).isEmpty)
    check("2분엔 아직", tr.due(hog, now: base + 120).isEmpty)
    check("한 번 끊겨도 이어짐", tr.due([], now: base + 140).isEmpty && tr.due(hog, now: base + 150).isEmpty)
    let due = tr.due(hog, now: base + 180)
    check("3분 되면 말함", due.map(\.key) == ["cpu:/Applications/Chrome.app"])
    tr.markFired(due[0].key, now: base + 180)
    check("말한 건 다시 안 함", tr.due(hog, now: base + 400).isEmpty && tr.held(hog, now: base + 400).count == 1)
    _ = tr.due([], now: base + 500)   // 풀림
    _ = tr.due(hog, now: base + 600)
    check("다시 생겨도 1시간 안엔 안 함", tr.due(hog, now: base + 900).isEmpty)
    _ = tr.due([], now: base + 4000)
    _ = tr.due(hog, now: base + 4000)
    check("1시간 지나면 다시", tr.due(hog, now: base + 4200).count == 1)
    // 메모리 빠듯: 5분 이어져야, 한 번 말하면 6시간 쉼
    var mt = Resource.Tracker()
    let tight = Resource.alerts(sample([], pressure: 1))
    _ = mt.due(tight, now: base)
    check("메모리 빠듯은 5분 기다림", mt.due(tight, now: base + 120).isEmpty && mt.due(tight, now: base + 300).count == 1)
    mt.markFired("memory:tight", now: base + 300)
    _ = mt.due([], now: base + 400)
    _ = mt.due(tight, now: base + 4000)
    check("메모리 빠듯은 1시간 지나도 안 함", mt.due(tight, now: base + 4400).isEmpty)
    _ = mt.due([], now: base + 22000)
    _ = mt.due(tight, now: base + 22000)
    check("6시간 지나면 다시", mt.due(tight, now: base + 22400).count == 1)
    check("글자", Resource.duration(130) == "2시간 10분" && Resource.duration(45) == "45분"
          && Resource.bytes(3_221_225_472) == "3.0GB" && Resource.cores(130) == "1.3")
}

// MARK: 묘전트 자기 사용량
do {
    check("브레인 알아봄", Resource.helperPart(args: ["/x/python3", "-I", "/Users/a/Library/Application Support/ActLog/brain/actlog_brain.py", "run"]) == .brain)
    check("말하는 고양이 알아봄", Resource.helperPart(args: ["python3", "/a/brain/cat_mind.py"]) == .mind)
    check("다른 python 은 아님", Resource.helperPart(args: ["python3", "/a/server.py"]) == nil)
    let m = Resource.ownMembers(root: 10, helpers: [20: .mind], parents: [10: 1, 11: 10, 12: 11, 20: 1, 21: 20, 30: 1, 31: 30])
    check("자식까지 묶음", m[10] == .app && m[12] == .app && m[20] == .mind && m[21] == .mind)
    check("남의 프로세스는 뺌", m[30] == nil && m[31] == nil)
    check("순환 부모에도 멈춤", Resource.ownMembers(root: 10, helpers: [:], parents: [40: 41, 41: 40]).isEmpty)
    let l = Resource.nettopLine("Google Chrome H.123,10,20,")
    check("nettop 줄", l?.pid == 123 && l?.input == 10 && l?.output == 20)
    check("nettop 머리글은 무시", Resource.nettopLine(",bytes_in,bytes_out,") == nil && Resource.nettopLine("") == nil)
    check("크기 글자", Resource.size(512) == "512B" && Resource.size(2048) == "2KB" && Resource.size(1_572_864) == "1.5MB" && Resource.rate(1024) == "1KB/s")
}

// MARK: 앱 정리
do {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let h: TimeInterval = 3600
    func cand(_ id: String = "com.example.app", regular: Bool = true, front: Bool = false, windows: Bool = false,
              idle: TimeInterval = 8 * h, tracked: TimeInterval = 8 * h, cpu: Double = 0.1, mem: UInt64 = 100_000_000) -> Cleanup.Candidate {
        Cleanup.Candidate(key: "/Applications/App.app", bundleID: id, name: "App", regular: regular, front: front, hasWindows: windows,
                          idle: idle, tracked: tracked, avgCPU: cpu, memBytes: mem)
    }
    func isAsk(_ v: Cleanup.Verdict) -> Bool { if case .ask = v { return true } else { return false } }
    func isAuto(_ v: Cleanup.Verdict) -> Bool { if case .auto = v { return true } else { return false } }
    let ok = Cleanup.Prefs(always: ["/Applications/App.app"])
    let gb: UInt64 = 2_000_000_000
    func d(_ c: Cleanup.Candidate, _ p: Cleanup.Prefs = .init(), pressure: Int = 0) -> Cleanup.Verdict { Cleanup.decide(c, pressure: pressure, prefs: p, now: now) }

    check("허락 없으면 자동 없음: 묻기만", isAsk(d(cand())))
    check("허락 + 창 없음 + 오래 조용 = 자동", isAuto(d(cand(), ok)))
    check("허락했어도 창 있으면 자동 아님", !isAuto(d(cand(windows: true, mem: gb), ok)))
    check("허락했어도 CPU 쓰면 자동 아님", !isAuto(d(cand(cpu: 3), ok)))
    check("허락했어도 덜 오래면 자동 아님", !isAuto(d(cand(idle: 3 * h), ok)))
    check("허락했어도 메뉴바 앱은 자동 없음", !isAuto(d(cand(regular: false, mem: gb), ok)))
    check("보호 앱은 건드리지 않음", d(cand("com.apple.TextEdit", mem: gb), ok) == .keep && d(cand("com.anthropic.claudefordesktop", mem: gb)) == .keep)
    check("보호 목록은 대소문자 무시", Cleanup.isProtected("com.hnc.Discord") && Cleanup.isProtected("") && !Cleanup.isProtected("com.google.Chrome"))
    check("앞에 있으면 건드리지 않음", d(cand(front: true, mem: gb), ok) == .keep)
    check("일하는 중이면 묻지 않음", d(cand(windows: true, cpu: 20, mem: gb)) == .keep)
    check("지켜본 지 얼마 안 되면 판단 안 함", d(cand(tracked: 5 * 60, mem: gb), ok) == .keep)
    check("항상 두기", d(cand(), Cleanup.Prefs(never: ["/Applications/App.app"])) == .keep)
    let snooze = Cleanup.Prefs(snoozedUntil: ["/Applications/App.app": now + h])
    check("이번엔 두기 기간엔 안 물음", d(cand(), snooze) == .keep)
    check("기간이 지나면 다시", isAsk(d(cand(), Cleanup.Prefs(snoozedUntil: ["/Applications/App.app": now - 1]))))
    check("자동 앱도 안 꺼졌던 기간엔 다시 안 건드림", d(cand(), Cleanup.Prefs(always: ["/Applications/App.app"], snoozedUntil: ["/Applications/App.app": now + h])) == .keep)
    check("창 있고 작으면 안 물음", d(cand(windows: true)) == .keep)
    check("창 있어도 크고 오래 안 쓰면 물음", isAsk(d(cand(windows: true, idle: 3 * h, mem: gb))))
    check("막 쓴 앱은 안 물음", d(cand(windows: true, idle: 30 * 60, mem: gb)) == .keep)
    check("메모리 빠듯하면 작아도 물음", isAsk(d(cand(windows: true, idle: 3 * h, mem: 500_000_000), pressure: 1)))
    check("메뉴바 앱은 많이 쓸 때만 물음", d(cand(regular: false)) == .keep && isAsk(d(cand(regular: false, mem: gb))) && isAsk(d(cand(regular: false, cpu: 40))))
}

// 런처: 검색 점수 · 한글 · 계산기 · 창 배치
do {
    typealias L = LauncherRules
    func s(_ n: String, _ q: String) -> Double { L.score(n, q) ?? -1 }
    check("이름 그대로가 가장 높음", s("Safari", "safari") > s("Safari Technology Preview", "safari"))
    check("앞부분 > 단어 시작 > 포함", s("Notes", "no") > s("Sticky Notes", "no") && s("Sticky Notes", "no") > s("Piano", "no"))
    check("글자 순서만 맞아도 찾음", s("Visual Studio Code", "vsc") > 0)
    check("안 맞으면 nil", L.score("Mail", "xyz") == nil)
    check("한글 자판으로 친 영문", L.qwerty("초개ㅡㄷ") == "chrome" && s("Google Chrome", "초개ㅡㄷ") > 0, L.qwerty("초개ㅡㄷ"))
    check("겹받침·겹모음 자판", L.qwerty("읽") == "dlfr" && L.qwerty("와") == "dhk", L.qwerty("읽") + " " + L.qwerty("와"))
    check("초성 검색", L.chosung("캘린더") == "ㅋㄹㄷ" && s("캘린더", "ㅋㄹ") > 0)
    check("한글 이름 그대로", s("캘린더", "캘린") > s("캘린더", "ㅋㄹ"))
    check("자주 연 앱 가산점", L.frecency(count: 10, lastUsed: 0, now: 0) > L.frecency(count: 1, lastUsed: 0, now: 0))
    check("오래되면 줄어듦", L.frecency(count: 10, lastUsed: 0, now: 28 * 86400) < L.frecency(count: 10, lastUsed: 0, now: 0) / 3)
    check("가산점 상한 20", L.frecency(count: 100_000, lastUsed: 0, now: 0) <= 20)

    check("계산 사칙연산", L.calculate("12*(3+4)/2") == 42)
    check("계산 우선순위·거듭제곱", L.calculate("2+3*4") == 14 && L.calculate("2^3^2") == 512)
    check("계산 기호·쉼표", L.calculate("1,000 × 3 ÷ 2") == 1500)
    check("계산 음수", L.calculate("-3+5") == 2 && L.calculate("2*-3") == -6)
    check("숫자 하나는 식 아님", L.calculate("2026") == nil && L.calculate("-5") == nil)
    check("글자 섞이면 식 아님", L.calculate("c++") == nil && L.calculate("3x4") == nil)
    check("0 나누기·괄호 오류는 nil", L.calculate("1/0") == nil && L.calculate("(1+2") == nil)
    check("결과 글", L.format(42) == "42" && L.format(0.1 + 0.2) == "0.3" && L.format(1.5) == "1.5", L.format(0.1 + 0.2))

    let v = CGRect(x: 0, y: 25, width: 1440, height: 875)
    check("왼쪽 반", L.frame(.left, visible: v, current: .zero) == CGRect(x: 0, y: 25, width: 720, height: 875))
    check("오른쪽 반", L.frame(.right, visible: v, current: .zero) == CGRect(x: 720, y: 25, width: 720, height: 875))
    check("위쪽 반은 y가 큰 쪽", L.frame(.top, visible: v, current: .zero).minY == 25 + 875 - 438)
    check("가운데는 크기 유지", L.frame(.center, visible: v, current: CGSize(width: 800, height: 600)) == CGRect(x: 320, y: 163, width: 800, height: 600))
    check("가운데는 화면보다 크면 줄임", L.frame(.center, visible: v, current: CGSize(width: 3000, height: 600)).width == 1440)
    check("손쉬운 사용 좌표로", L.axOrigin(CGRect(x: 10, y: 25, width: 100, height: 875), primaryHeight: 900) == CGPoint(x: 10, y: 0))
}

// 클립보드 기록: 종류 · 색 · 보관 정리 · 검색
do {
    typealias C = ClipRules
    check("링크", C.classify("https://github.com/jasonwpgml") == .link && C.classify(" http://a.b/c?d=1 \n") == .link)
    check("글 속 주소는 글", C.classify("여기 봐 https://a.com") == .text)
    check("색: #RRGGBB·#RGB·rgb()", C.classify("#3a7bd5") == .color && C.classify("#FFF") == .color && C.classify("rgb(58, 123, 213)") == .color)
    check("# 없는 6자리 색", C.classify("3A7BD5") == .color)
    check("# 없는 3자리·숫자는 색 아님", C.classify("123") == .text && C.classify("fff") == .text)
    check("rgb 범위 밖은 색 아님", C.color("rgb(300, 0, 0)") == nil)
    if let c = C.color("#ff8000") { check("색 값", abs(c.r - 1) < 0.001 && abs(c.g - 128.0 / 255) < 0.001 && c.b == 0) } else { check("색 값", false) }
    let day = 86400.0
    let items: [C.Keep] = [.init(id: "new", ts: 100 * day, pinned: false), .init(id: "old", ts: 50 * day, pinned: false),
                           .init(id: "oldPin", ts: 1 * day, pinned: true), .init(id: "mid", ts: 90 * day, pinned: false)]
    check("기간 지난 것만 지움, 고정은 남김", C.expired(items, now: 100 * day, days: 30, maxCount: 10) == ["old"])
    check("개수 넘으면 오래된 것부터", C.expired(items, now: 100 * day, days: 0, maxCount: 2) == ["old"])
    check("기간 제한 없음", C.expired(items, now: 100 * day, days: 0, maxCount: 10).isEmpty)
    check("검색: 낱말 모두", C.matches("회의 내일", in: ["내일 오후 회의 자료"]) && !C.matches("회의 모레", in: ["내일 오후 회의 자료"]))
    check("검색: 이미지 글자·앱 이름", C.matches("영수증", in: ["", "카페 영수증 4,500원", "Preview"]) && C.matches("preview", in: ["", "", "Preview"]))
    check("검색: 한글 자판으로 친 영문", C.matches("ㅎㅑ소ㅕㅠ", in: ["https://github.com"]))
}

// 대시보드: 질문 묶기 · 알림 접기
do {
    let now = 1_000_000.0
    let proj: [[String: String]] = [["id": "a", "label": "A 프로젝트"], ["id": "b", "label": "B"]]
    func ask(_ f: String, _ src: String = "brain", choices: [[String: String]]? = nil, created: Double = now, level: String = "yellow") -> InboxRules.Item? {
        InboxRules.parse(["kind": "ask", "text": "질문 \(f)", "source": src, "choices": choices ?? proj, "created": created, "level": level], file: f + ".json", now: now)
    }
    let a1 = ask("e1", created: now - 30)!, a2 = ask("e2", created: now - 20)!, a3 = ask("e3", created: now - 10)!
    let perm = ask("perm", "고양이", choices: [["id": "y", "label": "허락"], ["id": "n", "label": "안 돼"]])!
    let todo = InboxRules.parse(["text": "마감", "due": now + 3600], file: "t.json", now: now)!
    let groups = InboxRules.group([a3, perm, a1, todo, a2])
    check("같은 곳·같은 선택지는 한 묶음", groups.contains { $0.isBatch && $0.items.map(\.id) == ["e1", "e2", "e3"] })
    check("다른 선택지·확인할 일은 따로", groups.count == 3 && groups.filter(\.isBatch).count == 1)
    check("마감 하루 안이면 빨강이 맨 앞", groups.first?.items.first?.id == "t" && todo.red)
    check("파일 이름이 id 기본값", a1.id == "e1" && a1.file == "e1.json")
    check("선택지 글자만 줘도 됨", InboxRules.parse(["kind": "ask", "text": "x", "choices": ["예", "아니오"]], file: "x.json", now: now)?.choices.map(\.id) == ["예", "아니오"])
    check("만료된 건 안 보임", InboxRules.parse(["text": "x", "expires": now - 1], file: "x.json", now: now) == nil)
    check("javascript 주소는 버림", InboxRules.parse(["text": "x", "url": "javascript:alert(1)"], file: "x.json", now: now)?.url == nil)

    let log = """
    {"text":"🧠 메모리 빠듯\\n큰 앱: A 3GB","ts":100,"urgent":false}
    {"text":"🧠 메모리 빠듯\\n큰 앱: B 4GB","ts":200,"urgent":false}
    {"text":"저녁 먹어라","ts":300,"urgent":false}
    {"text":"🧠 메모리 빠듯\\n큰 앱: C 5GB","ts":400,"urgent":false}
    깨진 줄
    {"text":"컨텍스트 85%","ts":500,"urgent":true}
    """
    let ns = NoticeRules.parse(log)
    check("알림 읽기 (깨진 줄 건너뜀)", ns.count == 5 && ns.filter(\.urgent).count == 1)
    let rows = NoticeRules.collapse(ns.filter { !$0.urgent })
    check("연달아 같은 알림만 접음", rows.map(\.count) == [1, 1, 2] && rows.first?.ts == 400, "\(rows.map(\.count))")
    check("접으면 가장 최근 글", rows.last?.text.hasSuffix("B 4GB") == true)
    let ctx = NoticeRules.collapse(NoticeRules.parse("""
    {"text":"Claude ‘x’ 컨텍스트 80%다","ts":1,"urgent":true}
    {"text":"Claude ‘x’ 컨텍스트 85%다","ts":2,"urgent":true}
    {"text":"Codex ‘y’ 컨텍스트 85%다","ts":3,"urgent":true}
    """))
    let chatSet = NoticeRules.catLines("{\"role\":\"cat\",\"text\":\"날씨 도구는 이렇다냥 \"}\n{\"role\":\"user\",\"text\":\"컨텍스트 85%다\"}")
    check("대화 답은 경고 아님", !NoticeRules.isWarning(.init(text: "날씨 도구는 이렇다냥", ts: 1, urgent: true), chat: chatSet)
          && NoticeRules.isWarning(.init(text: "컨텍스트 85%다", ts: 1, urgent: true), chat: chatSet)
          && !NoticeRules.isWarning(.init(text: "저녁", ts: 1, urgent: false), chat: chatSet))
    let qs = ["10/27 02:41부터 22분 Claude에서 한 일은 어느 프로젝트?", "10/26 01:37부터 28분 Claude에서 한 일은 어느 프로젝트?"]
    let suf = InboxRules.commonSuffix(qs)
    check("묶음 공통 문구 (낱말 단위)", suf == "Claude에서 한 일은 어느 프로젝트?", suf ?? "nil")
    check("공통 문구 뺀 앞부분", InboxRules.stripSuffix(qs[0], suf) == "10/27 02:41부터 22분")
    check("공통 문구가 짧으면 없음", InboxRules.commonSuffix(["사과 먹을까?", "배 먹을까?"]) == nil)
    check("알림 종류", NoticeRules.category("Claude ‘x’ 컨텍스트 85%다") == .context && NoticeRules.category("⛔ Codex 주간 한도 다 썼다냥") == .quota
          && NoticeRules.category("🧠 메모리가 빠듯하다냥\n제일 큰 앱") == .memory && NoticeRules.category("Claude ‘y’ 답 끝났다. 읽어 봐 ✅") == .done
          && NoticeRules.category("하암… 돌아왔냥") == .other)
    check("목록 글에서 이모지 떼기", NoticeRules.plain("🧠 메모리가 빠듯하다냥\n제일 큰 앱: A") == "메모리가 빠듯하다냥\n제일 큰 앱: A"
          && NoticeRules.plain("Claude ‘x’ 답 끝났다. 읽어 봐 ✅") == "Claude ‘x’ 답 끝났다. 읽어 봐" && NoticeRules.plain("50분 일했다") == "50분 일했다"
          && NoticeRules.plain("⏳ Cursor 주간 53%") == "Cursor 주간 53%")
    check("숫자만 다른 첫 줄은 접음, 세션이 다르면 따로", ctx.map(\.count) == [1, 2] && ctx.last?.text.contains("85%") == true, "\(ctx.map(\.count))")
}

// 고양이 말: 답 끝남 묶기 · 컨텍스트 단계 · 같은 알림 쉬기 · 말투
do {
    typealias B = NoticeBatch
    let one = B.doneLine([.init(agent: "Claude", name: "x")])!
    check("하나 끝남 (~다냥)", one == "Claude ‘x’ 답 끝났다냥. 읽어 봐라냥 ✅", one)
    check("Codex 끝남", B.doneLine([.init(agent: "Codex", name: "y")]) == "Codex ‘y’ 일 끝났다냥. 가 봐라냥 ✅")
    let many = B.doneLine((1...6).map { .init(agent: $0 % 2 == 0 ? "Codex" : "Claude", name: "s\($0)") })!
    check("여럿은 한 마디로 묶음", many.hasPrefix("✅ 6개 끝났다냥.") && many.contains("Claude ‘s1’ · Codex ‘s2’") && many.hasSuffix("외 2개"), many)
    check("없으면 말 안 함", B.doneLine([]) == nil)
    check("컨텍스트 단계", B.contextStep(49) == 0 && B.contextStep(50) == 50 && B.contextStep(85) == 80 && B.contextStep(93) == 90)
    check("컨텍스트 말투", B.contextLine(agent: "Claude ‘a’", pct: 91, step: 90) == "Claude ‘a’ 컨텍스트 91%다냥. 정리(compact)하거나 새 세션으로 넘기라냥"
          && B.contextLine(agent: "Codex ‘b’", pct: 55, step: 50).hasSuffix("절반 넘었다냥 (55%)"))
    var g = B.Gate(normal: 1800, urgent: 600)
    check("처음은 말함", g.allow("🧠 메모리가 빠듯하다냥\n큰 앱: A 3GB", urgent: false, now: 0))
    check("숫자만 다른 같은 알림은 쉼", !g.allow("🧠 메모리가 빠듯하다냥\n큰 앱: B 4GB", urgent: false, now: 600))
    check("쉬는 시간 지나면 다시", g.allow("🧠 메모리가 빠듯하다냥\n큰 앱: C 5GB", urgent: false, now: 2000))
    check("다른 알림은 따로", g.allow("저녁 먹어라냥", urgent: false, now: 2001))
    check("급한 건 짧게 쉼", g.allow("⛔ 한도 다 썼다냥", urgent: true, now: 0) && !g.allow("⛔ 한도 다 썼다냥", urgent: true, now: 300) && g.allow("⛔ 한도 다 썼다냥", urgent: true, now: 700))
}

// 문구·설정 표 · 판단 기록 · 개선 제안
do {
    typealias P = PhraseTable
    check("자리표시 빠진 문구는 거절", P.validate(kind: "phrase", key: "done.claude", value: "답 끝났다냥") == nil)
    check("자리표시 다 있으면 통과", P.validate(kind: "phrase", key: "done.claude", value: "{agent} ‘{name}’ 다 됐다냥") != nil)
    check("모르는 키는 거절", P.validate(kind: "phrase", key: "nope", value: "x") == nil && P.validate(kind: "param", key: "nope", value: "1") == nil)
    check("설정은 범위 안으로", P.validate(kind: "param", key: "gate.normal_min", value: "999") == "240.0" && P.validate(kind: "param", key: "done.window_s", value: "abc") == nil)
    check("자리표시 채우기", P.fill("{agent} ‘{name}’", ["agent": "Claude", "name": "x"]) == "Claude ‘x’")
    var custom = P.defaults
    custom.phrases["done.claude"] = "{agent} ‘{name}’ 끝냥"
    custom.params["context.high_pct"] = 70
    check("표 문구를 씀", NoticeBatch.doneLine([.init(agent: "Claude", name: "a")], table: custom) == "Claude ‘a’ 끝냥")
    check("표 설정으로 단계", NoticeBatch.contextStep(75, table: custom) == 70 && NoticeBatch.contextStep(75) == 50)
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("phr-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let saved = P.current
    P.current = P.load(dir: dir)
    check("처음 읽으면 기본값으로 파일 만듦", FileManager.default.fileExists(atPath: dir.appendingPathComponent("phrases.json").path) && P.current == P.defaults)
    check("적용하면 표와 파일이 같이 바뀜", P.apply(kind: "param", key: "gate.normal_min", value: "45", dir: dir) && P.current.param("gate.normal_min") == 45
          && P.load(dir: dir).param("gate.normal_min") == 45)
    check("맞지 않는 값은 적용 안 함", !P.apply(kind: "phrase", key: "done.many", value: "끝났다냥", dir: dir))
    P.current = saved

    let decs = ThinkRules.parse("""
    {"ts":1,"kind":"proactive","trig":"back","facts":"1시간 비웠다 돌아옴","p":0.71,"mode":"chat","outcome":"said","took":8.9,"text":"왔냥"}
    {"ts":2,"kind":"proactive","trig":"late","p":0.2,"mode":"quiet","outcome":"quiet"}
    {"ts":3,"kind":"chat","outcome":"timeout","took":120}
    깨진 줄
    """)
    check("판단 기록 읽기", decs.count == 3)
    check("판단 제목", ThinkRules.title(decs[0]) == "돌아옴 · 가볍게 · 말함" && ThinkRules.title(decs[2]) == "말 걸어 옴 · 시간 초과", ThinkRules.title(decs[0]))
    check("판단 부제", ThinkRules.subtitle(decs[0]) == "1시간 비웠다 돌아옴 · 말할 확률 0.71 · 8.9초", ThinkRules.subtitle(decs[0]))
    let imp = ThinkRules.parseImprove(Data(#"{"ts":5,"summary":"잦다","suggestions":[{"id":"a","kind":"param","key":"gate.normal_min","value":"45","current":30,"why":"w","status":"new"},{"id":"b","kind":"idea","key":"","value":"새벽엔 조용히","current":null,"why":"","status":"ignored"}]}"#.utf8))
    check("개선 제안 읽기", imp?.suggestions.count == 2 && imp?.suggestions[0].current == "30" && imp?.suggestions[1].status == "ignored", "\(String(describing: imp))")
}

// Grok Bot 전달 (InboxForwardRules)
do {
    typealias F = InboxForwardRules
    check("웹훅: https + 키", F.hook(["url": "https://example.test/automations/webhook/a1", "key": "k1"]) == F.Hook(url: URL(string: "https://example.test/automations/webhook/a1")!, key: "k1"))
    check("웹훅: http 는 안 씀", F.hook(["url": "http://example.test/x", "key": "k"]) == nil)
    check("웹훅: 이 맥 안 시험 서버는 http 허용", F.hook(["url": "http://127.0.0.1:8799/h", "key": "k"]) != nil)
    check("웹훅: 예제 자리표시는 안 씀", F.hook(["url": "https://example.test/x", "key": "PASTE_BEARER_TOKEN"]) == nil && F.hook(["url": "PASTE_WEBHOOK_URL", "key": "k"]) == nil)
    check("웹훅: Bearer 붙여 넣어도 키만", F.hook(["url": "https://example.test/x", "key": "Bearer abc "])?.key == "abc")
    check("웹훅: 파일 없음", F.hook(nil) == nil)
    check("넘길 항목", F.wants(["text": "이력서", "forward": "grokbot"]) && F.wants(["text": "a", "forward": "GrokBot", "kind": "todo"]))
    check("안 넘김: 표시 없음·질문·빈 글", !F.wants(["text": "a"]) && !F.wants(["text": "a", "forward": "grokbot", "kind": "ask"]) && !F.wants(["text": " ", "forward": "grokbot"]))
    let now = 1_800_000_000.0
    var st = F.State(first: now)
    check("처음은 보낼 차례", F.due(nil, now: now) && F.due(st, now: now))
    st = F.failed(st, status: 500, error: "HTTP 500", now: now)
    check("500 실패 → 1분 뒤", st.tries == 1 && st.next == now + 60 && !F.due(st, now: now + 30) && F.due(st, now: now + 61), "\(st)")
    let auth = F.failed(F.State(first: now), status: 401, error: "HTTP 401", now: now)
    check("401 실패 → 30분 뒤", auth.next == now + 1800, "\(auth)")
    check("재시도 간격 상한 4시간", F.retryDelay(tries: 7) == 14400 && F.retryDelay(tries: 50) == 14400)
    var many = F.State(first: now); for _ in 0..<F.maxTries { many = F.failed(many, status: nil, error: "x", now: now) }
    check("10번 실패하면 그만", many.gaveUp && !F.due(many, now: now + 1e6))
    let ok = F.succeeded(st, run: "r1", now: now + 100)
    check("보낸 뒤로는 다시 안 보냄", ok.sent == now + 100 && ok.run == "r1" && ok.error == nil && !F.due(ok, now: now + 1e6))
    check("기록 왕복", F.State(ok.json) == ok && F.State(many.json) == many)
    check("한 시간 보낸 수", F.sentLastHour(["a": ok, "b": F.succeeded(F.State(first: 0), run: nil, now: now - 4000)], now: now + 200) == 1)
    let old = F.State(first: now - 50 * 86400)
    let pr = F.prune(["gone": old, "kept": old, "new": st], present: ["kept"], now: now)
    check("오래되고 없는 기록만 지움", Set(pr.keys) == ["kept", "new"], "\(pr.keys)")
    let item: [String: Any] = ["text": " 토스 이력서 ", "detail": "키 sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123 는 빼고", "source": "claude-code",
                               "due": 1_793_000_000.0, "url": "https://example.test/apply", "level": "red", "forward": "grokbot"]
    let body = F.body(item, id: "t1", machine: "Mac", zone: TimeZone(identifier: "Asia/Seoul")!)
    check("본문 필드", body["kind"] as? String == "todo" && body["id"] as? String == "t1" && body["text"] as? String == "토스 이력서"
          && body["from"] as? String == "claude-code" && body["level"] as? String == "red" && body["url"] as? String == "https://example.test/apply", "\(body)")
    let ctx = body["context"] as? String ?? ""
    check("context 한 덩어리", ctx.hasPrefix("할일: 토스 이력서\n설명: ") && ctx.contains("마감: ") && ctx.contains("급함") && ctx.hasSuffix("보낸 곳: claude-code (Mac, 묘전트 경유)"), ctx)
    check("밖으로 나가는 글에서 키 가림", !ctx.contains("abcdefghij") && !((body["detail"] as? String) ?? "").contains("abcdefghij"), ctx)
    check("긴 글 자름", F.clean(String(repeating: "가", count: 400), max: F.maxText)?.count == F.maxText + 1)
    check("링크: 쿼리 토큰·주소 속 비밀번호 가림", F.link("https://me:pw@example.test/cb?code=abc123&id=7#access_token=zz") == "https://example.test/cb?code=REDACTED&id=7#REDACTED",
          F.link("https://me:pw@example.test/cb?code=abc123&id=7#access_token=zz") ?? "nil")
    check("링크: 경로 속 키 모양 가림", !(F.link("https://example.test/k/sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123") ?? "").contains("abcdefghij"))
    check("링크: http(s)·호스트 없거나 너무 길면 버림", F.link("javascript:alert(1)") == nil && F.link("httpx://a") == nil && F.link("https://") == nil
          && F.link("https://example.test/" + String(repeating: "a", count: F.maxURL)) == nil && F.link(nil) == nil)
    let sneaky = F.body(["text": "a", "source": "x sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123 " + String(repeating: "b", count: 100), "url": "https://example.test/?token=t0k"],
                        id: "t2", machine: "Mac")
    check("보낸 곳·링크도 가리고 자름", !((sneaky["from"] as? String) ?? "").contains("abcdefghij") && ((sneaky["from"] as? String) ?? "").count <= F.maxSource + 1
          && sneaky["url"] as? String == "https://example.test/?token=REDACTED" && !((sneaky["context"] as? String) ?? "").contains("t0k"), "\(sneaky)")
}

// 여러 개 고르는 질문 (고양이 되묻기·투표) · 고양이가 맡긴 코딩 작업
do {
    let now = 1_800_000_000.0
    let multi = ["kind": "ask", "text": "뭐 할래", "source": "고양이", "choices": ["코딩", "산책"], "multi": true] as [String: Any]
    let a = InboxRules.parse(multi, file: "m1.json", now: now)!, b = InboxRules.parse(multi, file: "m2.json", now: now)!
    check("multi 읽기", a.multi && !InboxRules.parse(["kind": "todo", "text": "x", "multi": true], file: "t.json", now: now)!.multi)
    check("보기 하나면 multi 아님", !InboxRules.parse(["kind": "ask", "text": "x", "choices": ["예"], "multi": true], file: "o.json", now: now)!.multi)
    check("multi 질문은 묶지 않음", InboxRules.group([a, b]).count == 2)
    let run = TaskRules.parse(["id": "t1", "agent_name": "Claude Code", "repo": "Meowgent", "task": "고치기", "state": "running", "started": now - 600])!
    let done = TaskRules.parse(["id": "t2", "agent_name": "Codex", "repo": "Meowgent", "task": "x", "state": "done", "started": now - 60, "ended": now, "files": 3])!
    check("하는 중이 먼저", [done, run].sorted(by: TaskRules.order).map(\.id) == ["t1", "t2"])
    check("작업 한 줄", TaskRules.subtitle(run, now: now) == "Claude Code · Meowgent · 하는 중 10분째" && TaskRules.subtitle(done, now: now).hasSuffix("1분 걸림 · 파일 3개"),
          TaskRules.subtitle(done, now: now))
    check("id 없으면 버림", TaskRules.parse(["state": "done"]) == nil)
}

// 말풍선 반응 기록 (실시간 업무 보조 0단계 계측) · 생각 탭 판단 라벨
do {
    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Asia/Seoul")!
    func at(_ h: Int, _ m: Int = 0) -> Date { cal.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: h, minute: m))! }
    check("끄기: 저녁에 끄면 다음 날 6시", ReactionRules.muteUntil(now: at(21), cal: cal) == cal.date(byAdding: .day, value: 1, to: at(6))!)
    check("끄기: 새벽 2시에 끄면 그날 6시", ReactionRules.muteUntil(now: at(2), cal: cal) == at(6))
    check("끄기: 6시 정각이면 다음 날 6시", ReactionRules.muteUntil(now: at(6), cal: cal) == cal.date(byAdding: .day, value: 1, to: at(6))!)
    check("지난 끄기는 버림", ReactionRules.active(["a": 10, "b": 30], now: 20) == ["b": 30])

    let shown = ReactionRules.line(id: "m-1", ev: "shown", src: "mind", kind: "mind:stuck", text: "줄1\n줄2", shownAt: nil, now: 100)
    check("보임: 글은 한 줄로, 걸린 시간 없음", shown["text"] as? String == "줄1 / 줄2" && shown["after"] == nil, "\(shown)")
    let long = ReactionRules.line(id: "m-1", ev: "shown", src: "mind", kind: "k", text: String(repeating: "가", count: 300), shownAt: nil, now: 1)
    check("보임: 글은 160자까지", (long["text"] as? String)?.count == 160)
    let ign = ReactionRules.line(id: "m-1", ev: "ignored", src: "mind", kind: "mind:stuck", text: "줄1", shownAt: 100, now: 107.04)
    check("반응: 글은 안 남기고 걸린 시간만", ign["text"] == nil && ign["after"] as? Double == 7.0, "\(ign)")

    let s = ReactionRules.Shown(id: "m-1", src: "mind", kind: "mind:stuck", at: 100)
    check("대화창을 2분 안에 열면 답한 것", ReactionRules.creditsChat(s, now: 200) && !ReactionRules.creditsChat(s, now: 221))
    var touched = s; touched.touched = true
    check("이미 손댄 말풍선·고양이 말 아닌 건 안 셈", !ReactionRules.creditsChat(touched, now: 150)
          && !ReactionRules.creditsChat(.init(id: "n-1", src: "agent", kind: "agent", at: 100), now: 150))
    check("손댄 사건", ReactionRules.touches("replied") && ReactionRules.touches("muted") && !ReactionRules.touches("read") && !ReactionRules.touches("shown"))

    let log = [
        #"{"id":"m-1","ev":"shown"}"#, #"{"id":"m-1","ev":"read"}"#,
        #"{"id":"m-2","ev":"shown"}"#, #"{"id":"m-2","ev":"detail"}"#, #"{"id":"m-2","ev":"rejected"}"#,
        #"{"id":"m-3","ev":"shown"}"#, #"{"id":"m-3","ev":"ignored"}"#,
        #"{"id":"m-4","ev":"dropped"}"#, "깨진 줄",
    ].joined(separator: "\n")
    let by = ReactionRules.byID(log)
    check("대표 반응: 강한 것", by == ["m-1": "read", "m-2": "rejected", "m-3": "ignored", "m-4": "dropped"], "\(by)")

    let said = ThinkRules.parse(#"{"ts": 1794059165.7005599, "trig": "long_focus", "p": 0.89, "kind": "proactive", "outcome": "said", "sid": "m-1794059165700"}"#)[0]
    let quiet = ThinkRules.parse(#"{"ts": 1794000000.25, "trig": "stuck", "p": 0.3, "kind": "proactive", "outcome": "quiet"}"#)[0]
    let chat = ThinkRules.parse(#"{"ts": 1.0, "kind": "chat", "outcome": "said"}"#)[0]
    check("판단 sid 읽기 · 키", said.sid == "m-1794059165700" && ThinkRules.key(said) == "m-1794059165700" && ThinkRules.key(quiet) == "t1794000000.250")
    check("라벨은 먼저 말 걸기의 말함·참음만", ThinkRules.labelable(said) && ThinkRules.labelable(quiet) && !ThinkRules.labelable(chat))
    check("라벨 버튼 글", ThinkRules.labelTitles(said).wrong == "괜히 말했다" && ThinkRules.labelTitles(quiet).wrong == "말했어야 했다")
    func json(_ o: [String: Any]) -> String { String(data: try! JSONSerialization.data(withJSONObject: o), encoding: .utf8)! }
    let ll = [json(ThinkRules.labelLine(said, verdict: "wrong", now: 1)), json(ThinkRules.labelLine(quiet, verdict: "right", now: 2)),
              json(ThinkRules.labelLine(said, verdict: "clear", now: 3)), json(ThinkRules.labelLine(said, verdict: "right", now: 4)),
              json(ThinkRules.labelLine(quiet, verdict: "clear", now: 5))].joined(separator: "\n")
    check("라벨: 마지막 것이 이기고 clear 는 지움", ThinkRules.labels(ll) == ["m-1794059165700": "right"], "\(ThinkRules.labels(ll))")
    check("끈 신호 판단 제목", ThinkRules.title(ThinkRules.parse(#"{"ts": 1.0, "trig": "drift", "kind": "proactive", "outcome": "muted"}"#)[0]) == "딴짓 · 끈 신호")
}

// MARK: 저장공간
do {
    let tb: UInt64 = 1_000_000_000_000
    check("저장공간 넉넉", Resource.diskLevel(.init(total: tb, free: 300_000_000_000)) == 0)
    check("저장공간 빠듯 (10% 밑)", Resource.diskLevel(.init(total: tb, free: 80_000_000_000)) == 1)
    check("저장공간 심각 (10GB 밑)", Resource.diskLevel(.init(total: tb, free: 8_000_000_000)) == 2)
    check("작은 디스크는 25GB 밑이면 빠듯", Resource.diskLevel(.init(total: 256_000_000_000, free: 20_000_000_000)) == 1)
    check("저장공간 단위 (1000 단위)", Resource.diskSize(tb) == "1TB" && Resource.diskSize(1_500_000_000_000) == "1.5TB"
          && Resource.diskSize(188_400_000_000) == "188GB" && Resource.diskSize(4_260_000_000) == "4.3GB",
          [Resource.diskSize(tb), Resource.diskSize(1_500_000_000_000), Resource.diskSize(188_400_000_000), Resource.diskSize(4_260_000_000)].joined(separator: " "))
    let d = Resource.Disk(total: 500, free: 600)
    check("남은 게 전체보다 크게 읽혀도 사용량은 0", d.used == 0 && d.usedFraction == 0)
}

// MARK: 행동 창
do {
    check("행동: 그 앱으로 감", ReactionRules.matches(.app(["com.anthropic.claudefordesktop"]), .app("com.anthropic.claudefordesktop")))
    check("행동: 다른 앱은 아님", !ReactionRules.matches(.app(["com.openai.codex"]), .app("com.google.Chrome")))
    check("행동: 자리 비움", ReactionRules.matches(.away, .away) && !ReactionRules.matches(.away, .app("x")) && !ReactionRules.matches(.app(["x"]), .away))
    check("눌러서 엶은 손댐, 관련 행동은 읽기보다 강함", ReactionRules.touches("opened")
          && ReactionRules.summary(["shown", "ignored", "acted"]) == "acted" && ReactionRules.summary(["shown", "opened", "acted"]) == "opened")
    check("끝남 짧은 답 기준 기본 90초", PhraseTable.defaults.param("done.min_turn_s") == 90)
}

print(failed == 0 ? "\n모두 통과" : "\n실패 \(failed)건")
exit(failed == 0 ? 0 : 1)
