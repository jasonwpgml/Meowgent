import Foundation

/// 클립보드 기록의 순수 규칙: 종류 나누기 · 색 읽기 · 보관 기간 정리 · 검색. 화면·권한 없이 테스트한다 (Tests/logic).
enum ClipRules {
    enum Kind: String, Codable, CaseIterable {
        case text, link, color, image, file

        var title: String {
            switch self {
            case .text: "글"
            case .link: "링크"
            case .color: "색"
            case .image: "이미지"
            case .file: "파일"
            }
        }
    }

    /// 글 하나의 종류: 주소 하나면 링크, #RRGGBB·rgb(…) 하나면 색, 아니면 글
    static func classify(_ text: String) -> Kind {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if color(t) != nil { return .color }
        if !t.contains(where: \.isWhitespace), t.range(of: #"^https?://[^\s/$.?#].[^\s]*$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return .link
        }
        return .text
    }

    /// "#3a7bd5", "3A7BD5", "#fff", "rgb(58, 123, 213)" → 0~1 RGB
    static func color(_ s: String) -> (r: Double, g: Double, b: Double)? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let m = t.range(of: #"^rgba?\(\s*(\d{1,3})\s*,\s*(\d{1,3})\s*,\s*(\d{1,3})\s*(,\s*[\d.]+\s*)?\)$"#, options: .regularExpression) {
            let nums = t[m].split(whereSeparator: { !$0.isNumber && $0 != "." }).prefix(3).compactMap { Double($0) }
            guard nums.count == 3, nums.allSatisfy({ $0 <= 255 }) else { return nil }
            return (nums[0] / 255, nums[1] / 255, nums[2] / 255)
        }
        var hex = t.hasPrefix("#") ? String(t.dropFirst()) : t
        // # 없는 3자리는 숫자 "123" 같은 흔한 글과 겹쳐서 색으로 보지 않는다
        guard hex.allSatisfy(\.isHexDigit), hex.count == 6 || (hex.count == 3 && t.hasPrefix("#")) else { return nil }
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard let v = UInt32(hex, radix: 16) else { return nil }
        return (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
    }

    struct Keep: Equatable {
        let id: String
        let ts: Double
        let pinned: Bool
    }

    /// 지울 항목 id: 고정한 것은 남기고, 나머지는 `days`일 지난 것과 최근 `maxCount`개 밖의 것 (days 0 = 기간 제한 없음)
    static func expired(_ items: [Keep], now: Double, days: Int, maxCount: Int) -> Set<String> {
        var out = Set<String>()
        var kept = 0
        for i in items.sorted(by: { $0.ts > $1.ts }) where !i.pinned {
            if days > 0 && now - i.ts > Double(days) * 86400 { out.insert(i.id); continue }
            kept += 1
            if kept > maxCount { out.insert(i.id) }
        }
        return out
    }

    /// 검색: 내용·이미지 속 글자·앱 이름에 모든 낱말이 들어 있나. 한글 자판으로 친 영문도 같이 본다
    static func matches(_ query: String, in fields: [String]) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        let hay = fields.joined(separator: "\n").lowercased()
        let words = q.split(separator: " ").map(String.init)
        if words.allSatisfy({ hay.contains($0) }) { return true }
        guard q.contains(where: LauncherRules.isHangul) else { return false }
        return LauncherRules.qwerty(q).split(separator: " ").allSatisfy { hay.contains($0) }
    }
}
