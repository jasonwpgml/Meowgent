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

print(failed == 0 ? "\n모두 통과" : "\n실패 \(failed)건")
exit(failed == 0 ? 0 : 1)
