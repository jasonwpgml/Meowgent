import AppKit

/// Meowgent 대시보드: 질문 · 경고 · 알림 탭.
/// - 질문: 고양이 ! · ? 항목(inbox/). 같은 곳에서 같은 선택지로 물은 질문은 한 카드로 묶어 체크한 것 전부에 한 번에 답하고,
///   다른 답이 필요한 것만 따로 고른다. 답은 고양이 메뉴와 똑같이 inbox/done/ 으로 옮기고 answer·resolved 를 붙인다 (docs/INBOX.md).
///   방금 한 답은 아래 줄에서 되돌린다 (만든 쪽이 그새 가져갔으면 거기엔 반영되지 않는다).
/// - 경고 / 알림: 고양이가 한 말(notices.jsonl) 중 급한 것(대화 답 제외) / 나머지. 숫자만 바뀌며 연달아 온 알림은 한 줄로 접는다.
final class Dashboard: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    enum Tab: Int { case inbox, warnings, notices }

    private let inbox: URL
    private let noticesURL: URL
    private let chatURL: URL
    private var window: NSWindow?
    private let tabs = NSSegmentedControl(labels: ["질문", "경고", "알림"], trackingMode: .selectOne, target: nil, action: nil)
    private let stack = NSStackView()
    private let scroll = NSScrollView()
    private let undoBar = NSStackView()
    private let undoLabel = NSTextField(labelWithString: "")
    private var timer: Timer?
    private var items: [InboxRules.Item] = []
    private var notices: [NoticeRules.Notice] = []
    private var chat: Set<String> = []
    private var unchecked: Set<String> = []        // 묶음에서 체크를 푼 항목
    private var writing: String?                   // "직접 적기" 칸을 연 항목
    private var lastMoved: [(src: URL, dest: URL)] = []
    private var shownStamp = ""

    static let warnDays: Double = 7
    static let maxRows = 300

    /// 경고 탭을 마지막으로 본 시각 (그 뒤 경고만 개수에 센다)
    private var warnSeen: Double {
        get { UserDefaults.standard.double(forKey: "dashboardWarnSeen") }
        set { UserDefaults.standard.set(newValue, forKey: "dashboardWarnSeen") }
    }

    init(dataDir: URL) {
        inbox = dataDir.appendingPathComponent("inbox", isDirectory: true)
        noticesURL = dataDir.appendingPathComponent("notices.jsonl")
        chatURL = dataDir.appendingPathComponent("mind/conversation.jsonl")
        super.init()
        // 처음 쓸 때는 지금부터 온 경고만 센다 (예전 경고는 탭에서만 본다)
        if warnSeen == 0 { warnSeen = Date().timeIntervalSince1970 }
    }

    private var tab: Tab { Tab(rawValue: tabs.selectedSegment) ?? .inbox }

    func addMenuItems(to menu: NSMenu) {
        let asks = loadInbox().count
        let chat = NoticeRules.catLines((try? String(contentsOf: chatURL, encoding: .utf8)) ?? "")
        let warns = loadNotices().filter { NoticeRules.isWarning($0, chat: chat) && $0.ts > warnSeen }.count
        let counts = [asks > 0 ? "질문 \(asks)" : nil, warns > 0 ? "경고 \(warns)" : nil].compactMap { $0 }.joined(separator: " · ")
        menu.addItem("📋 대시보드\(counts.isEmpty ? "" : " (\(counts))")", #selector(show), target: self)
    }

    @objc func show() {
        DispatchQueue.main.async { [self] in
            if window == nil { build() }
            // 답할 질문이 없고 새 경고가 있으면 경고 탭부터
            if !window!.isVisible {
                let chat = NoticeRules.catLines((try? String(contentsOf: chatURL, encoding: .utf8)) ?? "")
                let newWarn = loadNotices().contains { NoticeRules.isWarning($0, chat: chat) && $0.ts > warnSeen }
                tabs.selectedSegment = loadInbox().isEmpty && newWarn ? Tab.warnings.rawValue : Tab.inbox.rawValue
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

    @objc private func tabChanged() {
        writing = nil
        reload(force: true)
        scroll.documentView?.scroll(.zero)
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

    /// 파일이 바뀌었을 때만 다시 그린다 (고른 체크·적던 글을 지키려고)
    private func reload(force: Bool) {
        items = loadInbox()
        notices = loadNotices()
        chat = NoticeRules.catLines((try? String(contentsOf: chatURL, encoding: .utf8)) ?? "")
        unchecked.formIntersection(Set(items.map(\.id)))
        if let w = writing, !items.contains(where: { $0.id == w }) { writing = nil }
        let warns = notices.filter { NoticeRules.isWarning($0, chat: chat) && $0.ts > warnSeen }.count
        tabs.setLabel(items.isEmpty ? "질문" : "질문 \(items.count)", forSegment: Tab.inbox.rawValue)
        tabs.setLabel(warns == 0 || tab == .warnings ? "경고" : "경고 \(warns)", forSegment: Tab.warnings.rawValue)
        let stamp = "\(tab.rawValue)|" + items.map(\.file).joined(separator: ",") + "|\(notices.last?.ts ?? 0)"
        guard force || stamp != shownStamp else { return }
        shownStamp = stamp
        render()
        if tab == .warnings, window?.isVisible == true { warnSeen = Date().timeIntervalSince1970 }
    }

    // MARK: 답하기

    /// answer: 고른 선택지 id 또는 직접 적은 글, 확인은 "done", 건너뛰기는 nil
    private func resolve(_ list: [InboxRules.Item], _ answer: String?, label: String) {
        guard !list.isEmpty else { return }
        let fm = FileManager.default
        let done = inbox.appendingPathComponent("done", isDirectory: true)
        try? fm.createDirectory(at: done, withIntermediateDirectories: true)
        var moved: [(URL, URL)] = []
        for it in list {
            let src = inbox.appendingPathComponent(it.file), dest = done.appendingPathComponent(it.file)
            guard let d = try? Data(contentsOf: src), var o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            o["answer"] = answer ?? NSNull()
            o["resolved"] = Date().timeIntervalSince1970
            guard Self.write(o, to: dest) else { continue }
            try? fm.removeItem(at: src)
            moved.append((src, dest))
        }
        Log.write("대시보드 답: \(list.map(\.id).joined(separator: ", ")) → \(answer ?? "건너뜀")")
        lastMoved = moved
        undoLabel.stringValue = "\(moved.count)개 → \(label)"
        undoBar.isHidden = moved.isEmpty
        writing = nil
        reload(force: true)
    }

    @objc private func undo() {
        let fm = FileManager.default
        for (src, dest) in lastMoved {
            guard let d = try? Data(contentsOf: dest), var o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            o["answer"] = nil
            o["resolved"] = nil
            if Self.write(o, to: src) { try? fm.removeItem(at: dest) }
        }
        Log.write("대시보드 답 되돌림: \(lastMoved.count)개")
        lastMoved = []
        undoBar.isHidden = true
        reload(force: true)
    }

    /// 임시 파일에 쓰고 바꿔치기 (반쯤 쓴 파일을 고양이·만든 쪽이 읽지 않게), 0600
    private static func write(_ o: [String: Any], to url: URL) -> Bool {
        guard let out = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]) else { return false }
        let tmp = url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".tmp")
        guard FileManager.default.createFile(atPath: tmp.path, contents: out, attributes: [.posixPermissions: 0o600]) else { return false }
        return rename(tmp.path, url.path) == 0
    }

    @objc private func choose(_ sender: NSButton) {
        // [대상: 항목 id 또는 "group:<첫 id>", 선택지 id, 선택지 이름]
        guard let p = sender.cell?.representedObject as? [String], p.count == 3 else { return }
        resolve(targets(p[0]), p[1], label: p[2])
    }

    @objc private func chooseFromPopup(_ sender: NSPopUpButton) {
        guard let p = sender.selectedItem?.representedObject as? [String], p.count == 3 else { return }
        resolve(targets(p[0]), p[1], label: p[2])
    }

    @objc private func skip(_ sender: NSButton) {
        guard let t = sender.cell?.representedObject as? String else { return }
        resolve(targets(t), nil, label: "건너뜀")
    }

    @objc private func confirm(_ sender: NSButton) {
        guard let t = sender.cell?.representedObject as? String else { return }
        resolve(targets(t), "done", label: "확인")
    }

    @objc private func openURL(_ sender: NSButton) {
        guard let s = sender.cell?.representedObject as? String, let u = URL(string: s) else { return }
        NSWorkspace.shared.open(u)
    }

    @objc private func startWriting(_ sender: NSButton) {
        writing = sender.cell?.representedObject as? String
        render()
    }

    @objc private func toggleCheck(_ sender: NSButton) {
        guard let id = sender.cell?.representedObject as? String else { return }
        if sender.state == .on { unchecked.remove(id) } else { unchecked.insert(id) }
        render()
    }

    /// 직접 적은 답: ⏎ 보내기, Esc 취소
    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.cancelOperation(_:)) { writing = nil; render(); return true }
        guard sel == #selector(NSResponder.insertNewline(_:)), let id = writing else { return false }
        let text = control.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { resolve(targets(id), text, label: "“\(text.prefix(30))”") }
        return true
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

    // MARK: 화면

    private func build() {
        let w = DashboardWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 700),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: true)
        w.title = "Meowgent"
        w.onTab = { [weak self] n in self?.tabs.selectedSegment = n; self?.tabChanged() }
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 460, height: 360)
        w.delegate = self
        w.setFrameAutosaveName("MeowgentDashboard")
        if !w.setFrameUsingName("MeowgentDashboard") { w.center() }

        tabs.selectedSegment = 0
        tabs.target = self
        tabs.action = #selector(tabChanged)
        tabs.segmentDistribution = .fillEqually
        let head = NSStackView(views: [tabs])
        head.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 8, right: 16)
        tabs.widthAnchor.constraint(equalToConstant: 300).isActive = true

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedDoc()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        scroll.documentView = doc
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor), stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor), stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])

        undoLabel.font = .systemFont(ofSize: 12)
        let undoButton = NSButton(title: "되돌리기", target: self, action: #selector(undo))
        undoButton.controlSize = .small
        undoBar.setViews([undoLabel, NSView(), undoButton], in: .leading)
        undoBar.orientation = .horizontal
        undoBar.spacing = 6
        undoBar.edgeInsets = NSEdgeInsets(top: 6, left: 18, bottom: 8, right: 18)
        undoBar.isHidden = true

        let root = NSStackView(views: [head, scroll, undoBar])
        root.orientation = .vertical
        root.alignment = .centerX
        root.spacing = 0
        for v in [scroll, undoBar] as [NSView] { v.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        w.contentView = root
        window = w
    }

    private func render() {
        guard window != nil else { return }
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        switch tab {
        case .inbox:
            if items.isEmpty { add(emptyLabel("없음")) }
            for g in InboxRules.group(items) { add(g.isBatch ? batchCard(g) : singleCard(g.items[0])) }
        case .warnings:
            let cut = Date().timeIntervalSince1970 - Self.warnDays * 86400
            noticeList(notices.filter { NoticeRules.isWarning($0, chat: chat) && $0.ts >= cut }, highlightAfter: warnSeen)
        case .notices:
            noticeList(notices.filter { !NoticeRules.isWarning($0, chat: chat) }, highlightAfter: nil)
        }
    }

    private func add(_ v: NSView) {
        stack.addArrangedSubview(v)
        v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -(stack.edgeInsets.left + stack.edgeInsets.right)).isActive = true
    }

    // MARK: 질문 카드

    /// 하나짜리: 무엇을 묻나 · 설명 · 선택지 / 직접 적기 · 건너뛰기 (확인할 일이면 확인 · 열기 · 건너뛰기)
    private func singleCard(_ it: InboxRules.Item) -> NSView {
        var views: [NSView] = [metaLine(it), titleLabel(it.text)]
        if let d = it.detail { views.append(detailLabel(d, lines: 4)) }
        if it.ask {
            if !it.choices.isEmpty { views.append(choiceGrid(it.choices, target: it.id)) }
            views.append(writing == it.id ? writeField() : buttonRow([
                button("직접 적기", #selector(startWriting(_:)), it.id),
                button("건너뛰기", #selector(skip(_:)), it.id),
            ]))
        } else {
            var b = [button("확인", #selector(confirm(_:)), it.id)]
            if let u = it.url { b.append(button("열기", #selector(openURL(_:)), u.absoluteString)) }
            b.append(button("건너뛰기", #selector(skip(_:)), it.id))
            views.append(buttonRow(b))
        }
        return card(views, red: it.red)
    }

    /// 묶음: 위 선택지는 체크한 질문 전부에. 아래 질문마다 체크 · 따로 답하기
    private func batchCard(_ g: InboxRules.Group) -> NSView {
        guard let first = g.items.first else { return NSView() }
        let key = "group:" + first.id
        let checked = g.items.filter { !unchecked.contains($0.id) }.count
        let head = detailLabel([first.source.isEmpty ? nil : first.source, "\(checked)/\(g.items.count)개"].compactMap { $0 }.joined(separator: " · "), lines: 1)
        var views: [NSView] = [head, choiceGrid(g.choices, target: key, enabled: checked > 0)]
        let skipAll = button("건너뛰기", #selector(skip(_:)), key)
        skipAll.isEnabled = checked > 0
        views.append(buttonRow([skipAll]))
        views.append(separator())
        for it in g.items {
            let check = NSButton(checkboxWithTitle: it.text, target: self, action: #selector(toggleCheck(_:)))
            check.state = unchecked.contains(it.id) ? .off : .on
            check.cell?.representedObject = it.id
            check.font = .systemFont(ofSize: 12.5, weight: .medium)
            check.lineBreakMode = .byTruncatingTail
            check.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let popup = NSPopUpButton(frame: .zero, pullsDown: true)
            popup.controlSize = .small
            popup.addItem(withTitle: "따로")
            for c in it.choices {
                popup.addItem(withTitle: c.label)
                popup.lastItem?.representedObject = [it.id, c.id, c.label]
            }
            popup.target = self
            popup.action = #selector(chooseFromPopup(_:))
            popup.setContentCompressionResistancePriority(.required, for: .horizontal)
            let line = NSStackView(views: [check, NSView(), popup])
            line.orientation = .horizontal
            line.spacing = 8
            var row: [NSView] = [line]
            if let d = it.detail { row.append(detailLabel(d, lines: 2)) }
            let member = NSStackView(views: row)
            member.orientation = .vertical
            member.alignment = .leading
            member.spacing = 2
            member.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 4, right: 0)
            for v in row { v.widthAnchor.constraint(equalTo: member.widthAnchor).isActive = true }
            views.append(member)
        }
        return card(views, red: g.items.contains(where: \.red))
    }

    // MARK: 경고·알림 목록

    /// 날짜별로 나눠 최신순. highlightAfter 이후 것(아직 안 본 경고)은 빨간 점
    private func noticeList(_ list: [NoticeRules.Notice], highlightAfter: Double?) {
        let rows = NoticeRules.collapse(list).prefix(Self.maxRows)
        guard !rows.isEmpty else { add(emptyLabel("없음")); return }
        let day = DateFormatter(); day.locale = Locale(identifier: "ko_KR"); day.dateFormat = "M월 d일 (E)"
        let time = DateFormatter(); time.locale = Locale(identifier: "ko_KR"); time.dateFormat = "HH:mm"
        var lastDay = ""
        for r in rows {
            let date = Date(timeIntervalSince1970: r.ts)
            let d = Calendar.current.isDateInToday(date) ? "오늘" : Calendar.current.isDateInYesterday(date) ? "어제" : day.string(from: date)
            if d != lastDay {
                lastDay = d
                let h = NSTextField(labelWithString: d)
                h.font = .systemFont(ofSize: 11, weight: .semibold)
                h.textColor = .secondaryLabelColor
                add(h)
            }
            let t = NSTextField(labelWithString: time.string(from: date))
            t.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            t.textColor = .secondaryLabelColor
            t.setContentCompressionResistancePriority(.required, for: .horizontal)
            t.setContentHuggingPriority(.required, for: .horizontal)
            let dot = NSTextField(labelWithString: (highlightAfter.map { r.ts > $0 } ?? false) ? "●" : " ")
            dot.font = .systemFont(ofSize: 8)
            dot.textColor = .systemRed
            dot.setContentHuggingPriority(.required, for: .horizontal)
            let body = NSTextField(wrappingLabelWithString: r.text + (r.count > 1 ? "  ×\(r.count)" : ""))
            body.font = .systemFont(ofSize: 12.5)
            body.isSelectable = true
            body.maximumNumberOfLines = 6
            body.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let row = NSStackView(views: [t, dot, body])
            row.orientation = .horizontal
            row.alignment = .firstBaseline
            row.spacing = 6
            add(row)
        }
    }

    // MARK: 조각

    private func card(_ views: [NSView], red: Bool) -> NSView {
        let inner = NSStackView(views: views)
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = 7
        inner.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        inner.translatesAutoresizingMaskIntoConstraints = false
        for v in views { v.widthAnchor.constraint(equalTo: inner.widthAnchor, constant: -28).isActive = true }
        let box = NSBox()
        box.boxType = .custom
        box.cornerRadius = 10
        box.borderWidth = red ? 1.5 : 1
        box.borderColor = red ? .systemRed.withAlphaComponent(0.6) : .separatorColor
        box.fillColor = .controlBackgroundColor
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

    private func metaLine(_ it: InboxRules.Item) -> NSView {
        let mark = NSTextField(labelWithString: it.ask ? "?" : "!")
        mark.font = .systemFont(ofSize: 13, weight: .heavy)
        mark.textColor = it.red ? .systemRed : .systemYellow
        let rel = RelativeDateTimeFormatter()
        rel.locale = Locale(identifier: "ko_KR")
        rel.unitsStyle = .short
        var when = rel.localizedString(for: Date(timeIntervalSince1970: it.created), relativeTo: Date())
        if let due = it.due { when += " · 마감 " + rel.localizedString(for: Date(timeIntervalSince1970: due), relativeTo: Date()) }
        let rest = detailLabel([it.source.isEmpty ? nil : it.source, when].compactMap { $0 }.joined(separator: " · "), lines: 1)
        let row = NSStackView(views: [mark, rest])
        row.orientation = .horizontal
        row.spacing = 6
        return row
    }

    private func titleLabel(_ s: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        l.font = .systemFont(ofSize: 13.5, weight: .semibold)
        l.isSelectable = true
        return l
    }

    private func detailLabel(_ s: String, lines: Int) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        l.font = .systemFont(ofSize: 11.5)
        l.textColor = .secondaryLabelColor
        l.maximumNumberOfLines = lines
        l.lineBreakMode = .byTruncatingTail
        l.toolTip = s
        l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return l
    }

    private func emptyLabel(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: 13)
        l.textColor = .tertiaryLabelColor
        l.alignment = .center
        return l
    }

    /// 선택지 버튼 두 칸씩 (긴 이름은 줄이고 마우스를 올리면 전체)
    private func choiceGrid(_ choices: [InboxRules.Choice], target: String, enabled: Bool = true) -> NSView {
        var rows: [NSView] = []
        for pair in stride(from: 0, to: choices.count, by: 2).map({ Array(choices[$0..<min($0 + 2, choices.count)]) }) {
            let buttons: [NSView] = pair.map { c in
                let b = NSButton(title: c.label, target: self, action: #selector(choose(_:)))
                b.bezelStyle = .rounded
                b.lineBreakMode = .byTruncatingTail
                b.toolTip = c.label
                b.isEnabled = enabled
                b.cell?.representedObject = [target, c.id, c.label]
                b.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                return b
            } + (pair.count == 1 ? [NSView()] : [])
            let row = NSStackView(views: buttons)
            row.orientation = .horizontal
            row.distribution = .fillEqually
            row.spacing = 6
            rows.append(row)
        }
        let grid = NSStackView(views: rows)
        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = 4
        for r in rows { r.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true }
        return grid
    }

    private func button(_ title: String, _ sel: Selector, _ payload: String) -> NSButton {
        let b = NSButton(title: title, target: self, action: sel)
        b.bezelStyle = .rounded
        b.controlSize = .small
        b.cell?.representedObject = payload
        return b
    }

    private func buttonRow(_ buttons: [NSView]) -> NSView {
        let r = NSStackView(views: buttons + [NSView()])
        r.orientation = .horizontal
        r.spacing = 6
        return r
    }

    private func writeField() -> NSView {
        let f = NSTextField()
        f.placeholderString = "⏎ 보내기 · Esc 취소"
        f.delegate = self
        DispatchQueue.main.async { [weak f] in f?.window?.makeFirstResponder(f) }
        return f
    }

    private func separator() -> NSView {
        let b = NSBox()
        b.boxType = .separator
        return b
    }
}

/// ⌘1·⌘2·⌘3 으로 탭을 바꾼다 (자판이 한글이어도 키 위치로)
private final class DashboardWindow: NSWindow {
    var onTab: ((Int) -> Void)?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let tabs: [UInt16: Int] = [18: 0, 19: 1, 20: 2]
        if event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command, let n = tabs[event.keyCode] {
            onTab?(n)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// 위에서부터 쌓이는 문서 뷰
private final class FlippedDoc: NSView {
    override var isFlipped: Bool { true }
}
