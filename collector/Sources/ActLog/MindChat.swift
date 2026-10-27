import AppKit

/// 고양이와 이야기하는 창. 창 테두리 없이 둥근 유리판 하나만 떠 있다 (macOS 26: Liquid Glass, 그 전: HUD 재질).
/// 대화는 cat_mind 가 쓰는 mind/conversation.jsonl 을 그대로 보여 주고, 보낼 말은 MindBridge.send 로 mind/in 에 놓는다.
/// ⌃⌥M 짧게: 열기·닫기, 길게: 누르는 동안 말하기 (떼면 받아 적은 글을 1초 뒤 보낸다. 그 사이 글을 고치면 안 보낸다)
/// 유리 진하기·말풍선 진하기·유리 종류는 ⚙︎ 에서 바꾸고 UserDefaults 에 남는다.
final class MindChat: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    private unowned let bridge: MindBridge
    private let voice = MindVoice()
    private var panel: ChatPanel!
    private var glass: NSView!                 // NSGlassEffectView 또는 NSVisualEffectView
    private let tintLayer = NSView()           // macOS 26 전: 유리 위 어두운 층
    private let stack = NSStackView()
    private let scroll = NSScrollView()
    private let field = NSTextField()
    private let inputBox = NSView()
    private let mic = CircleButton()
    private let sendButton = CircleButton()
    private let name = NSTextField(labelWithString: "냥이")
    private let status = NSTextField(labelWithString: "")
    private let askBox = NSStackView()
    private var popover: NSPopover?
    private var timer: Timer?
    private var shownStamp = ""
    private var pending: [(text: String, ts: Double)] = []
    private var autoSend: DispatchWorkItem?
    private var voiceSend = false          // 받아 적기가 끝나면 바로 보낼지 (단축키를 길게 눌렀을 때)
    private var note: String?              // 잠깐 보여 줄 상태 글
    private var previous: NSRunningApplication?   // 창을 열기 전 앞에 있던 앱 (닫으면 돌려준다)

    static let width: CGFloat = 360
    static let radius: CGFloat = 22
    private static let cream = NSColor(srgbRed: 0.95, green: 0.92, blue: 0.85, alpha: 1)
    private static let ink = NSColor(srgbRed: 0.10, green: 0.08, blue: 0.07, alpha: 1)
    private static let dim = NSColor(srgbRed: 0.09, green: 0.07, blue: 0.06, alpha: 1)

    // MARK: 설정 (⚙︎)

    /// 유리에 입히는 어두운 색 0~0.75. 맑은 유리는 뒤가 밝으면 글자가 안 보여 어둡게 깐다 (Apple 권장)
    private var tint: Double {
        get { UserDefaults.standard.object(forKey: "chatGlassTint") as? Double ?? 0.35 }
        set { UserDefaults.standard.set(newValue, forKey: "chatGlassTint") }
    }
    /// 말풍선 진하기 0.2~1
    private var bubbleAlpha: Double {
        get { UserDefaults.standard.object(forKey: "chatBubble") as? Double ?? 0.7 }
        set { UserDefaults.standard.set(newValue, forKey: "chatBubble") }
    }
    /// 0 맑게(clear), 1 보통(regular)
    private var glassStyle: Int {
        get { UserDefaults.standard.integer(forKey: "chatGlassStyle") }
        set { UserDefaults.standard.set(newValue, forKey: "chatGlassStyle") }
    }

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
        timer?.invalidate()
        let t = Timer(timeInterval: 0.7, repeats: true) { [weak self] _ in self?.reload(force: false) }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func close() {
        voice.cancel()
        autoSend?.cancel()
        popover?.close()
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
        if autoSend != nil { autoSend?.cancel(); autoSend = nil; note = nil }
        refreshStatus()
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

    // MARK: 상태

    private func flash(_ text: String) {
        note = text
        refreshStatus()
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            if self?.note == text { self?.note = nil; self?.refreshStatus() }
        }
    }

    private func refreshStatus() {
        mic.symbol = voice.listening ? "stop.fill" : "mic.fill"
        mic.fill = voice.listening ? NSColor(srgbRed: 0.90, green: 0.36, blue: 0.30, alpha: 0.95) : NSColor.white.withAlphaComponent(0.16)
        mic.pulsing = voice.listening
        mic.toolTip = voice.listening ? "그만 듣기" : "말로 하기 (\(MindBridge.hotKeyName) 길게 눌러도 된다)"
        sendButton.alphaValue = field.stringValue.trimmingCharacters(in: .whitespaces).isEmpty ? 0.35 : 1
        let s: String
        if voice.listening { s = "듣는 중… 다 말하면 ■ 또는 단축키를 떼라냥" }
        else if let note { s = note }
        else if !bridge.isAlive { s = "고양이 머리(cat_mind)가 안 돌고 있다냥" }
        else if bridge.isThinking || !pending.isEmpty { s = "생각 중이다냥 ···" }
        else { s = bridge.quotaLine ?? "곁에 있다냥" }
        status.stringValue = s
    }

    // MARK: 대화

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
                if #available(macOS 26, *) { b.bezelStyle = .glass } else { b.bezelStyle = .rounded }
                b.controlSize = .small
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

    /// 고양이 말풍선은 옅은 유리, 내 말풍선은 크림색. 진하기에 따라 글자 색을 바꿔 늘 읽히게 한다
    private func bubble(_ text: String, cat: Bool) -> NSView {
        let b = bubbleAlpha
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 13)
        label.textColor = cat || b < 0.5 ? Self.cream : Self.ink
        label.isSelectable = true
        label.preferredMaxLayoutWidth = Self.width - 110
        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = (cat ? NSColor.white.withAlphaComponent(0.08 + b * 0.14) : Self.cream.withAlphaComponent(b)).cgColor
        box.layer?.borderColor = NSColor.white.withAlphaComponent(cat ? 0.14 : 0.2).cgColor
        box.layer?.borderWidth = 0.5
        box.layer?.cornerRadius = 14
        box.layer?.cornerCurve = .continuous
        label.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 11),
            label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -11),
            label.topAnchor.constraint(equalTo: box.topAnchor, constant: 7),
            label.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -7),
            box.widthAnchor.constraint(lessThanOrEqualToConstant: Self.width - 80),
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
        l.textColor = Self.cream.withAlphaComponent(0.5)
        l.alignment = .center
        return l
    }

    // MARK: 유리

    /// 진하기·종류를 지금 값으로 칠한다 (슬라이더를 움직일 때마다)
    private func applyLook() {
        let t = tint
        if #available(macOS 26, *), let g = glass as? NSGlassEffectView {
            g.style = glassStyle == 1 ? .regular : .clear
            g.tintColor = Self.dim.withAlphaComponent(t)
        } else {
            tintLayer.layer?.backgroundColor = Self.dim.withAlphaComponent(t).cgColor
        }
        inputBox.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06 + t * 0.08).cgColor
    }

    @objc private func showSettings(_ sender: NSButton) {
        if let p = popover, p.isShown { p.close(); return }
        let tintSlider = NSSlider(value: tint, minValue: 0, maxValue: 0.75, target: self, action: #selector(tintChanged(_:)))
        let bubbleSlider = NSSlider(value: bubbleAlpha, minValue: 0.2, maxValue: 1, target: self, action: #selector(bubbleChanged(_:)))
        [tintSlider, bubbleSlider].forEach { $0.isContinuous = true; $0.widthAnchor.constraint(equalToConstant: 160).isActive = true }
        let style = NSSegmentedControl(labels: ["맑게", "보통"], trackingMode: .selectOne, target: self, action: #selector(styleChanged(_:)))
        style.selectedSegment = glassStyle
        func line(_ title: String, _ control: NSView) -> NSView {
            let l = NSTextField(labelWithString: title); l.font = .systemFont(ofSize: 12)
            l.widthAnchor.constraint(equalToConstant: 76).isActive = true
            let r = NSStackView(views: [l, control]); r.orientation = .horizontal; r.spacing = 8
            return r
        }
        let v = NSStackView(views: [line("유리 진하기", tintSlider), line("말풍선 진하기", bubbleSlider), line("유리 종류", style)])
        v.orientation = .vertical
        v.alignment = .leading
        v.spacing = 10
        v.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        let vc = NSViewController()
        vc.view = v
        let p = NSPopover()
        p.contentViewController = vc
        p.behavior = .transient
        p.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
        popover = p
    }

    @objc private func tintChanged(_ s: NSSlider) { tint = s.doubleValue; applyLook() }
    @objc private func bubbleChanged(_ s: NSSlider) { bubbleAlpha = s.doubleValue; reload(force: true) }
    @objc private func styleChanged(_ s: NSSegmentedControl) { glassStyle = s.selectedSegment; applyLook() }
    @objc private func closePressed() { close() }

    // MARK: 만들기

    private func build() {
        panel = ChatPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 480),
                          styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.minSize = NSSize(width: 300, height: 280)
        panel.delegate = self
        panel.onEscape = { [weak self] in self?.close() }
        panel.setFrameAutosaveName("MeowgentChat")

        let root = buildContent()
        if #available(macOS 26, *) {
            let g = NSGlassEffectView()
            g.cornerRadius = Self.radius
            g.contentView = root
            glass = g
        } else {
            let v = NSVisualEffectView()
            v.material = .hudWindow
            v.blendingMode = .behindWindow
            v.state = .active
            v.maskImage = Self.roundedMask(Self.radius)
            tintLayer.wantsLayer = true
            for sub in [tintLayer, root] {
                sub.translatesAutoresizingMaskIntoConstraints = false
                v.addSubview(sub)
                NSLayoutConstraint.activate([
                    sub.leadingAnchor.constraint(equalTo: v.leadingAnchor), sub.trailingAnchor.constraint(equalTo: v.trailingAnchor),
                    sub.topAnchor.constraint(equalTo: v.topAnchor), sub.bottomAnchor.constraint(equalTo: v.bottomAnchor),
                ])
            }
            glass = v
        }
        panel.contentView = glass
        applyLook()
    }

    private func buildContent() -> NSView {
        // 머리: 도트 고양이 얼굴 · 이름(갈무리) · 상태 한 줄 · ⚙︎ · ×
        let face = NSImageView(image: Self.catFace())
        face.imageScaling = .scaleNone
        Self.registerPixelFont()
        name.font = NSFont(name: "Galmuri11-Bold", size: 13) ?? NSFont(name: "Galmuri11", size: 13) ?? .systemFont(ofSize: 13, weight: .semibold)
        name.textColor = Self.cream
        status.font = .systemFont(ofSize: 11)
        status.textColor = Self.cream.withAlphaComponent(0.62)
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let titles = NSStackView(views: [name, status])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 1
        let gear = Self.iconButton("slider.horizontal.3", "유리·말풍선 진하기", self, #selector(showSettings(_:)))
        let xb = Self.iconButton("xmark", "닫기 (Esc)", self, #selector(closePressed))
        let header = DragStack(views: [face, titles, NSView(), gear, xb])
        header.orientation = .horizontal
        header.spacing = 8
        header.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 6, right: 12)

        // 대화
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 14, bottom: 8, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        scroll.documentView = doc
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        askBox.orientation = .vertical
        askBox.alignment = .leading
        askBox.spacing = 4
        askBox.edgeInsets = NSEdgeInsets(top: 4, left: 16, bottom: 0, right: 16)

        // 입력: 알약 모양 칸 안에 글 · 🎤 · 보내기
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.textColor = Self.cream
        field.placeholderAttributedString = NSAttributedString(string: "말 걸어 봐라냥 · \(MindBridge.hotKeyName) 길게 = 말하기", attributes: [
            .foregroundColor: Self.cream.withAlphaComponent(0.45), .font: NSFont.systemFont(ofSize: 13)])
        field.delegate = self
        field.target = self
        field.action = #selector(send)
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        mic.target = self
        mic.action = #selector(micPressed)
        mic.tint = Self.cream
        sendButton.symbol = "arrow.up"
        sendButton.fill = Self.cream
        sendButton.tint = Self.ink
        sendButton.target = self
        sendButton.action = #selector(send)
        sendButton.toolTip = "보내기 (⏎)"
        let inputRow = NSStackView(views: [field, mic, sendButton])
        inputRow.orientation = .horizontal
        inputRow.spacing = 6
        inputRow.edgeInsets = NSEdgeInsets(top: 5, left: 14, bottom: 5, right: 5)
        inputRow.translatesAutoresizingMaskIntoConstraints = false
        inputBox.wantsLayer = true
        inputBox.layer?.cornerRadius = 19
        inputBox.layer?.cornerCurve = .continuous
        inputBox.layer?.borderWidth = 0.5
        inputBox.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        inputBox.addSubview(inputRow)
        let inputWrap = NSStackView(views: [inputBox])
        inputWrap.edgeInsets = NSEdgeInsets(top: 4, left: 12, bottom: 14, right: 12)

        let root = NSStackView(views: [header, scroll, askBox, inputWrap])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 4
        root.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            header.widthAnchor.constraint(equalTo: root.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: root.widthAnchor),
            askBox.widthAnchor.constraint(equalTo: root.widthAnchor),
            inputWrap.widthAnchor.constraint(equalTo: root.widthAnchor),
            inputRow.leadingAnchor.constraint(equalTo: inputBox.leadingAnchor),
            inputRow.trailingAnchor.constraint(equalTo: inputBox.trailingAnchor),
            inputRow.topAnchor.constraint(equalTo: inputBox.topAnchor),
            inputRow.bottomAnchor.constraint(equalTo: inputBox.bottomAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
        ])
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        scroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return root
    }

    func windowWillClose(_ notification: Notification) { close() }

    // MARK: 그림 조각

    private static func iconButton(_ symbol: String, _ tip: String, _ target: AnyObject, _ action: Selector) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage(), target: target, action: action)
        b.isBordered = false
        b.contentTintColor = cream.withAlphaComponent(0.75)
        b.toolTip = tip
        b.symbolConfiguration = .init(pointSize: 13, weight: .medium)
        return b
    }

    /// 머리의 도트 고양이 얼굴 (11×11 칸, 2배): 귀·검은 얼굴·노란 눈
    private static func catFace() -> NSImage {
        let px: CGFloat = 2
        return NSImage(size: NSSize(width: 11 * px, height: 11 * px), flipped: true) { _ in
            func fill(_ c: NSColor, _ cells: [(Int, Int, Int, Int)]) {
                c.setFill()
                for (x, y, w, h) in cells { NSRect(x: CGFloat(x) * px, y: CGFloat(y) * px, width: CGFloat(w) * px, height: CGFloat(h) * px).fill() }
            }
            fill(cream, [(1, 1, 2, 1), (8, 1, 2, 1), (1, 2, 9, 6), (2, 8, 7, 2)])
            fill(ink, [(2, 3, 7, 4)])
            fill(NSColor(srgbRed: 0.95, green: 0.76, blue: 0.31, alpha: 1), [(3, 4, 1, 1), (7, 4, 1, 1)])
            return true
        }
    }

    /// 앱에 들어 있는 갈무리11 (Resources/fonts) 을 등록한다. 고양이 말풍선이 먼저 등록했으면 그대로 쓴다
    private static func registerPixelFont() {
        guard NSFont(name: "Galmuri11", size: 12) == nil, let dir = Bundle.main.resourceURL?.appendingPathComponent("fonts") else { return }
        for f in ["Galmuri11.ttf", "Galmuri11-Bold.ttf"] {
            CTFontManagerRegisterFontsForURL(dir.appendingPathComponent(f) as CFURL, .process, nil)
        }
    }

    private static func roundedMask(_ r: CGFloat) -> NSImage {
        let size = NSSize(width: r * 2 + 1, height: r * 2 + 1)
        let img = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        img.resizingMode = .stretch
        return img
    }
}

