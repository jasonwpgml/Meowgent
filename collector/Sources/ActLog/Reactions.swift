import Foundation

/// 말풍선 하나에 붙는 반응 기록 고리. 고양이(Pet)가 보여 주고, 눌리고, 사라질 때 record 를 부른다.
/// 사건: shown 보임 · replied 답함 · detail 자세히 봄 · read 올려 두고 읽기만 함 · ignored 손대지 않고 사라짐 ·
///      cut 다른 말에 밀려 사라짐 · dropped 보여 줄 틈이 없어 버림 · rejected 👎 · muted 🔇 (그 종류는 다음 아침까지 끔)
final class NoticeTrack {
    let canMute: Bool
    let record: (String) -> Void
    init(canMute: Bool, record: @escaping (String) -> Void) {
        self.canMute = canMute
        self.record = record
    }
}

/// 말풍선마다 사용자가 어떻게 반응했는지 reactions.jsonl 에 남긴다 (실시간 업무 보조의 0단계 계측).
/// 고양이가 먼저 건 말(mind:*)은 cat_mind 가 붙인 id 를 그대로 써서 mind/decisions.jsonl 의 sid 와 이어진다.
/// 끈 종류는 muted.json 에 둔다 (cat_mind 도 읽어서 그 신호로는 Codex 를 부르지 않는다).
final class Reactions {
    private let file: URL
    private let mutedFile: URL
    private var mutes: [String: Double] = [:]
    /// 마지막으로 보인 말풍선: 대화창을 바로 열면 그 말에 답한 것으로 친다
    private var lastShown: ReactionRules.Shown?

    init(dataDir: URL) {
        file = dataDir.appendingPathComponent("reactions.jsonl")
        mutedFile = dataDir.appendingPathComponent("muted.json")
        if let d = try? Data(contentsOf: mutedFile), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Double] {
            mutes = ReactionRules.active(o, now: Date().timeIntervalSince1970)
        }
        trim()
    }

    /// src: 알림을 낸 곳 (mind·agent·quota·resource·forward·secret), kind: 끌 단위 ("mind:long_focus", "agent" …)
    func track(src: String, kind: String, text: String, id: String? = nil, canMute: Bool) -> NoticeTrack {
        let id = id ?? "n-\(Int(Date().timeIntervalSince1970 * 1000))-\(Int.random(in: 100...999))"
        var shownAt: Double?
        return NoticeTrack(canMute: canMute) { [weak self] ev in
            guard let self else { return }
            let now = Date().timeIntervalSince1970
            if ev == "shown" {
                shownAt = now
                self.lastShown = ReactionRules.Shown(id: id, src: src, kind: kind, at: now)
            } else if ReactionRules.touches(ev), self.lastShown?.id == id {
                self.lastShown?.touched = true
            }
            if ev == "muted" { self.mute(kind, now: now) }
            self.write(ReactionRules.line(id: id, ev: ev, src: src, kind: kind, text: text, shownAt: shownAt, now: now))
        }
    }

    func isMuted(_ kind: String) -> Bool {
        (mutes[kind] ?? 0) > Date().timeIntervalSince1970
    }

    /// 대화창이 열렸다: 방금(2분 안) 보인 말풍선에 손대지 않았으면 그 말에 답하러 온 것으로 친다
    func chatOpened() {
        let now = Date().timeIntervalSince1970
        guard let s = lastShown, ReactionRules.creditsChat(s, now: now) else { return }
        lastShown?.touched = true
        write(ReactionRules.line(id: s.id, ev: "replied", src: s.src, kind: s.kind, text: nil, shownAt: s.at, now: now, via: "chat"))
    }

    private func mute(_ kind: String, now: Double) {
        mutes = ReactionRules.active(mutes, now: now)
        mutes[kind] = ReactionRules.muteUntil(now: Date(timeIntervalSince1970: now)).timeIntervalSince1970
        guard let d = try? JSONSerialization.data(withJSONObject: mutes, options: [.sortedKeys]) else { return }
        try? d.write(to: mutedFile, options: .atomic)
        chmod(mutedFile.path, 0o600)
        Log.write("말풍선 끔: \(kind) (내일 아침까지)")
    }

    private func write(_ o: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]),
              let line = String(data: d, encoding: .utf8) else { return }
        let data = Data((line + "\n").utf8)
        if let h = try? FileHandle(forWritingTo: file) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: file, options: .atomic)
            chmod(file.path, 0o600)
        }
    }

    /// 켤 때 한 번: 최근 maxLines 줄만 남긴다
    private func trim() {
        guard let s = try? String(contentsOf: file, encoding: .utf8) else { return }
        let lines = s.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count > ReactionRules.maxLines else { return }
        let keep = lines.suffix(ReactionRules.maxLines).joined(separator: "\n") + "\n"
        try? keep.write(to: file, atomically: true, encoding: .utf8)
        chmod(file.path, 0o600)
    }
}

