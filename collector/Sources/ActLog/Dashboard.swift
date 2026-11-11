import AppKit

/// Meowgent 대시보드: 맥 기본 앱 모양(분할 창 · 도구 막대 · 회색 묶음 칸)으로 질문 · 경고 · 알림을 본다.
/// - 질문: 고양이 ! · ? 항목(inbox/). 같은 곳에서 같은 선택지로 물은 질문은 한 묶음으로, 함께 끝나는 문구는 제목으로 한 번만 보인다.
///   버튼 하나로 체크한 질문 전부에 답하고, 다른 답이 필요한 것만 그 줄의 "따로"에서 고른다. 맨 위 묶음은 숫자키(1–9)로 바로 답한다.
///   답은 고양이 메뉴와 똑같이 inbox/done/ 으로 옮기고 answer·resolved 를 붙인다 (docs/INBOX.md).
///   방금 한 답은 아래 막대의 되돌리기나 ⌘Z 로 되돌린다 (만든 쪽이 그새 가져갔으면 거기엔 반영되지 않는다).
/// - 경고 / 알림: 고양이가 한 말(notices.jsonl) 중 급한 것(대화 답 제외) / 나머지. 숫자만 바뀌며 연달아 온 알림은 한 줄로 접는다.
/// 색은 급한 것(빨강)과 안 읽은 경고(시스템 강조색 점)에만 쓰고 나머지는 회색 음영으로 나눈다.
final class Dashboard: NSObject, NSWindowDelegate, NSTextFieldDelegate, NSSearchFieldDelegate, NSToolbarDelegate {
    enum Tab: Int, CaseIterable {
        case inbox, suggest, warnings, notices, thinking, tasks, improve

        var title: String { ["질문", "제안", "경고", "알림", "생각", "작업", "개선"][rawValue] }
        var symbol: String { ["questionmark.bubble", "lightbulb", "exclamationmark.triangle", "bell", "brain", "hammer", "wrench.and.screwdriver"][rawValue] }
    }

    private let inbox: URL
    private let noticesURL: URL
    private let chatURL: URL
    private let dataDir: URL
    private let mindDir: URL
    private var window: DashboardWindow?
    private var tab = Tab.inbox
    private var sideRows: [SidebarRow] = []
    private var search: NSSearchField?
    private var readAllItem: NSToolbarItem?
    private let stack = NSStackView()
    private let scroll = NSScrollView()
    private let statusBar = NSStackView()
    private let statusLabel = NSTextField(labelWithString: "")
    private var statusHeight: NSLayoutConstraint!
    private var statusHide: DispatchWorkItem?
    private var timer: Timer?
    private var items: [InboxRules.Item] = []
    private var notices: [NoticeRules.Notice] = []
    private var chat: Set<String> = []
    private var decisions: [ThinkRules.Decision] = []
    private var reactions: [String: String] = [:]   // 말풍선 id → 대표 반응 (reactions.jsonl)
    private var labels: [String: String] = [:]      // 판단 키 → right · wrong (mind/decision_labels.jsonl)
    private var improve: ThinkRules.Improve?
    private var tasks: [TaskRules.Task] = []
    private var picks: [String: [String]] = [:]     // 여러 개 고르는 질문에서 체크한 보기 id (고른 순서)
    private var unchecked: Set<String> = []        // 묶음에서 체크를 푼 항목
    private var expanded: Set<String> = []         // 펼친 설명·알림
    private var writing: String?                   // "직접 적기" 칸을 연 항목
    private var focusKey: String?                  // 숫자키가 답할 묶음 (맨 위)
    private var focusChoices: [InboxRules.Choice] = []
    private var lastMoved: [(src: URL, dest: URL)] = []
    /// 제안 목록 (suggest/) — main 이 넣어 준다
    var suggestions: Suggestions?
    private var shownStamp = ""

    static let warnDays: Double = 7
    static let maxRows = 300
    private static let searchID = NSToolbarItem.Identifier("search")
    private static let readAllID = NSToolbarItem.Identifier("readAll")

    /// 경고 탭을 마지막으로 본 시각 (그 뒤 경고만 개수에 센다)
    private var warnSeen: Double {
        get { UserDefaults.standard.double(forKey: "dashboardWarnSeen") }
        set { UserDefaults.standard.set(newValue, forKey: "dashboardWarnSeen") }
    }

    init(dataDir: URL) {
        inbox = dataDir.appendingPathComponent("inbox", isDirectory: true)
        noticesURL = dataDir.appendingPathComponent("notices.jsonl")
        chatURL = dataDir.appendingPathComponent("mind/conversation.jsonl")
        self.dataDir = dataDir
        mindDir = dataDir.appendingPathComponent("mind", isDirectory: true)
        super.init()
        // 처음 쓸 때는 지금부터 온 경고만 센다 (예전 경고는 탭에서만 본다)
        if warnSeen == 0 { warnSeen = Date().timeIntervalSince1970 }
    }

