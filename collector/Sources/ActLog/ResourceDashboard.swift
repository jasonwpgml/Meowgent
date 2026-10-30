import AppKit

/// 고양이 말풍선에 붙이는 자세히 보기. 말풍선을 2초 올려 두면 show(anchor, false) 미리보기,
/// 누르면 show(anchor, true) 고정. 마우스가 말풍선을 떠나면 hide() (미리보기일 때만 닫힌다).
/// anchor 는 말풍선 자리 (화면 좌표).
struct NoticeDetail {
    let show: (_ anchor: CGRect, _ pinned: Bool) -> Void
    let hide: () -> Void
}

/// 맥 상태 대시보드: 알림이 왜 떴는지 + CPU·메모리·발열·에너지(·GPU) 막대와 최근 10분 선 + 많이 쓰는 앱.
/// 미리보기는 마우스가 말풍선이나 이 창 위에 있는 동안만 떠 있고, 누르면 고정된다. 고정은 ×·Esc·바깥 클릭으로 닫는다.
final class ResourceDashboard: NSObject {
    private unowned let watch: ResourceWatch
    private var panel: DashPanel!
    private var content: NSView!
    private var focus: Resource.Alert?
    private var anchor: CGRect = .zero
    private var pinned = false
    private var hoverTimer: Timer?
    private var outsideClick: Any?

    private let focusBox = NSView()
    private let focusLabel = NSTextField(wrappingLabelWithString: "")
    private let ignoreButton = NSButton(title: "", target: nil, action: nil)
    private let rows = (cpu: MetricRow("CPU"), memory: MetricRow("메모리"), thermal: MetricRow("발열"),
                        energy: MetricRow("에너지"), gpu: MetricRow("GPU"))
    private let appsTitle = NSTextField(labelWithString: "")
    private var appRows: [AppRow] = []
    private let footer = NSTextField(labelWithString: "")

    // 묘전트 자신
    private let ownTitle = NSTextField(labelWithString: "🐈 묘전트가 쓰는 양")
    private let ownCount = NSTextField(labelWithString: "")
    private let own = (cpu: KeyValueRow("CPU"), memory: KeyValueRow("메모리"), diskNow: KeyValueRow("디스크 지금"), diskTotal: KeyValueRow("디스크 합계"),
                       netNow: KeyValueRow("네트워크 지금"), netTotal: KeyValueRow("네트워크 연 뒤 합계"), data: KeyValueRow("데이터 폴더"))
    private let ownParts = Resource.OwnPart.allCases.map { KeyValueRow($0.title, dim: true) }

    // 정리 후보
    private let cleanBox = NSStackView()
    private let cleanLabel = NSTextField(wrappingLabelWithString: "")
    private let cleanAuto = NSButton(title: "앞으로 자동 정리", target: nil, action: nil)

    static let width: CGFloat = 340
    static let radius: CGFloat = 20
    static let cream = NSColor(srgbRed: 0.95, green: 0.92, blue: 0.85, alpha: 1)
    static let amber = NSColor(srgbRed: 0.98, green: 0.74, blue: 0.30, alpha: 1)
    static let red = NSColor(srgbRed: 0.98, green: 0.42, blue: 0.36, alpha: 1)
    static let calm = NSColor(srgbRed: 0.62, green: 0.82, blue: 0.62, alpha: 1)
    private static let dim = NSColor(srgbRed: 0.09, green: 0.07, blue: 0.06, alpha: 1)

    init(watch: ResourceWatch) {
        self.watch = watch
        super.init()
    }

    var isVisible: Bool { panel?.isVisible == true }

