import AppKit

/// 메뉴 맨 위에 붙는 맥 상태 카드 (메뉴바 메뉴·고양이 우클릭 메뉴 둘 다).
/// CPU·GPU·메모리·전력·저장공간·배터리를 막대로, 이어지는 문제와 앱 색 범례를 한 줄씩. 누르면 대시보드를 연다.
/// CPU·GPU(내장일 때)·메모리·전력 막대는 앱별 색 조각으로 나눠 그리고, 조각에 마우스를 올리면 그 줄 설명 자리에 앱 이름과 양이 뜬다.
/// (메뉴 안이라 macOS 툴팁은 늦게 뜨거나 안 떠서 직접 그린다.)
/// 메뉴가 열려 있는 동안 2초마다 새로 읽는다. 색은 시스템 색이라 밝은·어두운 메뉴 모두 맞는다.
final class ResourceCard: NSView {
    private unowned let watch: ResourceWatch
    private var timer: Timer?
    private var hovered = false
    /// 마우스가 올라간 조각 (줄 번호, 조각 번호)과, 그리면서 모아 둔 조각 위치
    private var hoverSlice: (row: Int, index: Int)?
    private var hits: [(rect: NSRect, row: Int, index: Int)] = []
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
        /// 앱별 조각 (없으면 fraction 만큼 한 색으로 채운다)
        var metric: AppSlices.Metric?
        /// 배터리처럼 위험도를 보여 주는 막대: 평소에도 초록 (저장공간은 평소 차분한 잉크색, 사용자 요청)
        var risk = false
        var slices: [Resource.Slice] { metric?.slices ?? [] }
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
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; hoverSlice = nil; needsDisplay = true }
    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let hit = hits.first { $0.rect.contains(p) }.map { (row: $0.row, index: $0.index) }
        guard hit?.row != hoverSlice?.row || hit?.index != hoverSlice?.index else { return }
        hoverSlice = hit
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        enclosingMenuItem?.menu?.cancelTracking()
        DispatchQueue.main.async { [weak watch] in watch?.openDashboard() }
    }

    // MARK: 내용

    private func rows(_ s: Resource.Sample) -> [Row] {
        let hist = watch.history
        var out: [Row] = []
        out.append(Row(name: "CPU", value: "\(Int(s.cpu))%", fraction: s.cpu / 100, level: s.cpu >= Resource.busyCPU ? 1 : 0,
                       detail: "코어 \(s.cores)개 · 최근 10분", spark: hist.map(\.cpu), metric: AppSlices.cpu(s)))
        if let g = s.gpu {
            out.append(Row(name: "GPU", value: "\(Int(g))%", fraction: g / 100, level: !s.gpuBuiltIn && g >= Resource.busyGPU ? 1 : 0,
                           detail: s.gpuBuiltIn ? "내장 GPU · 화면 그리기 포함" : "따로 단 GPU", spark: hist.compactMap(\.gpu), metric: AppSlices.gpu(s)))
        }

        let total = ProcessInfo.processInfo.physicalMemory
        let used = UInt64(Double(total) * s.memUsed / 100)
        var memLine = "\(Resource.bytes(used)) / \(Resource.bytes(total)) · 압박 \(Resource.pressureName[min(s.pressure, 2)])"
        if s.swapBytes >= 1_073_741_824 { memLine += " · 스왑 \(Resource.bytes(s.swapBytes))" }
        out.append(Row(name: "메모리", value: "\(Int(s.memUsed))%", fraction: s.memUsed / 100, level: min(s.pressure, 2),
                       detail: memLine, spark: hist.map(\.memUsed), metric: AppSlices.memory(s)))

        if let p = AppSlices.power(s) {
            let w = AppSlices.totalWatts(s), t = AppSlices.powerTexts(s)
            out.append(Row(name: "전력", value: t.value, fraction: w / p.whole, level: 0, detail: t.detail,
                           spark: hist.map(AppSlices.totalWatts), sparkMax: p.whole, metric: p))
        }
        if let d = s.disk {
            out.append(Row(name: "저장공간", value: "\(Resource.diskSize(d.free)) 남음", fraction: d.usedFraction, level: Resource.diskLevel(d),
                           detail: "전체 \(Resource.diskSize(d.total)) 중 \(Resource.diskSize(d.used)) 사용 (\(Int((d.usedFraction * 100).rounded()))%)"))
        }
        if let b = s.battery {
            let level = b.onBattery && b.percent <= 10 ? 2 : (b.onBattery && b.percent <= 20 ? 1 : 0)
            out.append(Row(name: "배터리", value: "\(b.percent)%", fraction: Double(b.percent) / 100, level: level,
                           detail: ResourceDashboard.batteryLine(b, watts: s.watts), risk: true))
        }
        return out
    }

    private static func color(_ level: Int) -> NSColor { level >= 2 ? .systemRed : (level == 1 ? .systemOrange : .secondaryLabelColor) }
    /// 오른쪽 숫자: 모든 줄이 위험도대로 초록·주황·빨강
    private static func valueColor(_ level: Int) -> NSColor { level > 0 ? color(level) : .systemGreen }
    /// 한 색 막대: 배터리는 위험도대로 초록·주황·빨강, 저장공간·GPU 는 평소 차분한 잉크색이고 문제 있을 때만 주황·빨강
    private static func barColor(_ level: Int, risk: Bool) -> NSColor {
        level > 0 ? color(level) : (risk ? .systemGreen : NSColor.labelColor.withAlphaComponent(0.42))
    }
    private static let trackColor = NSColor.labelColor.withAlphaComponent(0.08)
    /// 앱별 막대의 '기타'
    private static let restColor = NSColor.labelColor.withAlphaComponent(0.24)

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
        // 색은 몫이 큰 앱 다섯까지만, 나머지 앱은 각 막대의 '기타'로 합친다
        var all = rows(s)
        let prepared = AppSlices.prepare(all.compactMap(\.metric))
        var mi = 0
        for i in all.indices where all[i].metric != nil { all[i].metric = prepared.metrics[mi]; mi += 1 }
        let legend = prepared.legend
        hits = []
        if let h = hoverSlice, h.row >= all.count || h.index >= all[h.row].slices.count { hoverSlice = nil }

        var y = Self.headerH
        let barX = pad + Self.nameW, barW = w - pad - Self.valueW - barX - 8
        for (ri, r) in all.enumerated() {
            let c = Self.color(r.level)
            text(r.name, NSRect(x: pad, y: y, width: Self.nameW, height: 16), size: 12, weight: .medium)
            let track = NSRect(x: barX, y: y + 4, width: barW, height: 8)
            if let m = r.metric, !m.slices.isEmpty {
                let spans = AppSlices.draw(m, in: track, hover: hoverSlice?.row == ri ? hoverSlice?.index : nil,
                                           rest: Self.restColor, empty: Self.trackColor)
                // 마우스로 맞히기 쉽게 막대 위아래로 넉넉히
                for (i, sp) in spans.enumerated() { hits.append((NSRect(x: sp.lowerBound, y: y, width: sp.upperBound - sp.lowerBound, height: 17), ri, i)) }
            } else {
                Self.trackColor.setFill()
                NSBezierPath(roundedRect: track, xRadius: 4, yRadius: 4).fill()
                var fill = track
                fill.size.width = max(track.height, track.width * CGFloat(max(0, min(1, r.fraction))))
                Self.barColor(r.level, risk: r.risk).setFill()
                NSBezierPath(roundedRect: fill, xRadius: 4, yRadius: 4).fill()
            }
            text(r.value, NSRect(x: w - pad - Self.valueW, y: y, width: Self.valueW, height: 16), size: 12, weight: .semibold,
                 color: Self.valueColor(r.level), align: .right, digits: true)

            let sparkW: CGFloat = r.spark.count > 1 ? 70 : 0
            let detailRect = NSRect(x: barX, y: y + 16, width: w - pad - barX - sparkW - (sparkW > 0 ? 8 : 0), height: 15)
            if let h = hoverSlice, h.row == ri, let m = r.metric {
                // 마우스가 올라간 조각: 설명 자리에 앱 이름과 양
                let sl = r.slices[h.index]
                sliceColor(sl).setFill()
                NSBezierPath(ovalIn: NSRect(x: detailRect.minX, y: detailRect.minY + 4, width: 7, height: 7)).fill()
                text(AppSlices.label(m, sl), NSRect(x: detailRect.minX + 11, y: detailRect.minY, width: detailRect.width - 11, height: detailRect.height), size: 10.5, weight: .medium,
                     color: .labelColor, digits: true)
            } else {
                text(r.detail, detailRect, size: 10.5, color: .secondaryLabelColor, digits: true)
            }
            if sparkW > 0 { drawSpark(r.spark, max: r.sparkMax, in: NSRect(x: w - pad - sparkW, y: y + 17, width: sparkW, height: 12),
                                      color: r.level > 0 ? c : .tertiaryLabelColor) }
            y += Self.rowH
        }

        // 지금 이어지고 있는 문제
        for a in watch.active.prefix(alertSlots) {
            text("⚠︎ " + a.short.replacingOccurrences(of: "\n", with: " "), NSRect(x: pad, y: y, width: w - pad * 2, height: 16),
                 size: 11.5, weight: .medium, color: a.urgent ? .systemRed : .systemOrange)
            y += Self.lineH
        }

        // 색 범례: 막대에 나온 앱 (막대들에서 차지한 몫이 큰 순), 들어가는 만큼
        guard !legend.isEmpty else {
            text("조용하다냥", NSRect(x: pad, y: y, width: w - pad * 2, height: 16), size: 11, color: .secondaryLabelColor)
            return
        }
        var x = pad
        let font = NSFont.systemFont(ofSize: 11)
        for l in legend {
            let sl = Resource.Slice(key: l.key, name: l.name, value: 0, fraction: 0)
            let nameW = ceil((sl.name as NSString).size(withAttributes: [.font: font]).width)
            guard x + 11 + nameW <= w - pad else { break }
            sliceColor(sl).setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: y + 5, width: 7, height: 7)).fill()
            text(sl.name, NSRect(x: x + 11, y: y, width: nameW + 2, height: 16), size: 11, color: .secondaryLabelColor)
            x += 11 + nameW + 12
        }
    }

    private func sliceColor(_ sl: Resource.Slice) -> NSColor { AppSlices.color(sl, rest: Self.restColor) }

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
