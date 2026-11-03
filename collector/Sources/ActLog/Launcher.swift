import AppKit
import Carbon

/// 단축키로 여는 런처 (Raycast 비슷한 것). 앱 찾아 열기 · 계산기 · 창 배치 · 주소 열기 · 웹 검색.
/// Tab 이나 ⌃⌘V 로 클립보드 기록(ClipHistory, 따로 켜는 기능)을 찾아 붙여넣는다. 클립보드 모드는 오른쪽에 미리보기가 붙는다.
/// 검색 점수·계산·창 틀 계산은 LauncherRules, 기록 종류·보관은 ClipRules.
/// 자주 연 앱 순위(launcher.json)는 활동 기록을 켠 동안만 디스크에 남긴다.
final class Launcher: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    enum Mode { case search, clipboard }

    struct Item {
        enum Action {
            case app(URL), calc(String), layout(LauncherRules.Layout), clip(ClipHistory.Entry), open(URL), web(String), enableClips
        }
        let title: String
        let subtitle: String
        let icon: NSImage?
        let tag: String
        let action: Action
    }

    private struct Usage: Codable { var n: Int; var t: Double }

    let clips: ClipHistory
    /// 자주 연 앱 순위를 디스크에 남겨도 되나 (활동 기록이 켜져 있나)
    var canPersist: () -> Bool = { false }
    /// 창을 닫은 뒤 알려 줄 말 (고양이 말풍선)
    var notify: ((String) -> Void)?

    private let apps = AppIndex()
    private let usageURL: URL
    private var usage: [String: Usage] = [:]
    private var icons: [String: NSImage] = [:]
    private var panel: LauncherPanel!
    private let field = NSTextField()
    private let list = NSStackView()
    private let preview = PreviewPane()
    private let filter = NSSegmentedControl(labels: Launcher.filters.map { $0.title }, trackingMode: .selectOne, target: nil, action: nil)
    private let footer = NSTextField(labelWithString: "")
    private var listWidth: NSLayoutConstraint!
    private var rows: [LauncherRow] = []
    private var items: [Item] = []
    private var selected = 0
    private var mode = Mode.search
    private var previous: NSRunningApplication?   // 런처를 열기 전 앞에 있던 앱 (붙여넣기·창 배치 대상)
    private var hotKey: HotKey?
    private var clipKey: HotKey?

    static let searchWidth: CGFloat = 620
    static let clipListWidth: CGFloat = 470
    static let previewWidth: CGFloat = 370
    static let rowHeight: CGFloat = 44
    static let maxRows = 8
    static let clipRows = 9            // ⌘1~9
    static let radius: CGFloat = 20
    private static let filters: [(title: String, kind: ClipRules.Kind?)] =
        [("전체", nil), ("글", .text), ("링크", .link), ("이미지", .image), ("파일", .file), ("색", .color)]
    fileprivate static let cream = NSColor(srgbRed: 0.95, green: 0.92, blue: 0.85, alpha: 1)
    private static let dim = NSColor(srgbRed: 0.09, green: 0.07, blue: 0.06, alpha: 1)

    /// ⌘Space 로 열지 (Spotlight·Raycast 단축키를 꺼야 잡힌다). 기본은 ⌘⇧Space
    private var useCmdSpace: Bool {
        get { UserDefaults.standard.bool(forKey: "launcherCmdSpace") }
        set { UserDefaults.standard.set(newValue, forKey: "launcherCmdSpace") }
    }
    var hotKeyName: String { useCmdSpace ? "⌘Space" : "⌘⇧Space" }
    static let clipKeyName = "⌃⌘V"

    init(dataDir: URL) {
        clips = ClipHistory(dataDir: dataDir)
        usageURL = dataDir.appendingPathComponent("launcher.json")
        super.init()
        if let d = try? Data(contentsOf: usageURL), let u = try? JSONDecoder().decode([String: Usage].self, from: d) { usage = u }
        apps.onChange = { [weak self] in if self?.panel?.isVisible == true && self?.mode == .search { self?.refresh() } }
    }

    func start() {
        registerHotKeys()
        clips.start()
        apps.refreshIfStale()
    }

    private func registerHotKeys() {
        hotKey = nil
        let space = 49, v = 9   // kVK_Space, kVK_ANSI_V
        hotKey = HotKey(keyCode: space, modifiers: cmdKey | (useCmdSpace ? 0 : shiftKey))
        if hotKey == nil && useCmdSpace {
            useCmdSpace = false
            hotKey = HotKey(keyCode: space, modifiers: cmdKey | shiftKey)
            notify?("⌘Space 는 다른 앱이 쓰고 있다냥. 런처는 ⌘⇧Space 로 열어라냥")
        }
        hotKey?.onDown = { [weak self] in self?.toggle(.search) }
        if clipKey == nil {
            clipKey = HotKey(keyCode: v, modifiers: controlKey | cmdKey)
            clipKey?.onDown = { [weak self] in self?.toggle(.clipboard) }
        }
    }

    /// 활동 기록을 끄면 디스크의 순위 파일을 지운다 (이번 실행 동안은 메모리에만 둔다)
    func recordingOff() {
        try? FileManager.default.removeItem(at: usageURL)
    }

    // MARK: 열고 닫기

    var isVisible: Bool { panel?.isVisible == true }

    func toggle(_ m: Mode) {
        if isVisible && mode == m { close(reactivate: true) } else { show(m) }
    }

    func show(_ m: Mode) {
        if panel == nil { build() }
        let wasVisible = panel.isVisible
        mode = m
        field.stringValue = ""
        if !NSApp.isActive, let front = NSWorkspace.shared.frontmostApplication, front != .current { previous = front }
        apps.refreshIfStale()
        refresh()
        if !wasVisible { position() }
        // 비활성 패널은 키보드를 못 받으니 앱을 앞으로 가져온다 (MindChat 과 같은 이유)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    func close(reactivate: Bool) {
        guard panel?.isVisible == true else { return }
        panel.orderOut(nil)
        if reactivate { previous?.activate() }
        previous = nil
    }

    func windowDidResignKey(_ notification: Notification) { close(reactivate: false) }

    /// 마우스가 있는 화면의 가운데 위쪽
    private func position() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let v = screen?.visibleFrame else { return }
        let top = v.maxY - v.height * 0.18
        let f = panel.frame
        panel.setFrame(NSRect(x: (v.midX - f.width / 2).rounded(), y: top - f.height, width: f.width, height: f.height), display: false)
    }

    // MARK: 검색

    private func refresh(keep: Int = 0) {
        let q = field.stringValue.trimmingCharacters(in: .whitespaces)
        items = mode == .search ? searchItems(q) : clipItems(q)
        let placeholder = mode == .search ? "앱 · 계산식 · 창 배치(왼쪽·최대화…) · 주소" : "클립보드 기록에서 찾기 (이미지 속 글자도)"
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .foregroundColor: Self.cream.withAlphaComponent(0.4), .font: NSFont.systemFont(ofSize: 20, weight: .light)])
        footer.stringValue = mode == .search
            ? "⏎ 열기 · ↑↓ 고르기 · Tab 클립보드 기록 · Esc 닫기"
            : "⏎ 붙여넣기 · ⇧⏎ 서식 없이 · ⌘⏎ 복사만 · ⌘1–9 바로 · ⌘P 고정 · ⌘⌫ 지우기 · ⌘[ ] 종류 · Tab 검색"
        filter.isHidden = mode == .search || !clips.enabled
        rebuildRows(select: min(keep, max(items.count - 1, 0)))
    }

    private func searchItems(_ q: String) -> [Item] {
        let now = Date().timeIntervalSince1970
        if q.isEmpty {
            // 빈 칸이면 자주 연 앱부터
            return apps.all.compactMap { a -> (AppIndex.App, Double)? in
                guard let u = usage[a.url.path] else { return nil }
                return (a, LauncherRules.frecency(count: u.n, lastUsed: u.t, now: now))
            }
            .sorted { $0.1 > $1.1 }.prefix(Self.maxRows).map { appItem($0.0) }
        }
        var out: [Item] = []
        if let v = LauncherRules.calculate(q) {
            let s = LauncherRules.format(v)
            out.append(Item(title: "= " + s, subtitle: q, icon: symbol("equal.circle.fill"), tag: "⏎ 복사", action: .calc(s)))
        }
        var scored: [(Item, Double)] = apps.all.compactMap { a in
            guard let s = [LauncherRules.score(a.name, q), LauncherRules.score(a.file, q)].compactMap({ $0 }).max() else { return nil }
            let u = usage[a.url.path]
            return (appItem(a), s + LauncherRules.frecency(count: u?.n ?? 0, lastUsed: u?.t ?? 0, now: now))
        }
        if previous != nil {
            for l in LauncherRules.Layout.allCases {
                guard let s = (l.keywords + [l.title]).compactMap({ LauncherRules.score($0, q) }).max(), s >= 60 else { continue }
                scored.append((Item(title: l.title, subtitle: "\(previous?.localizedName ?? "앞 앱") 창", icon: symbol(Self.layoutSymbol(l)),
                                    tag: "창", action: .layout(l)), s))
            }
        }
        out += scored.sorted { $0.1 > $1.1 }.prefix(Self.maxRows).map(\.0)
        if let u = Self.addressURL(q) {
            out.append(Item(title: u.absoluteString, subtitle: "브라우저로 열기", icon: symbol("link"), tag: "주소", action: .open(u)))
        }
        out.append(Item(title: "‘\(q)’ 구글에서 찾기", subtitle: "웹 검색", icon: symbol("magnifyingglass"), tag: "웹", action: .web(q)))
        return Array(out.prefix(Self.maxRows))
    }

    private func clipItems(_ q: String) -> [Item] {
        guard clips.enabled else {
            return [Item(title: "클립보드 기록 켜기", subtitle: "복사한 글·이미지·파일을 이 맥에만 암호화해서 남긴다 (비밀번호·키 같은 건 빼고)",
                         icon: symbol("doc.on.clipboard"), tag: "⏎", action: .enableClips)]
        }
        let kind = Self.filters[max(0, filter.selectedSegment)].kind
        let rel = RelativeDateTimeFormatter()
        rel.locale = Locale(identifier: "ko_KR")
        rel.unitsStyle = .short
        let shown = clips.entries
            .filter { kind == nil || $0.kind == kind }
            .filter { ClipRules.matches(q, in: [$0.text, $0.ocr ?? "", $0.app ?? ""] + $0.paths.map { ($0 as NSString).lastPathComponent }) }
            .sorted { ($0.pinned ? 1 : 0, $0.ts) > ($1.pinned ? 1 : 0, $1.ts) }
            .prefix(Self.clipRows)
        return shown.enumerated().map { n, e in
            let when = rel.localizedString(for: Date(timeIntervalSince1970: e.ts), relativeTo: Date())
            let size: String
            switch e.kind {
            case .image: size = "\(e.width ?? 0)×\(e.height ?? 0) · \(ByteCountFormatter.string(fromByteCount: Int64(e.bytes ?? 0), countStyle: .file))"
            case .file: size = "\(e.paths.count)개"
            default: size = "\(e.text.count)자"
            }
            let sub = [e.kind.title, e.app, when, size].compactMap { $0 }.joined(separator: " · ")
            return Item(title: (e.pinned ? "📌 " : "") + Self.clipTitle(e), subtitle: sub, icon: clipIcon(e), tag: "⌘\(n + 1)", action: .clip(e))
        }
    }

    private static func clipTitle(_ e: ClipHistory.Entry) -> String {
        func firstLine(_ s: String) -> String {
            let line = s.split(whereSeparator: \.isNewline).first.map(String.init) ?? s
            return String(line.trimmingCharacters(in: .whitespaces).prefix(90))
        }
        switch e.kind {
        case .image: return e.ocr.map { "🖼 " + firstLine($0) } ?? "이미지"
        case .file: return e.paths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
        default: return firstLine(e.text)
        }
    }

    private func clipIcon(_ e: ClipHistory.Entry) -> NSImage? {
        switch e.kind {
        case .text: return symbol("text.alignleft")
        case .link: return symbol("link")
        case .color: return Self.swatch(e.text, size: 22)
        case .image: return clips.thumbnail(e) ?? symbol("photo")
        case .file:
            guard let p = e.paths.first else { return symbol("doc") }
            let i = NSWorkspace.shared.icon(forFile: p)
            i.size = NSSize(width: 28, height: 28)
            return i
        }
    }

    fileprivate static func swatch(_ text: String, size: CGFloat) -> NSImage? {
        guard let c = ClipRules.color(text) else { return nil }
        let color = NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
            color.setFill()
            NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), xRadius: size / 4, yRadius: size / 4).fill()
            NSColor.white.withAlphaComponent(0.3).setStroke()
            NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), xRadius: size / 4, yRadius: size / 4).stroke()
            return true
        }
    }

    private func appItem(_ a: AppIndex.App) -> Item {
        let icon = icons[a.url.path] ?? {
            let i = NSWorkspace.shared.icon(forFile: a.url.path)
            i.size = NSSize(width: 28, height: 28)
            icons[a.url.path] = i
            return i
        }()
        let sub = a.name == a.file ? a.url.deletingLastPathComponent().path : a.file
        return Item(title: a.name, subtitle: sub, icon: icon, tag: "앱", action: .app(a.url))
    }

    private func symbol(_ name: String) -> NSImage? {
        let i = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 18, weight: .regular))
        i?.isTemplate = true
        return i
    }

    private static func layoutSymbol(_ l: LauncherRules.Layout) -> String {
        switch l {
        case .left: "rectangle.lefthalf.filled"
        case .right: "rectangle.righthalf.filled"
        case .top: "rectangle.tophalf.filled"
        case .bottom: "rectangle.bottomhalf.filled"
        case .maximize: "rectangle.fill"
        case .center: "rectangle.center.inset.filled"
        }
    }

    /// 주소처럼 보이면 (example.com, https://…) 열 주소
    static func addressURL(_ q: String) -> URL? {
        guard !q.contains(" "), q.range(of: #"^(https?://)?[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+(:\d+)?(/\S*)?$"#, options: .regularExpression) != nil,
              q.range(of: #"^[\d.]+$"#, options: .regularExpression) == nil else { return nil }
        return URL(string: q.hasPrefix("http") ? q : "https://" + q)
    }

    // MARK: 실행

    /// plain: 서식 없이 붙여넣기 · copyOnly: 붙여넣지 않고 클립보드에만
    private func run(_ item: Item, plain: Bool = false, copyOnly: Bool = false) {
        let target = previous
        switch item.action {
        case .app(let url):
            remember(url)
            close(reactivate: false)
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        case .calc(let s):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(s, forType: .string)
            close(reactivate: true)
        case .layout(let l):
            close(reactivate: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                if let err = WindowMover.apply(l, to: target) { self?.notify?(err) }
            }
        case .clip(let e):
            let ok = clips.put(e, plain: plain)
            close(reactivate: true)
            guard ok else { notify?("그 기록을 못 꺼냈다냥 (파일이 지워졌을 수 있다냥)"); return }
            guard !copyOnly else { return }
            guard AXIsProcessTrusted() else {
                notify?("복사해 뒀다냥. ⌘V 로 붙여넣어라냥 (바로 붙여넣으려면 손쉬운 사용 권한이 필요하다냥)")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { Self.pasteKeystroke() }
        case .open(let url):
            close(reactivate: false)
            NSWorkspace.shared.open(url)
        case .web(let q):
            close(reactivate: false)
            var c = URLComponents(string: "https://www.google.com/search")!
            c.queryItems = [URLQueryItem(name: "q", value: q)]
            if let u = c.url { NSWorkspace.shared.open(u) }
        case .enableClips:
            if confirmClips() { clips.setEnabled(true) }
            show(.clipboard)
        }
    }

    /// 앞 앱에 ⌘V 를 보낸다 (손쉬운 사용 권한 필요). 자판이 한글이어도 키 위치(V)로 간다
    private static func pasteKeystroke() {
        let src = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: down)
            e?.flags = .maskCommand
            e?.post(tap: .cghidEventTap)
        }
    }

    private func remember(_ url: URL) {
        var u = usage[url.path] ?? Usage(n: 0, t: 0)
        u.n += 1
        u.t = Date().timeIntervalSince1970
        usage[url.path] = u
        guard canPersist(), let d = try? JSONEncoder().encode(usage) else { return }
        try? d.write(to: usageURL, options: .atomic)
    }

    // MARK: 키보드

    func controlTextDidChange(_ obj: Notification) { refresh() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)): select(selected + 1)
        case #selector(NSResponder.moveUp(_:)): select(selected - 1)
        case #selector(NSResponder.insertNewline(_:)):
            let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
            if items.indices.contains(selected) { run(items[selected], plain: shift) }
        case #selector(NSResponder.cancelOperation(_:)): close(reactivate: true)
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            mode = mode == .search ? .clipboard : .search
            field.stringValue = ""
            refresh()
        default: return false
        }
        return true
    }

    /// 클립보드 모드의 ⌘ 단축키. 자판이 한글이어도 되게 키 위치로 본다
    private func keyEquivalent(_ e: NSEvent) -> Bool {
        guard mode == .clipboard, clips.enabled else { return false }
        let mods = e.modifierFlags.intersection([.command, .control, .option, .shift])
        guard mods == .command else { return false }
        let digits: [UInt16: Int] = [18: 0, 19: 1, 20: 2, 21: 3, 23: 4, 22: 5, 26: 6, 28: 7, 25: 8]
        let current = items.indices.contains(selected) ? items[selected] : nil
        switch e.keyCode {
        case let k where digits[k] != nil:
            if let i = digits[k], items.indices.contains(i) { run(items[i]) }
        case 36:   // ⌘⏎ 복사만
            if let current { run(current, copyOnly: true) }
        case 35:   // ⌘P 고정
            if case .clip(let c)? = current?.action { clips.togglePin(c); refresh(keep: selected) }
        case 51:   // ⌘⌫ 지우기
            if case .clip(let c)? = current?.action { clips.remove(c); refresh(keep: selected) }
        case 33, 30:   // ⌘[ ⌘] 종류
            let n = Self.filters.count
            filter.selectedSegment = (max(0, filter.selectedSegment) + (e.keyCode == 30 ? 1 : n - 1)) % n
            refresh()
        default:
            return false
        }
        return true
    }

    @objc private func filterChanged() {
        refresh()
        panel.makeFirstResponder(field)
    }

    private func select(_ i: Int) {
        guard !items.isEmpty else { preview.show(nil, clips: clips); return }
        selected = (i + items.count) % items.count
        for (n, r) in rows.enumerated() { r.selected = n == selected }
        if mode == .clipboard, case .clip(let e) = items[selected].action { preview.show(e, clips: clips) } else { preview.show(nil, clips: clips) }
    }

    // MARK: 메뉴

    func addMenuItems(to menu: NSMenu) {
        let top = NSMenuItem(title: "🔎 런처", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.addItem("런처 열기 (\(hotKeyName))", #selector(openFromMenu), target: self)
        sub.addItem("클립보드 기록 열기 (\(Self.clipKeyName))", #selector(openClipsFromMenu), target: self)
        sub.addItem(.separator())
        sub.addItem("클립보드 기록 남기기", #selector(toggleClips), target: self).state = clips.enabled ? .on : .off
        if clips.enabled {
            let keep = NSMenuItem(title: "보관 기간 (고정한 것은 계속)", action: nil, keyEquivalent: "")
            let km = NSMenu()
            for (title, days) in [("7일", 7), ("30일", 30), ("90일", 90), ("1년", 365), ("제한 없음 (최근 \(ClipHistory.maxCount)개)", 0)] {
                let it = km.addItem(title, #selector(setRetention(_:)), target: self)
                it.tag = days
                it.state = clips.retentionDays == days ? .on : .off
            }
            keep.submenu = km
            sub.addItem(keep)
            let ign = NSMenuItem(title: "기록 안 할 앱", action: nil, keyEquivalent: "")
            ign.submenu = ignoreMenu()
            sub.addItem(ign)
            if !clips.entries.isEmpty {
                sub.addItem("클립보드 기록 모두 지우기 (\(clips.entries.count)개, 고정 포함)", #selector(clearClips), target: self)
            }
        }
        sub.addItem(.separator())
        sub.addItem("⌘Space 로 열기 (Spotlight·Raycast 단축키를 먼저 끌 것)", #selector(toggleCmdSpace), target: self).state = useCmdSpace ? .on : .off
        top.submenu = sub
        menu.addItem(top)
    }

    /// 지금 막아 둔 앱 + 최근 기록에 나온 앱. 누르면 켜고 끈다
    private func ignoreMenu() -> NSMenu {
        let m = NSMenu()
        var seen: [(bundle: String, name: String)] = []
        for b in clips.ignored.sorted() {
            let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b).map { FileManager.default.displayName(atPath: $0.path) } ?? b
            seen.append((b, name.replacingOccurrences(of: ".app", with: "")))
        }
        for e in clips.entries {
            guard let b = e.bundle, !seen.contains(where: { $0.bundle == b }) else { continue }
            seen.append((b, e.app ?? b))
            if seen.count >= 15 { break }
        }
        if seen.isEmpty {
            let i = NSMenuItem(title: "아직 기록에 나온 앱이 없다", action: nil, keyEquivalent: "")
            i.isEnabled = false
            m.addItem(i)
        }
        for s in seen {
            let it = m.addItem(s.name, #selector(toggleIgnore(_:)), target: self)
            it.representedObject = s.bundle
            it.state = clips.ignored.contains(s.bundle) ? .on : .off
        }
        return m
    }

    @objc private func openFromMenu() { DispatchQueue.main.async { self.show(.search) } }
    @objc private func openClipsFromMenu() { DispatchQueue.main.async { self.show(.clipboard) } }
    @objc private func clearClips() { clips.clear() }
    @objc private func setRetention(_ sender: NSMenuItem) { clips.retentionDays = sender.tag }

    @objc private func toggleIgnore(_ sender: NSMenuItem) {
        guard let b = sender.representedObject as? String else { return }
        var s = clips.ignored
        if s.contains(b) { s.remove(b) } else { s.insert(b) }
        clips.ignored = s
    }

    @objc private func toggleClips() {
        if clips.enabled { clips.setEnabled(false) } else if confirmClips() { clips.setEnabled(true) }
    }

    @objc private func toggleCmdSpace() {
        useCmdSpace.toggle()
        registerHotKeys()
    }

    private func confirmClips() -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "클립보드 기록을 남길까요?"
        a.informativeText = """
        복사한 글·이미지·파일을 이 맥에만 암호화해서 저장하고(열쇠는 키체인), \(Self.clipKeyName) 나 런처의 Tab 으로 다시 붙여넣습니다. 외부로 보내는 것은 없습니다. 고정한 것은 계속, 나머지는 30일(메뉴에서 바꿈) 동안 둡니다.
        비밀번호 관리자에서 복사한 것, 막은 앱·사이트·시크릿 창·주소를 확인 못 한 브라우저(Safari 기본 포함)에서 복사한 것, 키·토큰·카드번호처럼 보이는 글은 남기지 않습니다. 이미지는 글자를 읽어 같은 규칙으로 거릅니다. 끄면 기록을 바로 지웁니다.
        """
        a.addButton(withTitle: "켜기")
        a.addButton(withTitle: "취소")
        return a.runModal() == .alertFirstButtonReturn
    }

    // MARK: 화면

    private func build() {
        panel = LauncherPanel(contentRect: NSRect(x: 0, y: 0, width: Self.searchWidth, height: 120),
                              styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .modalPanel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.delegate = self
        panel.onKeyEquivalent = { [weak self] e in self?.keyEquivalent(e) ?? false }

        let lens = NSImageView(image: symbol("magnifyingglass") ?? NSImage())
        lens.contentTintColor = Self.cream.withAlphaComponent(0.6)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 20, weight: .light)
        field.textColor = Self.cream
        field.delegate = self
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        filter.selectedSegment = 0
        filter.controlSize = .small
        filter.target = self
        filter.action = #selector(filterChanged)
        filter.setContentCompressionResistancePriority(.required, for: .horizontal)
        let header = NSStackView(views: [lens, field, filter])
        header.orientation = .horizontal
        header.spacing = 10
        header.edgeInsets = NSEdgeInsets(top: 14, left: 18, bottom: 12, right: 18)

        list.orientation = .vertical
        list.spacing = 0
        list.alignment = .leading
        list.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 4, right: 8)
        listWidth = list.widthAnchor.constraint(equalToConstant: Self.searchWidth)
        listWidth.isActive = true
        preview.widthAnchor.constraint(equalToConstant: Self.previewWidth).isActive = true
        let body = NSStackView(views: [list, preview])
        body.orientation = .horizontal
        body.alignment = .top
        body.spacing = 0

        footer.font = .systemFont(ofSize: 10.5)
        footer.textColor = Self.cream.withAlphaComponent(0.42)
        footer.lineBreakMode = .byTruncatingTail
        let foot = NSStackView(views: [footer])
        foot.edgeInsets = NSEdgeInsets(top: 4, left: 18, bottom: 10, right: 18)

        let root = NSStackView(views: [header, body, foot])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 0
        for v in [header, body, foot] { v.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }

        let glass: NSView
        if #available(macOS 26, *) {
            let g = NSGlassEffectView()
            g.cornerRadius = Self.radius
            g.tintColor = Self.dim.withAlphaComponent(0.45)
            g.contentView = root
            glass = g
        } else {
            let v = NSVisualEffectView()
            v.material = .hudWindow
            v.blendingMode = .behindWindow
            v.state = .active
            v.wantsLayer = true
            v.layer?.cornerRadius = Self.radius
            v.layer?.masksToBounds = true
            root.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(root)
            NSLayoutConstraint.activate([
                root.leadingAnchor.constraint(equalTo: v.leadingAnchor), root.trailingAnchor.constraint(equalTo: v.trailingAnchor),
                root.topAnchor.constraint(equalTo: v.topAnchor), root.bottomAnchor.constraint(equalTo: v.bottomAnchor),
            ])
            glass = v
        }
        panel.contentView = glass
    }

    private func rebuildRows(select keep: Int) {
        rows.forEach { $0.removeFromSuperview() }
        rows = items.enumerated().map { n, item in
            let r = LauncherRow(item: item, cream: Self.cream)
            r.onClick = { [weak self] in
                guard let self else { return }
                self.select(n)
                self.run(item)
            }
            return r
        }
        for r in rows {
            list.addArrangedSubview(r)
            r.widthAnchor.constraint(equalTo: list.widthAnchor, constant: -16).isActive = true
            r.heightAnchor.constraint(equalToConstant: Self.rowHeight).isActive = true
        }
        // 클립보드 모드: 목록 + 미리보기, 높이는 9줄로 고정 / 검색: 목록만, 줄 수만큼. 위쪽 가장자리는 그대로 둔다
        let clip = mode == .clipboard && clips.enabled
        preview.isHidden = !clip
        listWidth.constant = clip ? Self.clipListWidth : Self.searchWidth
        let width = clip ? Self.clipListWidth + Self.previewWidth : Self.searchWidth
        let shownRows = clip ? Self.clipRows : rows.count
        let h = 56 + CGFloat(shownRows) * Self.rowHeight + (shownRows == 0 ? 0 : 4) + 30
        var f = panel.frame
        f.origin.y += f.height - h
        f.origin.x += (f.width - width) / 2
        f.size = NSSize(width: width, height: h)
        panel.setFrame(f, display: true)
        select(keep)
    }
}

/// 앱 목록: /Applications 등을 한 단계 아래 폴더까지 훑는다. 5분 넘게 지났으면 열 때 뒤에서 다시 훑는다
final class AppIndex {
    struct App {
        let url: URL
        let name: String   // Finder 에 보이는 이름 (한국어면 한국어)
        let file: String   // 파일 이름 (영문)
    }

    private(set) var all: [App] = []
    var onChange: (() -> Void)?
    private var builtAt = Date.distantPast
    private var building = false

    static let dirs = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                       "/System/Library/CoreServices/Applications", NSHomeDirectory() + "/Applications"]

    func refreshIfStale() {
        guard !building, Date().timeIntervalSince(builtAt) > 300 else { return }
        building = true
        DispatchQueue.global(qos: .userInitiated).async {
            let found = Self.scan()
            DispatchQueue.main.async {
                self.all = found
                self.builtAt = Date()
                self.building = false
                self.onChange?()
            }
        }
    }

    static func scan() -> [App] {
        let fm = FileManager.default
        var seen = Set<String>()
        var out: [App] = []
        func add(_ url: URL) {
            guard seen.insert(url.resolvingSymlinksInPath().path).inserted else { return }
            let file = url.deletingPathExtension().lastPathComponent
            var name = fm.displayName(atPath: url.path)
            if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
            out.append(App(url: url, name: name, file: file))
        }
        for dir in dirs {
            guard let items = try? fm.contentsOfDirectory(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [.skipsHiddenFiles]) else { continue }
            for u in items {
                if u.pathExtension == "app" { add(u); continue }
                guard (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                      let inner = try? fm.contentsOfDirectory(at: u, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
                inner.filter { $0.pathExtension == "app" }.forEach(add)
            }
        }
        return out
    }
}

/// 앞 앱의 창을 손쉬운 사용 API 로 옮긴다. 실패하면 사람이 읽을 이유를 돌려준다
enum WindowMover {
    static func apply(_ layout: LauncherRules.Layout, to app: NSRunningApplication?) -> String? {
        guard AXIsProcessTrusted() else { return "창을 옮기려면 손쉬운 사용 권한이 필요하다냥" }
        guard let app else { return "옮길 창을 못 찾았다냥" }
        let el = AXUIElementCreateApplication(app.processIdentifier)
        guard let win = AX.element(el, kAXFocusedWindowAttribute) ?? AX.element(el, kAXMainWindowAttribute),
              let pos = point(win, kAXPositionAttribute), let size = size(win, kAXSizeAttribute),
              let primary = NSScreen.screens.first?.frame.height else { return "\(app.localizedName ?? "그 앱")의 창을 못 찾았다냥" }
        let rect = CGRect(x: pos.x, y: primary - pos.y - size.height, width: size.width, height: size.height)
        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: rect.midX, y: rect.midY)) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return "화면을 못 찾았다냥" }
        let target = LauncherRules.frame(layout, visible: visible, current: size)
        var origin = LauncherRules.axOrigin(target, primaryHeight: primary)
        var newSize = target.size
        // 크기를 바꾸면 화면 밖으로 밀리는 앱이 있어 위치 → 크기 → 위치 순서로 둔다
        guard let p = AXValueCreate(.cgPoint, &origin), let s = AXValueCreate(.cgSize, &newSize) else { return nil }
        _ = AX.set(win, kAXPositionAttribute, p)
        let r = AX.set(win, kAXSizeAttribute, s)
        _ = AX.set(win, kAXPositionAttribute, p)
        return r == .success || layout == .center ? nil : "\(app.localizedName ?? "그 앱")은 창 크기를 못 바꾸게 막아 뒀다냥"
    }

    private static func point(_ el: AXUIElement, _ attr: String) -> CGPoint? {
        var v: CFTypeRef?
        var p = CGPoint.zero
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success, let v,
              CFGetTypeID(v) == AXValueGetTypeID(), AXValueGetValue(v as! AXValue, .cgPoint, &p) else { return nil }
        return p
    }

    private static func size(_ el: AXUIElement, _ attr: String) -> CGSize? {
        var v: CFTypeRef?
        var s = CGSize.zero
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success, let v,
              CFGetTypeID(v) == AXValueGetTypeID(), AXValueGetValue(v as! AXValue, .cgSize, &s) else { return nil }
        return s
    }
}

/// 테두리 없이 키보드를 받는 패널. ⌘ 단축키는 검색칸보다 먼저 런처가 받는다
private final class LauncherPanel: NSPanel {
    var onKeyEquivalent: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { true }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        onKeyEquivalent?(event) == true || super.performKeyEquivalent(with: event)
    }
}

