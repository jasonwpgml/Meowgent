import AppKit

/// 고양이 inbox 의 할일 중 `"forward": "grokbot"` 이 붙은 것을 Grok Bot 자동화(루틴) 웹훅으로 넘긴다. 판단은 InboxForwardRules.
/// - 웹훅: `{ "url", "key" }` 파일, git 밖. 기본 `<데이터 폴더>/grokbot-webhook.json`,
///   `defaults write io.github.jasonwpgml.meowgent grokbotWebhookFile <경로>` 로 다른 파일을 가리킬 수 있다. 파일이 없으면 아무것도 안 보낸다.
/// - 보낸 기록: `<데이터 폴더>/inbox-forward.json` (항목 id → 보낸 시각·Grok Bot 실행 id·실패). inbox 파일 자체는 고치지 않는다
///   (확인하면 done/ 으로 옮기는 고양이·대시보드와 부딪히지 않게).
/// - 활동 기록을 끈 동안에도 돈다. 기록이 아니라 다른 에이전트가 맡긴 심부름이어서다.
final class InboxForward {
    private let inbox: URL
    private let stateURL: URL
    private let defaultHook: URL
    private let queue = DispatchQueue(label: "meowgent.forward")
    private var timer: Timer?
    private var inFlight: Set<String> = []
    private var states: [String: InboxForwardRules.State]?
    private var hookOn = false
    private let machine = Host.current().localizedName ?? "Mac"
    /// 끝내 못 보낸 항목을 고양이로 알린다 (main 에서 부른다)
    var notify: ((String) -> Void)?

    init(dataDir: URL) {
        inbox = dataDir.appendingPathComponent("inbox", isDirectory: true)
        stateURL = dataDir.appendingPathComponent("inbox-forward.json")
        defaultHook = dataDir.appendingPathComponent("grokbot-webhook.json")
    }

    var hookFile: URL {
        guard let p = UserDefaults.standard.string(forKey: "grokbotWebhookFile"), !p.isEmpty else { return defaultHook }
        return URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
    }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.tick() }
        tick()
    }

    func tick() { queue.async { [weak self] in self?.scan() } }

    // MARK: 읽고 보내기 (queue 위에서)

    private static func readJSON(_ url: URL) -> [String: Any]? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    }

    private func loadStates() -> [String: InboxForwardRules.State] {
        if let states { return states }
        let raw = Self.readJSON(stateURL) ?? [:]
        let s = raw.compactMapValues { ($0 as? [String: Any]).flatMap(InboxForwardRules.State.init) }
        states = s
        return s
    }

    private func save() {
        guard let states else { return }
        guard let out = try? JSONSerialization.data(withJSONObject: states.mapValues(\.json), options: [.prettyPrinted, .sortedKeys]) else { return }
        let tmp = stateURL.deletingLastPathComponent().appendingPathComponent("." + stateURL.lastPathComponent + ".tmp")
        if FileManager.default.createFile(atPath: tmp.path, contents: out, attributes: [.posixPermissions: 0o600]) {
            rename(tmp.path, stateURL.path)
        }
    }

    private func scan() {
        let hook = InboxForwardRules.hook(Self.readJSON(hookFile))
        if (hook != nil) != hookOn {
            hookOn = hook != nil
            Log.write(hookOn ? "Grok Bot 전달 켜짐: \(hookFile.path)" : "Grok Bot 전달 꺼짐 (웹훅 파일 없음·형식 틀림): \(hookFile.path)")
        }
        guard let hook else { return }
        var states = loadStates()
        let now = Date().timeIntervalSince1970
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "json" }
        let doneFiles = ((try? fm.contentsOfDirectory(at: inbox.appendingPathComponent("done"), includingPropertiesForKeys: nil)) ?? [])
        var present = Set(doneFiles.map { $0.deletingPathExtension().lastPathComponent })
        var budget = min(InboxForwardRules.perTick, InboxForwardRules.perHour - InboxForwardRules.sentLastHour(states, now: now))
        for f in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let o = Self.readJSON(f) else { continue }
            let id = o["id"] as? String ?? f.deletingPathExtension().lastPathComponent
            present.insert(id)
            guard InboxForwardRules.wants(o), !inFlight.contains(id), InboxForwardRules.due(states[id], now: now) else { continue }
            guard budget > 0 else { continue }
            budget -= 1
            if states[id] == nil { states[id] = InboxForwardRules.State(first: now) }
            send(id: id, item: o, hook: hook)
        }
        let pruned = InboxForwardRules.prune(states, present: present, now: now)
        self.states = pruned
        save()
    }

    private func send(id: String, item: [String: Any], hook: InboxForwardRules.Hook) {
        inFlight.insert(id)
        var req = URLRequest(url: hook.url, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("Bearer \(hook.key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: InboxForwardRules.body(item, id: id, machine: machine), options: [.sortedKeys])
        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            self?.queue.async { self?.finish(id: id, status: (response as? HTTPURLResponse)?.statusCode, data: data, error: error) }
        }.resume()
    }

    private func finish(id: String, status: Int?, data: Data?, error: Error?) {
        inFlight.remove(id)
        var states = loadStates()
        let now = Date().timeIntervalSince1970
        let s = states[id] ?? InboxForwardRules.State(first: now)
        if let status, (200..<300).contains(status) {
            let run = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["runUuid"] as? String
            states[id] = InboxForwardRules.succeeded(s, run: run, now: now)
            Log.write("Grok Bot 전달: \(id) → \(status)\(run.map { " run \($0)" } ?? "")")
        } else {
            let why = status.map { "HTTP \($0)" } ?? (error?.localizedDescription ?? "응답 없음")
            let f = InboxForwardRules.failed(s, status: status, error: why, now: now)
            states[id] = f
            Log.write("Grok Bot 전달 실패: \(id) (\(f.tries)번째) \(why)")
            if f.gaveUp {
                DispatchQueue.main.async { [weak self] in self?.notify?("📮 Grok Bot에 할일을 못 보냈다냥 (\(why)). 웹훅 키랑 루틴이 켜져 있는지 봐 줘라냥") }
            }
        }
        self.states = states
        save()
    }

    // MARK: 메뉴

    /// 메뉴 한 줄: 켜졌는지, 오늘 보낸 수, 아직 못 보낸 수
    func addMenuItems(to menu: NSMenu) {
        let (on, sent, pending) = queue.sync { () -> (Bool, Int, Int) in
            let st = states ?? [:]
            let today = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
            return (hookOn, st.values.filter { ($0.sent ?? 0) >= today }.count, st.values.filter { $0.sent == nil }.count)
        }
        guard on || pending > 0 else { return }
        var t = on ? "📮 Grok Bot 전달 켜짐 · 오늘 \(sent)개 보냄" : "📮 Grok Bot 전달 꺼짐 (웹훅 파일 없음)"
        if pending > 0 { t += " · 못 보낸 것 \(pending)개" }
        let i = NSMenuItem(title: t, action: nil, keyEquivalent: "")
        i.isEnabled = false
        menu.addItem(i)
    }
}
