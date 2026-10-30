import AppKit

/// 안 쓰는 앱을 찾아 묻거나 (허락받은 앱은) 알아서 끈다. 판단은 CleanupRules.
/// 끌 때는 항상 terminate(): 앱에 "종료해 달라"고 부탁하는 것이라 저장 안 한 게 있으면 앱이 먼저 묻는다. 강제 종료는 하지 않는다.
final class AppCleaner: NSObject {
    struct Pending {
        let key: String
        let name: String
        let reason: String
        let canAutomate: Bool
        let until: Date
    }
    enum Answer { case quit, quitAndAutomate, later, never }

    var notify: ((_ text: String, _ validUntil: Date) -> Void)?
    var changed: (() -> Void)?
    private(set) var pending: Pending?

    private var lastTick = Date.distantPast
    private var lastAsk = Date.distantPast
    private var startedAt = Date()
    private var avgCPU: [String: (value: Double, at: Date)] = [:]
    private var recent: [(name: String, url: URL)] = []
    private var latest: Resource.Sample?

    static let tickEvery: TimeInterval = 60
    /// 묻는 건 1시간에 한 번까지
    static let askGap: TimeInterval = 3600
    static let answerWait: TimeInterval = 30 * 60
    static let snoozeLater: TimeInterval = 3 * 86400
    /// 입력이 이보다 오래 없으면 자리에 없는 것으로 보고 묻지 않는다
    static let awayAfter: TimeInterval = 5 * 60
    static let quitWait: TimeInterval = 20

