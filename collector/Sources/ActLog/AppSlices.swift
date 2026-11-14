import AppKit

/// 맥 상태 카드(메뉴)와 대시보드(자세히)가 같이 쓰는 앱별 색 막대.
/// 어느 쪽에서 보든 같은 앱은 같은 색이 되게 색 배정도 여기 한 곳에서 들고 있는다.
enum AppSlices {
    enum Kind { case cpu, memory, power, gpu }

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

    /// GPU: 내장 GPU 일 때만 앱별로 나눈다 (따로 단 GPU 는 nil → 한 색 막대). 막대 끝은 100%.
    /// 앱 목록에 없는 시스템 프로세스(화면 그리기 등)도 따로 조각을 받는다
    static func gpu(_ s: Resource.Sample) -> Metric? {
        guard s.gpuBuiltIn, let g = s.gpu else { return nil }
        let others = s.gpuOthers.map { (key: "gpu:" + $0.key, name: $0.key, value: $0.value) }
        return Metric(kind: .gpu, slices: Resource.slices(items(s, \.gpu) + others, whole: 100, filled: g),
                      whole: 100, restName: "그 밖의 앱·시스템")
    }

    static func appWatts(_ s: Resource.Sample) -> Double { s.everyApp.values.reduce(0) { $0 + $1.watts } }
    /// 맥 전체가 쓰는 전력: 배터리로 쓸 땐 배터리에서 끄는 전력, 전원에 꽂혀 있으면 맥이 재는 시스템 전력,
    /// 둘 다 모르면 (배터리 없는 맥) 앱들이 쓰는 전력 추정
    static func totalWatts(_ s: Resource.Sample) -> Double { s.watts ?? s.power?.systemW ?? appWatts(s) }
    /// 맥이 직접 잰 값인지 (아니면 앱별 추정의 합)
    static func measured(_ s: Resource.Sample) -> Bool { s.watts != nil || s.power?.systemW != nil }

    /// 전력 줄 오른쪽 숫자와 설명. 전원 연결 중에 충전하고 있으면 "소모 / 충전" 과 충전기 최대 W.
    /// 충전하지 않을 때 (꽉 찼거나 macOS 가 배터리 보호로 멈춤) 는 "0W" 대신 소모만 보이고 설명에 그 상태를 적는다
    static func powerTexts(_ s: Resource.Sample) -> (value: String, detail: String) {
        if let w = s.watts { return (Resource.watts(w), "배터리에서 끄는 전력 · 앱별은 추정") }
        if let p = s.power, let sys = p.systemW {
            let adapter = p.adapterW.map { " · 충전기 최대 \($0)W" } ?? ""
            if let charge = p.chargeW, charge >= 0.05 {
                return ("\(Resource.watts(sys)) / \(Resource.watts(charge))", "소모 / 충전" + adapter)
            }
            let state = (s.battery?.percent ?? 0) >= 99 ? "완충" : "충전 안 함 (배터리 보호 등)"
            return (Resource.watts(sys), "소모 · " + state + adapter)
        }
        return ("약 " + Resource.watts(appWatts(s)), "앱들이 쓰는 전력 (추정)")
    }

    /// 전력: 앱별 값은 macOS 추정치. 막대 끝은 30W (넘으면 그만큼 늘린다).
    /// 배터리로 쓸 때는 실제로 끄는 전력을 채우고, 앱에 안 잡히는 몫(화면 등)은 회색으로 남긴다
    static func power(_ s: Resource.Sample) -> Metric? {
        let filled = totalWatts(s)
        guard filled > 0 else { return nil }
        let whole = max(30, filled)
        return Metric(kind: .power, slices: Resource.slices(items(s, \.watts), whole: whole, filled: filled),
                      whole: whole, restName: measured(s) ? "화면·시스템·그 밖의 앱" : "그 밖의 앱")
    }

    // MARK: 색

