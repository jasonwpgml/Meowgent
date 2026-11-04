import Foundation

/// 고양이 알림 문구·설정 표 (데이터 폴더의 phrases.json). 앱이 켤 때 빠진 키를 기본값으로 채워 쓰고,
/// 대시보드의 개선 제안을 [적용]하면 여기만 바뀐다 (다시 빌드하지 않는다). 주간 개선 제안(cat_mind)도 이 표를 읽어 보낸다.
struct PhraseTable: Equatable {
    var phrases: [String: String]
    var params: [String: Double]

    static let defaults = PhraseTable(
        phrases: [
            "done.claude": "{agent} ‘{name}’ 답 끝났다냥. 읽어 봐라냥 ✅",
            "done.codex": "Codex ‘{name}’ 일 끝났다냥. 가 봐라냥 ✅",
            "done.many": "✅ {count}개 끝났다냥. 하나씩 봐라냥",
            "context.high": "{agent} 컨텍스트 {pct}%다냥. 정리(compact)하거나 새 세션으로 넘기라냥",
            "context.half": "{agent} 컨텍스트 절반 넘었다냥 ({pct}%)",
        ],
        params: ["done.window_s": 15, "gate.normal_min": 30, "gate.urgent_min": 10,
                 "context.half_pct": 50, "context.high_pct": 80, "context.top_pct": 90])

    /// 설정마다 허용 범위 (개선 제안이 엉뚱한 값을 넣어도 이 안으로)
    static let ranges: [String: ClosedRange<Double>] = [
        "done.window_s": 0...120, "gate.normal_min": 0...240, "gate.urgent_min": 0...120,
        "context.half_pct": 30...79, "context.high_pct": 60...95, "context.top_pct": 70...99,
    ]

    /// 지금 쓰는 표 (앱 시작 때 load, 적용할 때 바뀜)
    static var current = defaults

    func phrase(_ key: String) -> String { phrases[key] ?? Self.defaults.phrases[key] ?? "" }
    func param(_ key: String) -> Double { params[key] ?? Self.defaults.params[key] ?? 0 }

    /// "{agent} ‘{name}’" + [agent: Claude, name: x] → "Claude ‘x’"
    static func fill(_ template: String, _ values: [String: String]) -> String {
        values.reduce(template) { $0.replacingOccurrences(of: "{\($1.key)}", with: $1.value) }
    }

    static func placeholders(_ s: String) -> Set<String> {
        let re = try! NSRegularExpression(pattern: #"\{\w+\}"#)
        return Set(re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { Range($0.range, in: s).map { String(s[$0]) } })
    }

    /// 바꿔도 되는 값이면 정리한 값, 아니면 nil (모르는 키, 자리표시가 빠진 문구, 숫자가 아닌 설정)
    static func validate(kind: String, key: String, value: String) -> String? {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case "phrase":
            guard let cur = defaults.phrases[key], !v.isEmpty, placeholders(cur).isSubset(of: placeholders(v)) else { return nil }
            return v
        case "param":
            guard let range = ranges[key], let d = Double(v) else { return nil }
            return String(min(max(d, range.lowerBound), range.upperBound))
        default:
            return nil
        }
    }

    /// 파일에서 읽고 빠진 키는 기본값으로 채워 다시 쓴다
    static func load(dir: URL) -> PhraseTable {
        let url = dir.appendingPathComponent("phrases.json")
        var t = defaults
        if let d = try? Data(contentsOf: url), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            for (k, v) in o["phrases"] as? [String: String] ?? [:] where validate(kind: "phrase", key: k, value: v) != nil { t.phrases[k] = v }
            for (k, v) in o["params"] as? [String: Double] ?? [:] {
                if let s = validate(kind: "param", key: k, value: String(v)), let d = Double(s) { t.params[k] = d }
            }
        }
        t.save(dir: dir)
        return t
    }

    func save(dir: URL) {
        let o: [String: Any] = ["phrases": phrases, "params": params]
        guard let d = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? d.write(to: dir.appendingPathComponent("phrases.json"), options: .atomic)
    }

    /// 개선 제안 하나를 적용한다. 성공하면 true (current 와 파일이 같이 바뀐다)
    static func apply(kind: String, key: String, value: String, dir: URL) -> Bool {
        guard let v = validate(kind: kind, key: key, value: value) else { return false }
        var t = current
        if kind == "phrase" { t.phrases[key] = v } else if let d = Double(v) { t.params[key] = d }
        current = t
        t.save(dir: dir)
        return true
    }
}

