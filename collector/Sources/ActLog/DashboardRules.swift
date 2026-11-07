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
        var multi = false           // 여러 개 골라도 되는 질문 (체크 상자로 고르고 answer 에 "A, B")
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
                    created: o["created"] as? Double ?? now, due: due, url: url, choices: choices,
                    multi: kind == "ask" && o["multi"] as? Bool == true && choices.count > 1)
    }

    /// 빨강 먼저, 그 안에서 마감 가까운 것 → 오래된 것
    static func order(_ a: Item, _ b: Item) -> Bool {
        if a.red != b.red { return a.red }
        if (a.due ?? .infinity) != (b.due ?? .infinity) { return (a.due ?? .infinity) < (b.due ?? .infinity) }
        return a.created < b.created
    }

    /// 질문(?)은 보낸 곳 + 선택지 id 목록이 같으면 한 묶음. 확인할 일(!)과 선택지 없는 질문, 여러 개 고르는 질문은 하나씩.
    /// 묶음 순서는 그 안에서 가장 앞에 올 항목 기준
    static func group(_ items: [Item]) -> [Group] {
        var keyed: [String: [Item]] = [:]
        var keys: [String] = []
        for i in items.sorted(by: InboxRules.order) {
            let key = i.ask && !i.choices.isEmpty && !i.multi ? "ask|\(i.source)|" + i.choices.map(\.id).joined(separator: "\u{1F}") : "one|\(i.file)"
            if keyed[key] == nil { keys.append(key) }
            keyed[key, default: []].append(i)
        }
        return keys.map { Group(items: keyed[$0]!) }
    }

    /// 묶음 질문들이 함께 끝나는 문구 (낱말 단위). 각 질문엔 앞부분만 보여 준다.
    /// "10/27 02:41부터 22분 Claude에서 한 일은 어느 프로젝트?" ×n → "Claude에서 한 일은 어느 프로젝트?". 짧거나 없으면 nil
    static func commonSuffix(_ texts: [String]) -> String? {
        guard texts.count > 1, var common = texts.first.map({ Array($0) }) else { return nil }
        for t in texts.dropFirst() {
            let c = Array(t)
            var n = 0
            while n < common.count, n < c.count, common[common.count - 1 - n] == c[c.count - 1 - n] { n += 1 }
            common = Array(common.suffix(n))
        }
        var s = String(common)
        // 낱말 중간에서 시작하면 첫 공백 뒤부터 (질문 하나가 통째로 같으면 그대로 둔다)
        if !texts.contains(s), let sp = s.firstIndex(of: " ") { s = String(s[s.index(after: sp)...]) }
        s = s.trimmingCharacters(in: .whitespaces)
        guard s.count >= 6, texts.allSatisfy({ $0.count > s.count }) else { return nil }
        return s
    }

    /// 공통 문구를 뺀 앞부분 (없으면 전체)
    static func stripSuffix(_ text: String, _ suffix: String?) -> String {
        guard let suffix, text.hasSuffix(suffix) else { return text }
        let head = String(text.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
        return head.isEmpty ? text : head
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

    enum Category: Equatable { case context, quota, memory, battery, done, ask, todo, rest, other }

    /// 아이콘·색을 고르려고 첫 줄로 대강 나눈다
    static func category(_ text: String) -> Category {
        let head = String(text.split(separator: "\n", maxSplits: 1).first ?? "")
        func has(_ words: String...) -> Bool { words.contains { head.contains($0) } }
        if has("컨텍스트") { return .context }
        if has("한도", "⛔") { return .quota }
        if has("메모리", "🧠") { return .memory }
        if has("배터리", "⚡") { return .battery }
        if has("끝났다", "✅") { return .done }
        if has("물어볼", "확인할", "❓", "❗") { return .ask }
        if has("할 일", "📝") { return .todo }
        if has("기지개", "일했다", "식사", "밥", "점심", "저녁", "아침", "잠", "쉬") { return .rest }
        return .other
    }

    /// 목록에 보일 글: 왼쪽 아이콘과 겹치는 줄 앞 이모지·끝의 ✅ 를 뗀다
    static func plain(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            var s = Substring(line)
            while let c = s.first, c.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation || ($0.properties.isEmoji && $0.value > 0x2000) }) || c == " " {
                s = s.dropFirst()
            }
            var out = String(s)
            if out.hasSuffix("✅") { out = String(out.dropLast()).trimmingCharacters(in: .whitespaces) }
            return out
        }.joined(separator: "\n")
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