    func addMenuItems(to menu: NSMenu) {
        let asks = loadInbox().count
        let warns = newWarnings(loadNotices(), loadChat())
        let counts = [asks > 0 ? "질문 \(asks)" : nil, warns > 0 ? "경고 \(warns)" : nil].compactMap { $0 }.joined(separator: " · ")
        menu.addItem("📋 대시보드\(counts.isEmpty ? "" : " (\(counts))")", #selector(show), target: self)
        if let n = suggestions?.items.count, n > 0 { menu.addItem("💡 제안 \(n)개 보기", #selector(showSuggest), target: self) }
    }

    @objc func showSuggest() { showTab(.suggest) }

    @objc func show() { showTab(nil) }

    /// tab 을 주면 그 탭으로 (고양이에게 "작업 보여 줘" 같은 말로 열 때)
    func showTab(_ want: Tab?) {
        DispatchQueue.main.async { [self] in
            if window == nil { build() }
            // 답할 질문이 없고 새 경고가 있으면 경고 탭부터
            if let want { tab = want }
            else if window?.isVisible != true {
                tab = loadInbox().isEmpty && newWarnings(loadNotices(), loadChat()) > 0 ? .warnings : .inbox
            }
            reload(force: true)
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
            timer?.invalidate()
            let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in self?.reload(force: false) }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
    }

    private func select(_ t: Tab) {
        guard t != tab else { return }
        tab = t
        writing = nil
        search?.stringValue = ""
        reload(force: true)
        // 도구 막대 아래(내용 여백)부터 보이게 맨 위로
        scroll.contentView.scroll(to: NSPoint(x: 0, y: -scroll.contentInsets.top))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    // MARK: 읽기

    private func loadInbox() -> [InboxRules.Item] {
        let now = Date().timeIntervalSince1970
        let files = (try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { f in
            guard let d = try? Data(contentsOf: f), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
            return InboxRules.parse(o, file: f.lastPathComponent, now: now)
        }.sorted(by: InboxRules.order)
    }

    /// 파일 끝 512KB 만 읽는다 (오래 켜 두면 커진다)
    private func loadNotices() -> [NoticeRules.Notice] {
        guard let h = try? FileHandle(forReadingFrom: noticesURL) else { return [] }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let start = size > 512_000 ? size - 512_000 : 0
        try? h.seek(toOffset: start)
        guard let d = try? h.readToEnd(), var s = String(data: d, encoding: .utf8) else { return [] }
        if start > 0, let nl = s.firstIndex(of: "\n") { s = String(s[s.index(after: nl)...]) }   // 잘린 첫 줄 버림
        return NoticeRules.parse(s)
    }

    private func loadChat() -> Set<String> {
        NoticeRules.catLines((try? String(contentsOf: chatURL, encoding: .utf8)) ?? "")
    }

    private func newWarnings(_ ns: [NoticeRules.Notice], _ chat: Set<String>) -> Int {
        ns.filter { NoticeRules.isWarning($0, chat: chat) && $0.ts > warnSeen }.count
    }

    /// 파일이 바뀌었을 때만 다시 그린다 (고른 체크·적던 글을 지키려고)
    private func reload(force: Bool) {
        items = loadInbox()
        notices = loadNotices()
        chat = loadChat()
        decisions = ThinkRules.parse(Self.tail(mindDir.appendingPathComponent("decisions.jsonl")))
        let reactText = Self.tail(dataDir.appendingPathComponent("reactions.jsonl"))
        reactions = ReactionRules.byID(reactText)
        let labelText = Self.tail(mindDir.appendingPathComponent("decision_labels.jsonl"))
        labels = ThinkRules.labels(labelText)
        improve = (try? Data(contentsOf: mindDir.appendingPathComponent("improve/latest.json"))).flatMap(ThinkRules.parseImprove)
        tasks = loadTasks()
        suggestions?.load()
        let sugg = suggestions?.items ?? []
        sideRows[Tab.suggest.rawValue].count = sugg.count
        unchecked.formIntersection(Set(items.map(\.id)))
        picks = picks.filter { k, _ in items.contains { $0.id == k } }
        if let w = writing, !items.contains(where: { $0.id == w }) { writing = nil }
        sideRows[Tab.inbox.rawValue].count = items.count
        sideRows[Tab.warnings.rawValue].count = tab == .warnings ? 0 : newWarnings(notices, chat)
        sideRows[Tab.improve.rawValue].count = improve?.suggestions.filter { $0.status == "new" }.count ?? 0
        sideRows[Tab.tasks.rawValue].count = tasks.filter { $0.state == "running" }.count
        for (n, r) in sideRows.enumerated() { r.selected = n == tab.rawValue }
        // 하는 중인 작업은 분이 바뀔 때마다 다시 그린다
        let taskStamp = tasks.map { "\($0.id):\($0.state)" }.joined(separator: ",") + (tab == .tasks && tasks.contains { $0.state == "running" } ? "|\(Int(Date().timeIntervalSince1970 / 60))" : "")
        let stamp = "\(tab.rawValue)|" + items.map(\.file).joined(separator: ",") + "|\(notices.last?.ts ?? 0)|\(decisions.last?.ts ?? 0)|\(reactText.count)|\(labelText.count)|\(improve?.ts ?? 0)|\(improveOn)|" + taskStamp
            + "|" + sugg.map { "\($0.file):\($0.count)" }.joined(separator: ",")
        guard force || stamp != shownStamp else { return }
        shownStamp = stamp
        render()
        if tab == .warnings, window?.isVisible == true { warnSeen = Date().timeIntervalSince1970 }
    }

    // MARK: 답하기

    private func loadTasks() -> [TaskRules.Task] {
        let dir = mindDir.appendingPathComponent("tasks", isDirectory: true)
        let subs = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return subs.compactMap { d in
            (try? Data(contentsOf: d.appendingPathComponent("task.json")))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }.flatMap(TaskRules.parse)
        }.sorted(by: TaskRules.order)
    }

    /// answer: 고른 선택지 id 또는 직접 적은 글, 확인은 "done", 건너뛰기는 nil. answers: 여러 개 고른 질문의 id 목록
    private func resolve(_ list: [InboxRules.Item], _ answer: String?, label: String, answers: [String]? = nil) {
        guard !list.isEmpty else { return }
        let fm = FileManager.default
        let done = inbox.appendingPathComponent("done", isDirectory: true)
        try? fm.createDirectory(at: done, withIntermediateDirectories: true)
        var moved: [(URL, URL)] = []
        for it in list {
            let src = inbox.appendingPathComponent(it.file), dest = done.appendingPathComponent(it.file)
            guard let d = try? Data(contentsOf: src), var o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            o["answer"] = answer ?? NSNull()
            if let answers { o["answers"] = answers }
            o["resolved"] = Date().timeIntervalSince1970
            guard Self.write(o, to: dest) else { continue }
            try? fm.removeItem(at: src)
            moved.append((src, dest))
        }
        Log.write("대시보드 답: \(list.map(\.id).joined(separator: ", ")) → \(answer ?? "건너뜀")")
        lastMoved = moved
        writing = nil
        if !moved.isEmpty { showStatus("\(moved.count)개 답함: \(label)") }
        reload(force: true)
    }

    @objc private func undo() {
        guard !lastMoved.isEmpty else { return }
        let fm = FileManager.default
        for (src, dest) in lastMoved {
            guard let d = try? Data(contentsOf: dest), var o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            o["answer"] = nil
            o["answers"] = nil
            o["resolved"] = nil
            if Self.write(o, to: src) { try? fm.removeItem(at: dest) }
        }
        Log.write("대시보드 답 되돌림: \(lastMoved.count)개")
        lastMoved = []
        hideStatus()
        reload(force: true)
    }

    /// 임시 파일에 쓰고 바꿔치기 (반쯤 쓴 파일을 고양이·만든 쪽이 읽지 않게), 0600
    private static func write(_ o: [String: Any], to url: URL) -> Bool {
        guard let out = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]) else { return false }
        let tmp = url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".tmp")
        guard FileManager.default.createFile(atPath: tmp.path, contents: out, attributes: [.posixPermissions: 0o600]) else { return false }
        return rename(tmp.path, url.path) == 0
    }

    /// "group:<id>" 는 그 묶음에서 체크한 항목 전부, 아니면 그 항목 하나
    private func targets(_ key: String) -> [InboxRules.Item] {
        if key.hasPrefix("group:") {
            let first = String(key.dropFirst(6))
            guard let g = InboxRules.group(items).first(where: { $0.items.first?.id == first }) else { return [] }
            return g.items.filter { !unchecked.contains($0.id) }
        }
        return items.filter { $0.id == key }
    }

    @objc private func chooseFromPopup(_ sender: NSPopUpButton) {
        guard let p = sender.selectedItem?.representedObject as? [String], p.count == 3 else { return }
        resolve(targets(p[0]), p[1], label: p[2])
    }

    @objc private func toggleCheck(_ sender: NSButton) {
        guard let id = sender.cell?.representedObject as? String else { return }
        if sender.state == .on { unchecked.remove(id) } else { unchecked.insert(id) }
        render()
    }

    @objc private func markAllRead() {
        warnSeen = Date().timeIntervalSince1970
        reload(force: true)
    }

    // MARK: 키보드

    /// 숫자키: 맨 위 묶음에 그 번호 선택지로 답 · ⌘Z 되돌리기 · ⌘F 찾기 · ⌘1–3 탭
    fileprivate func key(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .control, .option, .shift])
        let digits: [UInt16: Int] = [18: 0, 19: 1, 20: 2, 21: 3, 23: 4, 22: 5, 26: 6, 28: 7, 25: 8]
        if mods == .command {
            switch e.keyCode {
            case 6: undo(); return true
            case 3: if let search { window?.makeFirstResponder(search) }; return true
            case 18, 19, 20, 21, 23, 22, 26: select(Tab(rawValue: digits[e.keyCode]!)!); return true
            default: return false
            }
        }
        guard mods.isEmpty, tab == .inbox, writing == nil, let n = digits[e.keyCode],
              let key = focusKey, focusChoices.indices.contains(n) else { return false }
        let c = focusChoices[n]
        resolve(targets(key), c.id, label: c.label)
        return true
    }

    /// 직접 적은 답: ⏎ 보내기, Esc 취소 (찾기 칸은 기본 동작)
    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        guard control !== search else { return false }
        if sel == #selector(NSResponder.cancelOperation(_:)) { writing = nil; render(); return true }
        guard sel == #selector(NSResponder.insertNewline(_:)), let id = writing else { return false }
        let text = control.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { resolve(targets(id), text, label: "“\(text.prefix(30))”") }
        return true
    }

    func controlTextDidChange(_ obj: Notification) {
        if let s = obj.object as? NSSearchField, s === search { render() }
    }

    // MARK: 도구 막대

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebarTrackingSeparator, .flexibleSpace, Self.readAllID, Self.searchID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case Self.searchID:
            let item = NSSearchToolbarItem(itemIdentifier: id)
            item.searchField.placeholderString = "찾기"
            item.searchField.delegate = self
            item.searchField.sendsSearchStringImmediately = true
            search = item.searchField
            return item
        case Self.readAllID:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = "모두 읽음"
            item.toolTip = "새 경고 표시를 지운다"
            item.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: "모두 읽음")
            item.isBordered = true
            item.autovalidates = false
            item.target = self
            item.action = #selector(markAllRead)
            readAllItem = item
            return item
        default:
            return nil
        }
    }

    // MARK: 창 뼈대

    private func build() {
        let side = NSViewController()
        side.view = buildSidebar()
        let main = NSViewController()
        main.view = buildMain()
        let split = NSSplitViewController()
        let sideItem = NSSplitViewItem(sidebarWithViewController: side)
        sideItem.minimumThickness = 180
        sideItem.maximumThickness = 240
        sideItem.canCollapse = false
        split.addSplitViewItem(sideItem)
        split.addSplitViewItem(NSSplitViewItem(viewController: main))

        let w = DashboardWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 640),
                                styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                                backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 640, height: 420)
        w.delegate = self
        w.onKey = { [weak self] e in self?.key(e) ?? false }
        w.contentViewController = split
        let tb = NSToolbar(identifier: "MeowgentDashboard")
        tb.delegate = self
        tb.displayMode = .iconOnly
        tb.allowsUserCustomization = false
        w.toolbar = tb
        w.toolbarStyle = .unified
        w.setContentSize(NSSize(width: 820, height: 640))
        w.setFrameAutosaveName("MeowgentDashboard3")
        if !w.setFrameUsingName("MeowgentDashboard3") { w.center() }
        window = w
    }

    private func buildSidebar() -> NSView {
        let v = NSView()
        sideRows = Tab.allCases.map { t in
            let r = SidebarRow(title: t.title, symbol: t.symbol)
            r.onClick = { [weak self] in self?.select(t) }
            return r
        }
        let list = NSStackView(views: sideRows)
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 1
        list.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(list)
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 10),
            list.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -10),
            list.topAnchor.constraint(equalTo: v.safeAreaLayoutGuide.topAnchor, constant: 8),
        ])
        for r in sideRows { r.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true }
        return v
    }

    private func buildMain() -> NSView {
        let main = NSView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 24, bottom: 24, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedDoc()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        scroll.documentView = doc
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        // 아래 막대: 방금 한 답 + 되돌리기 (Finder 상태 막대처럼, 평소엔 접힌다)
        let line = NSBox()
        line.boxType = .separator
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let undoButton = NSButton(title: "되돌리기", target: self, action: #selector(undo))
        undoButton.controlSize = .small
        undoButton.bezelStyle = .push
        statusBar.setViews([statusLabel, NSView(), undoButton], in: .leading)
        statusBar.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 12)
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        statusBar.isHidden = true
        line.translatesAutoresizingMaskIntoConstraints = false
        statusBar.addSubview(line)

        main.addSubview(scroll)
        main.addSubview(statusBar)
        statusHeight = statusBar.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: main.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: main.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: main.topAnchor), scroll.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            statusBar.leadingAnchor.constraint(equalTo: main.leadingAnchor), statusBar.trailingAnchor.constraint(equalTo: main.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: main.bottomAnchor), statusHeight,
            line.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor), line.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor),
            line.topAnchor.constraint(equalTo: statusBar.topAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor), stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor), stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        return main
    }

    private func showStatus(_ text: String) {
        statusLabel.stringValue = text
        statusBar.isHidden = false
        statusHeight.constant = 30
        statusHide?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.hideStatus() }
        statusHide = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: w)
    }

    private func hideStatus() {
        statusBar.isHidden = true
        statusHeight.constant = 0
    }

    // MARK: 내용

    private var query: String { search?.stringValue.trimmingCharacters(in: .whitespaces).lowercased() ?? "" }

    private func render() {
        guard let window else { return }
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        window.title = tab.title
        readAllItem?.isEnabled = false
        focusKey = nil
        focusChoices = []
        switch tab {
        case .inbox:
            let q = query
            let shown = items.filter { q.isEmpty || ($0.text + " " + ($0.detail ?? "") + " " + $0.source).lowercased().contains(q) }
            let asks = shown.filter(\.ask).count
            window.subtitle = [asks > 0 ? "질문 \(asks)개" : nil, shown.count > asks ? "확인할 일 \(shown.count - asks)개" : nil]
                .compactMap { $0 }.joined(separator: " · ")
            let groups = InboxRules.group(shown)
            if groups.isEmpty { add(emptyState("questionmark.bubble", q.isEmpty ? "질문 없음" : "찾는 질문 없음")) }
            for (n, g) in groups.enumerated() {
                let focused = n == 0
                if g.isBatch { batchSection(g, focused: focused) }
                else if g.items[0].ask { askSection(g.items[0], focused: focused) }
                else { todoSection(g.items[0], focused: focused) }
            }
        case .warnings:
            let cut = Date().timeIntervalSince1970 - Self.warnDays * 86400
            let list = notices.filter { NoticeRules.isWarning($0, chat: chat) && $0.ts >= cut }
            readAllItem?.isEnabled = list.contains { $0.ts > warnSeen }
            noticeList(list, unseenAfter: warnSeen, empty: "경고 없음")
        case .notices:
            noticeList(notices.filter { !NoticeRules.isWarning($0, chat: chat) }, unseenAfter: nil, empty: "알림 없음")
        case .suggest:
            suggestList()
        case .thinking:
            thinkingList()
        case .tasks:
            taskList()
        case .improve:
            improveView()
        }
    }

    private func add(_ v: NSView, after: CGFloat? = nil) {
        stack.addArrangedSubview(v)
        v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -(stack.edgeInsets.left + stack.edgeInsets.right)).isActive = true
        if let after { stack.setCustomSpacing(after, after: v) }
    }

    /// 묶음 칸 위 머리말 (시스템 설정처럼). 급하면 빨간 점
    private func header(_ text: String, red: Bool = false, top: Bool = false) {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 12, weight: .semibold)
        l.textColor = .secondaryLabelColor
        l.lineBreakMode = .byTruncatingTail
        var views: [NSView] = [l]
        if red {
            let dot = NSImageView(image: NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "급함") ?? NSImage())
            dot.symbolConfiguration = .init(pointSize: 6, weight: .regular)
            dot.contentTintColor = .systemRed
            views.insert(dot, at: 0)
        }
        let row = NSStackView(views: views)
        row.spacing = 5
        row.edgeInsets = NSEdgeInsets(top: top ? 0 : 14, left: 4, bottom: 0, right: 0)
        add(row, after: 6)
    }

    // MARK: 질문

    private func askSection(_ it: InboxRules.Item, focused: Bool) {
        header(Self.meta(it.source, Self.ago(it.created), it.due.map { "마감 " + Self.ago($0) }, it.multi ? "여러 개 골라도 됨" : nil),
               red: it.red, top: stack.arrangedSubviews.isEmpty)
        var rows: [NSView] = [textBlock(it.text, detail: it.detail, key: it.id)]
        if it.multi { rows.append(contentsOf: pickRows(it)) }
        else if !it.choices.isEmpty { rows.append(choiceButtons(it.choices, target: it.id, numbered: focused)) }
        rows.append(writing == it.id ? writeField() : actions([
            button("직접 적기…") { [weak self] in self?.writing = it.id; self?.render() },
            button("건너뛰기") { [weak self] in self?.resolve([it], nil, label: "건너뜀") },
        ]))
        if focused && !it.multi { focusKey = it.id; focusChoices = it.choices }
        add(group([rows], focused: focused))
    }

    /// 여러 개 고르는 질문: 보기마다 체크 상자 + "n개 고르기" (answer 는 "A, B", answers 는 id 목록)
    private func pickRows(_ it: InboxRules.Item) -> [NSView] {
        let chosen = picks[it.id] ?? []
        let flow = FlowView()
        flow.setViews(it.choices.map { c in
            let b = ActionButton(title: c.label) { [weak self] in
                guard let self else { return }
                var l = self.picks[it.id] ?? []
                if let i = l.firstIndex(of: c.id) { l.remove(at: i) } else { l.append(c.id) }
                self.picks[it.id] = l
                self.render()
            }
            b.setButtonType(.switch)
            b.state = chosen.contains(c.id) ? .on : .off
            b.toolTip = c.label
            return b
        })
        let labels = chosen.compactMap { id in it.choices.first { $0.id == id }?.label }
        let go = button(chosen.isEmpty ? "고르기" : "\(chosen.count)개 고르기") { [weak self] in
            guard let self, !chosen.isEmpty else { return }
            self.picks[it.id] = nil
            self.resolve([it], labels.joined(separator: ", "), label: labels.joined(separator: ", "), answers: chosen)
        }
        go.isEnabled = !chosen.isEmpty
        go.keyEquivalent = chosen.isEmpty ? "" : "\r"
        return [flow, actions([go])]
    }

    private func todoSection(_ it: InboxRules.Item, focused: Bool) {
        header(Self.meta(it.source, Self.ago(it.created), it.due.map { "마감 " + Self.ago($0) }), red: it.red, top: stack.arrangedSubviews.isEmpty)
        var buttons = [button("건너뛰기") { [weak self] in self?.resolve([it], nil, label: "건너뜀") }]
        if let u = it.url { buttons.append(button("열기") { NSWorkspace.shared.open(u) }) }
        let ok = button("확인") { [weak self] in self?.resolve([it], "done", label: "확인") }
        ok.keyEquivalent = focused ? "\r" : ""
        buttons.append(ok)
        if focused { focusKey = it.id; focusChoices = [InboxRules.Choice(id: "done", label: "확인")] }
        add(group([[textBlock(it.text, detail: it.detail, key: it.id), actions(buttons)]], focused: focused))
    }

    /// 묶음: 공통 문구 · 선택지 버튼 (체크한 것 전부에) / 질문마다 체크 · 앞부분 · 설명 · 따로 / 체크 수 · 건너뛰기
    private func batchSection(_ g: InboxRules.Group, focused: Bool) {
        guard let first = g.items.first else { return }
        let key = "group:" + first.id
        let suffix = InboxRules.commonSuffix(g.items.map(\.text))
        let checked = g.items.filter { !unchecked.contains($0.id) }
        header(Self.meta(first.source, "질문 \(g.items.count)개"), red: g.items.contains(where: \.red), top: stack.arrangedSubviews.isEmpty)
        let buttons = choiceButtons(g.choices, target: key, numbered: focused)
        buttons.subviews.forEach { ($0 as? NSButton)?.isEnabled = !checked.isEmpty }
        var sections: [[NSView]] = [[textBlock(suffix ?? "같은 선택지로 물은 질문", detail: nil, key: key), buttons]]
        sections.append(g.items.map { memberRow($0, suffix: suffix) })
        let count = NSTextField(labelWithString: "\(checked.count)개 선택됨")
        count.font = .systemFont(ofSize: 11)
        count.textColor = .secondaryLabelColor
        let skip = button("선택한 것 건너뛰기") { [weak self] in
            guard let self, !self.targets(key).isEmpty else { return }
            self.resolve(self.targets(key), nil, label: "건너뜀")
        }
        skip.isEnabled = !checked.isEmpty
        sections.append([actions([skip], leading: count)])
        if focused { focusKey = key; focusChoices = g.choices }
        add(group(sections, focused: focused))
    }

    private func memberRow(_ it: InboxRules.Item, suffix: String?) -> NSView {
        let check = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleCheck(_:)))
        check.state = unchecked.contains(it.id) ? .off : .on
        check.cell?.representedObject = it.id
        check.setContentHuggingPriority(.required, for: .horizontal)
        let head = NSTextField(labelWithString: InboxRules.stripSuffix(it.text, suffix))
        head.font = .systemFont(ofSize: 13)
        head.lineBreakMode = .byTruncatingTail
        head.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var texts: [NSView] = [head]
        if let d = it.detail { texts.append(expandable(d, key: it.id, lines: 1, size: 11)) }
        let col = NSStackView(views: texts)
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 1
        col.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        col.setHuggingPriority(.init(1), for: .horizontal)   // 남는 폭은 글 쪽이 가져가서 "따로"는 오른쪽 끝에
        for t in texts { t.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true }
        let popup = NSPopUpButton(frame: .zero, pullsDown: true)
        popup.controlSize = .small
        popup.font = .systemFont(ofSize: 11)
        popup.addItem(withTitle: "따로")
        for c in it.choices {
            popup.addItem(withTitle: c.label)
            popup.lastItem?.representedObject = [it.id, c.id, c.label]
        }
        popup.target = self
        popup.action = #selector(chooseFromPopup(_:))
        popup.setContentCompressionResistancePriority(.required, for: .horizontal)
        popup.setContentHuggingPriority(.required, for: .horizontal)
        let row = NSStackView(views: [check, col, popup])
        row.distribution = .fill
        row.alignment = .firstBaseline
        row.spacing = 8
        return row
    }

    // MARK: 경고·알림

    /// 날짜별 묶음 칸, 최신순. unseenAfter 이후 것(아직 안 본 경고)은 굵게 + 강조색 점
    private func noticeList(_ list: [NoticeRules.Notice], unseenAfter: Double?, empty: String) {
        let q = query
        let rows = NoticeRules.collapse(list).filter { q.isEmpty || $0.text.lowercased().contains(q) }.prefix(Self.maxRows)
        let unseen = unseenAfter.map { t in rows.filter { $0.ts > t }.count } ?? 0
        window?.subtitle = rows.isEmpty ? "" : "\(rows.count)건\(unseen > 0 ? " · 새로 \(unseen)건" : "")"
        guard !rows.isEmpty else { add(emptyState(tab.symbol, q.isEmpty ? empty : "찾는 \(tab.title) 없음")); return }
        let day = DateFormatter(); day.locale = Locale(identifier: "ko_KR"); day.dateFormat = "M월 d일 EEEE"
        var lastDay = ""
        var dayRows: [NSView] = []
        func flush() {
            guard !dayRows.isEmpty else { return }
            add(group([dayRows], focused: false, inset: 44))
            dayRows = []
        }
        for r in rows {
            let date = Date(timeIntervalSince1970: r.ts)
            let d = Calendar.current.isDateInToday(date) ? "오늘" : Calendar.current.isDateInYesterday(date) ? "어제" : day.string(from: date)
            if d != lastDay {
                flush()
                lastDay = d
                header(d, top: stack.arrangedSubviews.isEmpty)
            }
            dayRows.append(noticeRow(r, unseen: unseenAfter.map { r.ts > $0 } ?? false))
        }
        flush()
    }

    private func noticeRow(_ r: NoticeRules.Row, unseen: Bool) -> NSView {
        let icon = NSImageView(image: NSImage(systemSymbolName: Self.symbol(NoticeRules.category(r.text)), accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 14, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.widthAnchor.constraint(equalToConstant: 22).isActive = true

        let lines = NoticeRules.plain(r.text).split(separator: "\n", maxSplits: 1).map(String.init)
        let head = NSTextField(labelWithString: lines.first ?? "")
        head.font = .systemFont(ofSize: 13, weight: unseen ? .semibold : .regular)
        head.lineBreakMode = .byTruncatingTail
        head.toolTip = r.text
        head.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var col: [NSView] = [head]
        if lines.count > 1 { col.append(expandable(lines[1], key: "n\(r.ts)", lines: 2, size: 11)) }
        let texts = NSStackView(views: col)
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 1
        texts.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        texts.setHuggingPriority(.init(1), for: .horizontal)
        for v in col { v.widthAnchor.constraint(lessThanOrEqualTo: texts.widthAnchor).isActive = true }

        var trailing: [NSView] = []
        if r.count > 1 { trailing.append(Self.capsule("\(r.count)")) }
        if unseen {
            let dot = NSImageView(image: NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "새로") ?? NSImage())
            dot.symbolConfiguration = .init(pointSize: 7, weight: .regular)
            dot.contentTintColor = .controlAccentColor
            trailing.append(dot)
        }
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        let time = NSTextField(labelWithString: f.string(from: Date(timeIntervalSince1970: r.ts)))
        time.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        time.textColor = .tertiaryLabelColor
        time.setContentCompressionResistancePriority(.required, for: .horizontal)
        trailing.append(time)
        let right = NSStackView(views: trailing)
        right.spacing = 6
        right.setContentHuggingPriority(.required, for: .horizontal)
        let row = NSStackView(views: [icon, texts, right])
        row.distribution = .fill
        row.alignment = .firstBaseline
        row.spacing = 10
        return row
    }

    /// 알림 종류 → 단색 아이콘
    private static func symbol(_ c: NoticeRules.Category) -> String {
        switch c {
        case .context: "gauge.with.dots.needle.67percent"
        case .quota: "hourglass"
        case .memory: "memorychip"
        case .battery: "battery.25percent"
        case .done: "checkmark.circle"
        case .ask: "questionmark.circle"
        case .todo: "checklist"
        case .rest: "cup.and.saucer"
        case .other: "bubble.left"
        }
    }

    // MARK: 생각 (왜 말했나·참았나)

    /// 판단 기록 최신순, 날짜별 묶음 칸
    private func thinkingList() {
        let q = query
        let week = Date().timeIntervalSince1970 - 7 * 86400
        let list = decisions.filter { $0.kind != "improve" }.reversed().filter {
            q.isEmpty || (ThinkRules.title($0) + " " + ThinkRules.subtitle($0) + " " + ($0.text ?? "")).lowercased().contains(q)
        }.prefix(Self.maxRows)
        let recent = decisions.filter { $0.ts >= week }
        func n(_ o: String) -> Int { recent.filter { $0.outcome == o }.count }
        let failed = n("failed") + n("timeout") + n("limited")
        let labeled = recent.filter { labels[ThinkRules.key($0)] != nil }.count
        window?.subtitle = recent.isEmpty ? "" : "최근 7일 · 말함 \(n("said")) · 참음 \(n("quiet"))\(failed > 0 ? " · 실패 \(failed)" : "")"
            + (labeled > 0 ? " · 라벨 \(labeled)" : "")
        guard !list.isEmpty else { add(emptyState("brain", q.isEmpty ? "판단 기록 없음" : "찾는 기록 없음")); return }
        let day = DateFormatter(); day.locale = Locale(identifier: "ko_KR"); day.dateFormat = "M월 d일 EEEE"
        var lastDay = ""
        var rows: [NSView] = []
        func flush() { if !rows.isEmpty { add(group([rows], focused: false, inset: 44)); rows = [] } }
        for d in list {
            let date = Date(timeIntervalSince1970: d.ts)
            let label = Calendar.current.isDateInToday(date) ? "오늘" : Calendar.current.isDateInYesterday(date) ? "어제" : day.string(from: date)
            if label != lastDay { flush(); lastDay = label; header(label, top: stack.arrangedSubviews.isEmpty) }
            rows.append(decisionRow(d))
        }
        flush()
    }

    // MARK: 작업 (고양이가 맡긴 코딩)

    private func taskList() {
        let q = query
        let list = tasks.filter { q.isEmpty || ($0.task + " " + $0.repo + " " + $0.agent).lowercased().contains(q) }
        let running = list.filter { $0.state == "running" }.count
        window?.subtitle = list.isEmpty ? "" : "\(list.count)개\(running > 0 ? " · 하는 중 \(running)" : "")"
        guard !list.isEmpty else {
            add(emptyState("hammer", q.isEmpty ? "맡긴 작업 없음 · 대화창에서 \"…고쳐 줘\"라고 시키면 묻고 맡긴다냥" : "찾는 작업 없음"))
            return
        }
        let now = Date().timeIntervalSince1970
        for (n, t) in list.enumerated() {
            if n == 0 || (list[n - 1].state == "running") != (t.state == "running") {
                header(t.state == "running" ? "하는 중" : "끝난 것", top: stack.arrangedSubviews.isEmpty)
            }
            var rows: [NSView] = [textBlock(t.task, detail: TaskRules.subtitle(t, now: now), key: "task-" + t.id)]
            if let sm = t.summary ?? t.error { rows.append(expandable(sm, key: "task-s" + t.id, lines: 3, size: 12)) }
            var buttons: [NSView] = []
            let wt = URL(fileURLWithPath: t.worktree)
            let folder = mindDir.appendingPathComponent("tasks/\(t.id)", isDirectory: true)
            if FileManager.default.fileExists(atPath: wt.path) { buttons.append(button("폴더 열기") { NSWorkspace.shared.open(wt) }) }
            buttons.append(button("기록 보기") { NSWorkspace.shared.open(folder) })
            if t.state == "running" {
                buttons.append(button("멈추기") { [weak self] in
                    FileManager.default.createFile(atPath: folder.appendingPathComponent("cancel").path, contents: nil)
                    self?.showStatus("멈추라고 했다냥 (5초 안에 멈춘다)")
                })
            } else if t.state == "done" || t.state == "failed", t.files > 0, items.contains(where: { $0.text.contains("합칠까냥") && $0.ask }) {
                buttons.append(button("합칠지 고르기") { [weak self] in self?.select(.inbox) })
            }
            let branch = NSTextField(labelWithString: t.branch)
            branch.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            branch.textColor = .tertiaryLabelColor
            branch.lineBreakMode = .byTruncatingMiddle
            branch.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            rows.append(actions(buttons, leading: branch))
            add(group([rows], focused: t.state == "running"))
        }
    }

    private func decisionRow(_ d: ThinkRules.Decision) -> NSView {
        let symbol = ["said": "bubble.left", "quiet": "moon.zzz", "failed": "exclamationmark.triangle", "timeout": "clock.badge.xmark",
                      "limited": "hourglass", "retry": "arrow.clockwise", "muted": "speaker.slash"][d.outcome] ?? "circle"
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 14, weight: .regular)
        icon.contentTintColor = ["failed", "timeout"].contains(d.outcome) ? .systemRed : .secondaryLabelColor
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.widthAnchor.constraint(equalToConstant: 22).isActive = true
        let title = NSTextField(labelWithString: ThinkRules.title(d))
        title.font = .systemFont(ofSize: 13)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var col: [NSView] = [title]
        let reaction = d.sid.flatMap { reactions[$0] }.flatMap { ReactionRules.ko[$0] }
        let sub = [ThinkRules.subtitle(d), reaction.map { "반응: " + $0 } ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
        if !sub.isEmpty { col.append(expandable(sub, key: "d-s\(d.ts)", lines: 1, size: 11)) }
        if let t = d.text { col.append(expandable("“\(t)”", key: "d-t\(d.ts)", lines: 2, size: 12)) }
        if ThinkRules.labelable(d) { col.append(labelButtons(d)) }
        let texts = NSStackView(views: col)
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 2
        texts.setHuggingPriority(.init(1), for: .horizontal)
        texts.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for v in col { v.widthAnchor.constraint(lessThanOrEqualTo: texts.widthAnchor).isActive = true }
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        let time = NSTextField(labelWithString: f.string(from: Date(timeIntervalSince1970: d.ts)))
        time.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        time.textColor = .tertiaryLabelColor
        time.setContentHuggingPriority(.required, for: .horizontal)
        let row = NSStackView(views: [icon, texts, time])
        row.distribution = .fill
        row.alignment = .firstBaseline
        row.spacing = 10
        return row
    }

    /// 판단이 맞았나: 고른 쪽은 ✓, 다시 누르면 지운다. 나중에 '언제 말할지' 판단기를 학습하는 정답이 된다
    private func labelButtons(_ d: ThinkRules.Decision) -> NSView {
        let key = ThinkRules.key(d)
        let cur = labels[key]
        let titles = ThinkRules.labelTitles(d)
        let views: [NSView] = [("right", titles.right), ("wrong", titles.wrong)].map { verdict, title in
            let b = button((cur == verdict ? "✓ " : "") + title) { [weak self] in
                self?.label(d, verdict: cur == verdict ? "clear" : verdict)
            }
            b.controlSize = .small
            b.font = .systemFont(ofSize: 11)
            return b
        }
        let r = NSStackView(views: views)
        r.spacing = 6
        return r
    }

    private func label(_ d: ThinkRules.Decision, verdict: String) {
        let url = mindDir.appendingPathComponent("decision_labels.jsonl")
        let o = ThinkRules.labelLine(d, verdict: verdict, now: Date().timeIntervalSince1970)
        guard let data = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else { return }
        let bytes = Data((line + "\n").utf8)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(bytes); try? h.close()
        } else {
            try? FileManager.default.createDirectory(at: mindDir, withIntermediateDirectories: true)
            try? bytes.write(to: url, options: .atomic)
            chmod(url.path, 0o600)
        }
        reload(force: true)
    }

    // MARK: 개선 (주간 개선 제안)

    private var improveOn: Bool { FileManager.default.fileExists(atPath: mindDir.appendingPathComponent("improve.on").path) }

    /// cat_mind 가 최근 30초 안에 신호를 남겼나
    private var mindAlive: Bool {
        guard let d = try? Data(contentsOf: mindDir.appendingPathComponent("alive.json")),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let ts = o["ts"] as? Double else { return false }
        return Date().timeIntervalSince1970 - ts < 30
    }

    /// 제안: 중요한 순. 항목마다 필요 없음 · 나중에(하루 뒤 다시) · 하기
    private func suggestList() {
        let now = Date().timeIntervalSince1970
        let q = query
        let list = (suggestions?.items ?? []).filter { q.isEmpty || ($0.title + " " + ($0.detail ?? "")).lowercased().contains(q) }
        window?.subtitle = list.isEmpty ? "" : "제안 \(list.count)개 · 중요한 순"
        if list.isEmpty { add(emptyState("lightbulb", q.isEmpty ? "제안 없음" : "찾는 제안 없음")); return }
        let src = ["mind": "고양이", "cleaner": "앱 정리"]
        for (n, it) in list.enumerated() {
            let s = SuggestRules.score(it, now: now)
            header(Self.meta(SuggestRules.rank(s), src[it.source] ?? (it.source.isEmpty ? nil : it.source), Self.ago(it.updated),
                             it.count > 1 ? "\(it.count)번" : nil), red: s >= 0.6, top: stack.arrangedSubviews.isEmpty)
            var buttons = [button("필요 없음") { [weak self] in self?.suggestions?.decide(it, "no"); self?.reload(force: true) },
                           button("나중에") { [weak self] in self?.suggestions?.decide(it, "later"); self?.reload(force: true) }]
            let go = button(it.actionLabel ?? (it.action == nil ? "확인" : "하기")) { [weak self] in
                self?.suggestions?.decide(it, "do"); self?.reload(force: true)
            }
            go.keyEquivalent = n == 0 ? "\r" : ""
            buttons.append(go)
            add(group([[textBlock(it.title, detail: it.detail, key: "sg-" + it.file), actions(buttons)]], focused: n == 0))
        }
    }

    private func improveView() {
        let pending = FileManager.default.fileExists(atPath: mindDir.appendingPathComponent("improve.now").path)
        let toggle = NSSwitch()
        toggle.state = improveOn ? .on : .off
        toggle.controlSize = .small
        let onRow = settingRow("매주 개선 제안 받기", control: toggle)
        (toggle as NSControl).target = self
        toggle.action = #selector(toggleImprove(_:))
        let d = DateFormatter(); d.locale = Locale(identifier: "ko_KR"); d.dateFormat = "M월 d일 a h:mm"
        let lastText = improve.map { "마지막 제안 " + d.string(from: Date(timeIntervalSince1970: $0.ts)) } ?? "아직 받은 제안 없음"
        let now = button(pending ? "받는 중…" : "지금 받기") { [weak self] in self?.requestImproveNow() }
        now.isEnabled = improveOn && !pending
        let info = NSTextField(labelWithString: mindAlive ? lastText : "고양이 머리(cat_mind)가 안 돌고 있다")
        info.font = .systemFont(ofSize: 12)
        info.textColor = .secondaryLabelColor
        header("설정", top: true)
        add(group([[onRow, actions([now], leading: info)]], focused: false))
        window?.subtitle = improve.map { "제안 \($0.suggestions.count)개 · 새로 \($0.suggestions.filter { $0.status == "new" }.count)개" } ?? ""
        guard let imp = improve else { return }
        if !imp.summary.isEmpty {
            header("요약")
            add(group([[textBlock(imp.summary, detail: nil, key: "imp-summary")]], focused: false))
        }
        for sg in imp.suggestions {
            let kindKo = ["phrase": "문구", "param": "설정", "idea": "아이디어"][sg.kind] ?? sg.kind
            header([kindKo, sg.key.isEmpty ? nil : sg.key].compactMap { $0 }.joined(separator: " · "))
            var rows: [NSView] = []
            switch sg.kind {
            case "phrase":
                rows.append(compare("지금", sg.current ?? "", dim: true))
                rows.append(compare("제안", sg.value, dim: false))
            case "param":
                rows.append(compare("값", "\(sg.current ?? "?") → \(sg.value)", dim: false))
            default:
                rows.append(textBlock(sg.value, detail: nil, key: sg.id))
            }
            if !sg.why.isEmpty { rows.append(expandable(sg.why, key: "why-" + sg.id, lines: 2, size: 12)) }
            if sg.status == "new" {
                var buttons = [button("무시") { [weak self] in self?.setSuggestion(sg, status: "ignored") }]
                if sg.kind != "idea" {
                    let apply = button("적용") { [weak self] in self?.applySuggestion(sg) }
                    buttons.append(apply)
                } else {
                    buttons.append(button("확인") { [weak self] in self?.setSuggestion(sg, status: "seen") })
                }
                rows.append(actions(buttons))
            } else {
                let done = NSTextField(labelWithString: ["applied": "적용함", "ignored": "무시함", "seen": "확인함"][sg.status] ?? sg.status)
                done.font = .systemFont(ofSize: 11)
                done.textColor = .tertiaryLabelColor
                rows.append(actions([], leading: done))
            }
            add(group([rows], focused: sg.status == "new"))
        }
    }

    /// "지금"·"제안" 처럼 앞에 작은 꼬리표가 붙은 한 줄
    private func compare(_ tag: String, _ text: String, dim: Bool) -> NSView {
        let t = NSTextField(labelWithString: tag)
        t.font = .systemFont(ofSize: 11, weight: .medium)
        t.textColor = .tertiaryLabelColor
        t.widthAnchor.constraint(equalToConstant: 30).isActive = true
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = .systemFont(ofSize: 13)
        l.textColor = dim ? .secondaryLabelColor : .labelColor
        l.isSelectable = true
        l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [t, l])
        row.alignment = .firstBaseline
        row.spacing = 8
        return row
    }

    private func settingRow(_ title: String, control: NSView) -> NSView {
        let l = NSTextField(labelWithString: title)
        l.font = .systemFont(ofSize: 13)
        let r = NSStackView(views: [l, NSView(), control])
        r.alignment = .centerY
        return r
    }

    @objc private func toggleImprove(_ sender: NSSwitch) {
        let flag = mindDir.appendingPathComponent("improve.on")
        if sender.state == .on {
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert()
            a.messageText = "매주 개선 제안을 받을까요?"
            a.informativeText = """
            일주일에 한 번, 아래 통계를 고양이 전용 Codex 계정으로 보내 알림·말투 개선 제안을 받습니다.
            • 지난 7일 고양이 알림 통계(건수·반복·몰림·종류)와 두 번 이상 한 알림 문장 (대화·작업 이름과 숫자는 가림)
            • 고양이 판단 통계(신호별 횟수·말할 확률·결과)
            • 지금 쓰는 알림 문구와 설정 값
            입력한 글, 활동 기록, 고양이와 나눈 대화는 보내지 않습니다. 제안은 [적용]을 눌러야만 바뀌고, 끄면 더 보내지 않습니다.
            """
            a.addButton(withTitle: "켜기")
            a.addButton(withTitle: "취소")
            guard a.runModal() == .alertFirstButtonReturn else { sender.state = .off; return }
            try? FileManager.default.createDirectory(at: mindDir, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: flag.path, contents: nil, attributes: [.posixPermissions: 0o600])
            Log.write("개선 제안 켬")
        } else {
            try? FileManager.default.removeItem(at: flag)
            try? FileManager.default.removeItem(at: mindDir.appendingPathComponent("improve.now"))
            Log.write("개선 제안 끔")
        }
        reload(force: true)
    }

    private func requestImproveNow() {
        FileManager.default.createFile(atPath: mindDir.appendingPathComponent("improve.now").path, contents: nil, attributes: [.posixPermissions: 0o600])
        showStatus("개선 제안을 요청했다. 몇 분 걸린다")
        reload(force: true)
    }

    private func applySuggestion(_ sg: ThinkRules.Suggestion) {
        guard PhraseTable.apply(kind: sg.kind, key: sg.key, value: sg.value, dir: dataDir) else {
            showStatus("적용 못 함: \(sg.key) 값이 맞지 않는다")
            return
        }
        Log.write("개선 제안 적용: \(sg.key) = \(sg.value)")
        setSuggestion(sg, status: "applied")
        showStatus("적용함: \(sg.key)")
    }

    /// latest.json 의 그 제안 상태만 바꿔 다시 쓴다
    private func setSuggestion(_ sg: ThinkRules.Suggestion, status: String) {
        let url = mindDir.appendingPathComponent("improve/latest.json")
        guard let d = try? Data(contentsOf: url), var o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              var list = o["suggestions"] as? [[String: Any]] else { return }
        for i in list.indices where list[i]["id"] as? String == sg.id { list[i]["status"] = status }
        o["suggestions"] = list
        _ = Self.write(o, to: url)
        reload(force: true)
    }

    /// 파일 끝 512KB 만 (오래 켜 두면 커진다)
    private static func tail(_ url: URL) -> String {
        guard let h = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let start = size > 512_000 ? size - 512_000 : 0
        try? h.seek(toOffset: start)
        guard let d = try? h.readToEnd(), var s = String(data: d, encoding: .utf8) else { return "" }
        if start > 0, let nl = s.firstIndex(of: "\n") { s = String(s[s.index(after: nl)...]) }
        return s
    }

    // MARK: 조각

    /// 시스템 설정 같은 회색 묶음 칸. sections 사이엔 꽉 찬 선, 같은 section 안 줄 사이엔 들여 쓴 선
    private func group(_ sections: [[NSView]], focused: Bool, inset: CGFloat = 0) -> NSView {
        var views: [NSView] = []
        for (i, rows) in sections.enumerated() {
            if i > 0 { views.append(hairline(inset: 0)) }
            for (j, r) in rows.enumerated() {
                if j > 0 && inset > 0 { views.append(hairline(inset: inset)) }
                views.append(r)
            }
        }
        let inner = NSStackView(views: views)
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = inset > 0 ? 0 : 10
        inner.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        inner.translatesAutoresizingMaskIntoConstraints = false
        for v in views {
            v.widthAnchor.constraint(equalTo: inner.widthAnchor, constant: -28).isActive = true
            if inset > 0, !(v is HairlineWrap) { (v as? NSStackView)?.edgeInsets = NSEdgeInsets(top: 7, left: 0, bottom: 7, right: 0) }
        }
        let box = NSBox()
        box.boxType = .custom
        box.cornerRadius = 10
        box.borderWidth = 0
        box.fillColor = focused ? .tertiarySystemFill : .quaternarySystemFill
        box.titlePosition = .noTitle
        box.contentViewMargins = .zero
        if let c = box.contentView {
            c.addSubview(inner)
            NSLayoutConstraint.activate([
                inner.leadingAnchor.constraint(equalTo: c.leadingAnchor), inner.trailingAnchor.constraint(equalTo: c.trailingAnchor),
                inner.topAnchor.constraint(equalTo: c.topAnchor), inner.bottomAnchor.constraint(equalTo: c.bottomAnchor),
            ])
        }
        return box
    }

    /// 질문 글 + 설명 (설명은 눌러서 펼친다)
    private func textBlock(_ text: String, detail: String?, key: String) -> NSView {
        let t = NSTextField(wrappingLabelWithString: text)
        t.font = .systemFont(ofSize: 13, weight: .semibold)
        t.isSelectable = true
        var views: [NSView] = [t]
        if let detail { views.append(expandable(detail, key: key, lines: 3, size: 12)) }
        let s = NSStackView(views: views)
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = 3
        for v in views { v.widthAnchor.constraint(equalTo: s.widthAnchor).isActive = true }
        return s
    }

    private func expandable(_ s: String, key: String, lines: Int, size: CGFloat) -> NSTextField {
        let l = ClickLabel(wrappingLabelWithString: s)
        l.font = .systemFont(ofSize: size)
        l.textColor = .secondaryLabelColor
        l.maximumNumberOfLines = expanded.contains(key) ? 0 : lines
        l.lineBreakMode = .byTruncatingTail
        l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        l.onClick = { [weak self] in
            guard let self else { return }
            if self.expanded.contains(key) { self.expanded.remove(key) } else { self.expanded.insert(key) }
            self.render()
        }
        return l
    }

    /// 기본 버튼으로 선택지. 맨 위 묶음이면 제목 앞에 흐린 번호 (그 숫자키로 고른다)
    private func choiceButtons(_ choices: [InboxRules.Choice], target: String, numbered: Bool) -> NSView {
        let flow = FlowView()
        flow.setViews(choices.enumerated().map { n, c in
            let b = button(c.label) { [weak self] in
                guard let self, !self.targets(target).isEmpty else { return }
                self.resolve(self.targets(target), c.id, label: c.label)
            }
            b.toolTip = c.label
            if numbered && n < 9 {
                let t = NSMutableAttributedString(string: "\(n + 1)  ", attributes: [.foregroundColor: NSColor.tertiaryLabelColor, .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)])
                t.append(NSAttributedString(string: c.label, attributes: [.foregroundColor: NSColor.labelColor, .font: NSFont.systemFont(ofSize: 13)]))
                b.attributedTitle = t
            }
            b.lineBreakMode = .byTruncatingTail
            b.widthAnchor.constraint(lessThanOrEqualToConstant: 340).isActive = true
            return b
        })
        return flow
    }

    private func button(_ title: String, _ action: @escaping () -> Void) -> NSButton {
        let b = ActionButton(title: title, action: action)
        b.bezelStyle = .push
        b.controlSize = .regular
        return b
    }

    /// 오른쪽에 버튼들, 왼쪽에 (있으면) 글
    private func actions(_ buttons: [NSView], leading: NSView? = nil) -> NSView {
        let r = NSStackView(views: [leading ?? NSView(), NSView()] + buttons)
        r.spacing = 8
        r.alignment = .centerY
        return r
    }

    private func writeField() -> NSView {
        let f = NSTextField()
        f.placeholderString = "답 입력 후 ⏎ · Esc 취소"
        f.delegate = self
        f.bezelStyle = .roundedBezel
        DispatchQueue.main.async { [weak f] in f?.window?.makeFirstResponder(f) }
        return f
    }

    private func hairline(inset: CGFloat) -> NSView {
        let line = NSBox()
        line.boxType = .separator
        let wrap = HairlineWrap(views: [line])
        wrap.edgeInsets = NSEdgeInsets(top: 0, left: inset, bottom: 0, right: 0)
        return wrap
    }

    /// 맥 앱의 빈 화면처럼: 흐린 큰 기호 + 한 줄
    private func emptyState(_ symbol: String, _ text: String) -> NSView {
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 36, weight: .light)
        icon.contentTintColor = .tertiaryLabelColor
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 15, weight: .medium)
        l.textColor = .secondaryLabelColor
        let v = NSStackView(views: [icon, l])
        v.orientation = .vertical
        v.spacing = 10
        v.edgeInsets = NSEdgeInsets(top: 120, left: 0, bottom: 0, right: 0)
        return v
    }

    /// Mail 의 읽지 않은 수처럼 회색 알약
    private static func capsule(_ s: String) -> NSView {
        let l = NSTextField(labelWithString: s)
        l.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
        l.textColor = .secondaryLabelColor
        l.alignment = .center
        let v = NSView()
        v.wantsLayer = true
        v.layer?.cornerRadius = 7
        v.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        l.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(l)
        NSLayoutConstraint.activate([
            l.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 5), l.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -5),
            l.centerYAnchor.constraint(equalTo: v.centerYAnchor), v.heightAnchor.constraint(equalToConstant: 14),
            v.widthAnchor.constraint(greaterThanOrEqualToConstant: 18),
        ])
        v.setContentHuggingPriority(.required, for: .horizontal)
        return v
    }

    private static func meta(_ parts: String?...) -> String {
        parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private static func ago(_ ts: Double) -> String {
        let rel = RelativeDateTimeFormatter()
        rel.locale = Locale(identifier: "ko_KR")
        rel.unitsStyle = .short
        return rel.localizedString(for: Date(timeIntervalSince1970: ts), relativeTo: Date())
    }
}