    func show(focus: Resource.Alert?, anchor: CGRect, pinned: Bool) {
        if panel == nil { build() }
        if isVisible, self.pinned, !pinned { return }   // 고정된 창을 미리보기로 바꾸지 않는다
        self.focus = focus
        self.anchor = anchor
        self.pinned = pinned
        focusLabel.stringValue = focus?.text ?? ""
        focusBox.isHidden = focus == nil
        if let a = focus?.app {
            ignoreButton.title = "\(a.name) 알림 끄기"
            ignoreButton.isHidden = !pinned
        } else {
            ignoreButton.isHidden = true
        }
        ignoreButton.isEnabled = true
        fill()
        place()
        watch.setFast(true)
        if pinned {
            hoverTimer?.invalidate(); hoverTimer = nil
            panel.makeKeyAndOrderFront(nil)
            if outsideClick == nil {
                outsideClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.close() }
            }
        } else {
            panel.orderFrontRegardless()
            // 말풍선에서 이 창으로 마우스를 옮기는 동안은 닫지 않는다
            hoverTimer?.invalidate()
            hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.checkHover() }
        }
    }

    /// 말풍선을 떠났을 때 (미리보기일 때만, 마우스가 이 창 위에 있으면 그대로)
    func hidePreview() {
        guard isVisible, !pinned else { return }
        checkHover()
    }

    private func checkHover() {
        guard isVisible, !pinned else { return }
        let m = NSEvent.mouseLocation
        if panel.frame.insetBy(dx: -6, dy: -6).contains(m) || anchor.insetBy(dx: -4, dy: -4).contains(m) { return }
        close()
    }

    func close() {
        hoverTimer?.invalidate(); hoverTimer = nil
        if let m = outsideClick { NSEvent.removeMonitor(m); outsideClick = nil }
        panel?.orderOut(nil)
        pinned = false
        watch.setFast(false)
    }

    /// 말풍선 위쪽(자리 없으면 아래)에, 화면 밖으로 안 나가게
    private func place() {
        content.layoutSubtreeIfNeeded()
        let size = NSSize(width: Self.width, height: content.fittingSize.height)
        let screen = NSScreen.screens.first { $0.frame.contains(anchor.origin) } ?? NSScreen.main
        let v = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        var x = anchor.midX - size.width / 2
        var y = anchor.maxY + 8
        if y + size.height > v.maxY { y = anchor.minY - size.height - 8 }
        x = min(max(x, v.minX + 8), v.maxX - size.width - 8)
        y = min(max(y, v.minY + 8), v.maxY - size.height - 8)
        panel.setFrame(NSRect(origin: CGPoint(x: x, y: y), size: size), display: true)
    }

    // MARK: 값 채우기

    /// 새로 읽을 때마다 (떠 있을 때만)
    func refresh() {
        guard isVisible else { return }
        fill()
        // 앱 줄 수가 바뀌면 높이만 맞춘다 (위쪽 가장자리는 그대로, 옮겨 둔 자리도 그대로)
        let h = content.fittingSize.height
        if abs(h - panel.frame.height) > 0.5 {
            var f = panel.frame
            f.origin.y += f.height - h
            f.size.height = h
            panel.setFrame(f, display: true)
        }
    }

    private func fill() {
        guard let s = watch.latest else { return }
        let hist = watch.history
        let kind = focus?.kind

        rows.cpu.set(value: "\(Int(s.cpu))%", fraction: s.cpu / 100, level: s.cpu >= Resource.busyCPU ? 1 : 0,
                     detail: "코어 \(s.cores)개", spark: hist.map(\.cpu), sparkMax: 100, focused: kind == .cpu)
        rows.memory.set(value: "\(Int(s.memUsed))%", fraction: s.memUsed / 100, level: s.pressure,
                        detail: "압박 \(Resource.pressureName[min(s.pressure, 2)]) · 스왑 \(Resource.bytes(s.swapBytes))",
                        spark: hist.map(\.memUsed), sparkMax: 100, focused: kind == .memory)
        let th = min(s.thermal, 3)
        rows.thermal.set(value: Resource.thermalName[th], fraction: Double(th + 1) / 4, level: th >= 3 ? 2 : (th == 2 ? 1 : 0),
                         detail: th >= 2 ? "macOS가 속도를 낮추는 중" : "괜찮다냥", spark: hist.map { Double($0.thermal) }, sparkMax: 3,
                         focused: kind == .thermal)
        // 선: 배터리로 쓸 땐 배터리에서 나가는 전력, 전원에 꽂혀 있으면 앱들이 쓰는 전력
        let appWatts = { (x: Resource.Sample) in x.apps.reduce(0) { $0 + $1.watts } }
        let power = hist.map { $0.watts ?? appWatts($0) }
        if let b = s.battery {
            let low = b.onBattery && b.percent <= 20
            rows.energy.set(value: "\(b.percent)%", fraction: Double(b.percent) / 100, level: b.onBattery && b.percent <= 10 ? 2 : (low ? 1 : 0),
                            detail: Self.batteryLine(b, watts: s.watts) + (b.onBattery ? "" : " · 앱 전력 \(Resource.watts(appWatts(s)))"),
                            spark: power, sparkMax: max(20, power.max() ?? 0), focused: kind == .energy)
        } else {
            rows.energy.set(value: Resource.watts(appWatts(s)), fraction: min(appWatts(s) / 30, 1), level: 0, detail: "앱들이 쓰는 전력",
                            spark: power, sparkMax: max(30, power.max() ?? 0), focused: kind == .energy)
        }
        rows.gpu.isHidden = s.gpu == nil
        if let g = s.gpu {
            rows.gpu.set(value: "\(Int(g))%", fraction: g / 100, level: g >= Resource.busyGPU ? 1 : 0, detail: "따로 단 GPU",
                         spark: hist.compactMap(\.gpu), sparkMax: 100, focused: kind == .gpu)
        }

        // 알림 종류에 맞춰 정렬: 메모리면 메모리 순, 에너지면 전력 순, 나머지는 CPU 순
        let ignored = Set(watch.ignored.keys)
        let sorted: [Resource.App]
        switch kind {
        case .memory: sorted = s.apps.sorted { $0.memBytes > $1.memBytes }; appsTitle.stringValue = "많이 쓰는 앱 · 메모리 순"
        case .energy: sorted = s.apps.sorted { $0.watts > $1.watts }; appsTitle.stringValue = "많이 쓰는 앱 · 전력 순"
        default: sorted = s.apps.sorted { $0.cpu > $1.cpu }; appsTitle.stringValue = "많이 쓰는 앱 · CPU 순"
        }
        for (i, r) in appRows.enumerated() {
            if i < sorted.count {
                let a = sorted[i]
                r.set(a, highlighted: a.key == focus?.app?.key, ignored: ignored.contains(a.key))
                r.isHidden = false
            } else {
                r.isHidden = true
            }
        }
        fillOwn(s.own)
        fillClean()
        footer.stringValue = (pinned ? "" : "누르면 고정된다냥 · ") + "시스템 프로세스는 목록에 없다 · 2초마다 새로 읽음"
    }

    private func fillOwn(_ o: Resource.Own?) {
        guard let o else { return }
        ownCount.stringValue = "프로세스 \(o.processes)개"
        own.cpu.value = String(format: "%.1f%%", o.cpu)
        own.memory.value = Resource.bytes(o.memBytes)
        own.diskNow.value = "읽기 \(Resource.rate(o.readRate)) · 쓰기 \(Resource.rate(o.writeRate))"
        own.diskTotal.value = "읽기 \(Resource.size(o.readTotal)) · 쓰기 \(Resource.size(o.writeTotal))"
        if let n = o.net {
            own.netNow.value = n.failed ? "읽지 못했다냥" : "받기 \(Resource.rate(n.inRate)) · 보내기 \(Resource.rate(n.outRate))"
            own.netTotal.value = n.failed ? "–" : "받기 \(Resource.size(n.inTotal)) · 보내기 \(Resource.size(n.outTotal))"
        } else {
            own.netNow.value = "읽는 중"
            own.netTotal.value = "–"
        }
        own.data.value = o.dataBytes.map(Resource.size) ?? "재는 중"
        for r in ownParts { r.isHidden = true }
        for u in o.parts {
            ownParts[u.part.rawValue].isHidden = false
            ownParts[u.part.rawValue].value = String(format: "%.1f%% · ", u.cpu) + Resource.bytes(u.memBytes)
        }
    }

    private func fillClean() {
        guard let p = watch.cleaner.pending else { cleanBox.isHidden = true; return }
        cleanBox.isHidden = false
        cleanLabel.stringValue = "🧹 \(p.name): \(p.reason)\n정리할까냥? 저장 안 한 게 있으면 그 앱이 먼저 물어본다냥."
        cleanAuto.isHidden = !p.canAutomate
    }

    static func batteryLine(_ b: Resource.Battery, watts: Double?) -> String {
        var parts: [String] = []
        if b.onBattery {
            parts.append("배터리 \(b.percent)%")
            if let m = b.minutesLeft { parts.append("약 \(Resource.duration(m)) 남음") }
            if let w = watts { parts.append(Resource.watts(w)) }
        } else {
            parts.append(b.charging ? "충전 중 \(b.percent)%" : "전원 연결 \(b.percent)%")
        }
        if b.lowPower { parts.append("저전력 모드") }
        return parts.joined(separator: " · ")
    }

    // MARK: 만들기

    private func build() {
        panel = DashPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 400),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.onEscape = { [weak self] in self?.close() }
        // 미리보기를 누르면 고정
        panel.onClick = { [weak self] in
            guard let self, !self.pinned else { return }
            self.show(focus: self.focus, anchor: self.anchor, pinned: true)
        }

        let root = buildContent()
        content = root
        // 대화창과 같은 유리, 숫자가 잘 읽히게 조금 더 어둡게
        let tint = max(UserDefaults.standard.object(forKey: "chatGlassTint") as? Double ?? 0.35, 0.45)
        if #available(macOS 26, *) {
            let g = NSGlassEffectView()
            g.cornerRadius = Self.radius
            g.tintColor = Self.dim.withAlphaComponent(tint)
            g.contentView = root
            panel.contentView = g
        } else {
            let v = NSVisualEffectView()
            v.material = .hudWindow
            v.blendingMode = .behindWindow
            v.state = .active
            v.wantsLayer = true
            v.layer?.cornerRadius = Self.radius
            v.layer?.masksToBounds = true
            let shade = NSView()
            shade.wantsLayer = true
            shade.layer?.backgroundColor = Self.dim.withAlphaComponent(tint).cgColor
            for sub in [shade, root] {
                sub.translatesAutoresizingMaskIntoConstraints = false
                v.addSubview(sub)
                NSLayoutConstraint.activate([
                    sub.leadingAnchor.constraint(equalTo: v.leadingAnchor), sub.trailingAnchor.constraint(equalTo: v.trailingAnchor),
                    sub.topAnchor.constraint(equalTo: v.topAnchor), sub.bottomAnchor.constraint(equalTo: v.bottomAnchor),
                ])
            }
            panel.contentView = v
        }
    }

    private func buildContent() -> NSView {
        let title = NSTextField(labelWithString: "🖥️ 맥 상태")
        title.font = NSFont(name: "Galmuri11-Bold", size: 13) ?? .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = Self.cream
        let am = Self.iconButton("waveform.path.ecg", "활성 상태 보기 열기", watch, #selector(ResourceWatch.openActivityMonitor))
        let xb = Self.iconButton("xmark", "닫기 (Esc)", self, #selector(closePressed))
        let header = NSStackView(views: [title, NSView(), am, xb])
        header.spacing = 8

        // 왜 떴는지
        focusLabel.font = .systemFont(ofSize: 12)
        focusLabel.textColor = Self.cream
        focusLabel.preferredMaxLayoutWidth = Self.width - 56
        focusBox.wantsLayer = true
        focusBox.layer?.cornerRadius = 10
        focusBox.layer?.backgroundColor = Self.amber.withAlphaComponent(0.16).cgColor
        focusLabel.translatesAutoresizingMaskIntoConstraints = false
        focusBox.addSubview(focusLabel)
        NSLayoutConstraint.activate([
            focusLabel.leadingAnchor.constraint(equalTo: focusBox.leadingAnchor, constant: 10),
            focusLabel.trailingAnchor.constraint(equalTo: focusBox.trailingAnchor, constant: -10),
            focusLabel.topAnchor.constraint(equalTo: focusBox.topAnchor, constant: 8),
            focusLabel.bottomAnchor.constraint(equalTo: focusBox.bottomAnchor, constant: -8),
        ])
        ignoreButton.target = self
        ignoreButton.action = #selector(ignorePressed)
        ignoreButton.controlSize = .small
        if #available(macOS 26, *) { ignoreButton.bezelStyle = .glass } else { ignoreButton.bezelStyle = .rounded }

        appsTitle.font = .systemFont(ofSize: 11, weight: .semibold)
        appsTitle.textColor = Self.cream.withAlphaComponent(0.7)
        let colHead = AppRow.header()
        appRows = (0..<6).map { _ in AppRow() }

        footer.font = .systemFont(ofSize: 10)
        footer.textColor = Self.cream.withAlphaComponent(0.45)
        footer.lineBreakMode = .byTruncatingTail

        ownTitle.font = .systemFont(ofSize: 11, weight: .semibold)
        ownTitle.textColor = Self.cream.withAlphaComponent(0.7)
        ownCount.font = .systemFont(ofSize: 10)
        ownCount.textColor = Self.cream.withAlphaComponent(0.45)
        let ownHead = NSStackView(views: [ownTitle, NSView(), ownCount])
        let ownRows: [NSView] = [own.cpu, own.memory, own.diskNow, own.diskTotal, own.netNow, own.netTotal, own.data] + ownParts

        let views: [NSView] = [header, focusBox, ignoreButton, buildCleanBox(), rows.cpu, rows.memory, rows.thermal, rows.energy, rows.gpu,
                               Self.separator(), appsTitle, colHead] + appRows + [Self.separator(), ownHead] + ownRows + [footer]
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(4, after: appsTitle)
        stack.setCustomSpacing(4, after: colHead)
        for r in appRows { stack.setCustomSpacing(3, after: r) }
        stack.setCustomSpacing(4, after: ownHead)
        for r in ownRows { stack.setCustomSpacing(3, after: r) }
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 12, right: 16)
        for v in views where v !== ignoreButton {
            v.widthAnchor.constraint(equalToConstant: Self.width - 32).isActive = true
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        return stack
    }

    private func buildCleanBox() -> NSView {
        cleanLabel.font = .systemFont(ofSize: 12)
        cleanLabel.textColor = Self.cream
        cleanLabel.preferredMaxLayoutWidth = Self.width - 56
        func button(_ title: String, _ sel: Selector) -> NSButton {
            let b = NSButton(title: title, target: self, action: sel)
            b.controlSize = .small
            if #available(macOS 26, *) { b.bezelStyle = .glass } else { b.bezelStyle = .rounded }
            return b
        }
        cleanAuto.target = self
        cleanAuto.action = #selector(cleanAlways)
        cleanAuto.controlSize = .small
        if #available(macOS 26, *) { cleanAuto.bezelStyle = .glass } else { cleanAuto.bezelStyle = .rounded }
        let first = NSStackView(views: [button("정리하기", #selector(cleanNow)), cleanAuto])
        let second = NSStackView(views: [button("이번엔 두기", #selector(cleanLater)), button("항상 두기", #selector(cleanNever))])
        first.spacing = 6
        second.spacing = 6
        cleanBox.orientation = .vertical
        cleanBox.alignment = .leading
        cleanBox.spacing = 6
        for v in [cleanLabel, first, second] { cleanBox.addArrangedSubview(v) }
        cleanBox.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        cleanBox.wantsLayer = true
        cleanBox.layer?.cornerRadius = 10
        cleanBox.layer?.backgroundColor = Self.calm.withAlphaComponent(0.14).cgColor
        cleanBox.isHidden = true
        return cleanBox
    }

    @objc private func cleanNow() { watch.cleaner.answer(.quit) }
    @objc private func cleanAlways() { watch.cleaner.answer(.quitAndAutomate) }
    @objc private func cleanLater() { watch.cleaner.answer(.later) }
    @objc private func cleanNever() { watch.cleaner.answer(.never) }

    @objc private func closePressed() { close() }

    @objc private func ignorePressed() {
        guard let a = focus?.app else { return }
        watch.ignore(a)
        ignoreButton.title = "알았다냥. 이제 안 알린다냥"
        ignoreButton.isEnabled = false
        refresh()
    }

    private static func separator() -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = cream.withAlphaComponent(0.12).cgColor
        v.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return v
    }

    static func iconButton(_ symbol: String, _ tip: String, _ target: AnyObject, _ action: Selector) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage(), target: target, action: action)
        b.isBordered = false
        b.contentTintColor = cream.withAlphaComponent(0.75)
        b.toolTip = tip
        b.symbolConfiguration = .init(pointSize: 13, weight: .medium)
        return b
    }

    static func color(_ level: Int) -> NSColor { level >= 2 ? red : (level == 1 ? amber : calm) }
}

/// 미리보기 상태에서 누르면 고정, Esc 로 닫는 테두리 없는 패널
private final class DashPanel: NSPanel {
    var onEscape: (() -> Void)?
    var onClick: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
    override func sendEvent(_ e: NSEvent) {
        if e.type == .leftMouseDown { onClick?() }
        super.sendEvent(e)
    }
}

/// 이름 · 값 / 막대 / 설명 · 최근 10분 선
private final class MetricRow: NSStackView {
    private let name: NSTextField
    private let value = NSTextField(labelWithString: "")
    private let bar = Bar()
    private let detail = NSTextField(labelWithString: "")
    private let spark = Sparkline()

    init(_ title: String) {
        name = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 4
        name.font = .systemFont(ofSize: 12, weight: .semibold)
        name.textColor = ResourceDashboard.cream
        value.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        value.alignment = .right
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = ResourceDashboard.cream.withAlphaComponent(0.6)
        detail.lineBreakMode = .byTruncatingTail
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let top = NSStackView(views: [name, NSView(), value])
        let bottom = NSStackView(views: [detail, NSView(), spark])
        bar.heightAnchor.constraint(equalToConstant: 5).isActive = true
        spark.widthAnchor.constraint(equalToConstant: 96).isActive = true
        spark.heightAnchor.constraint(equalToConstant: 18).isActive = true
        for v in [top, bar, bottom] {
            addArrangedSubview(v)
            v.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(value v: String, fraction: Double, level: Int, detail d: String, spark s: [Double], sparkMax: Double, focused: Bool) {
        let c = ResourceDashboard.color(level)
        value.stringValue = v
        value.textColor = level > 0 ? c : ResourceDashboard.cream
        name.textColor = focused ? ResourceDashboard.amber : ResourceDashboard.cream
        detail.stringValue = d
        bar.fraction = max(0, min(1, fraction)); bar.color = c
        spark.values = s; spark.maxValue = sparkMax; spark.color = c
    }
}

private final class Bar: NSView {
    var fraction: Double = 0 { didSet { if fraction != oldValue { needsDisplay = true } } }
    var color: NSColor = ResourceDashboard.calm { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.height / 2
        ResourceDashboard.cream.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: r, yRadius: r).fill()
        color.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: max(bounds.height, bounds.width * fraction), height: bounds.height), xRadius: r, yRadius: r).fill()
    }
}

private final class Sparkline: NSView {
    var values: [Double] = [] { didSet { needsDisplay = true } }
    var maxValue: Double = 100
    var color: NSColor = ResourceDashboard.calm
    override func draw(_ dirtyRect: NSRect) {
        guard values.count > 1, maxValue > 0 else { return }
        let p = NSBezierPath()
        let step = bounds.width / CGFloat(values.count - 1)
        for (i, v) in values.enumerated() {
            let pt = NSPoint(x: CGFloat(i) * step, y: 1 + (bounds.height - 2) * CGFloat(min(v / maxValue, 1)))
            i == 0 ? p.move(to: pt) : p.line(to: pt)
        }
        p.lineWidth = 1.5
        p.lineJoinStyle = .round
        color.withAlphaComponent(0.9).setStroke()
        p.stroke()
    }
}

/// 이름 ── 값 한 줄
private final class KeyValueRow: NSStackView {
    private let valueLabel = NSTextField(labelWithString: "")
    var value: String {
        get { valueLabel.stringValue }
        set { valueLabel.stringValue = newValue }
    }

    init(_ title: String, dim: Bool = false) {
        super.init(frame: .zero)
        let name = NSTextField(labelWithString: dim ? "  " + title : title)
        name.font = .systemFont(ofSize: 11)
        name.textColor = ResourceDashboard.cream.withAlphaComponent(dim ? 0.45 : 0.7)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        valueLabel.textColor = ResourceDashboard.cream.withAlphaComponent(dim ? 0.55 : 0.9)
        valueLabel.alignment = .right
        valueLabel.lineBreakMode = .byTruncatingHead
        valueLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        name.setContentCompressionResistancePriority(.required, for: .horizontal)
        setViews([name, NSView(), valueLabel], in: .leading)
        spacing = 6
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// 앱 한 줄: 이름 · CPU · 메모리 · 전력
private final class AppRow: NSStackView {
    private let name = NSTextField(labelWithString: "")
    private let cols = [NSTextField(labelWithString: ""), NSTextField(labelWithString: ""), NSTextField(labelWithString: "")]
    static let widths: [CGFloat] = [48, 58, 44]

    convenience init() {
        self.init(frame: .zero)
        name.font = .systemFont(ofSize: 12)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for (c, w) in zip(cols, Self.widths) {
            c.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            c.alignment = .right
            c.widthAnchor.constraint(equalToConstant: w).isActive = true
        }
        setViews([name, NSView()] + cols, in: .leading)
        spacing = 6
    }

    static func header() -> NSStackView {
        let labels = ["CPU", "메모리", "전력"].map { NSTextField(labelWithString: $0) }
        for (l, w) in zip(labels, widths) {
            l.font = .systemFont(ofSize: 10); l.alignment = .right
            l.textColor = ResourceDashboard.cream.withAlphaComponent(0.45)
            l.widthAnchor.constraint(equalToConstant: w).isActive = true
        }
        let s = NSStackView(views: [NSView()] + labels)
        s.spacing = 6
        return s
    }

    func set(_ a: Resource.App, highlighted: Bool, ignored: Bool) {
        let base = highlighted ? ResourceDashboard.amber : ResourceDashboard.cream
        let s = NSMutableAttributedString(string: a.name, attributes: [.foregroundColor: base, .font: NSFont.systemFont(ofSize: 12, weight: highlighted ? .semibold : .regular)])
        let tag = [a.front ? "지금 쓰는 앱" : nil, ignored ? "안 알림" : nil].compactMap { $0 }.joined(separator: " · ")
        if !tag.isEmpty {
            s.append(NSAttributedString(string: "  " + tag, attributes: [.foregroundColor: ResourceDashboard.cream.withAlphaComponent(0.45),
                                                                          .font: NSFont.systemFont(ofSize: 10)]))
        }
        name.attributedStringValue = s
        cols[0].stringValue = "\(Int(a.cpu.rounded()))%"
        cols[1].stringValue = Resource.bytes(a.memBytes)
        cols[2].stringValue = a.watts >= 0.05 ? Resource.watts(a.watts) : "–"
        for c in cols { c.textColor = base.withAlphaComponent(highlighted ? 1 : 0.85) }
    }
}
