import Foundation

/// 단축키 표기: ⌃⌥⇧⌘ 순서 + 키 ("⇧⌘T", "⌘[", "⌃←").
/// 메뉴(AX)에서 읽은 것과 키보드에서 잡은 것을 같은 글자로 맞춰야 "써 봤는지"를 셀 수 있다.
enum Keys {
    // AXMenuItemCmdModifiers 비트: ⌘는 기본, 3번 비트가 켜지면 ⌘ 없음
    static let axShift = 1, axOption = 2, axControl = 4, axNoCommand = 8

    static func mods(control: Bool, option: Bool, shift: Bool, command: Bool) -> String {
        (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "")
    }

    /// 물리 키 위치 → 글자 (미국 배열 기준. 한글 두벌식도 단축키는 이 위치로 동작한다)
    static let keyCodes: [Int: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W",
        14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9",
        26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L", 38: "J",
        39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 50: "`",
        36: "↩", 76: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    /// 키보드에서 누른 조합. ⌘나 ⌃가 없으면 nil (그냥 타자는 보지 않는다)
    static func chord(keyCode: Int, control: Bool, option: Bool, shift: Bool, command: Bool) -> String? {
        guard command || control, let k = keyCodes[keyCode] else { return nil }
        return mods(control: control, option: option, shift: shift, command: command) + k
    }

    /// ⇧를 눌러야 나오는 기호 → 그 자리의 기본 글자
    private static let shifted: [Character: String] = [
        "{": "[", "}": "]", "<": ",", ">": ".", "?": "/", ":": ";", "\"": "'", "|": "\\", "_": "-", "~": "`",
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
    ]

    /// 메뉴 항목의 단축키 (AXMenuItemCmdChar / VirtualKey / Modifiers).
    /// ⌘도 ⌃도 없는 것(⌥만, fn 조합 등)은 버린다: 키보드 쪽에서 셀 수 없고 AX가 fn을 표시하지 못한다.
    static func menu(char: String?, virtualKey: Int?, modifiers: Int) -> String? {
        let command = modifiers & axNoCommand == 0
        let control = modifiers & axControl != 0
        guard command || control else { return nil }
        var shift = modifiers & axShift != 0
        var key: String?
        if let c = char?.first, char?.count == 1 {
            if let base = shifted[c] {
                key = base; shift = true
            } else if c == "+" {
                key = "+"
            } else if let special = specialChar(c) {
                key = special
            } else if c == " " {
                key = "Space"
            } else if c.isASCII, !c.isWhitespace {
                key = String(c).uppercased()
            }
        }
        if key == nil, let vk = virtualKey { key = keyCodes[vk] }
        guard let key else { return nil }
        return mods(control: control, option: modifiers & axOption != 0, shift: shift, command: command) + key
    }

    private static func specialChar(_ c: Character) -> String? {
        guard let u = c.unicodeScalars.first?.value else { return nil }
        switch u {
        case 0x08, 0x7F: return "⌫"
        case 0x1B: return "⎋"
        case 0x09: return "⇥"
        case 0x0D, 0x03: return "↩"
        case 0xF700: return "↑"
        case 0xF701: return "↓"
        case 0xF702: return "←"
        case 0xF703: return "→"
        case 0xF728: return "⌦"
        case 0xF729: return "↖"
        case 0xF72B: return "↘"
        case 0xF72C: return "⇞"
        case 0xF72D: return "⇟"
        case 0xF704...0xF70F: return "F\(u - 0xF704 + 1)"
        default: return nil
        }
    }

    /// 이 표기를 키보드로 누르면 나올 수 있는 조합들. "⌘+"는 보통 ⌘=로 누르므로 둘 다.
    static func variants(_ keys: String) -> [String] {
        guard keys.hasSuffix("+") else { return [keys] }
        let m = String(keys.dropLast())
        let withShift = m.contains("⇧") ? m : m.replacingOccurrences(of: "⌘", with: "⇧⌘")
        return [m + "=", withShift + "="]
    }
}

/// 메뉴 막대에서 읽은 항목 하나
struct MenuShortcut: Equatable {
    let title: String
    let keys: String
}

/// 클릭한 요소에서 단축키 판단에 필요한 것만
struct ShortcutClick {
    var bundle: String?
    var role: String
    var subrole: String?
    var label: String?
    var menuKeys: String?         // 누른 게 메뉴 항목이면 그 항목의 단축키
    var inWeb = false             // 웹 내용(AXWebArea) 안쪽인지
}

/// 알려 줄 단축키
struct ShortcutHint: Equatable {
    let id: String                // "범위|대표 키" — 쓴 횟수·알림 기록의 열쇠
    let keys: String              // 보여 줄 표기
    let title: String             // 무엇을 하는지
    let accepts: [String]         // 이 중 하나를 키보드로 누르면 "썼다"로 센다
    let scope: String             // 앱 번들 ID, 또는 시스템 전체면 "system"
}

/// 클릭 → 단축키. 확실한 것만 말한다: 이름이 정확히 같은 메뉴 항목, 창 단추, 브라우저·Dock 고정 규칙.
/// 느슨하게 맞추면 "대화상자 닫기 → ⌘W(세션 닫기)" 같은 위험한 오답이 나온다 (docs/SHORTCUT_HINTS.md).
enum ShortcutRules {
    static let browsers: Set<String> = [
        "com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser", "com.brave.Browser",
        "com.microsoft.edgemac", "com.naver.Whale",
    ]
    static let dock = "com.apple.dock"

