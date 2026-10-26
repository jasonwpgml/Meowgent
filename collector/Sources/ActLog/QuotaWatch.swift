import AppKit

/// 에이전트 사용 한도·리셋권을 1분마다 읽어서 놓치기 쉬운 것을 고양이 말풍선으로 알려 준다.
/// 데이터: CodexBar가 로컬에 남기는 파일(Claude·Codex·Cursor·Grok) + Codex 세션 기록(없을 때 대신) + 직접 적은 리셋권.
/// 외부로 보내는 것 없음. 토큰·쿠키는 읽지 않는다.
final class QuotaWatch: NSObject {
    struct Notice { let text: String; let urgent: Bool; let validUntil: Date }
    var notify: ((Notice) -> Void)?
    /// CodexBar에 Codex 값이 없을 때 쓰는 세션 기록 값 (AgentMonitor)
    var codexFallback: () -> [Quota.Window] = { [] }

    private let dataDir: URL
    private let home = FileManager.default.homeDirectoryForCurrentUser
    private let queue = DispatchQueue(label: "meowgent.quota", qos: .utility)
    private var timer: Timer?
    private var cal: Calendar = { var c = Calendar(identifier: .gregorian); c.locale = Locale(identifier: "ko_KR"); return c }()

    // 메인 스레드에서만 만진다
    private(set) var windows: [Quota.Window] = []
    private(set) var credits: [Quota.Credit] = []
    private var previous: [String: Quota.Window] = [:]
    private var lastCalmNotice = Date.distantPast
    private var fired: [String: Double] {
        get { UserDefaults.standard.dictionary(forKey: "quotaFired") as? [String: Double] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "quotaFired") }
    }
    private var muted: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "quotaMuted") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "quotaMuted") }
    }
    private var snoozeUntil: Date {
        get { Date(timeIntervalSince1970: UserDefaults.standard.double(forKey: "quotaSnoozeUntil")) }
        set { UserDefaults.standard.set(newValue.timeIntervalSince1970, forKey: "quotaSnoozeUntil") }
    }

    /// 급하지 않은 알림은 30분에 한 번까지, 한 번에 세 개까지 (나머지는 다음 차례)
    static let calmGap: TimeInterval = 30 * 60
    /// "오늘 챙길 것"은 이 시각 이후 처음 볼 때
    static let digestHour = 7

    init(dataDir: URL) {
        self.dataDir = dataDir
        super.init()
    }

    var manualURL: URL { dataDir.appendingPathComponent("reset_passes.json") }

    func start() {
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.poll() }   // 켜자마자 말 걸지 않게
    }

    func poll() {
        let fallback = codexFallback()
        queue.async { [weak self] in
            guard let self else { return }
            let (w, c) = self.load(fallback: fallback)
            DispatchQueue.main.async { self.apply(windows: w, credits: c) }
        }
    }

    private func apply(windows w: [Quota.Window], credits c: [Quota.Credit]) {
        let now = Date()
        let mutedSet = muted
        windows = w; credits = c
        let ws = w.filter { !mutedSet.contains($0.provider) }
        let cs = c.filter { !mutedSet.contains($0.provider) }
        var log = fired
        log = log.filter { now.timeIntervalSince1970 - $0.value < 40 * 86400 }

        var due = Quota.reminders(windows: ws, credits: cs, previous: previous, now: now, cal: cal)
            .filter { log[$0.key] == nil && $0.validUntil > now }
        for x in w { previous[x.key] = x }

        let snoozed = now < snoozeUntil
        if snoozed { due = due.filter { $0.urgent } }
        let calmOK = now.timeIntervalSince(lastCalmNotice) >= Self.calmGap
        if !calmOK { due = due.filter { $0.urgent } }

        // 하루 한 번 브리핑 (조용히 해 달라고 한 날은 건너뜀)
        let dayKey = "digest:" + Self.dayKey(now, cal: cal)
        if !snoozed, calmOK, log[dayKey] == nil, cal.component(.hour, from: now) >= Self.digestHour,
           let d = Quota.digest(windows: ws, credits: cs, now: now, cal: cal) {
            log[dayKey] = now.timeIntervalSince1970
            // 브리핑에 이미 들어간 급하지 않은 알림은 따로 말하지 않는다
            let calm = due.filter { !$0.urgent }
            calm.forEach { log[$0.key] = now.timeIntervalSince1970 }
            due.removeAll { !$0.urgent }
            lastCalmNotice = now
            send(Notice(text: d, urgent: false, validUntil: cal.startOfDay(for: now).addingTimeInterval(86400)))
        }

        for group in [due.filter(\.urgent), due.filter { !$0.urgent }] where !group.isEmpty {
            let pick = Array(group.prefix(3))
            pick.forEach { log[$0.key] = now.timeIntervalSince1970 }
            if !pick[0].urgent { lastCalmNotice = now }
            send(Notice(text: pick.map(\.text).joined(separator: "\n\n"), urgent: pick[0].urgent,
                        validUntil: pick.map(\.validUntil).min() ?? now))
        }
        fired = log
    }

    private func send(_ n: Notice) {
        Log.write("한도 알림: \(n.text.replacingOccurrences(of: "\n", with: " / "))")
        notify?(n)
    }

    // MARK: 메뉴 · 요약

    /// 마우스 올림·메뉴 머리에 붙일 것: 80% 넘게 쓴 창, 사흘 안에 만료되는 리셋권만 (전체는 하위 메뉴)
    var attention: String {
        let now = Date()
        let ws = windows.filter { !muted.contains($0.provider) && $0.usedPercent >= 80 }
        let cs = credits.filter { !muted.contains($0.provider) && $0.expiresAt.timeIntervalSince(now) < 3 * 86400 }
        return Quota.summaryLines(windows: ws, credits: cs, now: now, cal: cal).joined(separator: "\n")
    }

    func addMenuItems(to menu: NSMenu) {
        let top = NSMenuItem(title: "⏳ 한도·리셋권", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let lines = Quota.summaryLines(windows: windows, credits: credits, now: Date(), cal: cal)
        if lines.isEmpty {
            let i = NSMenuItem(title: "읽은 값 없다 (CodexBar부터 켜 둬)", action: nil, keyEquivalent: ""); i.isEnabled = false; sub.addItem(i)
        }
        for l in lines { let i = NSMenuItem(title: l, action: nil, keyEquivalent: ""); i.isEnabled = false; sub.addItem(i) }
        sub.addItem(.separator())
        sub.addItem("☀️ 오늘 챙길 것 다시 보기", #selector(showDigest), target: self)
        sub.addItem("🎟️ 리셋권 직접 적기…", #selector(addManualPass), target: self)
        let manual = loadManual()
        if !manual.isEmpty {
            let used = NSMenuItem(title: "🎟️ 쓴 리셋권 지우기", action: nil, keyEquivalent: "")
            let um = NSMenu()
            for p in manual {
                let it = um.addItem("\(Quota.providerName(p.provider)) · \(Quota.dayText(p.expiresAt, cal: cal)) 만료", #selector(removeManualPass(_:)), target: self)
                it.representedObject = p.id
            }
            used.submenu = um
            sub.addItem(used)
        }
        sub.addItem(.separator())
        let snoozed = Date() < snoozeUntil
        sub.addItem(snoozed ? "🔔 한도 알림 다시 켜기" : "🔕 오늘은 급한 것만", #selector(toggleSnooze), target: self)
        let who = NSMenuItem(title: "알려 줄 에이전트", action: nil, keyEquivalent: "")
        let wm = NSMenu()
        for p in ["claude", "codex", "cursor", "grok"] {
            let it = wm.addItem(Quota.providerName(p), #selector(toggleMute(_:)), target: self)
            it.representedObject = p
            it.state = muted.contains(p) ? .off : .on
        }
        who.submenu = wm
        sub.addItem(who)
        top.submenu = sub
        menu.addItem(top)
    }

    @objc private func showDigest() {
        let now = Date()
        let text = Quota.digest(windows: windows.filter { !muted.contains($0.provider) },
                                credits: credits.filter { !muted.contains($0.provider) }, now: now, cal: cal)
            ?? "지금 챙길 건 없다. 일이나 해."
        send(Notice(text: text, urgent: true, validUntil: now.addingTimeInterval(600)))
    }

    @objc private func toggleSnooze() {
        if Date() < snoozeUntil {
            snoozeUntil = .distantPast
            send(Notice(text: "한도 알림 다시 켰다냥.", urgent: true, validUntil: Date().addingTimeInterval(60)))
        } else {
            // 다음 브리핑 시각까지
            let next = cal.date(bySettingHour: Self.digestHour, minute: 0, second: 0,
                                of: cal.startOfDay(for: Date()).addingTimeInterval(86400)) ?? Date().addingTimeInterval(12 * 3600)
            snoozeUntil = next
            send(Notice(text: "알았다냥. 내일 아침까진 급한 것만 말한다냥.", urgent: true, validUntil: Date().addingTimeInterval(60)))
        }
    }

    @objc private func toggleMute(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? String else { return }
        var m = muted
        if m.contains(p) { m.remove(p) } else { m.insert(p) }
        muted = m
    }

    // MARK: 직접 적은 리셋권 (Claude "Limit resets"처럼 CodexBar가 파일로 남기지 않는 것)

    struct ManualPass: Codable { var id: String; var provider: String; var title: String; var expiresAt: Date; var addedAt: Date }

    func loadManual() -> [ManualPass] {
        guard let d = try? Data(contentsOf: manualURL) else { return [] }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([ManualPass].self, from: d)) ?? []
    }

    private func saveManual(_ list: [ManualPass]) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(list).write(to: manualURL, options: .atomic)
        poll()
    }

    @objc private func addManualPass() {
        let previousApp = NSWorkspace.shared.frontmostApplication
        let alert = NSAlert()
        alert.messageText = "리셋권 적어 두기"
        alert.informativeText = "만료 전에 알려 주지.\nClaude는 설정 › 사용량 › 리셋에서 만료일을 볼 수 있다 (웹·데스크톱 앱에서만 사용 가능)"
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 56))
        let pop = NSPopUpButton(frame: NSRect(x: 0, y: 30, width: 300, height: 26))
        pop.addItems(withTitles: ["Claude", "Codex", "Cursor", "Grok"])
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "만료: 10/30 오후 3시 · 5일 후 · 다음주 금요일"
        box.addSubview(pop); box.addSubview(field)
        alert.accessoryView = box
        alert.addButton(withTitle: "저장")
        alert.addButton(withTitle: "취소")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        let r = alert.runModal()
        previousApp?.activate()
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard r == .alertFirstButtonReturn, !text.isEmpty else { return }
        guard let exp = Self.parseExpiry(text, now: Date(), cal: cal) ?? PetJournal.detectDate(text), exp > Date() else {
            send(Notice(text: "만료 날짜를 못 읽겠다냥. \"10/30 오후 3시\"처럼 써 달라냥.", urgent: true, validUntil: Date().addingTimeInterval(60)))
            return
        }
        let provider = (pop.titleOfSelectedItem ?? "Claude").lowercased()
        var list = loadManual()
        list.append(ManualPass(id: UUID().uuidString, provider: provider, title: "리셋권", expiresAt: exp, addedAt: Date()))
        saveManual(list)
        send(Notice(text: "🎟️ \(Quota.providerName(provider)) 리셋권 적어 뒀다냥 · \(Quota.whenText(exp, now: Date(), cal: cal)) 만료",
                    urgent: true, validUntil: Date().addingTimeInterval(60)))
    }

    @objc private func removeManualPass(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        saveManual(loadManual().filter { $0.id != id })
        send(Notice(text: "지웠다냥 🎟️", urgent: true, validUntil: Date().addingTimeInterval(60)))
    }

    /// "10/30", "10/30 15:00", "10/30 오후 3시" (NSDataDetector가 못 읽는 짧은 날짜)
    static func parseExpiry(_ text: String, now: Date, cal: Calendar) -> Date? {
        guard let m = text.range(of: #"(\d{1,2})\s*[/.]\s*(\d{1,2})"#, options: .regularExpression) else { return nil }
        let nums = text[m].split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard nums.count == 2 else { return nil }
        var c = cal.dateComponents([.year], from: now)
        c.month = nums[0]; c.day = nums[1]; c.hour = 23; c.minute = 59
        let rest = String(text[m.upperBound...])
        if let h = rest.range(of: #"(\d{1,2})\s*(시|:)\s*(\d{1,2})?"#, options: .regularExpression) {
            let hm = rest[h].split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            var hour = hm.first ?? 23
            if rest.contains("오후"), hour < 12 { hour += 12 }
            c.hour = hour; c.minute = hm.count > 1 ? hm[1] : 0
        }
        guard var d = cal.date(from: c) else { return nil }
        if d < now.addingTimeInterval(-86400) { d = cal.date(byAdding: .year, value: 1, to: d) ?? d }   // 12/30 → 내년 1/5 같은 경우
        return d
    }

    // MARK: 읽기 (백그라운드)

    func load(fallback: [Quota.Window]) -> ([Quota.Window], [Quota.Credit]) {
        var windows: [Quota.Window] = []
        var credits: [Quota.Credit] = []
        let support = home.appendingPathComponent("Library/Application Support")

        // Codex: 계정별 (리셋권 포함)
        let accountsURL = support.appendingPathComponent("CodexBar/codex-account-snapshots.json")
        if let o = Self.json(accountsURL), let records = o["records"] as? [[String: Any]] {
            let parsed = records.compactMap(Self.parseCodexAccount)
            let multi = parsed.count > 1
            for var p in parsed {
                let label = multi ? String(p.email.split(separator: "@").first ?? "") : nil
                for i in p.windows.indices {
                    p.windows[i].name += label.map { "(\($0))" } ?? ""
                }
                for i in p.credits.indices { p.credits[i].accountLabel = label }
                windows += p.windows
                credits += p.credits
            }
        }
        let codexFresh = windows.contains { Date().timeIntervalSince($0.capturedAt) < Quota.staleAfter }

        // Claude · Cursor · Grok (+ Codex: 계정 파일이 없거나 오래됐을 때)
        let widgetURL = home.appendingPathComponent("Library/Group Containers/Y5PE65HELJ.com.steipete.codexbar/widget-snapshot.json")
        var widgetCodex: [Quota.Window] = []
        if let o = Self.json(widgetURL), let entries = o["entries"] as? [[String: Any]] {
            for e in entries {
                let ws = Self.parseWidgetEntry(e)
                if e["provider"] as? String == "codex" { widgetCodex = ws } else { windows += ws }
            }
        }
        if !codexFresh {
            let alt = widgetCodex.contains { Date().timeIntervalSince($0.capturedAt) < Quota.staleAfter } ? widgetCodex : fallback
            windows.removeAll { $0.provider == "codex" }
            windows += alt
        }

        for p in loadManual() {
            credits.append(Quota.Credit(provider: p.provider, account: "manual", accountLabel: nil, id: "manual:" + p.id,
                                        title: p.title, grantedAt: p.addedAt, expiresAt: p.expiresAt, capturedAt: Date()))
        }
        return (windows, credits)
    }

    private static func json(_ url: URL) -> [String: Any]? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    private static func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }

    private static let iso: ISO8601DateFormatter = ISO8601DateFormatter()
    private static let isoFrac: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
    static func date(_ v: Any?) -> Date? {
        if let s = v as? String { return iso.date(from: s) ?? isoFrac.date(from: s) }
        return nil
    }

    struct CodexAccount { var email: String; var windows: [Quota.Window]; var credits: [Quota.Credit] }

    /// CodexBar 계정 파일 한 줄. 시각은 2001-01-01 기준 초(Swift Date 기본 인코딩)
    static func parseCodexAccount(_ r: [String: Any]) -> CodexAccount? {
        guard let s = r["snapshot"] as? [String: Any] else { return nil }
        let email = (s["accountEmail"] as? String) ?? (r["id"] as? String) ?? "?"
        let captured = Date(timeIntervalSinceReferenceDate: num(s["updatedAt"]) ?? 0)
        var ws: [Quota.Window] = []
        for slot in ["primary", "secondary", "tertiary"] {
            guard let w = s[slot] as? [String: Any], let used = num(w["usedPercent"]), let reset = num(w["resetsAt"]) else { continue }
            let mins = Int(num(w["windowMinutes"]) ?? 0)
            ws.append(Quota.Window(provider: "codex", name: "Codex \(Quota.periodName(mins))", key: "codex:\(email):\(mins)",
                                   usedPercent: used, minutes: mins, resetsAt: Date(timeIntervalSinceReferenceDate: reset),
                                   capturedAt: captured, account: email))
        }
        var cs: [Quota.Credit] = []
        if let rc = s["codexResetCredits"] as? [String: Any], let list = rc["credits"] as? [[String: Any]] {
            let at = Date(timeIntervalSinceReferenceDate: num(rc["updatedAt"]) ?? 0)
            for c in list where (c["status"] as? String ?? "available") == "available" {
                guard let id = c["id"] as? String, let exp = num(c["expires_at"]) else { continue }
                cs.append(Quota.Credit(provider: "codex", account: email, accountLabel: nil, id: id,
                                       title: c["title"] as? String ?? "리셋권",
                                       grantedAt: Date(timeIntervalSinceReferenceDate: num(c["granted_at"]) ?? 0),
                                       expiresAt: Date(timeIntervalSinceReferenceDate: exp), capturedAt: at))
            }
        }
        return CodexAccount(email: email, windows: ws, credits: cs)
    }

    /// 위젯 파일의 서비스 하나 → 창 목록. 같은 창(길이·리셋 시각)이 겹치면 하나만.
    static func parseWidgetEntry(_ e: [String: Any]) -> [Quota.Window] {
        guard let provider = e["provider"] as? String else { return [] }
        let captured = date(e["updatedAt"]) ?? .distantPast
        let rows = e["usageRows"] as? [[String: Any]] ?? []
        func title(_ id: String) -> String? { rows.first { $0["id"] as? String == id }?["title"] as? String }
        func minutes(_ w: [String: Any], _ t: String?) -> Int {
            if let m = num(w["windowMinutes"]), m > 0 { return Int(m) }
            let t = (t ?? "").lowercased()
            if t.contains("session") || t.contains("5h") { return 300 }
            if t.contains("month") || t.contains("월") { return 43200 }
            return 10080
        }
        var out: [Quota.Window] = []
        var seen = Set<String>()
        func add(_ w: [String: Any], _ t: String?, _ id: String, product: String?) {
            guard let used = num(w["usedPercent"]), let reset = date(w["resetsAt"]) else { return }
            let mins = minutes(w, t)
            let sig = "\(mins)|\(Int(reset.timeIntervalSince1970) / 60)|\(Int(used))"
            guard !seen.contains(sig) else { return }
            seen.insert(sig)
            let base = product ?? Quota.providerName(provider)
            // 모델별 주간 한도(Opus 등)는 이름을 붙여 구분
            let generic = ["session", "weekly", "total", "monthly", "primary", "secondary", "tertiary", "주간", "5시간", "월"]
            let tag = id == "tertiary" && product == nil && !(t.map { generic.contains($0.lowercased()) } ?? true) ? "(\(t!))" : ""
            out.append(Quota.Window(provider: provider, name: "\(base) \(Quota.periodName(mins))\(tag)", key: "\(provider):\(id):\(mins)",
                                    usedPercent: used, minutes: mins, resetsAt: reset, capturedAt: captured))
        }
        // Cursor의 secondary·tertiary는 같은 월 한도를 쪼갠 것이라 primary(전체)만 본다
        let slots = provider == "cursor" ? ["primary"] : ["primary", "secondary", "tertiary"]
        for slot in slots {
            if let w = e[slot] as? [String: Any] { add(w, title(slot), slot, product: nil) }
        }
        // 따로 창을 가진 줄 (예: Cursor 안의 Grok Bot 주간 한도)
        for r in rows {
            guard let w = r["window"] as? [String: Any], let id = r["id"] as? String, !["primary", "secondary", "tertiary", "weekly", "session"].contains(id) else { continue }
            add(w, r["title"] as? String, id, product: r["title"] as? String)
        }
        return out
    }

    private static func dayKey(_ d: Date, cal: Calendar) -> String {
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return "\(c.year!)-\(c.month!)-\(c.day!)"
    }
}
