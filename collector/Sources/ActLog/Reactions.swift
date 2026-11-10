import AppKit

/// 말풍선 하나에 붙는 반응 기록 고리. 고양이(Pet)가 보여 주고, 눌리고, 사라질 때 record 를 부른다.
/// 사건: shown 보임 · replied 답함 · opened 눌러서 그 앱 열기 · detail 자세히 봄 · read 올려 두고 읽기만 함 ·
///      ignored 7초 안에 마우스를 안 올림 · cut 다른 말에 밀려 사라짐 · dropped 보여 줄 틈이 없어 버림 · rejected 👎 · muted 🔇 ·
///      acted 말풍선과 상관없이 10분 안에 그 말이 가리키는 행동을 함 (그 앱으로 감, 자리를 비움 등)
final class NoticeTrack {
    let canMute: Bool
    let record: (String) -> Void
    init(canMute: Bool, record: @escaping (String) -> Void) {
        self.canMute = canMute
        self.record = record
    }
}

/// 말풍선을 누르면 할 일 (예: 끝난 대화가 있는 앱 열기). 우클릭 메뉴에는 "↗ title" 로 뜬다
struct NoticeOpen {
    let title: String
    let run: () -> Void
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
    /// 행동 창: 보인 말풍선마다 10분 동안 그 말이 가리키는 행동을 기다린다 ('무시'가 7초 마우스만 재는 한계를 메운다)
    private var watches: [(id: String, src: String, kind: String, at: Double, act: ReactionRules.Act)] = []
    private var activation: NSObjectProtocol?

    init(dataDir: URL) {
        file = dataDir.appendingPathComponent("reactions.jsonl")
        mutedFile = dataDir.appendingPathComponent("muted.json")
        if let d = try? Data(contentsOf: mutedFile), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Double] {
            mutes = ReactionRules.active(o, now: Date().timeIntervalSince1970)
        }
        trim()
        // 앞으로 온 앱이 기다리던 행동인지만 본다 (앱 이름은 남기지 않는다)
        activation = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let b = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier else { return }
            self?.happened(.app(b))
        }
    }

    /// 자리를 비웠다 (잠금·잠자기·3분 넘게 입력 없음)
    func away() { happened(.away) }

    private func happened(_ ev: ReactionRules.Happened) {
        let now = Date().timeIntervalSince1970
        watches.removeAll { now - $0.at > ReactionRules.actWindow }
        let hit = watches.filter { ReactionRules.matches($0.act, ev) }
        watches.removeAll { w in hit.contains { $0.id == w.id } }
        for w in hit {
            write(ReactionRules.line(id: w.id, ev: "acted", src: w.src, kind: w.kind, text: nil, shownAt: w.at, now: now, via: ev.via))
        }
    }

    /// src: 알림을 낸 곳 (mind·agent·quota·resource·forward·secret), kind: 끌 단위 ("mind:long_focus", "agent" …)
    /// act: 이 말이 가리키는 행동 (보인 뒤 10분 안에 하면 acted 로 남긴다)
    func track(src: String, kind: String, text: String, id: String? = nil, canMute: Bool, act: ReactionRules.Act? = nil) -> NoticeTrack {
        let id = id ?? "n-\(Int(Date().timeIntervalSince1970 * 1000))-\(Int.random(in: 100...999))"
        var shownAt: Double?
        return NoticeTrack(canMute: canMute) { [weak self] ev in
            guard let self else { return }
            let now = Date().timeIntervalSince1970
            if ev == "shown" {
                shownAt = now
                self.lastShown = ReactionRules.Shown(id: id, src: src, kind: kind, at: now)
                if let act { self.watches.append((id, src, kind, now, act)) }
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
    static let actWindow: Double = 600     // 행동 창 10분

    /// 말풍선이 가리키는 행동: 이 번들 ID 중 하나가 앞으로 옴 / 자리를 비움
    enum Act: Equatable { case app([String]), away }
    enum Happened: Equatable {
        case app(String), away
        var via: String { if case .away = self { return "away" }; return "app" }
    }

    static func matches(_ act: Act, _ ev: Happened) -> Bool {
        switch (act, ev) {
        case let (.app(ids), .app(b)): return ids.contains(b)
        case (.away, .away): return true
        default: return false
        }
    }

    struct Shown: Equatable {
        let id: String
        let src: String
        let kind: String
        let at: Double
        var touched = false
    }

    /// 사용자가 손을 댄 사건 (이 뒤로는 대화창을 열어도 다시 세지 않는다)
    static func touches(_ ev: String) -> Bool { ["replied", "opened", "detail", "rejected", "muted"].contains(ev) }

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
    static let order = ["muted", "rejected", "replied", "opened", "detail", "acted", "read", "ignored", "cut", "dropped", "shown"]
    static let ko = ["muted": "🔇 끔", "rejected": "👎 아니다", "replied": "답함", "opened": "눌러서 엶", "detail": "자세히 봄",
                     "acted": "관련 행동함", "read": "읽기만 함",
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
