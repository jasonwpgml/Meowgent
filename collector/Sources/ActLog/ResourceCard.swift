import AppKit

/// 메뉴 맨 위에 붙는 맥 상태 카드 (메뉴바 메뉴·고양이 우클릭 메뉴 둘 다).
/// CPU·메모리·저장공간·배터리(·GPU)를 막대로, 이어지는 문제와 많이 쓰는 앱을 한 줄씩. 누르면 대시보드를 연다.
/// 메뉴가 열려 있는 동안 2초마다 새로 읽는다. 색은 시스템 색이라 밝은·어두운 메뉴 모두 맞는다.
final class ResourceCard: NSView {
    private unowned let watch: ResourceWatch
    private var timer: Timer?
    private var hovered = false
    /// 높이는 메뉴를 열 때 정한다 (열린 메뉴의 항목 높이는 바뀌지 않으므로). 그 사이 생긴 문제 줄은 다음에 열 때 보인다
    private var alertSlots = 0

    static let width: CGFloat = 330
    private static let pad: CGFloat = 14
    private static let nameW: CGFloat = 54
    private static let valueW: CGFloat = 92
    private static let headerH: CGFloat = 26
    private static let rowH: CGFloat = 38
    private static let lineH: CGFloat = 18

    private struct Row {
        let name: String
        let value: String
        let fraction: Double
        let level: Int
        let detail: String
        var spark: [Double] = []
        var sparkMax: Double = 100
    }

