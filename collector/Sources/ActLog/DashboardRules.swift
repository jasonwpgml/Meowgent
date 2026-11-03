import Foundation

/// 대시보드의 순수 규칙 (Tests/logic).
/// InboxRules: 고양이 ! · ? 항목(inbox/*.json, 형식은 docs/INBOX.md) 읽기 · 순서 · 같은 선택지끼리 묶기.
/// 고양이(pet)의 PetMark 와 같은 규칙이지만, 고양이 저장소 없이도 대시보드가 돌게 수집기 쪽에 따로 둔다.
enum InboxRules {
    struct Choice: Equatable {
        let id: String
        let label: String
    }

    struct Item: Equatable {
        let id: String
        let file: String            // inbox/ 안 파일 이름
        let ask: Bool               // false = 확인할 일 (!), true = 물어볼 것 (?)
        let red: Bool
        let text: String
        let detail: String?
        let source: String
        let created: Double
        let due: Double?
        let url: URL?
        let choices: [Choice]
    }

    /// 같은 곳에서 같은 선택지로 물은 질문들 (2개 이상이면 한 번에 답할 수 있다)
    struct Group: Equatable {
        let items: [Item]
        var isBatch: Bool { items.count > 1 }
        var choices: [Choice] { items.first?.choices ?? [] }
    }

    static let redBefore: Double = 24 * 3600

    /// 파일 내용 → 항목. 지금 보여 줄 게 아니면(만료·형식 오류) nil
    static func parse(_ o: [String: Any], file: String, now: Double) -> Item? {
        guard let text = (o["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        let kind = o["kind"] as? String ?? "todo"
        guard kind == "todo" || kind == "ask" else { return nil }
        let due = o["due"] as? Double
        let expires = o["expires"] as? Double ?? due.map { $0 + 24 * 3600 }
        if let expires, expires < now { return nil }
        var red = o["level"] as? String == "red"
        if let due, due - now < redBefore { red = true }
        let choices: [Choice] = (o["choices"] as? [Any] ?? []).compactMap {
            if let s = $0 as? String { return Choice(id: s, label: s) }
            if let d = $0 as? [String: Any], let i = d["id"] as? String { return Choice(id: i, label: d["label"] as? String ?? i) }
            return nil
        }
        let url = (o["url"] as? String).flatMap(URL.init(string:)).flatMap { ["http", "https"].contains($0.scheme ?? "") ? $0 : nil }
        let stem = (file as NSString).deletingPathExtension
        return Item(id: o["id"] as? String ?? stem, file: file, ask: kind == "ask", red: red, text: text,
                    detail: (o["detail"] as? String).flatMap { $0.isEmpty ? nil : $0 }, source: o["source"] as? String ?? "",
                    created: o["created"] as? Double ?? now, due: due, url: url, choices: choices)
    }

    /// 빨강 먼저, 그 안에서 마감 가까운 것 → 오래된 것
    static func order(_ a: Item, _ b: Item) -> Bool {
        if a.red != b.red { return a.red }
        if (a.due ?? .infinity) != (b.due ?? .infinity) { return (a.due ?? .infinity) < (b.due ?? .infinity) }
        return a.created < b.created
    }

    /// 질문(?)은 보낸 곳 + 선택지 id 목록이 같으면 한 묶음. 확인할 일(!)과 선택지 없는 질문은 하나씩.
    /// 묶음 순서는 그 안에서 가장 앞에 올 항목 기준
    static func group(_ items: [Item]) -> [Group] {
        var keyed: [String: [Item]] = [:]
        var keys: [String] = []
        for i in items.sorted(by: InboxRules.order) {
            let key = i.ask && !i.choices.isEmpty ? "ask|\(i.source)|" + i.choices.map(\.id).joined(separator: "\u{1F}") : "one|\(i.file)"
            if keyed[key] == nil { keys.append(key) }
            keyed[key, default: []].append(i)
        }
        return keys.map { Group(items: keyed[$0]!) }
    }
}

/// 고양이 알림 기록(notices.jsonl: text·ts·urgent 한 줄씩)의 순수 규칙: 읽기 · 연달아 같은 알림 접기
enum NoticeRules {
    struct Notice: Equatable {
        let text: String
        let ts: Double
        let urgent: Bool
    }

    /// 접은 한 줄: 가장 최근 글·시각과 몇 번 왔는지
    struct Row: Equatable {
        let text: String
        let ts: Double
        let count: Int
    }

    static func parse(_ jsonl: String) -> [Notice] {
        jsonl.split(separator: "\n").compactMap { line in
            guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let text = o["text"] as? String, let ts = o["ts"] as? Double else { return nil }
            return Notice(text: text, ts: ts, urgent: o["urgent"] as? Bool ?? false)
        }
    }

    /// 경고: 급하게 알린 것 중 고양이와 나눈 대화 답(대화 기록 mind/conversation.jsonl 에 같은 글이 있는 것)은 뺀다
    static func isWarning(_ n: Notice, chat: Set<String>) -> Bool {
        n.urgent && !chat.contains(n.text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// 대화 기록에서 고양이가 한 말만
    static func catLines(_ jsonl: String) -> Set<String> {
        Set(jsonl.split(separator: "\n").compactMap { line in
            guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], o["role"] as? String == "cat",
                  let text = o["text"] as? String else { return nil }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        })
    }

    /// 최신순. 바로 이어서 첫 줄이 숫자만 다른 알림(컨텍스트 80% → 85%, 메모리 경고)은 한 줄로 접는다
    static func collapse(_ notices: [Notice]) -> [Row] {
        var out: [Row] = []
        var lastHead: String?
        for n in notices.sorted(by: { $0.ts > $1.ts }) {
            let first = n.text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
            let head = first.replacingOccurrences(of: #"\d+"#, with: "#", options: .regularExpression)
            if head == lastHead, let last = out.popLast() {
                out.append(Row(text: last.text, ts: last.ts, count: last.count + 1))
            } else {
                out.append(Row(text: n.text, ts: n.ts, count: 1))
                lastHead = head
            }
        }
        return out
    }
}
