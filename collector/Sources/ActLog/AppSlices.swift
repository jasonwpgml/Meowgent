import AppKit

/// 맥 상태 카드(메뉴)와 대시보드(자세히)가 같이 쓰는 앱별 색 막대.
/// 어느 쪽에서 보든 같은 앱은 같은 색이 되게 색 배정도 여기 한 곳에서 들고 있는다.
enum AppSlices {
    enum Kind { case cpu, memory, power }

    /// 막대 하나: 조각들과, 막대 끝(100%)에 해당하는 값, 나머지 조각의 이름
    struct Metric {
        var kind: Kind
        var slices: [Resource.Slice]
        var whole: Double
        var restName: String
        var filled: Double { min(1, slices.reduce(0) { $0 + $1.fraction }) }
    }

    private static func items(_ s: Resource.Sample, _ v: (Resource.App) -> Double) -> [(key: String, name: String, value: Double)] {
        s.everyApp.values.map { ($0.key, $0.name, v($0)) }
    }

    /// CPU: 앱 값은 코어 하나 = 100 이라 막대 끝은 코어 수 × 100
    static func cpu(_ s: Resource.Sample) -> Metric {
        let whole = Double(max(s.cores, 1)) * 100
        return Metric(kind: .cpu, slices: Resource.slices(items(s, \.cpu), whole: whole, filled: s.cpu / 100 * whole),
                      whole: whole, restName: "그 밖의 앱·시스템")
    }

    /// 메모리: 앱들의 합은 전체 사용량이 안 된다 (커널·압축·캐시). 남는 쪽은 회색 '시스템'
    static func memory(_ s: Resource.Sample) -> Metric {
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        return Metric(kind: .memory, slices: Resource.slices(items(s) { Double($0.memBytes) }, whole: total, filled: total * s.memUsed / 100),
                      whole: total, restName: "시스템·그 밖의 앱")
    }

    static func appWatts(_ s: Resource.Sample) -> Double { s.everyApp.values.reduce(0) { $0 + $1.watts } }
    /// 배터리로 쓸 땐 배터리에서 끄는 전력, 전원에 꽂혀 있으면 앱들이 쓰는 전력 (추정)
    static func totalWatts(_ s: Resource.Sample) -> Double { s.watts ?? appWatts(s) }

    /// 전력: 앱별 값은 macOS 추정치. 막대 끝은 30W (넘으면 그만큼 늘린다).
    /// 배터리로 쓸 때는 실제로 끄는 전력을 채우고, 앱에 안 잡히는 몫(화면 등)은 회색으로 남긴다
    static func power(_ s: Resource.Sample) -> Metric? {
        let filled = totalWatts(s)
        guard filled > 0 else { return nil }
        let whole = max(30, filled)
        return Metric(kind: .power, slices: Resource.slices(items(s, \.watts), whole: whole, filled: filled),
                      whole: whole, restName: s.watts != nil ? "화면·시스템·그 밖의 앱" : "그 밖의 앱")
    }

    // MARK: 색

    /// 상태(초록·주황·빨강)와 헷갈리지 않게 그 셋은 뺐다
    static let palette: [NSColor] = [.systemBlue, .systemPurple, .systemPink, .systemTeal, .systemYellow, .systemIndigo, .systemBrown]
    /// 앱 → 색 번호. 앱이 켜져 있는 동안 들고 있는다
    private(set) static var colorOf: [String: Int] = [:]

    /// 지금 보이는 앱들 (앞에 있을수록 먼저) 끼리 색이 안 겹치게 정한다
    static func assignColors(_ metrics: [Metric]) {
        var keys: [String] = []
        for sl in metrics.flatMap(\.slices) where !sl.key.isEmpty && !keys.contains(sl.key) { keys.append(sl.key) }
        colorOf = Resource.assignColors(keys, current: colorOf, palette: palette.count)
    }

    static func color(_ sl: Resource.Slice, rest: NSColor) -> NSColor {
        guard !sl.key.isEmpty, let i = colorOf[sl.key], i < palette.count else { return rest }
        return palette[i]
    }

    // MARK: 글자

    /// 마우스를 올렸을 때 보이는 한 줄
    static func label(_ m: Metric, _ sl: Resource.Slice) -> String {
        let name = sl.key.isEmpty ? m.restName : sl.name
        let pct = m.whole > 0 ? sl.value / m.whole * 100 : 0
        let pctText = pct < 1 ? "1% 미만" : "\(Int(pct.rounded()))%"
        switch m.kind {
        case .cpu: return "\(name)  \(pctText) · 코어 \(Resource.cores(sl.value))개"
        case .memory: return "\(name)  \(Resource.bytes(UInt64(max(0, sl.value)))) (\(pctText))"
        case .power: return "\(name)  약 \(Resource.watts(sl.value))"
        }
    }

    /// 색 동그라미 + 글자 (대시보드처럼 글자 칸에 넣을 때)
    static func attributed(_ m: Metric, _ sl: Resource.Slice, rest: NSColor, text: NSColor, size: CGFloat) -> NSAttributedString {
        let s = NSMutableAttributedString(string: "● ", attributes: [.foregroundColor: color(sl, rest: rest), .font: NSFont.systemFont(ofSize: size)])
        s.append(NSAttributedString(string: label(m, sl), attributes: [.foregroundColor: text,
                                                                         .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .medium)]))
        return s
    }

    // MARK: 그리기

    /// 찬 부분을 둥근 막대 모양으로 잘라 두고 조각을 차례로 칠한다. 조각 사이 1pt 는 비워 경계가 보이게 한다.
    /// hover 조각이 있으면 나머지는 흐리게. 돌려주는 값은 조각마다 차지한 x 범위 (마우스 맞히기용)
    @discardableResult
    static func draw(_ m: Metric, in track: NSRect, hover: Int?, rest: NSColor) -> [ClosedRange<CGFloat>] {
        let filledW = CGFloat(m.filled) * track.width
        guard filledW > 0 else { return [] }
        let radius = track.height / 2
        NSGraphicsContext.saveGraphicsState()
        var clip = track
        clip.size.width = max(track.height, filledW)
        NSBezierPath(roundedRect: clip, xRadius: radius, yRadius: radius).addClip()
        var x = track.minX
        var spans: [ClosedRange<CGFloat>] = []
        for (i, sl) in m.slices.enumerated() {
            let w = track.width * CGFloat(sl.fraction)
            let gap: CGFloat = i < m.slices.count - 1 && w > 3 ? 1 : 0
            color(sl, rest: rest).withAlphaComponent(hover != nil && hover != i ? 0.35 : 1).setFill()
            NSRect(x: x, y: track.minY, width: max(0, w - gap), height: track.height).fill()
            spans.append(x...(x + max(w, 2)))
            x += w
        }
        NSGraphicsContext.restoreGraphicsState()
        return spans
    }
}