    init(watch: ResourceWatch) {
        self.watch = watch
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 40))
        alertSlots = min(watch.active.count, 2)
        setFrameSize(NSSize(width: Self.width, height: height()))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("맥 상태. 누르면 대시보드를 연다")
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func height() -> CGFloat {
        guard let s = watch.latest else { return Self.headerH + Self.lineH + 8 }
        return Self.headerH + CGFloat(rows(s).count) * Self.rowH + CGFloat(alertSlots) * Self.lineH + Self.lineH + 10
    }

    // MARK: 열려 있는 동안

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        timer = nil
        guard window != nil else {
            if watch.card === self { watch.card = nil }
            return
        }
        watch.card = self
        watch.pollNow()
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.watch.pollNow() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func update() { needsDisplay = true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }

    override func mouseUp(with event: NSEvent) {
        enclosingMenuItem?.menu?.cancelTracking()
        DispatchQueue.main.async { [weak watch] in watch?.openDashboard() }
    }

    // MARK: 내용

    private func rows(_ s: Resource.Sample) -> [Row] {
        let hist = watch.history
        var out: [Row] = []
        out.append(Row(name: "CPU", value: "\(Int(s.cpu))%", fraction: s.cpu / 100, level: s.cpu >= Resource.busyCPU ? 1 : 0,
                       detail: "코어 \(s.cores)개 · 최근 10분", spark: hist.map(\.cpu)))
        let total = ProcessInfo.processInfo.physicalMemory
        let used = UInt64(Double(total) * s.memUsed / 100)
        var mem = "\(Resource.bytes(used)) / \(Resource.bytes(total)) · 압박 \(Resource.pressureName[min(s.pressure, 2)])"
        if s.swapBytes >= 1_073_741_824 { mem += " · 스왑 \(Resource.bytes(s.swapBytes))" }
        out.append(Row(name: "메모리", value: "\(Int(s.memUsed))%", fraction: s.memUsed / 100, level: min(s.pressure, 2),
                       detail: mem, spark: hist.map(\.memUsed)))
        if let d = s.disk {
            out.append(Row(name: "저장공간", value: "\(Resource.diskSize(d.free)) 남음", fraction: d.usedFraction, level: Resource.diskLevel(d),
                           detail: "전체 \(Resource.diskSize(d.total)) 중 \(Resource.diskSize(d.used)) 사용 (\(Int((d.usedFraction * 100).rounded()))%)"))
        }
        if let b = s.battery {
            let level = b.onBattery && b.percent <= 10 ? 2 : (b.onBattery && b.percent <= 20 ? 1 : 0)
            out.append(Row(name: "배터리", value: "\(b.percent)%", fraction: Double(b.percent) / 100, level: level,
                           detail: ResourceDashboard.batteryLine(b, watts: s.watts)))
        }
        if let g = s.gpu {
            out.append(Row(name: "GPU", value: "\(Int(g))%", fraction: g / 100, level: g >= Resource.busyGPU ? 1 : 0,
                           detail: "따로 단 GPU", spark: hist.compactMap(\.gpu)))
        }
        return out
    }

    private static func color(_ level: Int) -> NSColor { level >= 2 ? .systemRed : (level == 1 ? .systemOrange : .systemGreen) }

    private func text(_ s: String, _ rect: NSRect, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor,
                      align: NSTextAlignment = .left, digits: Bool = false) {
        let p = NSMutableParagraphStyle()
        p.alignment = align
        p.lineBreakMode = .byTruncatingTail
        let font = digits ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        (s as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                             attributes: [.font: font, .foregroundColor: color, .paragraphStyle: p])
    }

    override func draw(_ dirtyRect: NSRect) {
        let pad = Self.pad, w = bounds.width
        if hovered {
            NSColor.labelColor.withAlphaComponent(0.06).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 6, yRadius: 6).fill()
        }

        // 머리: 맥 상태 · 발열 · 자세히
        text("맥 상태", NSRect(x: pad, y: 6, width: 120, height: 18), size: 13, weight: .semibold)
        guard let s = watch.latest else {
            text("읽는 중이다냥", NSRect(x: pad, y: Self.headerH, width: w - pad * 2, height: 16), size: 11, color: .secondaryLabelColor)
            return
        }
        let th = min(s.thermal, 3)
        let hint = NSMutableAttributedString(string: "발열 \(Resource.thermalName[th])",
                                             attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: th >= 2 ? Self.color(th >= 3 ? 2 : 1) : NSColor.secondaryLabelColor])
        hint.append(NSAttributedString(string: "  ·  자세히 ›", attributes: [.font: NSFont.systemFont(ofSize: 11),
                                                                            .foregroundColor: hovered ? NSColor.labelColor : NSColor.tertiaryLabelColor]))
        let hs = hint.size()
        hint.draw(at: NSPoint(x: w - pad - hs.width, y: 8))

        // 막대 줄
        var y = Self.headerH
        let barX = pad + Self.nameW, barW = w - pad - Self.valueW - barX - 8
        for r in rows(s) {
            let c = Self.color(r.level)
            text(r.name, NSRect(x: pad, y: y, width: Self.nameW, height: 16), size: 12, weight: .medium)
            let track = NSRect(x: barX, y: y + 5, width: barW, height: 7)
            NSColor.quaternaryLabelColor.setFill()
            NSBezierPath(roundedRect: track, xRadius: 3.5, yRadius: 3.5).fill()
            var fill = track
            fill.size.width = max(track.height, track.width * CGFloat(max(0, min(1, r.fraction))))
            c.setFill()
            NSBezierPath(roundedRect: fill, xRadius: 3.5, yRadius: 3.5).fill()
            text(r.value, NSRect(x: w - pad - Self.valueW, y: y, width: Self.valueW, height: 16), size: 12, weight: .semibold,
                 color: r.level > 0 ? c : .labelColor, align: .right, digits: true)

            let sparkW: CGFloat = r.spark.count > 1 ? 70 : 0
            text(r.detail, NSRect(x: barX, y: y + 16, width: w - pad - barX - sparkW - (sparkW > 0 ? 8 : 0), height: 15),
                 size: 10.5, color: .secondaryLabelColor, digits: true)
            if sparkW > 0 { drawSpark(r.spark, max: r.sparkMax, in: NSRect(x: w - pad - sparkW, y: y + 17, width: sparkW, height: 12), color: c) }
            y += Self.rowH
        }

        // 지금 이어지고 있는 문제
        for a in watch.active.prefix(alertSlots) {
            text("⚠︎ " + a.short.replacingOccurrences(of: "\n", with: " "), NSRect(x: pad, y: y, width: w - pad * 2, height: 16),
                 size: 11.5, weight: .medium, color: a.urgent ? .systemRed : .systemOrange)
            y += Self.lineH
        }

        // 많이 쓰는 앱
        let top = s.apps.sorted { $0.cpu > $1.cpu }.filter { $0.cpu >= 1 }.prefix(3)
        let apps = top.isEmpty ? "조용하다냥" : top.map { "\($0.name) \(Int($0.cpu.rounded()))%" }.joined(separator: " · ")
        text("CPU 많이 쓰는 앱", NSRect(x: pad, y: y + 1, width: 100, height: 15), size: 10.5, color: .tertiaryLabelColor)
        text(apps, NSRect(x: pad + 92, y: y, width: w - pad * 2 - 92, height: 16), size: 11, color: .secondaryLabelColor, digits: true)
    }

    private func drawSpark(_ v: [Double], max m: Double, in r: NSRect, color: NSColor) {
        guard v.count > 1, m > 0 else { return }
        let p = NSBezierPath()
        let step = r.width / CGFloat(v.count - 1)
        for (i, x) in v.enumerated() {
            // 뒤집힌 좌표: 위가 큰 값
            let pt = NSPoint(x: r.minX + CGFloat(i) * step, y: r.maxY - (r.height - 1) * CGFloat(min(x / m, 1)))
            i == 0 ? p.move(to: pt) : p.line(to: pt)
        }
        p.lineWidth = 1.3
        p.lineJoinStyle = .round
        color.withAlphaComponent(0.85).setStroke()
        p.stroke()
    }
}