    /// 단추 이름이 같아도 메뉴와 하는 일이 다를 수 있는 이름. 메시지 "복사" 단추는 ⌘C(선택 복사)와 다르고,
    /// 대화상자 "닫기"는 창 닫기가 아니다.
    static let ambiguousLabels: Set<String> = [
        "닫기", "Close", "확인", "OK", "취소", "Cancel", "완료", "Done", "다음", "Next", "이전", "Previous",
        "열기", "Open", "저장", "Save", "삭제", "Delete", "복사", "Copy", "붙여넣기", "Paste", "잘라내기", "Cut",
        "모두 선택", "Select All", "실행 취소", "Undo", "다시 실행", "Redo", "찾기", "Find", "새로 만들기", "New",
        "확대", "축소", "공유", "Share", "보내기", "Send", "제출", "Submit",
    ]

    static let closeTitles = ["창 닫기", "윈도우 닫기", "Close Window"]
    static let minimizeTitles = ["최소화", "Minimize"]
    static let fullScreenTitles = ["전체 화면 시작", "전체 화면으로 전환", "전체화면 열기", "Enter Full Screen"]

    /// - spacesKeys: ⌃←/⌃→가 켜져 있으면 true (시스템 설정 › 키보드 단축키 › Mission Control)
    /// - spotlight: Spotlight 단축키 표기 (꺼져 있으면 nil)
    /// - isRunning: Dock 아이콘 이름의 앱이 이미 켜져 있는지
    static func hint(for c: ShortcutClick, menu: [MenuShortcut], spacesKeys: Bool, spotlight: String?,
                     isRunning: (String) -> Bool) -> ShortcutHint? {
        let label = c.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let app = c.bundle ?? "?"

        // 1. 메뉴 항목(메뉴 막대·우클릭 메뉴): 항목에 적힌 단축키 그대로
        if c.role == "AXMenuItem" {
            guard let k = c.menuKeys, !label.isEmpty else { return nil }
            return ShortcutHint(id: "\(app)|\(k)", keys: k, title: label, accepts: Keys.variants(k), scope: app)
        }

        // 2. Dock 아이콘 · Mission Control
        if c.bundle == dock {
            if c.subrole == "AXApplicationDockItem", !label.isEmpty {
                if isRunning(label) {
                    return ShortcutHint(id: "system|⌘⇥", keys: "⌘⇥", title: "앱 전환", accepts: ["⌘⇥", "⇧⌘⇥"], scope: "system")
                }
                if let s = spotlight {
                    return ShortcutHint(id: "system|\(s)", keys: s, title: "Spotlight로 앱 열기", accepts: [s], scope: "system")
                }
                return nil
            }
            // Mission Control 위쪽 데스크톱 줄: "데스크탑 2", 나란히 띄운 전체 화면은 "A 및 B".
            // 앱 이름 하나짜리는 창 썸네일인지 전체 화면 데스크톱인지 구분이 안 돼 말하지 않는다
            if c.role == "AXButton", spacesKeys,
               label.hasPrefix("데스크탑") || label.hasPrefix("데스크톱") || label.hasPrefix("Desktop") || label.contains(" 및 ") {
                return ShortcutHint(id: "system|⌃←", keys: "⌃← ⌃→", title: "데스크톱 이동",
                                    accepts: ["⌃←", "⌃→"] + (1...9).map { "⌃\($0)" }, scope: "system")
            }
            return nil
        }

        // 3. 창 단추: 그 앱 메뉴에서 같은 일을 하는 항목을 찾는다 (Claude는 ⌘W가 세션 닫기, 창 닫기는 ⇧⌘W)
        let windowTitles: [String]? = switch c.subrole {
        case "AXCloseButton": closeTitles
        case "AXMinimizeButton": minimizeTitles
        case "AXFullScreenButton": fullScreenTitles
        default: nil
        }
        if let titles = windowTitles {
            guard let m = titles.lazy.compactMap({ t in menu.first { $0.title == t } }).first else { return nil }
            return ShortcutHint(id: "\(app)|\(m.keys)", keys: m.keys, title: m.title, accepts: Keys.variants(m.keys), scope: app)
        }

        // 4. 브라우저 주소창 · 탭 (웹 페이지 안의 입력칸·탭은 제외)
        if browsers.contains(app), !c.inWeb {
            if ["AXTextField", "AXComboBox"].contains(c.role),
               label.contains("주소") || label.localizedCaseInsensitiveContains("address") || label.contains("검색 필드")
                || label.localizedCaseInsensitiveContains("search field") {
                return ShortcutHint(id: "\(app)|⌘L", keys: "⌘L", title: "주소창으로", accepts: ["⌘L"], scope: app)
            }
            if c.subrole == "AXTabButton" {
                return ShortcutHint(id: "\(app)|⌃⇥", keys: "⌃⇥ · ⌘1~9", title: "탭 이동",
                                    accepts: ["⌃⇥", "⌃⇧⇥", "⇧⌘[", "⇧⌘]", "⌥⌘←", "⌥⌘→"] + (1...9).map { "⌘\($0)" }, scope: app)
            }
        }

        // 5. 단추 이름 = 같은 앱 메뉴 항목 이름 (정확히 같을 때만). 브라우저는 페이지 속 "뒤로" 단추를 빼려고 웹 바깥만
        if ["AXButton", "AXMenuButton"].contains(c.role), !label.isEmpty, !ambiguousLabels.contains(label),
           !(browsers.contains(app) && c.inWeb), let m = menu.first(where: { $0.title == label }) {
            return ShortcutHint(id: "\(app)|\(m.keys)", keys: m.keys, title: m.title, accepts: Keys.variants(m.keys), scope: app)
        }
        return nil
    }
}

/// 힌트를 언제 보여 줄지. 숫자는 실험으로 정해진 값이 아니라 비슷한 프로그램 기본값에서 가져온 출발점.
struct ShortcutLedger: Codable {
    struct Entry: Codable {
        var keys: String
        var title: String
        var scope: String
        var accepts: [String]
        var mouse: [String: Int] = [:]     // 날짜 → 마우스로 한 횟수
        var keyboard: [String: Int] = [:]  // 날짜 → 단축키로 한 횟수
        var hinted: [String] = []          // 힌트를 보여 준 날짜
        var muted = false

