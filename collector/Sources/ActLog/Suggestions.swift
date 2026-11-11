import AppKit

/// 제안 목록 (데이터 폴더 suggest/): 고양이가 "해 줄 만한 것"을 모아 두고, 대시보드 '제안' 탭에서 중요한 순으로 한꺼번에 본다.
/// - 파일 하나가 제안 하나 (suggest/<id>.json). 누구나 넣을 수 있다: cat_mind(같은 요청 반복), 앱 정리, 다른 에이전트. 형식은 docs/CAT_MIND.md "제안 목록".
/// - 같은 key 로 다시 넣으면 새 파일을 만들지 않고 count·updated 만 늘린다 (같은 상황이 반복될수록 위로).
/// - say 가 있으면 고양이가 그때 한 마디 한다 (1시간에 한 번까지). 말풍선이 지나가도 목록에는 남는다.
/// - 하기·필요 없음은 suggest/done/ 으로 옮기고 suggest/log.jsonl 에 남긴다. 어떤 제안이 쓸모 있었는지의 근거다. 나중에는 하루 뒤 다시.
final class Suggestions {
    let dir: URL
    /// 고양이 한 마디 (say). main 이 말풍선으로 띄운다
    var say: ((SuggestRules.Item) -> Void)?
    /// 하기를 눌렀을 때 할 일. 처리했으면 true
    var run: ((SuggestRules.Action, SuggestRules.Item) -> Bool)?
    private(set) var items: [SuggestRules.Item] = []
    private var timer: Timer?
    private var lastSay: Double = 0

    static let sayGap: Double = 3600
    /// 만든 지 이만큼 지난 제안은 고양이가 새로 말하지 않는다 (목록에서만)
    static let sayFresh: Double = 1800
    static let snooze: Double = 86400
    /// 아무도 고르지 않은 제안은 이만큼 지나면 done 으로 (decision: expired)
    static let keep: Double = 14 * 86400

    init(dataDir: URL) {
        dir = dataDir.appendingPathComponent("suggest", isDirectory: true)
    }

    func start() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        poll()
        let t = Timer(timeInterval: 10, repeats: true) { [weak self] _ in self?.poll() }
        t.tolerance = 2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func poll() {
        load()
        announce()
    }

    private func files() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix(".") }
    }

    private func read(_ f: URL) -> [String: Any]? {
        (try? Data(contentsOf: f)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    func load() {
        let now = Date().timeIntervalSince1970
        var all: [SuggestRules.Item] = []
        for f in files() {
            guard let o = read(f), let it = SuggestRules.parse(o, file: f.lastPathComponent) else { continue }
            if now - it.updated > Self.keep { finish(it, decision: "expired", now: now); continue }
            all.append(it)
        }
        items = SuggestRules.sorted(all.filter { SuggestRules.visible($0, now: now) }, now: now)
    }

    /// 새로 들어온 제안 중 say 가 있는 것 하나를 고양이가 말한다 (1시간에 한 번)
    private func announce() {
        let now = Date().timeIntervalSince1970
        guard now - lastSay >= Self.sayGap,
              let it = items.filter({ $0.say != nil && $0.announced == nil && now - $0.created < Self.sayFresh }).max(by: { $0.created < $1.created })
        else { return }
        lastSay = now
        update(it.file) { $0["announced"] = now }
        say?(it)
    }

    /// Swift 쪽에서 넣기 (앱 정리 등). key 가 같으면 count 만 늘린다
    func add(_ o: [String: Any]) {
        guard let key = o["key"] as? String else { return }
        let now = Date().timeIntervalSince1970
        let url = dir.appendingPathComponent(SuggestRules.fileName(key))
        Self.write(SuggestRules.upsert(read(url), o, now: now), to: url)
        poll()
    }

    /// 다른 곳에서 이미 해결됐다 (예: 말풍선에서 앱 정리에 답함)
    func resolve(key: String) {
        let url = dir.appendingPathComponent(SuggestRules.fileName(key))
        guard let o = read(url), let it = SuggestRules.parse(o, file: url.lastPathComponent) else { return }
        finish(it, decision: "elsewhere", now: Date().timeIntervalSince1970)
        load()
    }

    /// 대시보드 버튼: do 하기 · later 나중에(하루 뒤 다시) · no 필요 없음
    func decide(_ it: SuggestRules.Item, _ decision: String) {
        let now = Date().timeIntervalSince1970
        switch decision {
        case "later":
            update(it.file) { $0["snooze_until"] = now + Self.snooze }
            log(it, decision, now: now)
        case "do":
            let ok = it.action.map { run?($0, it) ?? false } ?? true
            finish(it, decision: ok ? "do" : "do_failed", now: now)
        default:
            finish(it, decision: decision, now: now)
        }
        Log.write("제안 \(decision): \(it.title)")
        load()
    }

    private func finish(_ it: SuggestRules.Item, decision: String, now: Double) {
        let src = dir.appendingPathComponent(it.file)
        guard var o = read(src) else { return }
        let done = dir.appendingPathComponent("done", isDirectory: true)
        try? FileManager.default.createDirectory(at: done, withIntermediateDirectories: true)
        o["decision"] = decision
        o["decided"] = now
        if Self.write(o, to: done.appendingPathComponent(it.file)) { try? FileManager.default.removeItem(at: src) }
        log(it, decision, now: now)
    }

    private func log(_ it: SuggestRules.Item, _ decision: String, now: Double) {
        let line = SuggestRules.logLine(it, decision: decision, now: now)
        guard let d = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) else { return }
        let url = dir.appendingPathComponent("log.jsonl")
        let data = d + Data("\n".utf8)
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(data); try? h.close() }
        else { FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) }
    }

    private func update(_ file: String, _ change: (inout [String: Any]) -> Void) {
        let url = dir.appendingPathComponent(file)
        guard var o = read(url) else { return }
        change(&o)
        Self.write(o, to: url)
    }

    /// 임시 파일에 쓰고 바꿔치기 (반쯤 쓴 파일을 읽지 않게), 0600
    @discardableResult
    static func write(_ o: [String: Any], to url: URL) -> Bool {
        guard let out = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]) else { return false }
        let tmp = url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".tmp")
        guard FileManager.default.createFile(atPath: tmp.path, contents: out, attributes: [.posixPermissions: 0o600]) else { return false }
        return rename(tmp.path, url.path) == 0
    }
}