/// 고양이 판단 기록(mind/decisions.jsonl, cat_mind 가 쓴다)과 주간 개선 제안(mind/improve/latest.json)의 순수 규칙
enum ThinkRules {
    struct Decision: Equatable {
        let ts: Double
        let kind: String        // proactive · chat · improve
        let trig: String?
        let facts: String?
        let p: Double?
        let mode: String?
        let outcome: String     // said · quiet · failed · timeout · limited · retry
        let took: Double?
        let text: String?
        var sid: String? = nil  // 그 말풍선 id (reactions.jsonl 과 잇는다)
    }

    static let triggerKo = ["stuck": "막힘", "back": "돌아옴", "long_focus": "오래 쉬지 않음", "late": "늦은 밤", "drift": "딴짓",
                            "switch": "작업 전환", "notable": "기록할 만한 순간", "curious": "오래 조용함"]
    static let modeKo = ["chat": "가볍게", "judge": "의견", "ask": "질문", "quiet": "가만히"]
    static let outcomeKo = ["said": "말함", "quiet": "참음", "failed": "실패", "timeout": "시간 초과", "limited": "한도", "retry": "다시 시도",
                            "muted": "끈 신호"]

    static func parse(_ jsonl: String) -> [Decision] {
        jsonl.split(separator: "\n").compactMap { line in
            guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let ts = o["ts"] as? Double, let outcome = o["outcome"] as? String else { return nil }
            return Decision(ts: ts, kind: o["kind"] as? String ?? "proactive", trig: o["trig"] as? String, facts: o["facts"] as? String,
                            p: o["p"] as? Double, mode: o["mode"] as? String, outcome: outcome, took: o["took"] as? Double, text: o["text"] as? String,
                            sid: o["sid"] as? String)
        }
    }

    // MARK: 판단 라벨 (생각 탭의 맞다·아니다 → mind/decision_labels.jsonl)

    /// 판단 하나를 가리키는 키: 말풍선 id 가 있으면 그것, 없으면 시각
    static func key(_ d: Decision) -> String { d.sid ?? String(format: "t%.3f", d.ts) }

    /// 라벨을 받을 판단: 먼저 말 걸기에서 말했거나 참은 것
    static func labelable(_ d: Decision) -> Bool { d.kind == "proactive" && ["said", "quiet"].contains(d.outcome) }

    /// 버튼 글: 말했으면 "말한 게 맞다 / 괜히 말했다", 참았으면 "참은 게 맞다 / 말했어야 했다"
    static func labelTitles(_ d: Decision) -> (right: String, wrong: String) {
        d.outcome == "said" ? ("말한 게 맞다", "괜히 말했다") : ("참은 게 맞다", "말했어야 했다")
    }

    static func labelLine(_ d: Decision, verdict: String, now: Double) -> [String: Any] {
        var o: [String: Any] = ["ts": now, "key": key(d), "decision": d.ts, "verdict": verdict, "outcome": d.outcome]
        if let t = d.trig { o["trig"] = t }
        if let p = d.p { o["p"] = p }
        return o
    }

    /// 라벨 기록 → 키별 마지막 판정 (right · wrong, 지운 건 clear)
    static func labels(_ jsonl: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in jsonl.split(separator: "\n") {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let k = o["key"] as? String, let v = o["verdict"] as? String else { continue }
            out[k] = v == "clear" ? nil : v
        }
        return out
    }

    /// 목록 제목: "돌아옴 · 가볍게 · 말함" / 사용자가 말 건 건 "말 걸어 옴 · 답함"
    static func title(_ d: Decision) -> String {
        if d.kind == "chat" { return "말 걸어 옴 · " + (d.outcome == "said" ? "답함" : outcomeKo[d.outcome] ?? d.outcome) }
        let trig = d.trig.map { triggerKo[$0] ?? $0 } ?? "먼저 말 걸기"
        return [trig, d.mode.map { modeKo[$0] ?? $0 }, outcomeKo[d.outcome] ?? d.outcome].compactMap { $0 }.joined(separator: " · ")
    }