// MARK: - 부품

/// ⌘ 단축키는 performKeyEquivalent, 숫자키는 글 칸이 안 받았을 때 keyDown 으로 대시보드에 넘긴다
private final class DashboardWindow: NSWindow {
    var onKey: ((NSEvent) -> Bool)?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        onKey?(event) == true || super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }
}

/// 사이드바 한 줄: 아이콘 · 이름 · 개수(회색 숫자). 고른 줄은 회색 음영
private final class SidebarRow: NSView {
    var onClick: (() -> Void)?
    var selected = false { didSet { if selected != oldValue { update() } } }
    var count = 0 { didSet { if count != oldValue { update() } } }
    private let icon = NSImageView()
    private let label: NSTextField
    private let badge = NSTextField(labelWithString: "")

    init(title: String, symbol: String) {
        label = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        icon.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        label.font = .systemFont(ofSize: 13)
        badge.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        badge.textColor = .secondaryLabelColor
        let row = NSStackView(views: [icon, label, NSView(), badge])
        row.spacing = 7
        row.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 10)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 28), icon.widthAnchor.constraint(equalToConstant: 18),
        ])
        update()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func update() {
        layer?.backgroundColor = selected ? NSColor.labelColor.withAlphaComponent(0.1).cgColor : NSColor.clear.cgColor
        icon.contentTintColor = selected ? .labelColor : .secondaryLabelColor
        badge.stringValue = count > 0 ? "\(count)" : ""
    }

    override func viewDidChangeEffectiveAppearance() { update() }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// 버튼을 왼쪽부터 채우고 넘치면 다음 줄로 (기본 버튼은 테두리 바깥 여백이 있어 줄 간격은 0)
