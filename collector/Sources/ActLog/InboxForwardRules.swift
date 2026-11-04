import Foundation

/// InboxForwardRules: 고양이 inbox 항목 중 `"forward": "grokbot"` 이 붙은 할일을 Grok Bot 자동화 웹훅으로 넘길 때의 판단.
/// 무엇을 보낼지 · 보낼 본문 · 실패하면 언제 다시 보낼지. 보내기(네트워크·파일)는 InboxForward.swift. 형식은 docs/INBOX.md
enum InboxForwardRules {
    static let target = "grokbot"
    /// 한 항목을 이만큼 실패하면 더 보내지 않는다 (마지막 간격까지 합쳐 약 하루)
    static let maxTries = 10
    /// 한 번 읽을 때(10초) 이만큼까지만 보낸다. 웹훅 한 번이 Grok Bot 사용량을 쓰므로 한꺼번에 쏟지 않는다
    static let perTick = 3
    /// 한 시간에 이만큼까지만 보낸다 (Grok Bot 쪽 한도는 루틴당 200/시간)
    static let perHour = 30
    /// 보낸 기록은 이만큼 지나면 지운다
    static let keepDays: Double = 40

    struct Hook: Equatable { let url: URL; let key: String }

    /// 웹훅 파일 `{ "url", "key" }` → https 주소와 키가 다 있을 때만 (http 는 이 맥 안의 시험용 서버만)
    static func hook(_ o: [String: Any]?) -> Hook? {
        guard let o, let s = o["url"] as? String, let url = URL(string: s.trimmingCharacters(in: .whitespaces)), let host = url.host,
              url.scheme == "https" || (url.scheme == "http" && ["127.0.0.1", "localhost", "::1"].contains(host)),
              let key = (o["key"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty, !key.hasPrefix("PASTE_") else { return nil }
        return Hook(url: url, key: key.hasPrefix("Bearer ") ? String(key.dropFirst(7)) : key)
    }

    /// 항목 하나의 보낸 기록
    struct State: Equatable {
        var sent: Double?           // 보낸 시각
        var run: String?            // Grok Bot이 돌려준 실행 id
        var tries = 0
        var next: Double = 0        // 다음에 다시 보낼 시각
        var error: String?
        var first: Double           // 처음 본 시각 (기록 정리용)

        init(first: Double) { self.first = first }
        init?(_ o: [String: Any]) {
            guard let first = o["first"] as? Double else { return nil }
            self.first = first
            sent = o["sent"] as? Double
            run = o["run"] as? String
            tries = o["tries"] as? Int ?? 0
            next = o["next"] as? Double ?? 0
            error = o["error"] as? String
        }
        var json: [String: Any] {
            var o: [String: Any] = ["first": first, "tries": tries, "next": next]
            if let sent { o["sent"] = sent }
            if let run { o["run"] = run }
            if let error { o["error"] = error }
            return o
        }
        var gaveUp: Bool { sent == nil && tries >= InboxForwardRules.maxTries }
    }

    /// 넘길 항목인가: 할일(todo)이고 forward 가 grokbot, 글이 있음
    static func wants(_ o: [String: Any]) -> Bool {
        guard (o["forward"] as? String)?.lowercased() == target, (o["kind"] as? String ?? "todo") == "todo" else { return false }
        return !((o["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    /// 지금 보낼 차례인가 (이미 보냈거나, 포기했거나, 다시 보낼 시각 전이면 아니다)
    static func due(_ s: State?, now: Double) -> Bool {
        guard let s else { return true }
        return s.sent == nil && !s.gaveUp && now >= s.next
    }

    /// 실패 뒤 다시 보낼 때까지: 1분 · 5분 · 15분 · 30분 · 그다음은 1시간·2시간·4시간 (최대 4시간)
    static func retryDelay(tries: Int) -> Double {
        let steps: [Double] = [60, 300, 900, 1800, 3600, 7200]
        return tries <= 0 ? 0 : (tries <= steps.count ? steps[tries - 1] : 14400)
    }

    /// 실패를 적는다. 400·401·403·404 는 설정(키·루틴) 문제라 빨리 다시 해도 소용없으니 30분부터
    static func failed(_ s: State, status: Int?, error: String, now: Double) -> State {
        var s = s
        s.tries += 1
        s.error = error
        var wait = retryDelay(tries: s.tries)
        if let status, [400, 401, 403, 404].contains(status) { wait = max(wait, 1800) }
        s.next = now + wait
        return s
    }

    static func succeeded(_ s: State, run: String?, now: Double) -> State {
        var s = s
        s.sent = now
        s.run = run
        s.error = nil
        return s
    }

    /// 한 시간 안에 보낸 수
    static func sentLastHour(_ states: [String: State], now: Double) -> Int {
        states.values.filter { ($0.sent ?? 0) > now - 3600 }.count
    }

    /// 기록 정리: 처음 본 지 keepDays 지났고 inbox·done 어디에도 없는 항목
    static func prune(_ states: [String: State], present: Set<String>, now: Double) -> [String: State] {
        states.filter { present.contains($0.key) || now - $0.value.first < keepDays * 86400 }
    }

    /// 밖으로 나가는 글: 앞뒤 공백을 떼고, 키·카드번호 같은 것은 가리고(Privacy.redact), 길이를 자른다
    static func clean(_ v: Any?, max: Int) -> String? {
        guard let s = (v as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        let r = Privacy.redact(s).0
        return r.count > max ? String(r.prefix(max)) + "…" : r
    }
    static let maxText = 300, maxDetail = 2000

    /// 사람이 읽는 한 줄 + 세부. Grok Bot 루틴은 본문 전체를 받지만 Grok Bot 앱이 보내는 모양(`context`)도 맞춘다
    static func context(_ o: [String: Any], machine: String, zone: TimeZone = .current) -> String {
        var lines = ["할일: " + (clean(o["text"], max: maxText) ?? "")]
        if let d = clean(o["detail"], max: maxDetail) { lines.append("설명: " + d) }
        if let due = o["due"] as? Double { lines.append("마감: " + shortTime(due, zone: zone)) }
        if o["level"] as? String == "red" { lines.append("급함") }
        if let u = o["url"] as? String, u.hasPrefix("http") { lines.append("링크: " + u) }
        let from = (o["source"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "?"
        lines.append("보낸 곳: \(from) (\(machine), 묘전트 경유)")
        return lines.joined(separator: "\n")
    }

    /// POST 본문. 코드·대화 내용은 넣지 않고 inbox 항목에 적힌 것만
    static func body(_ o: [String: Any], id: String, machine: String, zone: TimeZone = .current) -> [String: Any] {
        var b: [String: Any] = ["source": "meowgent", "kind": "todo", "id": id, "machine": machine,
                                "text": clean(o["text"], max: maxText) ?? "",
                                "from": o["source"] as? String ?? "", "level": o["level"] as? String == "red" ? "red" : "yellow",
                                "context": context(o, machine: machine, zone: zone)]
        if let d = clean(o["detail"], max: maxDetail) { b["detail"] = d }
        if let due = o["due"] as? Double { b["due"] = iso(due) }
        if let u = o["url"] as? String, u.hasPrefix("http") { b["url"] = u }
        if let c = o["created"] as? Double { b["created"] = iso(c) }
        return b
    }

    static func iso(_ t: Double) -> String { ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: t)) }

    /// 11/5 (수) 18:00
    static func shortTime(_ t: Double, zone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.timeZone = zone
        f.dateFormat = "M/d (E) HH:mm"
        return f.string(from: Date(timeIntervalSince1970: t))
    }
}
