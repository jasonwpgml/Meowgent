import Foundation

/// 피드백·메모는 줄 단위 JSON으로 쌓는다 (brain이 나중에 읽어 규칙 학습에 씀).
enum PetJournal {
    static func append(_ dir: URL, _ file: String, _ obj: [String: Any]) {
        var o = obj
        o["ts"] = Date().timeIntervalSince1970
        guard let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]),
              var line = String(data: d, encoding: .utf8) else { return }
        line += "\n"
        let url = dir.appendingPathComponent(file)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
            chmod(url.path, 0o600)
        }
    }

    /// "내일 오후 3시 회의" → 날짜. 맥 기본 인식기 + "N일/시간 후" 보완.
    static func detectDate(_ text: String) -> Date? {
        if let m = text.range(of: #"(\d+)\s*(일|시간|분)\s*(후|뒤)"#, options: .regularExpression) {
            let s = String(text[m])
            let n = Double(s.prefix { $0.isNumber }) ?? 0
            let unit: Double = s.contains("일") ? 86400 : (s.contains("시간") ? 3600 : 60)
            return Date().addingTimeInterval(n * unit)
        }
        guard let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
              let r = det.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              var d = r.date else { return nil }
        // 지난 날짜로 읽히면 1주 뒤로 ("이번 주 금요일"이 지난 금요일로 잡히는 문제)
        while d < Date().addingTimeInterval(-3600) { d = d.addingTimeInterval(7 * 86400) }
        return d
    }
}