    /// 차분한 보석 톤 다섯 가지 (파랑·브론즈·청록·와인·보라). 상태색(초록·주황·빨강)과 겹치지 않게 골랐고,
    /// 밝은·어두운 바탕 모두에서 어느 두 색을 붙여도 색약 시뮬레이션 ΔE 13 이상 (dataviz 검사기, 모든 쌍 기준).
    /// 어두운 쪽은 같은 색을 어두운 바탕에 맞춰 조금 밝힌 값이다.
    static let palette: [NSColor] = [
        dynamic(light: 0x5185E9, dark: 0x578CF0), dynamic(light: 0x977017, dark: 0x9E7620), dynamic(light: 0x25A897, dark: 0x20A594),
        dynamic(light: 0x853750, dark: 0x9E3B5D), dynamic(light: 0x6D41A9, dark: 0x7347AF),
    ]
    private static func dynamic(light: Int, dark: Int) -> NSColor {
        func rgb(_ v: Int) -> NSColor {
            NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        }
        return NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? rgb(dark) : rgb(light) }
    }
    /// 앱 → 색 번호. 앱이 켜져 있는 동안 들고 있는다 (메뉴 카드·대시보드 같이)
    private(set) static var colorOf: [String: Int] = [:]

    /// 한 화면의 막대들을 그리기 전에: 색은 몫이 큰 앱 다섯까지만 주고 나머지는 '기타'로 합친 뒤 색을 정한다.
    /// 돌려주는 legend 는 색을 받은 앱 (몫이 큰 순)
    static func prepare(_ metrics: [Metric]) -> (legend: [(key: String, name: String)], metrics: [Metric]) {
        let folded = Resource.fold(metrics.map(\.slices), keep: palette.count)
        var out = metrics
        for i in out.indices { out[i].slices = folded.bars[i] }
        colorOf = Resource.assignColors(folded.keys, current: colorOf, palette: palette.count)
        let names = Dictionary(metrics.flatMap(\.slices).map { ($0.key, $0.name) }, uniquingKeysWith: { a, _ in a })
        return (folded.keys.map { ($0, names[$0] ?? $0) }, out)
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
        case .gpu: return "\(name)  \(pctText)"
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

    /// 바깥 끝만 둥근 막대 하나 안에 조각을 차례로 놓는다. 조각 사이와 빈 칸 앞은 2pt 를 비워 바탕이 보이게 한다
    /// (테두리를 그리지 않고 틈으로 나눈다). hover 조각이 있으면 나머지는 흐리게.
    /// 돌려주는 값은 조각마다 차지한 x 범위 (마우스 맞히기용)
    @discardableResult
    static func draw(_ m: Metric, in track: NSRect, hover: Int?, rest: NSColor, empty: NSColor) -> [ClosedRange<CGFloat>] {
        let gap: CGFloat = 2
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: track, xRadius: track.height / 2, yRadius: track.height / 2).addClip()
        var x = track.minX
        var spans: [ClosedRange<CGFloat>] = []
        for (i, sl) in m.slices.enumerated() {
            let w = track.width * CGFloat(sl.fraction)
            let atEnd = x + w >= track.maxX - 0.5
            let drawn = w > gap * 2 && !atEnd ? w - gap : w      // 아주 얇은 조각·끝까지 찬 조각은 틈을 두지 않는다
            // 흐리게 할 땐 색의 알파를 바꾸지 않고 그리기 알파를 곱한다 ('기타'처럼 원래 반투명인 색이 진해지지 않게)
            let ctx = NSGraphicsContext.current?.cgContext
            ctx?.saveGState()
            if hover != nil && hover != i { ctx?.setAlpha(0.4) }
            color(sl, rest: rest).setFill()
            NSRect(x: x, y: track.minY, width: max(0, drawn), height: track.height).fill()
            ctx?.restoreGState()
            spans.append(x...(x + max(w, 2)))
            x += w
        }
        // 빈 칸: 마지막 조각 뒤 틈(이미 비워 둠) 다음부터 끝까지
        if x < track.maxX - 1 {
            empty.setFill()
            NSRect(x: x, y: track.minY, width: track.maxX - x, height: track.height).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        return spans
    }
}