/// 클립보드 모드 오른쪽: 이미지·색 견본 · 내용 전체(이미지는 읽은 글자) · 정보 한 줄
private final class PreviewPane: NSView {
    private let visual = NSImageView()
    private let scroll = NSTextView.scrollableTextView()
    private let meta = NSTextField(wrappingLabelWithString: "")
    private var visualHeight: NSLayoutConstraint!

    init() {
        super.init(frame: .zero)
        let cream = Launcher.cream
        wantsLayer = true
        layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
        layer?.borderWidth = 0
        visual.imageScaling = .scaleProportionallyDown
        visual.wantsLayer = true
        visual.layer?.cornerRadius = 8
        visualHeight = visual.heightAnchor.constraint(equalToConstant: 0)
        visualHeight.isActive = true
        let tv = scroll.documentView as! NSTextView
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.textColor = cream
        tv.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        tv.textContainerInset = NSSize(width: 2, height: 4)
        scroll.drawsBackground = false
        scroll.scrollerStyle = .overlay
        scroll.hasVerticalScroller = true
        meta.font = .systemFont(ofSize: 10.5)
        meta.textColor = cream.withAlphaComponent(0.5)
        let stack = NSStackView(views: [visual, scroll, meta])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 4, bottom: 6, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            visual.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20),
            meta.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20),
            heightAnchor.constraint(equalToConstant: CGFloat(Launcher.clipRows) * Launcher.rowHeight),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ e: ClipHistory.Entry?, clips: ClipHistory) {
        let tv = scroll.documentView as! NSTextView
        guard let e else {
            visual.image = nil; visualHeight.constant = 0
            tv.string = ""; meta.stringValue = ""
            return
        }
        switch e.kind {
        case .image:
            visual.image = clips.image(e)
            visualHeight.constant = 190
            tv.string = e.ocr.map { "이미지 속 글자\n\n" + $0 } ?? "(읽은 글자 없음)"
        case .color:
            visual.image = Launcher.swatch(e.text, size: 120)
            visualHeight.constant = 120
            tv.string = e.text
        case .file:
            visual.image = nil; visualHeight.constant = 0
            tv.string = e.paths.joined(separator: "\n")
        case .text, .link:
            visual.image = nil; visualHeight.constant = 0
            tv.string = String(e.text.prefix(20_000))
        }
        tv.scrollToBeginningOfDocument(nil)
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "M월 d일 a h:mm"
        meta.stringValue = [e.pinned ? "📌 고정" : nil, e.kind.title, e.app, f.string(from: Date(timeIntervalSince1970: e.ts)),
                            e.rich ? "서식 있음 (⇧⏎ = 글만)" : nil].compactMap { $0 }.joined(separator: " · ")
    }
}