/// 반응 기록의 순수 규칙 (Tests/logic 에서 점검)
enum ReactionRules {
    static let maxLines = 20_000
    static let chatWindow: Double = 120     // 말풍선이 보인 뒤 이만큼 안에 대화창을 열면 답한 것으로 친다
    static let morningHour = 6

    struct Shown: Equatable {
        let id: String
        let src: String
        let kind: String
        let at: Double
        var touched = false
    }

    /// 사용자가 손을 댄 사건 (이 뒤로는 대화창을 열어도 다시 세지 않는다)
    static func touches(_ ev: String) -> Bool { ["replied", "detail", "rejected", "muted"].contains(ev) }

    static func creditsChat(_ s: Shown, now: Double) -> Bool {
        !s.touched && s.src == "mind" && now - s.at <= chatWindow && now >= s.at
    }

    /// 다가오는 아침 6시 (새벽 2시에 끄면 그날 6시, 저녁에 끄면 다음 날 6시)
    static func muteUntil(now: Date, cal: Calendar = .current) -> Date {
        let six = cal.date(bySettingHour: morningHour, minute: 0, second: 0, of: now)!
        return six > now ? six : cal.date(byAdding: .day, value: 1, to: six)!
    }

    static func active(_ m: [String: Double], now: Double) -> [String: Double] { m.filter { $0.value > now } }

    static func line(id: String, ev: String, src: String, kind: String, text: String?, shownAt: Double?, now: Double, via: String? = nil) -> [String: Any] {
        var o: [String: Any] = ["ts": now, "id": id, "ev": ev, "src": src, "kind": kind]
        if let t = text, ev == "shown" { o["text"] = String(t.replacingOccurrences(of: "\n", with: " / ").prefix(160)) }
        if let s = shownAt, ev != "shown" { o["after"] = (max(0, now - s) * 10).rounded() / 10 }
        if let via { o["via"] = via }
        return o
    }

    /// 한 말풍선의 사건들 → 대표 반응 하나 (강한 것부터)
    static let order = ["muted", "rejected", "replied", "detail", "read", "ignored", "cut", "dropped", "shown"]
    static let ko = ["muted": "🔇 끔", "rejected": "👎 아니다", "replied": "답함", "detail": "자세히 봄", "read": "읽기만 함",
                     "ignored": "무시", "cut": "다른 말에 밀림", "dropped": "못 보여 줌", "shown": "보이는 중"]

    static func summary(_ events: [String]) -> String? {
        order.first { events.contains($0) }
    }

    /// reactions.jsonl → id 별 대표 반응
    static func byID(_ jsonl: String) -> [String: String] {
        var evs: [String: [String]] = [:]
        for line in jsonl.split(separator: "\n") {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = o["id"] as? String, let ev = o["ev"] as? String else { continue }
            evs[id, default: []].append(ev)
        }
        return evs.compactMapValues(summary)
    }
}
