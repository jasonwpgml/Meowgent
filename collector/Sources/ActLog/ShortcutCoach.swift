import AppKit
import ApplicationServices

/// 앱 메뉴 막대의 단축키 목록. 앱이 앞으로 올 때 백그라운드에서 읽어 앱별로 캐시한다.
/// 실측: Claude 68개 0.06초, Chrome 84개 0.25초 (docs/SHORTCUT_HINTS.md)
final class MenuIndex {
    static let maxAge: TimeInterval = 60     // 메뉴는 상태에 따라 바뀐다 (Chrome 탭 1개면 "창 닫기 ⌘W")
    private var cache: [pid_t: (at: Date, items: [MenuShortcut])] = [:]   // 메인 스레드에서만 만진다
    private var waiting: [pid_t: [([MenuShortcut]) -> Void]] = [:]
    private let queue = DispatchQueue(label: "actlog.menus", qos: .utility)

    /// 이 앱 메뉴를 한 번이라도 읽어 뒀나 (오래됐어도)
    func has(_ pid: pid_t) -> Bool { cache[pid] != nil }

    /// 캐시가 새것이면 바로, 아니면 다시 읽은 뒤 done (메인 스레드)
    func items(_ pid: pid_t, done: @escaping ([MenuShortcut]) -> Void) {
        if let c = cache[pid], Date().timeIntervalSince(c.at) < Self.maxAge { done(c.items); return }
        if waiting[pid] != nil { waiting[pid]!.append(done); return }
        waiting[pid] = [done]
        queue.async {
            let items = Self.read(pid)
            DispatchQueue.main.async { [self] in
                cache[pid] = (Date(), items)
                cache = cache.filter { NSRunningApplication(processIdentifier: $0.key) != nil }
                waiting.removeValue(forKey: pid)?.forEach { $0(items) }
            }
        }
    }

    static func read(_ pid: pid_t) -> [MenuShortcut] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        guard let bar = AX.element(app, kAXMenuBarAttribute) else { return [] }
        var out: [MenuShortcut] = []
        var nodes = 0
        let start = Date()
        func walk(_ el: AXUIElement, depth: Int) {
            for k in AX.children(el) {
                nodes += 1
                if nodes > 3000 || Date().timeIntervalSince(start) > 1.5 { return }
                // 노드마다 다섯 번 묻지 않고 한 번에 (AX 왕복이 비용의 대부분)
                let v = AX.values(k, [kAXTitleAttribute, kAXRoleAttribute, kAXMenuItemCmdCharAttribute,
                                      kAXMenuItemCmdVirtualKeyAttribute, kAXMenuItemCmdModifiersAttribute])
                let title = v[0] as? String ?? ""
                if v[1] as? String == "AXMenuItem", !title.isEmpty,
                   let keys = Keys.menu(char: v[2] as? String,
                                        virtualKey: (v[3] as? NSNumber)?.intValue,
                                        modifiers: (v[4] as? NSNumber)?.intValue ?? 0) {
                    out.append(MenuShortcut(title: title, keys: keys))
                }
                if depth < 5, !["서비스", "Services"].contains(title) { walk(k, depth: depth + 1) }
            }
        }
        // 0번은 Apple 메뉴 (강제 종료·잠금 화면)
        for top in AX.children(bar).dropFirst() { walk(top, depth: 1) }
        return out
    }
}

/// 마우스로 한 일에 단축키가 있으면 고양이가 키캡으로 알려 준다.
/// 기록: 동작별 날짜별 마우스·단축키 횟수만 (shortcuts.json). 누른 글자나 그 밖의 조합은 남기지 않는다.
final class ShortcutCoach: NSObject {
    let menus = MenuIndex()
    /// 고양이가 실제로 보여 줬으면 true (숨김·말하는 중이면 false)
    var show: ((ShortcutHint) -> Bool)?
    private var ledger = ShortcutLedger()
    private let url: URL
    private var saveWork: DispatchWorkItem?
    private var lastHint: ShortcutHint?
    private var system: (at: Date, spaces: Bool, spotlight: String?)?