private final class FlowView: NSView {
    var spacing: CGFloat = 2
    var lineSpacing: CGFloat = 0
    private var height: CGFloat = 0
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height) }

    func setViews(_ views: [NSView]) {
        subviews.forEach { $0.removeFromSuperview() }
        for v in views { v.translatesAutoresizingMaskIntoConstraints = true; addSubview(v) }
        needsLayout = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize.width != frame.width
        super.setFrameSize(newSize)
        if changed { needsLayout = true }
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        let width = bounds.width
        for v in subviews {
            var s = v.fittingSize
            s.width = min(s.width, 340, width)
            if x > 0 && x + s.width > width { x = 0; y += rowH + lineSpacing; rowH = 0 }
            v.frame = NSRect(x: x, y: y, width: s.width, height: s.height)
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
        let h = subviews.isEmpty ? 0 : y + rowH
        if h != height { height = h; invalidateIntrinsicContentSize() }
    }
}

/// 누르면 할 일을 부르는 버튼 (셀렉터 없이 클로저로)
private final class ActionButton: NSButton {
    private var handler: () -> Void = {}
    convenience init(title: String, action: @escaping () -> Void) {
        self.init(frame: .zero)
        self.title = title
        handler = action
        target = self
        self.action = #selector(fire)
    }
    @objc private func fire() { handler() }
}

/// 누르면 펼치는 글
private final class ClickLabel: NSTextField {
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// 구분선 감싸개 (줄 여백을 주지 않으려고 따로 구분)
private final class HairlineWrap: NSStackView {}

/// 위에서부터 쌓이는 문서 뷰
private final class FlippedDoc: NSView {
    override var isFlipped: Bool { true }
}
