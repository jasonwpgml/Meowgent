import AppKit

/// Claude Code·Codex 세션 기록(로컬 jsonl)을 몇 초마다 읽어
/// 컨텍스트 사용률, "작업 끝남"을 알아낸다. 외부로 보내는 것 없음.
/// Codex 사용 한도는 codexWindows로 넘기고, 알림은 QuotaWatch가 한다 (CodexBar 값이 없을 때 대신 쓰임).
/// 비용: 파일마다 지난번 읽은 위치를 기억해 새로 붙은 줄만 읽고(처음에만 끝부분), 폴더 열거는 30초에 한 번만 한다.
final class AgentMonitor {
    struct Notice { let text: String; let urgent: Bool }
    var notify: ((Notice) -> Void)?
    /// 지금 그 에이전트 앱을 보고 있으면 "끝났어요" 알림은 생략
    var frontBundle: () -> String? = { nil }

    private let home = FileManager.default.homeDirectoryForCurrentUser
    private let queue = DispatchQueue(label: "meowgent.agents", qos: .utility)
    private var timer: Timer?
    private var warnedContext: [String: Int] = [:]        // 세션별로 이미 알린 단계 (50, 80)
    private var lastDone: [String: String] = [:]          // 세션별 마지막 "끝남" 표시 (중복 방지)
    private(set) var summary = ""                         // 메뉴·말풍선용 한 줄 요약
    private(set) var codexWindows: [Quota.Window] = []    // 세션 기록의 Codex 한도 (5시간·주간)

