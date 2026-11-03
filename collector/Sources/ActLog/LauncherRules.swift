import CoreGraphics
import Foundation

/// 런처의 순수 규칙: 검색 점수(한글 초성·한영 전환 오타 포함), 자주 쓴 정도, 계산기, 창 배치 계산.
/// 화면·권한 없이 테스트한다 (Tests/logic).
enum LauncherRules {

    // MARK: 검색 점수

    /// 이름 하나와 검색어의 점수 (클수록 앞). 안 맞으면 nil.
    /// 검색어는 그대로 · 한글 자판으로 친 영문(초개ㅡㄷ → chrome) · 초성(ㅋㄹ → 크롬)으로 각각 맞춰 보고 가장 높은 점수를 쓴다.
    static func score(_ name: String, _ query: String) -> Double? {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return nil }
        let n = name.lowercased()
        var best = plainScore(n, q)
        if q.contains(where: isHangul) {
            let typed = qwerty(q)
            if typed != q, let s = plainScore(n, typed) { best = max(best ?? 0, s - 5) }
        }
        if q.allSatisfy(isConsonantJamo), let s = plainScore(chosung(n), q) {
            best = max(best ?? 0, s - 10)
        }
        return best
    }

    private static func plainScore(_ n: String, _ q: String) -> Double? {
        if n == q { return 100 }
        if n.hasPrefix(q) { return 90 - Double(min(n.count - q.count, 20)) * 0.2 }
        let words = n.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" || $0 == "." })
        if words.contains(where: { $0.hasPrefix(q) }) { return 75 }
        if n.contains(q) { return 60 }
        // 글자가 순서대로만 들어 있으면 (vsc → visual studio code). 붙어 있을수록 높게
        var it = n.makeIterator()
        var gaps = 0
        for c in q {
            var found = false
            while let x = it.next() {
                if x == c { found = true; break }
                gaps += 1
            }
            if !found { return nil }
        }
        return max(20, 45 - Double(gaps))
    }

    /// 자주·최근에 연 것에 더하는 점수 (0~20). 열 때마다 count +1, 2주가 지나면 반으로 준다
    static func frecency(count: Int, lastUsed: Double, now: Double) -> Double {
        guard count > 0 else { return 0 }
        let days = max(0, now - lastUsed) / 86400
        return min(20, log2(Double(count) + 1) * 6) * pow(0.5, days / 14)
    }

    // MARK: 한글

    private static let initials = ["ㄱ", "ㄲ", "ㄴ", "ㄷ", "ㄸ", "ㄹ", "ㅁ", "ㅂ", "ㅃ", "ㅅ", "ㅆ", "ㅇ", "ㅈ", "ㅉ", "ㅊ", "ㅋ", "ㅌ", "ㅍ", "ㅎ"]
    /// 두벌식 자판에서 각 자모가 놓인 영문 키
    private static let initialKeys = ["r", "R", "s", "e", "E", "f", "a", "q", "Q", "t", "T", "d", "w", "W", "c", "z", "x", "v", "g"]
    private static let medialKeys = ["k", "o", "i", "O", "j", "p", "u", "P", "h", "hk", "ho", "hl", "y", "n", "nj", "np", "nl", "b", "m", "ml", "l"]
    private static let finalKeys = ["", "r", "R", "rt", "s", "sw", "sg", "e", "f", "fr", "fa", "fq", "ft", "fx", "fv", "fg",
                                    "a", "q", "qt", "t", "T", "d", "w", "c", "z", "x", "v", "g"]
    /// 낱자(ㄱ~ㅣ, U+3131~U+3163) → 영문 키
    private static let jamoKeys: [Character: String] = {
        let s = "ㄱㄲㄳㄴㄵㄶㄷㄸㄹㄺㄻㄼㄽㄾㄿㅀㅁㅂㅃㅄㅅㅆㅇㅈㅉㅊㅋㅌㅍㅎㅏㅐㅑㅒㅓㅔㅕㅖㅗㅘㅙㅚㅛㅜㅝㅞㅟㅠㅡㅢㅣ"
        let keys = ["r", "R", "rt", "s", "sw", "sg", "e", "E", "f", "fr", "fa", "fq", "ft", "fx", "fv", "fg", "a", "q", "Q", "qt",
                    "t", "T", "d", "w", "W", "c", "z", "x", "v", "g",
                    "k", "o", "i", "O", "j", "p", "u", "P", "h", "hk", "ho", "hl", "y", "n", "nj", "np", "nl", "b", "m", "ml", "l"]
        return Dictionary(uniqueKeysWithValues: zip(s, keys))
    }()

    static func isHangul(_ c: Character) -> Bool {
        guard let v = c.unicodeScalars.first?.value else { return false }
        return (0xAC00...0xD7A3).contains(v) || (0x3131...0x3163).contains(v)
    }

    static func isConsonantJamo(_ c: Character) -> Bool {
        guard let v = c.unicodeScalars.first?.value else { return false }
        return (0x3131...0x314E).contains(v)
    }

    /// 한글 자판 상태로 영문을 쳤을 때 나온 글을 원래 영문으로 (초개ㅡㄷ → chrome)
    static func qwerty(_ s: String) -> String {
        var out = ""
        for c in s {
            guard let v = c.unicodeScalars.first?.value else { continue }
            if (0xAC00...0xD7A3).contains(v) {
                let i = Int(v - 0xAC00)
                out += initialKeys[i / 588] + medialKeys[(i % 588) / 28] + finalKeys[i % 28]
            } else if let k = jamoKeys[c] {
                out += k
            } else {
                out.append(c)
            }
        }
        return out.lowercased()
    }

    /// 글자마다 초성만 (크롬 → ㅋㄹ). 한글이 아닌 글자는 그대로
    static func chosung(_ s: String) -> String {
        String(s.map { c -> Character in
            guard let v = c.unicodeScalars.first?.value, (0xAC00...0xD7A3).contains(v) else { return c }
            return Character(initials[Int(v - 0xAC00) / 588])
        })
    }

    // MARK: 계산기

    /// "12*(3+4)/2" 같은 식이면 결과, 아니면 nil. 숫자만 하나 있거나 연산자가 없으면 식으로 보지 않는다.
    static func calculate(_ input: String) -> Double? {
        let s = input.replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: ",", with: "").replacingOccurrences(of: " ", with: "")
        guard !s.isEmpty, s.allSatisfy({ "0123456789.+-*/^()".contains($0) }),
              s.dropFirst().contains(where: { "+-*/^".contains($0) }) else { return nil }
        var p = Calc(Array(s))
        guard let v = p.expression(), p.pos == p.chars.count, v.isFinite else { return nil }
        return v
    }

    /// 계산 결과를 복사하기 좋은 글로 (자릿수 쉼표 없이, 소수 10자리까지)
    static func format(_ v: Double) -> String {
        if v == v.rounded(), abs(v) < 1e15 { return String(Int64(v)) }
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.maximumFractionDigits = 10
        f.usesGroupingSeparator = false
        return f.string(from: NSNumber(value: v)) ?? String(v)
    }

    /// 사칙연산·거듭제곱·괄호 (재귀 하강). ^ 는 오른쪽부터 묶는다
    private struct Calc {
        let chars: [Character]
        var pos = 0
        init(_ c: [Character]) { chars = c }

        mutating func expression() -> Double? {
            guard var v = term() else { return nil }
            while pos < chars.count, chars[pos] == "+" || chars[pos] == "-" {
                let op = chars[pos]; pos += 1
                guard let r = term() else { return nil }
                v = op == "+" ? v + r : v - r
            }
            return v
        }

        mutating func term() -> Double? {
            guard var v = power() else { return nil }
            while pos < chars.count, chars[pos] == "*" || chars[pos] == "/" {
                let op = chars[pos]; pos += 1
                guard let r = power() else { return nil }
                if op == "/" && r == 0 { return nil }
                v = op == "*" ? v * r : v / r
            }
            return v
        }

        mutating func power() -> Double? {
            guard let b = unary() else { return nil }
            if pos < chars.count, chars[pos] == "^" {
                pos += 1
                guard let e = power() else { return nil }
                return pow(b, e)
            }
            return b
        }

        mutating func unary() -> Double? {
            if pos < chars.count, chars[pos] == "-" { pos += 1; return unary().map { -$0 } }
            if pos < chars.count, chars[pos] == "+" { pos += 1; return unary() }
            return atom()
        }

        mutating func atom() -> Double? {
            guard pos < chars.count else { return nil }
            if chars[pos] == "(" {
                pos += 1
                guard let v = expression(), pos < chars.count, chars[pos] == ")" else { return nil }
                pos += 1
                return v
            }
            let start = pos
            while pos < chars.count, chars[pos].isNumber || chars[pos] == "." { pos += 1 }
            return pos > start ? Double(String(chars[start..<pos])) : nil
        }
    }

    // MARK: 창 배치

    enum Layout: String, CaseIterable {
        case left, right, top, bottom, maximize, center

        var title: String {
            switch self {
            case .left: "창을 왼쪽 반으로"
            case .right: "창을 오른쪽 반으로"
            case .top: "창을 위쪽 반으로"
            case .bottom: "창을 아래쪽 반으로"
            case .maximize: "창을 화면 가득"
            case .center: "창을 가운데로"
            }
        }

        /// 검색어로 찾을 이름들 (한글·영문)
        var keywords: [String] {
            switch self {
            case .left: ["왼쪽", "left half"]
            case .right: ["오른쪽", "right half"]
            case .top: ["위쪽", "top half"]
            case .bottom: ["아래쪽", "bottom half"]
            case .maximize: ["최대화", "전체", "maximize"]
            case .center: ["가운데", "중앙", "center"]
            }
        }
    }

    /// 화면의 쓸 수 있는 영역(visible)에서 배치할 창 틀. 좌표계는 visible 과 같다 (y가 위로 커지는 Cocoa 좌표)
    /// center 는 지금 크기를 지키되 화면보다 크면 줄인다.
    static func frame(_ layout: Layout, visible v: CGRect, current: CGSize) -> CGRect {
        let w2 = (v.width / 2).rounded(), h2 = (v.height / 2).rounded()
        switch layout {
        case .left: return CGRect(x: v.minX, y: v.minY, width: w2, height: v.height)
        case .right: return CGRect(x: v.maxX - w2, y: v.minY, width: w2, height: v.height)
        case .top: return CGRect(x: v.minX, y: v.maxY - h2, width: v.width, height: h2)
        case .bottom: return CGRect(x: v.minX, y: v.minY, width: v.width, height: h2)
        case .maximize: return v
        case .center:
            let w = min(current.width, v.width), h = min(current.height, v.height)
            return CGRect(x: (v.midX - w / 2).rounded(), y: (v.midY - h / 2).rounded(), width: w, height: h)
        }
    }

    /// Cocoa 좌표(왼쪽 아래 원점) 틀 → 손쉬운 사용 좌표(주 화면 왼쪽 위 원점)의 왼쪽 위 점
    static func axOrigin(_ r: CGRect, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: r.minX, y: primaryHeight - r.maxY)
    }
}
