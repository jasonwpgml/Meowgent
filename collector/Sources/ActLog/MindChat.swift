import AppKit

/// 고양이와 이야기하는 창. 쓰던 앱의 포커스를 빼앗지 않는 떠 있는 패널(Spotlight 같은)이다.
/// 대화는 cat_mind 가 쓰는 mind/conversation.jsonl 을 그대로 보여 주고, 보낼 말은 MindBridge.send 로 mind/in 에 놓는다.
/// ⌃⌥M 짧게: 열기·닫기, 길게: 누르는 동안 말하기 (떼면 받아 적은 글을 1초 뒤 보낸다. 그 사이 글을 고치면 안 보낸다)
final class MindChat: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    private unowned let bridge: MindBridge
    private let voice = MindVoice()
    private var panel: ChatPanel!
    private let stack = NSStackView()
    private let scroll = NSScrollView()
    private let field = NSTextField()
    private let mic = NSButton()
    private let status = NSTextField(labelWithString: "")
    private let askBox = NSStackView()
    private var timer: Timer?
    private var shownStamp = ""
    private var pending: [(text: String, ts: Double)] = []
    private var autoSend: DispatchWorkItem?
    private var voiceSend = false          // 받아 적기가 끝나면 바로 보낼지 (단축키를 길게 눌렀을 때)
    private var note: String?              // 잠깐 보여 줄 상태 글
    private var previous: NSRunningApplication?   // 창을 열기 전 앞에 있던 앱 (닫으면 돌려준다)

    static let width: CGFloat = 380
    private static let bg = NSColor(srgbRed: 0.12, green: 0.10, blue: 0.09, alpha: 1)
    private static let cream = NSColor(srgbRed: 0.94, green: 0.89, blue: 0.80, alpha: 1)
    private static let catBubble = NSColor(srgbRed: 0.22, green: 0.19, blue: 0.17, alpha: 1)

    init(bridge: MindBridge) {
        self.bridge = bridge
        super.init()
        voice.onText = { [weak self] t in self?.field.stringValue = t }
        voice.onError = { [weak self] m in self?.flash(m) }
        voice.onFinish = { [weak self] t in self?.heard(t) }
    }

    var isVisible: Bool { panel?.isVisible == true }

    func toggle() { isVisible ? close() : show() }

    func show() {
        if panel == nil { build() }
        voice.hints = bridge.voiceHints
        reload(force: true)
        if !panel.isVisible, !panel.setFrameUsingName("MeowgentChat") {
            let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
            if let v = screen?.visibleFrame {
                panel.setFrameOrigin(NSPoint(x: v.maxX - panel.frame.width - 24, y: v.minY + 24))
            }
        }
        // 비활성 패널만으로는 단축키로 열었을 때 키보드가 안 넘어와 글이 뒤 앱으로 간다 → 앱을 앞으로 가져온다
        if !NSApp.isActive, let front = NSWorkspace.shared.frontmostApplication, front != .current { previous = front }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            Log.write("대화창 열림 (키 창: \(self.panel.isKeyWindow), 입력칸 포커스: \(self.panel.firstResponder === self.field.currentEditor()))")
        }
        timer?.invalidate()
        let t = Timer(timeInterval: 0.7, repeats: true) { [weak self] _ in self?.reload(force: false) }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func close() {
        voice.cancel()
        autoSend?.cancel()
        timer?.invalidate()
        timer = nil
        guard panel?.isVisible == true else { return }
        panel.orderOut(nil)
        previous?.activate()
        previous = nil
    }

    // MARK: 말하기

    /// 단축키를 길게 누르기 시작했을 때
    func startVoice(sendWhenDone: Bool) {
        show()
        autoSend?.cancel()
        voiceSend = sendWhenDone
        field.stringValue = ""
        voice.start()
        refreshStatus()
    }

    func stopVoice() {
        guard voice.listening else { return }
        voice.stop()
        refreshStatus()
    }

    @objc private func micPressed() {
        if voice.listening { stopVoice() } else { startVoice(sendWhenDone: false) }
    }

    private func heard(_ text: String?) {
        refreshStatus()
        guard let text, !text.isEmpty else {
            if text != nil { flash("못 알아들었다냥. 다시 말해 줘라냥.") }
            return
        }
        field.stringValue = text
        panel.makeFirstResponder(field)
        field.currentEditor()?.moveToEndOfDocument(nil)
        guard voiceSend else { return }
        let w = DispatchWorkItem { [weak self] in self?.send() }
        autoSend = w
        note = "1초 뒤 보낸다냥 (고치려면 글을 고쳐라냥)"
        refreshStatus()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: w)
    }

    func controlTextDidChange(_ obj: Notification) {
        if autoSend != nil { autoSend?.cancel(); autoSend = nil; note = nil; refreshStatus() }
    }

    @objc private func send() {
        autoSend = nil
        note = nil
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if voice.listening { voice.cancel() }
        bridge.send(text)
        pending.append((text, Date().timeIntervalSince1970))
        field.stringValue = ""
        reload(force: true)
    }

    @objc private func choose(_ sender: NSButton) {
        guard let o = sender.cell?.representedObject as? [String], o.count == 2 else { return }
        bridge.answer(askID: o[0], choice: o[1])
        reload(force: true)
    }

    // MARK: 화면

    private func flash(_ text: String) {
        note = text
        refreshStatus()
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            if self?.note == text { self?.note = nil; self?.refreshStatus() }
        }
    }

    private func refreshStatus() {
        mic.title = voice.listening ? "■" : "🎤"
        mic.toolTip = voice.listening ? "그만 듣기" : "말로 하기 (⌃⌥M 길게 눌러도 된다)"
        let s: String
        if voice.listening { s = "듣는 중… 다 말하면 ■ 또는 단축키를 떼라냥" }
        else if let note { s = note }
        else if !bridge.isAlive { s = "고양이 머리(cat_mind)가 안 돌고 있다냥 · brain/install.sh" }
        else if bridge.isThinking || !pending.isEmpty { s = "생각 중이다냥…" }
        else { s = "⏎ 보내기 · Esc 닫기 · ⌃⌥M 길게 눌러 말하기" }
        status.stringValue = s
    }

    /// 대화 기록이 바뀌었을 때만 다시 그린다
    private func reload(force: Bool) {
        let convo = bridge.conversation(limit: 40)
        pending.removeAll { p in convo.contains { $0.role == "user" && $0.text == p.text && $0.ts >= p.ts - 2 } || Date().timeIntervalSince1970 - p.ts > 30 }
        let ask = bridge.openAsk()
        let stamp = "\(convo.last?.ts ?? 0)|\(convo.count)|\(pending.count)|\(ask?.id ?? "")"
        refreshStatus()
        guard force || stamp != shownStamp else { return }
        shownStamp = stamp

        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if convo.isEmpty && pending.isEmpty {
            add(row(bubble("냥! 뭐든 말 걸어 봐라냥.", cat: true), cat: true))
        }
        var lastDay = ""
        let day = DateFormatter(); day.locale = Locale(identifier: "ko_KR"); day.dateFormat = "M월 d일 (E)"
        for m in convo {
            let d = day.string(from: Date(timeIntervalSince1970: m.ts))
            if d != lastDay { lastDay = d; add(dayLabel(d)) }
            add(row(bubble(m.text, cat: m.role == "cat"), cat: m.role == "cat"))
        }
        for p in pending {
            let b = bubble(p.text, cat: false); b.alphaValue = 0.6
            add(row(b, cat: false))
        }

        askBox.arrangedSubviews.forEach { $0.removeFromSuperview() }
        askBox.isHidden = ask == nil
        if let ask {
            let q = NSTextField(wrappingLabelWithString: "❓ " + ask.text)
            q.textColor = Self.cream; q.font = .systemFont(ofSize: 12, weight: .medium)
            askBox.addArrangedSubview(q)
            let buttons = NSStackView(); buttons.orientation = .horizontal; buttons.spacing = 6
            for c in ask.choices.prefix(4) {
                let b = NSButton(title: c, target: self, action: #selector(choose(_:)))
                b.bezelStyle = .rounded; b.controlSize = .small
                b.cell?.representedObject = [ask.id, c]
                buttons.addArrangedSubview(b)
            }
            askBox.addArrangedSubview(buttons)
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, let doc = self.scroll.documentView else { return }
            doc.layoutSubtreeIfNeeded()
            doc.scroll(NSPoint(x: 0, y: max(0, doc.frame.height - self.scroll.contentView.bounds.height)))
        }
    }

    /// 줄 하나를 대화 폭 가득 붙인다 (말풍선은 줄 안에서 왼쪽·오른쪽으로 붙는다)
    private func add(_ v: NSView) {
        stack.addArrangedSubview(v)
        v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -(stack.edgeInsets.left + stack.edgeInsets.right)).isActive = true
    }

    private func bubble(_ text: String, cat: Bool) -> NSView {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 13)
        label.textColor = cat ? Self.cream : NSColor(srgbRed: 0.15, green: 0.12, blue: 0.10, alpha: 1)
        label.isSelectable = true
        label.preferredMaxLayoutWidth = Self.width - 110
        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = (cat ? Self.catBubble : Self.cream).cgColor
        box.layer?.cornerRadius = 10
        label.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: box.topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -6),
            box.widthAnchor.constraint(lessThanOrEqualToConstant: Self.width - 90),
        ])
        return box
    }

    private func row(_ v: NSView, cat: Bool) -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let r = NSStackView(views: cat ? [v, spacer] : [spacer, v])
        r.orientation = .horizontal
        r.alignment = .top
        return r
    }

    private func dayLabel(_ text: String) -> NSView {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 10)
        l.textColor = Self.cream.withAlphaComponent(0.45)
        l.alignment = .center
        return l
    }

    private func build() {
        panel = ChatPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 460),
                          styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .fullSizeContentView],
                          backing: .buffered, defer: false)
        panel.title = "고양이"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = Self.bg
        panel.isOpaque = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.minSize = NSSize(width: 300, height: 260)
        panel.delegate = self
        panel.onEscape = { [weak self] in self?.close() }
        panel.setFrameAutosaveName("MeowgentChat")

        let title = NSTextField(labelWithString: "🐈‍⬛ 고양이와 이야기")
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = Self.cream

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        scroll.documentView = doc
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        askBox.orientation = .vertical
        askBox.alignment = .leading
        askBox.spacing = 4
        askBox.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 0, right: 12)

        field.placeholderString = "말 걸어 봐라냥"
        field.font = .systemFont(ofSize: 13)
        field.delegate = self
        field.target = self
        field.action = #selector(send)
        field.focusRingType = .none
        field.bezelStyle = .roundedBezel
        mic.title = "🎤"
        mic.bezelStyle = .rounded
        mic.target = self
        mic.action = #selector(micPressed)
        let input = NSStackView(views: [field, mic])
        input.orientation = .horizontal
        input.spacing = 6
        input.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)

        status.font = .systemFont(ofSize: 10)
        status.textColor = Self.cream.withAlphaComponent(0.55)
        status.lineBreakMode = .byTruncatingTail

        let header = NSStackView(views: [title])
        header.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
        let statusRow = NSStackView(views: [status])
        statusRow.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 10, right: 14)
        let root = NSStackView(views: [header, scroll, askBox, input, statusRow])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 6
        root.edgeInsets = NSEdgeInsets(top: 30, left: 0, bottom: 0, right: 0)
        root.translatesAutoresizingMaskIntoConstraints = false
        let content = panel.contentView!
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: root.widthAnchor),
            askBox.widthAnchor.constraint(equalTo: root.widthAnchor),
            input.widthAnchor.constraint(equalTo: root.widthAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
        ])
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        scroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    }

    func windowWillClose(_ notification: Notification) { close() }
}

/// 앱을 앞으로 가져오지 않고도 글자를 입력받는 패널
private final class ChatPanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

/// 위에서부터 쌓이는 문서 뷰 (스크롤 맨 아래 = 최신)
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