/// 결과 한 줄: 아이콘 · 이름 · 설명 · 오른쪽 꼬리표. 고른 줄은 옅게 칠한다
private final class LauncherRow: NSView {
    var onClick: (() -> Void)?
    var selected = false {
        didSet { layer?.backgroundColor = selected ? NSColor.white.withAlphaComponent(0.13).cgColor : NSColor.clear.cgColor }
    }

    init(item: Launcher.Item, cream: NSColor) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        let icon = NSImageView(image: item.icon ?? NSImage())
        icon.contentTintColor = cream.withAlphaComponent(0.85)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 28).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 28).isActive = true
        let title = NSTextField(labelWithString: item.title)
        title.font = .systemFont(ofSize: 14)
        title.textColor = cream
        title.lineBreakMode = .byTruncatingTail
        let sub = NSTextField(labelWithString: item.subtitle)
        sub.font = .systemFont(ofSize: 11)
        sub.textColor = cream.withAlphaComponent(0.5)
        sub.lineBreakMode = .byTruncatingTail
        for t in [title, sub] { t.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        let texts = NSStackView(views: [title, sub])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 1
        let tag = NSTextField(labelWithString: item.tag)
        tag.font = .systemFont(ofSize: 11)
        tag.textColor = cream.withAlphaComponent(0.4)
        tag.setContentCompressionResistancePriority(.required, for: .horizontal)
        let row = NSStackView(views: [icon, texts, NSView(), tag])
        row.orientation = .horizontal
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 12)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) { onClick?() }
}