/// 제안 목록의 순수 규칙 (Tests/logic 에서 점검)
enum SuggestRules {
    /// 하기를 누르면 할 일: chat 고양이에게 이 글로 말 걸기 · open 주소 열기 · app 앱 열기(번들 ID) · cleanup 앱 정리(앱 경로)
    struct Action: Equatable {
        let type: String
        let value: String
    }

    struct Item: Equatable {
        let id: String
        let file: String
        let key: String
        let kind: String
        let source: String
        let title: String
        let detail: String?
        let created: Double
        let updated: Double
        let count: Int
        let value: Double          // 0~1 얼마나 쓸모 있을지 (넣는 쪽이 정한다)
        let halfLife: Double       // 시간. 이만큼 지나면 중요도가 반으로 (빨리 상하는 것일수록 짧게)
        let say: String?
        let announced: Double?
        let snoozeUntil: Double?
        let expires: Double?
        let action: Action?
        let actionLabel: String?
    }

    static func parse(_ o: [String: Any], file: String) -> Item? {
        func num(_ k: String) -> Double? { (o[k] as? NSNumber)?.doubleValue }
        guard let title = o["title"] as? String, !title.isEmpty, let created = num("created") else { return nil }
        let a = o["action"] as? [String: Any]
        let action = (a?["type"] as? String).flatMap { t in (a?["value"] as? String).map { Action(type: t, value: $0) } }
        return Item(id: o["id"] as? String ?? file, file: file, key: o["key"] as? String ?? file,
                    kind: o["kind"] as? String ?? "other", source: o["source"] as? String ?? "",
                    title: title, detail: (o["detail"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                    created: created, updated: num("updated") ?? created, count: max(1, (o["count"] as? NSNumber)?.intValue ?? 1),
                    value: min(1, max(0, num("value") ?? 0.5)), halfLife: max(0.25, num("half_life_h") ?? 24),
                    say: (o["say"] as? String).flatMap { $0.isEmpty ? nil : $0 }, announced: num("announced"),
                    snoozeUntil: num("snooze_until"), expires: num("expires"), action: action,
                    actionLabel: a?["label"] as? String)
    }

    /// 중요도: 쓸모 × 시간이 지나며 줄어듦 + 반복될수록 조금씩 위로
    static func score(_ it: Item, now: Double) -> Double {
        let age = max(0, now - it.updated) / 3600
        return it.value * pow(0.5, age / it.halfLife) + 0.1 * log2(Double(it.count))
    }

    static func visible(_ it: Item, now: Double) -> Bool {
        (it.snoozeUntil ?? 0) <= now && (it.expires ?? .infinity) > now
    }

    static func sorted(_ items: [Item], now: Double) -> [Item] {
        items.sorted { score($0, now: now) > score($1, now: now) }
    }

    /// 대시보드 머리말에 붙이는 말
    static func rank(_ s: Double) -> String { s >= 0.6 ? "중요" : (s >= 0.3 ? "보통" : "나중에 봐도 됨") }

    /// key → 파일 이름 (글자·숫자·-_ 만)
    static func fileName(_ key: String) -> String {
        let safe = key.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII || "-_".unicodeScalars.contains($0) ? String($0) : "-" }.joined()
        return String(safe.prefix(120)) + ".json"
    }

    /// 새로 넣을 때와 같은 key 로 다시 넣을 때. 처음 만든 시각·말한 시각은 지키고, 반복 횟수와 마지막 시각을 늘린다
    static func upsert(_ old: [String: Any]?, _ new: [String: Any], now: Double) -> [String: Any] {
        var o = new
        o["id"] = new["id"] ?? new["key"]
        o["updated"] = now
        if let old {
            o["created"] = old["created"] ?? now
            o["count"] = ((old["count"] as? NSNumber)?.intValue ?? 1) + 1
            if let a = old["announced"] { o["announced"] = a }
            if let s = old["snooze_until"] { o["snooze_until"] = s }
        } else {
            o["created"] = new["created"] ?? now
            o["count"] = new["count"] ?? 1
        }
        return o
    }

    static func logLine(_ it: Item, decision: String, now: Double) -> [String: Any] {
        var o: [String: Any] = ["ts": now, "id": it.id, "kind": it.kind, "source": it.source, "decision": decision,
                                "count": it.count, "age_h": ((now - it.created) / 360).rounded() / 10,
                                "score": (score(it, now: now) * 100).rounded() / 100]
        if it.announced != nil { o["announced"] = true }
        return o
    }
}