/// 고양이가 말을 덜·한결같이 하게 하는 순수 규칙 (Tests/logic). 말투는 pet/docs/CAT_VOICE.md 의 "~다냥", 문구는 PhraseTable.
/// - 답 끝남: 짧은 사이에 여럿 끝나면 한 마디로 묶는다.
/// - 컨텍스트: 대화마다 절반·높음·꼭대기 단계에서 한 번씩만.
/// - Gate: 숫자만 다른 같은 알림은 잠깐 다시 말하지 않는다.
enum NoticeBatch {
    /// 끝난 대화 하나. agent 는 "Claude" 또는 "Codex"
    struct Done: Equatable {
        let agent: String
        let name: String
    }

    /// 여러 개는 첫 줄에 개수, 둘째 줄에 이름들 (4개 넘으면 "외 N개")
    static func doneLine(_ items: [Done], table t: PhraseTable = PhraseTable.current) -> String? {
        guard let first = items.first else { return nil }
        if items.count == 1 {
            return PhraseTable.fill(t.phrase(first.agent == "Codex" ? "done.codex" : "done.claude"), ["agent": first.agent, "name": first.name])
        }
        let names = items.prefix(4).map { "\($0.agent) ‘\($0.name)’" }.joined(separator: " · ")
        let more = items.count > 4 ? " 외 \(items.count - 4)개" : ""
        return PhraseTable.fill(t.phrase("done.many"), ["count": "\(items.count)"]) + "\n" + names + more
    }

    /// 알릴 단계: 절반(조용히) · 높음 · 꼭대기 (급함). 그 아래는 0
    static func contextStep(_ pct: Int, table t: PhraseTable = PhraseTable.current) -> Int {
        let top = Int(t.param("context.top_pct")), high = Int(t.param("context.high_pct")), half = Int(t.param("context.half_pct"))
        return pct >= top ? top : pct >= high ? high : pct >= half ? half : 0
    }

    static func contextLine(agent: String, pct: Int, step: Int, table t: PhraseTable = PhraseTable.current) -> String {
        PhraseTable.fill(t.phrase(step >= Int(t.param("context.high_pct")) ? "context.high" : "context.half"), ["agent": agent, "pct": "\(pct)"])
    }

    /// 같은 알림(첫 줄에서 숫자만 지우면 같은 것)을 다시 말해도 되나. 쉬는 시간은 표의 gate.normal_min / gate.urgent_min
    struct Gate {
        private var last: [String: Double] = [:]
        private let fixed: (normal: Double, urgent: Double)?

        /// 시험용으로 쉬는 시간(초)을 고정할 수 있다. 없으면 PhraseTable.current 를 그때그때 읽는다
        init(normal: Double? = nil, urgent: Double? = nil) {
            fixed = normal.map { ($0, urgent ?? $0) }
        }

        static func key(_ text: String) -> String {
            let first = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
            return first.replacingOccurrences(of: #"\d+"#, with: "#", options: .regularExpression)
        }

        mutating func allow(_ text: String, urgent isUrgent: Bool, now: Double) -> Bool {
            let t = PhraseTable.current
            let normal = fixed?.normal ?? t.param("gate.normal_min") * 60
            let urgent = fixed?.urgent ?? t.param("gate.urgent_min") * 60
            let k = Self.key(text)
            if let at = last[k], now - at < (isUrgent ? urgent : normal) { return false }
            last[k] = now
            if last.count > 500 { last = last.filter { now - $0.value < normal } }
            return true
        }
    }
}