    private let defaults = UserDefaults.standard
    private var isOff: Bool {
        get { defaults.bool(forKey: "cleanupOff") }
        set { defaults.set(newValue, forKey: "cleanupOff") }
    }
    private var always: [String: String] {
        get { defaults.dictionary(forKey: "cleanupAlways") as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: "cleanupAlways") }
    }
    private var never: [String: String] {
        get { defaults.dictionary(forKey: "cleanupNever") as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: "cleanupNever") }
    }
    private var snoozed: [String: Date] {
        get { defaults.dictionary(forKey: "cleanupSnoozed") as? [String: Date] ?? [:] }
        set { defaults.set(newValue, forKey: "cleanupSnoozed") }
    }
    /// 앱별 마지막 사용 시각. 활동 기록이 켜져 있을 때만 디스크에 남긴다 ("고양이만"은 아무것도 저장하지 않는다는 약속).
    /// 꺼져 있으면 메모리에만 두므로 다시 시작하면 그때부터 다시 잰다 (덜 오래 안 쓴 것으로 보니 안전한 쪽이다).
    private lazy var lastUsed: [String: Date] = defaults.dictionary(forKey: Self.lastUsedKey) as? [String: Date] ?? [:]
    private static let lastUsedKey = "cleanupLastUsed"
    private static let lastUsedKeep: TimeInterval = 30 * 86400

    private func saveLastUsed() {
        guard !Context.shared.snapshot.paused, !isOff else { defaults.removeObject(forKey: Self.lastUsedKey); return }
        let cutoff = Date().addingTimeInterval(-Self.lastUsedKeep)
        lastUsed = lastUsed.filter { $0.value > cutoff }
        defaults.set(lastUsed, forKey: Self.lastUsedKey)
    }
    /// 시간 기준은 defaults 로 조절할 수 있다 (시간 단위)
    private var limits: Cleanup.Limits {
        var l = Cleanup.Limits()
        let ask = defaults.double(forKey: "cleanupAskIdleHours"), quiet = defaults.double(forKey: "cleanupQuietIdleHours")
        if ask > 0 { l.askIdle = ask * 3600 }
        if quiet > 0 { l.quietIdle = quiet * 3600 }
        return l
    }

    func start() {
        saveLastUsed()   // 기록을 끈 채 시작했다면 남아 있던 것도 지운다
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(activated(_:)),
                                                          name: NSWorkspace.didActivateApplicationNotification, object: nil)
    }

    @objc private func activated(_ n: Notification) {
        guard let path = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleURL?.path else { return }
        lastUsed[path] = Date()
        saveLastUsed()
        if pending?.key == path { resolve() }   // 다시 쓰기 시작했으면 물을 일이 없다
    }

    /// ResourceWatch 가 새로 읽을 때마다 부른다
    func observe(_ s: Resource.Sample, canAsk: Bool) {
        latest = s
        for (key, a) in s.everyApp {
            // 5분쯤 되는 평균: 읽는 간격(2초·10초)이 달라도 같게
            if let old = avgCPU[key] {
                let k = 1 - exp(-s.at.timeIntervalSince(old.at) / 300)
                avgCPU[key] = (old.value + (a.cpu - old.value) * k, s.at)
            } else {
                avgCPU[key] = (a.cpu, s.at)
            }
        }
        avgCPU = avgCPU.filter { s.everyApp[$0.key] != nil }
        guard !isOff, s.at.timeIntervalSince(lastTick) >= Self.tickEvery else { return }
        lastTick = s.at
        tick(s, canAsk: canAsk)
    }

    private func candidates(_ s: Resource.Sample) -> [(Cleanup.Candidate, NSRunningApplication)] {
        let used = lastUsed
        let windows = Self.ownersWithWindows()
        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy != .prohibited, !app.isTerminated, app.processIdentifier != getpid(),
                  let url = app.bundleURL, let stat = s.everyApp[url.path] else { return nil }
            let launched = app.launchDate ?? startedAt
            let seen = max(launched, startedAt)
            return (Cleanup.Candidate(key: url.path, bundleID: app.bundleIdentifier ?? "", name: app.localizedName ?? stat.name,
                                      regular: app.activationPolicy == .regular, front: app.isActive,
                                      hasWindows: windows.contains(app.processIdentifier),
                                      idle: s.at.timeIntervalSince(max(used[url.path] ?? seen, launched)),
                                      tracked: s.at.timeIntervalSince(seen),
                                      avgCPU: avgCPU[url.path]?.value ?? stat.cpu, memBytes: stat.memBytes), app)
        }
    }

    private func tick(_ s: Resource.Sample, canAsk: Bool) {
        if let p = pending, !NSWorkspace.shared.runningApplications.contains(where: { $0.bundleURL?.path == p.key }) {
            resolve()   // 사용자가 직접 껐다
        } else if let p = pending, s.at >= p.until {
            snooze(p.key)   // 답이 없으면 끄지 않고 넘어간다
            resolve()
        }
        let prefs = Cleanup.Prefs(always: Set(always.keys), never: Set(never.keys), snoozedUntil: snoozed)
        let list = candidates(s)
        let l = limits
        var ask: (Cleanup.Candidate, String)?
        for (c, app) in list {
            switch Cleanup.decide(c, pressure: s.pressure, prefs: prefs, now: s.at, limits: l) {
            case .keep: break
            case .auto(let why):
                Log.write("앱 정리(자동): \(c.name) — \(why)")
                quit(app, name: c.name, memBytes: c.memBytes, announce: true)
            case .ask(let why):
                if c.memBytes > ask?.0.memBytes ?? 0 || ask == nil { ask = (c, why) }   // 제일 큰 것부터
            }
        }
        guard let (c, why) = ask, pending == nil, canAsk, s.at.timeIntervalSince(lastAsk) >= Self.askGap,
              Self.secondsSinceInput() < Self.awayAfter else { return }
        lastAsk = s.at
        let until = s.at.addingTimeInterval(Self.answerWait)
        pending = Pending(key: c.key, name: c.name, reason: why, canAutomate: c.regular, until: until)
        Log.write("앱 정리(묻기): \(c.name) — \(why)")
        notify?("🧹 \(c.name), \(why)\n정리할까냥? (누르면 고른다냥)", until)
        changed?()
    }

    /// 대시보드·메뉴에서 고른 것
    func answer(_ a: Answer) {
        guard let p = pending else { return }
        switch a {
        case .later: snooze(p.key)
        case .never:
            var m = never
            m[p.key] = p.name
            never = m
        case .quit, .quitAndAutomate:
            if a == .quitAndAutomate {
                var m = always
                m[p.key] = p.name
                always = m
            }
            if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.path == p.key }) {
                quit(app, name: p.name, memBytes: latest?.everyApp[p.key]?.memBytes ?? 0, announce: false)
            }
        }
        Log.write("앱 정리(답): \(p.name) → \(a)")
        resolve()
    }

    private func resolve() {
        pending = nil
        changed?()
    }

    private func snooze(_ key: String) {
        var m = snoozed.filter { $0.value > Date() }
        m[key] = Date().addingTimeInterval(Self.snoozeLater)
        snoozed = m
    }

    /// 부탁만 한다. 안 꺼지면 (저장 창이 떴거나 거절) 그대로 두고 며칠 건드리지 않는다
    private func quit(_ app: NSRunningApplication, name: String, memBytes: UInt64, announce: Bool) {
        guard let url = app.bundleURL, app.terminate() else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.quitWait) { [weak self] in
            guard let self else { return }
            guard app.isTerminated else {
                Log.write("앱 정리: \(name) 안 꺼짐 (저장 창이거나 거절) — 그대로 둔다")
                self.snooze(url.path)
                if !announce { self.notify?("🧹 \(name)이(가) 아직 안 꺼졌다냥. 저장할 게 있는지 봐 달라냥", Date().addingTimeInterval(600)) }
                return
            }
            self.recent.insert((name, url), at: 0)
            self.recent = Array(self.recent.prefix(5))
            self.notify?("🧹 \(name) 정리했다냥 (메모리 \(Resource.bytes(memBytes)) 비움)\n메뉴에서 다시 열 수 있다냥", Date().addingTimeInterval(600))
        }
    }

    private static func secondsSinceInput() -> TimeInterval {
        [CGEventType.keyDown, .leftMouseDown, .mouseMoved, .scrollWheel]
            .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? .infinity
    }

    /// 창(내려 둔 것 포함)을 가진 프로세스들. 메뉴바 아이콘 같은 건 일반 창 층이 아니라서 빠진다
    private static func ownersWithWindows() -> Set<pid_t> {
        guard let info = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        var out: Set<pid_t> = []
        for w in info where w[kCGWindowLayer as String] as? Int == 0 {
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat], (b["Height"] ?? 0) > 60, (b["Width"] ?? 0) > 60 else { continue }
            out.insert(pid)
        }
        return out
    }

    // MARK: 메뉴

    func addMenuItems(to menu: NSMenu) {
        let top = NSMenuItem(title: "🧹 앱 정리", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        func info(_ t: String) { let i = NSMenuItem(title: t, action: nil, keyEquivalent: ""); i.isEnabled = false; sub.addItem(i) }
        func list(_ title: String, _ items: [String: String], _ sel: Selector) {
            guard !items.isEmpty else { return }
            let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let m = NSMenu()
            for (k, name) in items.sorted(by: { $0.value < $1.value }) { m.addItem(name, sel, target: self).representedObject = k }
            it.submenu = m
            sub.addItem(it)
        }
        if let p = pending {
            info("\(p.name): \(p.reason)")
            sub.addItem("정리하기", #selector(menuQuit), target: self)
            if p.canAutomate { sub.addItem("정리하고 앞으로 자동 정리", #selector(menuAutomate), target: self) }
            sub.addItem("이번엔 두기", #selector(menuLater), target: self)
            sub.addItem("항상 두기", #selector(menuNever), target: self)
            sub.addItem(.separator())
        }
        sub.addItem(isOff ? "🔔 정리 제안 켜기" : "🔕 정리 제안 끄기 (자동 정리도 멈춤)", #selector(toggleOff), target: self)
        list("자동 정리하는 앱 (누르면 해제)", always, #selector(removeAlways(_:)))
        list("항상 두는 앱 (누르면 해제)", never, #selector(removeNever(_:)))
        if !recent.isEmpty {
            let it = NSMenuItem(title: "최근 정리한 앱 (누르면 다시 열기)", action: nil, keyEquivalent: "")
            let m = NSMenu()
            for r in recent { m.addItem(r.name, #selector(reopen(_:)), target: self).representedObject = r.url }
            it.submenu = m
            sub.addItem(it)
        }
        top.submenu = sub
        menu.addItem(top)
    }

    @objc private func menuQuit() { answer(.quit) }
    @objc private func menuAutomate() { answer(.quitAndAutomate) }
    @objc private func menuLater() { answer(.later) }
    @objc private func menuNever() { answer(.never) }
    @objc private func toggleOff() {
        isOff.toggle()
        if isOff { lastUsed = [:] }
        saveLastUsed()
    }

    @objc private func removeAlways(_ sender: NSMenuItem) {
        guard let k = sender.representedObject as? String else { return }
        var m = always
        m[k] = nil
        always = m
    }

    @objc private func removeNever(_ sender: NSMenuItem) {
        guard let k = sender.representedObject as? String else { return }
        var m = never
        m[k] = nil
        never = m
    }

    @objc private func reopen(_ sender: NSMenuItem) {
        guard let u = sender.representedObject as? URL else { return }
        NSWorkspace.shared.openApplication(at: u, configuration: .init())
    }
}