/// 앱을 앞으로 가져오지 않고도 글자를 입력받는 테두리 없는 패널
private final class ChatPanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

/// 위에서부터 쌓이는 문서 뷰 (스크롤 맨 아래 = 최신)
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// 머리 부분을 잡고 창을 옮긴다 (테두리 없는 창)
private final class DragStack: NSStackView {
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}

/// 동그란 버튼 (🎤 · 보내기). 듣는 동안은 숨 쉬듯 깜빡인다
private final class CircleButton: NSButton {
    var symbol = "mic.fill" { didSet { if symbol != oldValue { update() } } }
    var fill: NSColor = .clear { didSet { layer?.backgroundColor = fill.cgColor } }
    var tint: NSColor = .white { didSet { contentTintColor = tint } }
    var pulsing = false {
        didSet {
            guard pulsing != oldValue else { return }
            if pulsing {
                let a = CABasicAnimation(keyPath: "opacity")
                a.fromValue = 1; a.toValue = 0.55; a.duration = 0.7
                a.autoreverses = true; a.repeatCount = .infinity
                layer?.add(a, forKey: "pulse")
            } else {
                layer?.removeAnimation(forKey: "pulse")
            }
        }
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 14
        imagePosition = .imageOnly
        symbolConfiguration = .init(pointSize: 12, weight: .semibold)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 28).isActive = true
        heightAnchor.constraint(equalToConstant: 28).isActive = true
        update()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func update() { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
}