        var keyboardTotal: Int { keyboard.values.reduce(0, +) }
    }

    static let mouseBeforeHint = 3     // 같은 날 마우스로 이만큼 하면 (Key Promoter류 기본 3~5)
    static let learnedAfter = 3        // 단축키로 이만큼 쓰면 익힌 걸로 보고 더 말하지 않는다
    static let dailyCap = 10           // 하루 힌트 수
    static let minGap: TimeInterval = 20
    static let keepDays = 30

    var entries: [String: Entry] = [:]
    var shown: [String: Int] = [:]     // 날짜 → 그날 보여 준 힌트 수
    var lastShownAt: Date?

    /// 마우스로 한 번 했다. 지금 힌트를 보여 줄 만하면 true (보여 줬다는 기록은 markShown에서)
    mutating func noteMouse(_ h: ShortcutHint, day: String, now: Date) -> Bool {
        var e = entries[h.id] ?? Entry(keys: h.keys, title: h.title, scope: h.scope, accepts: h.accepts)
        e.keys = h.keys; e.title = h.title; e.accepts = h.accepts
        e.mouse[day, default: 0] += 1
        entries[h.id] = e
        guard !e.muted, e.keyboardTotal < Self.learnedAfter, !e.hinted.contains(day),
              e.mouse[day, default: 0] >= Self.mouseBeforeHint,
              shown[day, default: 0] < Self.dailyCap else { return false }
        if let last = lastShownAt, now.timeIntervalSince(last) < Self.minGap { return false }
        return true
    }

    mutating func markShown(_ id: String, day: String, now: Date) {
        entries[id]?.hinted.append(day)
        shown[day, default: 0] += 1
        lastShownAt = now
    }

    /// 키보드로 조합을 눌렀다. 마우스로 해 본 적 있는 동작만 센다 (그 밖의 조합은 남기지 않는다)
    mutating func noteChord(_ chord: String, frontBundle: String?, day: String) -> [String] {
        var hit: [String] = []
        for (id, e) in entries where e.accepts.contains(chord) && (e.scope == "system" || e.scope == frontBundle) {
            entries[id]?.keyboard[day, default: 0] += 1
            hit.append(id)
        }
        return hit
    }

    /// 오래된 날짜 지우기 (days: 남길 날짜들). 단축키 횟수는 "익혔는지" 판단에 쓰므로 남긴다
    mutating func prune(keeping days: Set<String>) {
        entries = entries.mapValues { e in
            var e = e
            e.mouse = e.mouse.filter { days.contains($0.key) }
            e.hinted = e.hinted.filter { days.contains($0) }
            return e
        }
        shown = shown.filter { days.contains($0.key) }
    }

    /// 최근(days 안) 마우스로 많이 한 순서
    func top(days: Set<String>, limit: Int) -> [(id: String, entry: Entry, mouse: Int)] {
        entries.map { (id: $0.key, entry: $0.value, mouse: $0.value.mouse.filter { days.contains($0.key) }.values.reduce(0, +)) }
            .filter { $0.mouse > 0 }
            .sorted { $0.mouse > $1.mouse }
            .prefix(limit).map { $0 }
    }
}