    var hintsOn: Bool {
        get { UserDefaults.standard.object(forKey: "shortcutHints") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "shortcutHints") }
    }

    init(dataDir: URL) {
        url = dataDir.appendingPathComponent("shortcuts.json")
        super.init()
        if let d = try? Data(contentsOf: url), let l = try? JSONDecoder().decode(ShortcutLedger.self, from: d) { ledger = l }
        ledger.prune(keeping: Self.days(ShortcutLedger.keepDays))
    }

    func start() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != getpid(), !Privacy.isBlocked(bundle: app.bundleIdentifier), let self else { return }
            // 처음 보는 앱만 미리 읽어 둔다. 오래된 캐시는 실제로 클릭했을 때 새로 읽는다
            // (앱을 오갈 때마다 다시 읽으면 메뉴 큰 앱은 0.3~1.5초씩 CPU 를 먹는다)
            if !self.menus.has(app.processIdentifier) { self.menus.items(app.processIdentifier) { _ in } }
        }
    }

    // MARK: 입력

    func clicked(_ c: ShortcutClick, pid: pid_t?) {
        guard !Context.shared.snapshot.paused else { return }
        guard let pid else { return evaluate(c, menu: []) }
        menus.items(pid) { [weak self] items in self?.evaluate(c, menu: items) }
    }

    private func evaluate(_ c: ShortcutClick, menu: [MenuShortcut]) {
        let sys = systemKeys()
        // 실행 중인 앱 이름은 규칙이 실제로 물을 때만 모은다: localizedName 은 앱마다 LaunchServices XPC 왕복이라
        // 클릭마다 다 모으면 50ms 넘게 걸린다 (실측 sample)
        var names: Set<String>?
        guard let h = ShortcutRules.hint(for: c, menu: menu, spacesKeys: sys.spaces, spotlight: sys.spotlight,
                                         isRunning: { app in
                                             if names == nil { names = Set(NSWorkspace.shared.runningApplications.compactMap(\.localizedName)) }
                                             return names!.contains(app)
                                         }) else { return }
        let now = Date(), day = Self.day(now)
        if ledger.noteMouse(h, day: day, now: now), hintsOn, show?(h) == true {
            ledger.markShown(h.id, day: day, now: now)
            lastHint = h
            Log.write("단축키 힌트: \(h.keys) \(h.title)")
        }
        scheduleSave()
    }

    /// ⌘·⌃ 조합을 눌렀다 (입력 탭에서, 메인 스레드)
    func chord(_ chord: String) {
        let s = Context.shared.snapshot
        guard !s.paused, !s.blocked else { return }
        if !ledger.noteChord(chord, frontBundle: s.bundle, day: Self.day(Date())).isEmpty { scheduleSave() }
    }

    // MARK: 시스템 단축키 (시스템 설정 › 키보드 단축키)

    /// com.apple.symbolichotkeys: 79/81 = 데스크톱 왼쪽/오른쪽(⌃←/⌃→), 64 = Spotlight. 항목이 없으면 기본값(켜짐)
    private func systemKeys() -> (spaces: Bool, spotlight: String?) {
        if let s = system, Date().timeIntervalSince(s.at) < 600 { return (s.spaces, s.spotlight) }
        let all = UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys") ?? [:]
        func entry(_ id: Int) -> [String: Any]? { all[String(id)] as? [String: Any] }
        func on(_ id: Int) -> Bool { (entry(id)?["enabled"] as? NSNumber)?.boolValue ?? true }
        var spotlight: String? = on(64) ? "⌘Space" : nil
        if on(64), let p = (entry(64)?["value"] as? [String: Any])?["parameters"] as? [Int], p.count == 3 {
            let f = p[2]
            spotlight = Keys.chord(keyCode: p[1], control: f & 262144 != 0, option: f & 524288 != 0,
                                   shift: f & 131072 != 0, command: f & 1048576 != 0)
        }
        let r = (spaces: on(79) && on(81), spotlight: spotlight)
        system = (Date(), r.spaces, r.spotlight)
        return r
    }

    // MARK: 저장

    private func scheduleSave() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: w)
    }

    private func save() {
        guard let d = try? JSONEncoder().encode(ledger) else { return }
        try? d.write(to: url, options: .atomic)
    }

    static func day(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    /// 오늘부터 n일 전까지의 날짜들
    static func days(_ n: Int) -> Set<String> {
        Set((0..<n).compactMap { Calendar.current.date(byAdding: .day, value: -$0, to: Date()).map(day) })
    }

    // MARK: 메뉴 (고양이 우클릭 메뉴)

    func addMenuItems(to menu: NSMenu) {
        let top = NSMenuItem(title: "⌨️ 단축키 힌트", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let toggle = sub.addItem("힌트 보여 주기", #selector(toggleHints), target: self)
        toggle.state = hintsOn ? .on : .off
        if let h = lastHint, ledger.entries[h.id]?.muted == false {
            let it = sub.addItem("방금 힌트(\(h.keys) \(h.title)) 그만 보기", #selector(toggleMute(_:)), target: self)
            it.representedObject = h.id
        }
        sub.addItem(.separator())
        let rows = ledger.top(days: Self.days(7), limit: 8)
        let head = NSMenuItem(title: rows.isEmpty ? "아직 기록 없다" : "최근 7일 마우스로 한 것 (✓ = 힌트 켜짐)", action: nil, keyEquivalent: "")
        head.isEnabled = false
        sub.addItem(head)
        for r in rows {
            let learned = r.entry.keyboardTotal >= ShortcutLedger.learnedAfter
            let it = sub.addItem("\(r.entry.keys)  \(r.entry.title) — 마우스 \(r.mouse) · 단축키 \(r.entry.keyboardTotal)\(learned ? " (익힘)" : "")",
                          #selector(toggleMute(_:)), target: self)
            it.representedObject = r.id
            it.state = r.entry.muted ? .off : .on
        }
        top.submenu = sub
        menu.addItem(top)
    }

    @objc private func toggleHints() { hintsOn.toggle() }

    @objc private func toggleMute(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, ledger.entries[id] != nil else { return }
        ledger.entries[id]!.muted.toggle()
        save()
    }
}