    func start() {
        let t = Timer(timeInterval: 6, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        poll()
    }

    private func poll() {
        let front = frontBundle()
        queue.async { [weak self] in
            guard let self else { return }
            var lines: [String] = []
            if let s = self.checkCodex(front: front) { lines.append(s) }
            if let s = self.checkClaude(front: front) { lines.append(s) }
            DispatchQueue.main.async { self.summary = lines.joined(separator: "\n") }
        }
    }

    private func send(_ text: String, urgent: Bool = false) {
        DispatchQueue.main.async { [weak self] in self?.notify?(Notice(text: text, urgent: urgent)) }
    }

    // MARK: Codex  (~/.codex/sessions/연/월/일/rollout-*.jsonl)

    /// 파일 하나에서 지금까지 읽어 알아낸 것 (끝에서부터 훑던 때와 같은 값이 나오게 앞에서부터 갱신한다)
    private struct CodexTail {
        var offset: UInt64 = 0
        var ctxPct: Int?
        var limits: [Quota.Window]?
        var limitsLocked = false     // 가장 최근 token_count 줄의 한도를 쓰고 있다 (더 새 줄이 와야 바뀜)
        var doneAt: String?
    }
    private var codexTails: [String: CodexTail] = [:]

    /// 최근에 움직인 Codex 대화마다 본다. 스크립트가 돌린 codex exec(그림 생성 등)은 빼고, 알림엔 작업 폴더 이름을 붙인다.
    private func checkCodex(front: String?) -> String? {
        let base = home.appendingPathComponent(".codex/sessions")
        var lines: [String] = []
        let files = recentFiles(in: base, depth: 4, maxAge: 30 * 60, limit: 6)
        codexTails = codexTails.filter { k, _ in files.contains { $0.path == k } }
        for f in files {
            let id = f.lastPathComponent
            guard let meta = codexMeta(f), meta.interactive else { continue }
            let name = meta.name
            let mod = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            var st = codexTails[f.path] ?? CodexTail()
            let (objs, reset) = newJSON(f, from: &st.offset, tailBytes: 200_000)
            if reset { st = CodexTail(offset: st.offset) }
            for obj in objs {
                let p = (obj["payload"] as? [String: Any]) ?? obj
                let type = p["type"] as? String
                if type == "token_count" {
                    var pct: Int?
                    if let info = p["info"] as? [String: Any],
                       let last = info["last_token_usage"] as? [String: Any],
                       let win = (info["model_context_window"] as? NSNumber)?.doubleValue, win > 0 {
                        let used = ((last["input_tokens"] as? NSNumber)?.doubleValue ?? 0) + ((last["output_tokens"] as? NSNumber)?.doubleValue ?? 0)
                        pct = Int(used / win * 100)
                    }
                    var rl: [Quota.Window]?
                    if let r = p["rate_limits"] as? [String: Any] {
                        rl = ["primary", "secondary"].compactMap { slot in
                            guard let w = r[slot] as? [String: Any], let used = (w["used_percent"] as? NSNumber)?.doubleValue,
                                  let reset = (w["resets_at"] as? NSNumber)?.doubleValue else { return nil }
                            let mins = (w["window_minutes"] as? NSNumber)?.intValue ?? 0
                            return Quota.Window(provider: "codex", name: "Codex \(Quota.periodName(mins))", key: "codex:local:\(mins)",
                                                usedPercent: used, minutes: mins, resetsAt: Date(timeIntervalSince1970: reset), capturedAt: mod)
                        }
                    }
                    if pct != nil { st.ctxPct = pct; st.limits = rl; st.limitsLocked = rl != nil }
                    else if let rl, !st.limitsLocked { st.limits = rl; st.limitsLocked = true }
                }
                if type == "task_complete" || type == "turn_complete" {
                    st.doneAt = (obj["timestamp"] as? String) ?? "\(p.description.count)"
                }
            }
            codexTails[f.path] = st
            if let c = st.ctxPct { warnContext(session: "codex:" + id, agent: "Codex ‘\(name)’", pct: c) }
            if let limits = st.limits, lines.isEmpty {
                let stamped = limits.map { var w = $0; w.capturedAt = mod; return w }
                DispatchQueue.main.async { self.codexWindows = stamped }
            }
            if let d = st.doneAt, lastDone["codex:" + id] != d {
                let first = lastDone["codex:" + id] == nil
                lastDone["codex:" + id] = d
                let inCodex = front.map { $0.contains("openai") || $0.contains("codex") } ?? false
                let fresh = Date().timeIntervalSince(mod) < 30
                if !first && !inCodex && fresh { send("Codex ‘\(name)’ 일 끝났다. 가 봐 ✅") }
            }
            if let c = st.ctxPct, lines.count < 3 { lines.append("Codex ‘\(name)’: 컨텍스트 \(c)%") }
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// 대화 첫 줄(session_meta): 사람이 쓰는 대화인지(codex exec 제외), 이름(작업 폴더)
    private var codexMetaCache: [String: (interactive: Bool, name: String)] = [:]
    private func codexMeta(_ f: URL) -> (interactive: Bool, name: String)? {
        if let c = codexMetaCache[f.path] { return c }
        guard let h = try? FileHandle(forReadingFrom: f) else { return nil }
        defer { try? h.close() }
        guard let data = try? h.read(upToCount: 64_000),
              let line = String(data: data, encoding: .utf8)?.split(separator: "\n").first,
              let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return nil }
        let p = (obj["payload"] as? [String: Any]) ?? [:]
        let origin = (p["originator"] as? String ?? "") + " " + (p["source"] as? String ?? "")
        let cwd = p["cwd"] as? String ?? ""
        let r = (interactive: !origin.contains("exec"), name: URL(fileURLWithPath: cwd).lastPathComponent)
        codexMetaCache[f.path] = r
        return r
    }

    // MARK: Claude Code  (~/.claude/projects/<프로젝트>/<세션>.jsonl)

    private struct ClaudeTail {
        var offset: UInt64 = 0
        var ctx: Int?
        var model = ""
        var sidechain = false
        var doneKey: String?
        var entry: String?
    }
    private var claudeTails: [String: ClaudeTail] = [:]

    /// 최근에 움직인 Claude 대화마다 본다 (여러 세션을 동시에 쓰니까). 알림엔 대화 제목을 붙여 어느 대화인지 알 수 있게 한다.
    /// SDK·스크립트로 돌린 대화와 하위 에이전트는 뺀다.
    private func checkClaude(front: String?) -> String? {
        let base = home.appendingPathComponent(".claude/projects")
        var lines: [String] = []
        let files = recentFiles(in: base, depth: 2, maxAge: 30 * 60, skip: "subagents", limit: 8)
        claudeTails = claudeTails.filter { k, _ in files.contains { $0.path == k } }
        for f in files {
            let id = f.deletingPathExtension().lastPathComponent
            var st = claudeTails[f.path] ?? ClaudeTail()
            let (objs, reset) = newJSON(f, from: &st.offset, tailBytes: 400_000)
            if reset { st = ClaudeTail(offset: st.offset) }
            for obj in objs {
                if let e = obj["entrypoint"] as? String { st.entry = e }
                guard obj["type"] as? String == "assistant", let msg = obj["message"] as? [String: Any] else { continue }
                let ended = msg["stop_reason"] as? String == "end_turn"
                let key = obj["uuid"] as? String ?? (obj["timestamp"] as? String)
                if let u = msg["usage"] as? [String: Any] {
                    st.ctx = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens"]
                        .reduce(0) { $0 + ((u[$1] as? NSNumber)?.intValue ?? 0) }
                    st.model = msg["model"] as? String ?? ""
                    st.sidechain = obj["isSidechain"] as? Bool ?? false
                    // 마지막 답이 끝맺음이면 그 답, 아니면(도구 호출 중) 끝난 게 아니다
                    st.doneKey = ended ? key : (st.entry == nil ? st.doneKey : nil)
                } else if ended {
                    st.doneKey = key
                }
            }
            claudeTails[f.path] = st
            if st.sidechain || (st.entry ?? "").hasPrefix("sdk") { continue }
            let name = claudeTitle(f)
            if let c = st.ctx {
                let pct = c * 100 / claudeWindow(model: st.model, used: c, session: id)
                warnContext(session: "claude:" + id, agent: "Claude ‘\(name)’", pct: pct)
                if lines.count < 3 { lines.append("Claude ‘\(name)’: 컨텍스트 \(pct)% (\(c / 1000)k)") }
            }
            if let d = st.doneKey, lastDone["claude:" + id] != d {
                let first = lastDone["claude:" + id] == nil
                lastDone["claude:" + id] = d
                let inAgent = front.map { $0.contains("anthropic") || $0.contains("Terminal") || $0.contains("iterm") || $0.contains("ghostty") } ?? false
                let mod = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if !first && !inAgent && Date().timeIntervalSince(mod) < 30 { send("Claude ‘\(name)’ 답 끝났다. 읽어 봐 ✅") }
            }
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// 컨텍스트 창 크기: petClaudeWindow 설정 > 한 번이라도 20만을 넘은 대화 > Claude 5 계열(100만) > 그 밖(20만)
    private var bigSessions: Set<String> = []
    private func claudeWindow(model: String, used: Int, session: String) -> Int {
        let set = UserDefaults.standard.integer(forKey: "petClaudeWindow")
        if set > 0 { return set }
        if used > 200_000 { bigSessions.insert(session) }
        if bigSessions.contains(session) || model.contains("1m") { return 1_000_000 }
        let m = model.lowercased()
        if ["opus-5", "sonnet-5", "fable-5", "haiku-5"].contains(where: { m.contains($0) }) { return 1_000_000 }
        return 200_000
    }

    /// 대화 제목(customTitle). 파일 앞쪽에만 있을 수 있어 전체를 훑되, 5분에 한 번만
    private var titleCache: [String: (title: String, at: Date)] = [:]
    private func claudeTitle(_ f: URL) -> String {
        if let c = titleCache[f.path], Date().timeIntervalSince(c.at) < 300 { return c.title }
        var title = f.deletingLastPathComponent().lastPathComponent.split(separator: "-").last.map(String.init) ?? "?"
        if let data = try? Data(contentsOf: f, options: .mappedIfSafe) {
            let key = Data("\"customTitle\":\"".utf8)
            if let r = data.range(of: key, options: .backwards) {
                let rest = data[r.upperBound...].prefix(400)
                if let s = String(data: rest, encoding: .utf8) ?? String(data: rest.dropLast(3), encoding: .utf8),
                   let end = s.firstIndex(of: "\"") {
                    let t = String(s[..<end])
                    if !t.isEmpty { title = t.count > 18 ? String(t.prefix(17)) + "…" : t }
                }
            }
        }
        titleCache[f.path] = (title, Date())
        return title
    }

    private func warnContext(session: String, agent: String, pct: Int) {
        let step = pct >= 80 ? 80 : (pct >= 50 ? 50 : 0)
        guard step > (warnedContext[session] ?? 0) else { return }
        let first = warnedContext[session] == nil
        warnedContext[session] = step
        if first && step == 50 { return }   // 앱을 켰을 때 이미 절반 넘은 대화들까지 한꺼번에 알리지 않는다 (80% 넘은 건 알림)
        send(step >= 80 ? "\(agent) 컨텍스트 \(pct)%다. 정리(compact)하든지 새 세션으로 넘겨"
                        : "\(agent) 컨텍스트 절반 넘었다 (\(pct)%)", urgent: step >= 80)
    }

    // MARK: 파일 도구

    /// 폴더 열거 결과(maxAge 안의 jsonl 전부): 30초 동안은 이 목록의 수정 시각만 다시 보고 쓴다
    private var dirCache: [String: (files: [URL], at: Date)] = [:]

    /// maxAge 안에 고친 jsonl을 최근 것부터 limit개
    private func recentFiles(in dir: URL, depth: Int, maxAge: TimeInterval, skip: String? = nil, limit: Int) -> [URL] {
        let cutoff = Date().addingTimeInterval(-maxAge)
        func modDate(_ u: URL) -> Date? { try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        var found: [(URL, Date)]
        if let c = dirCache[dir.path], Date().timeIntervalSince(c.at) < 30 {
            found = c.files.compactMap { u in modDate(u).map { (u, $0) } }
        } else {
            guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
                                                         options: [.skipsHiddenFiles]) else { return [] }
            found = []
            for case let u as URL in e {
                if e.level > depth { e.skipDescendants(); continue }
                if let skip, u.lastPathComponent == skip { e.skipDescendants(); continue }
                guard u.pathExtension == "jsonl", let d = modDate(u), d > cutoff else { continue }
                found.append((u, d))
            }
            dirCache[dir.path] = (found.map(\.0), Date())
        }
        return found.filter { $0.1 > cutoff }.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    /// offset 뒤에 새로 붙은 완전한 줄만 JSON으로. offset이 0이면(처음) 끝 tailBytes만 읽고 잘린 첫 줄은 버린다.
    /// 파일이 줄었으면(다시 쓰임) 끝부분부터 다시 읽고 reset을 돌려 준다. 아직 개행이 없는 마지막 줄은 다음에 읽는다.
    private func newJSON(_ url: URL, from offset: inout UInt64, tailBytes: Int) -> (objs: [[String: Any]], reset: Bool) {
        guard let h = try? FileHandle(forReadingFrom: url) else { return ([], false) }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let reset = offset > 0 && size < offset
        var start = offset
        var fresh = false
        if offset == 0 || reset {
            start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
            fresh = true
        }
        guard size > start else { return ([], reset) }
        try? h.seek(toOffset: start)
        guard let data = try? h.readToEnd(), !data.isEmpty else { return ([], reset) }
        guard let nl = data.lastIndex(of: 0x0A) else { offset = start; return ([], reset) }
        offset = start + UInt64(nl - data.startIndex) + 1
        var lines = data[data.startIndex..<nl].split(separator: 0x0A, omittingEmptySubsequences: true)
        if fresh, start > 0, !lines.isEmpty { lines.removeFirst() }    // 잘린 첫 줄
        return (lines.compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }, reset)
    }
}