    /// 부제: 신호 내용 · 말할 확률 · 걸린 시간
    static func subtitle(_ d: Decision) -> String {
        [d.facts, d.p.map { String(format: "말할 확률 %.2f", $0) }, d.took.map { String(format: "%.1f초", $0) }]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    struct Suggestion: Equatable {
        let id: String
        let kind: String        // phrase · param · idea
        let key: String
        let value: String
        let current: String?
        let why: String
        var status: String      // new · applied · ignored
    }

    struct Improve: Equatable {
        let ts: Double
        let summary: String
        var suggestions: [Suggestion]
    }

    static func parseImprove(_ data: Data) -> Improve? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let ts = o["ts"] as? Double else { return nil }
        let list: [Suggestion] = (o["suggestions"] as? [[String: Any]] ?? []).compactMap { s in
            guard let id = s["id"] as? String, let kind = s["kind"] as? String, let value = s["value"] as? String else { return nil }
            let cur: String? = (s["current"] as? String) ?? (s["current"] as? NSNumber).map { n in
                n.doubleValue == n.doubleValue.rounded() ? String(Int(n.doubleValue)) : n.stringValue
            }
            return Suggestion(id: id, kind: kind, key: s["key"] as? String ?? "", value: value, current: cur,
                              why: s["why"] as? String ?? "", status: s["status"] as? String ?? "new")
        }
        return Improve(ts: ts, summary: o["summary"] as? String ?? "", suggestions: list)
    }
}

/// 고양이가 맡긴 코딩 작업 (mind/tasks/<id>/task.json, brain/code_tasks.py 가 쓴다)
enum TaskRules {
    struct Task: Equatable {
        let id: String
        let agent: String       // 보이는 이름 (Claude Code 등)
        let repo: String
        let task: String
        let state: String       // running · done · failed · timeout · cancelled · merged · discarded
        let started: Double
        let ended: Double?
        let summary: String?
        let error: String?
        let files: Int
        let stat: String
        let branch: String
        let worktree: String
    }

    static let stateKo = ["running": "하는 중", "done": "끝남", "failed": "실패", "timeout": "시간 초과", "cancelled": "멈춤",
                          "merged": "합침", "discarded": "버림"]

    static func parse(_ o: [String: Any]) -> Task? {
        guard let id = o["id"] as? String, let state = o["state"] as? String else { return nil }
        return Task(id: id, agent: o["agent_name"] as? String ?? o["agent"] as? String ?? "?", repo: o["repo"] as? String ?? "",
                    task: o["task"] as? String ?? "", state: state, started: o["started"] as? Double ?? 0, ended: o["ended"] as? Double,
                    summary: (o["summary"] as? String).flatMap { $0.isEmpty ? nil : $0 }, error: (o["error"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                    files: o["files"] as? Int ?? 0, stat: o["stat"] as? String ?? "", branch: o["branch"] as? String ?? "",
                    worktree: o["worktree"] as? String ?? "")
    }

    /// 하는 중 먼저, 그다음 최근 것부터
    static func order(_ a: Task, _ b: Task) -> Bool {
        if (a.state == "running") != (b.state == "running") { return a.state == "running" }
        return a.started > b.started
    }

    /// "Claude Code · Meowgent · 하는 중 12분" / "… · 끝남 · 파일 3개"
    static func subtitle(_ t: Task, now: Double) -> String {
        let mins = Int(((t.ended ?? now) - t.started) / 60)
        var parts = [t.agent, t.repo, (stateKo[t.state] ?? t.state) + (t.state == "running" ? " \(mins)분째" : " · \(mins)분 걸림")]
        if t.state != "running" { parts.append(t.files > 0 ? "파일 \(t.files)개" : "바뀐 파일 없음") }
        return parts.joined(separator: " · ")
    }
}
