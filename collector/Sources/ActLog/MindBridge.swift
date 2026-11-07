import AppKit

/// 말하는 고양이(brain/cat_mind.py)와 앱을 잇는다. 둘은 데이터 폴더의 `mind/` 파일로만 이야기한다.
///  - mind/in/*.json   사용자가 고양이에게 건 말 (여기서 쓴다)
///  - mind/out/*.json  고양이가 할 말 (cat_mind 가 쓰고, 여기서 읽어 말풍선으로 보낸 뒤 지운다)
///  - mind/off         있으면 말하는 고양이를 끈다
///  - mind/alive.json  cat_mind 가 10초마다 남기는 신호
///  - mind/act/*.json  대화로 시킨 일 (cat_mind 가 검사해 쓰고, 여기서 정해진 코드로 실행한 뒤 act/done 에 결과를 남긴다)
///  - mind/commands.json  대화로 부를 수 있는 Meowgent 기능 목록 (여기서 쓴다. cat_mind 가 이 id 만 받는다)
///  - mind/tasks.json  돌고 있는 코딩 작업 (cat_mind 가 쓴다. 대화창 상태 줄)
final class MindBridge: NSObject {
    /// id·kind: cat_mind 가 쓴 말이면 그 말의 id (decisions.jsonl 의 sid) 와 종류 (chat · say · 신호 이름)
    struct Line { let text: String; let urgent: Bool; var id: String? = nil; var kind: String? = nil }
    var say: ((Line) -> Void)?
    /// 대화창을 열었다 (방금 본 말풍선에 답하러 온 것으로 칠 수 있게)
    var opened: (() -> Void)?
    /// 고양이 재주 (기지개 등). 한도가 다시 채워져 깰 때 쓴다
    var trick: ((String) -> Void)?
    /// 대화로 부를 수 있는 기능 (main 이 채운다). start() 때 mind/commands.json 으로 남긴다
    var commands: [(id: String, title: String, run: () -> Void)] = []

    /// mind/quota.json: 고양이 Codex 계정의 한도 (cat_mind 가 부를 때마다 갱신)
    struct Quota {
        struct Window { let name: String; let used: Double; let resetsAt: Date }
        let windows: [Window]
        let limitedUntil: Date?
    }
    private(set) var quota: Quota?
    private var quotaStamp: Date?
    private var wasSleepy: Bool?

    private let dir: URL
    private let dataDir: URL
    private let queue = DispatchQueue(label: "meowgent.mind", qos: .utility)
    private var timer: Timer?
    private lazy var chat = MindChat(bridge: self)
    private var hotKey: HotKey?
    private var hold: DispatchWorkItem?
    private var holding = false

    /// ⌃⌥M (Meow). ⌃⌥Space 는 macOS 기본 "다음 입력 소스 선택"이라 피한다
    static let hotKeyCode = 46              // kVK_ANSI_M
    static let hotKeyMods = 0x1000 | 0x0800 // controlKey | optionKey
    static let hotKeyName = "⌃⌥M"
    /// 이만큼 누르고 있으면 "말하기", 그 전에 떼면 창 열기·닫기
    static let holdSeconds = 0.35

    init(dataDir: URL) {
        self.dataDir = dataDir
        dir = dataDir.appendingPathComponent("mind", isDirectory: true)
        super.init()
    }

    var isOff: Bool { FileManager.default.fileExists(atPath: dir.appendingPathComponent("off").path) }

    /// cat_mind 가 최근 30초 안에 신호를 남겼나
    var isAlive: Bool {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent("alive.json")),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let ts = o["ts"] as? Double else { return false }
        return Date().timeIntervalSince1970 - ts < 30
    }

    /// cat_mind 가 Codex 답을 기다리는 중
    var isThinking: Bool { FileManager.default.fileExists(atPath: dir.appendingPathComponent("thinking").path) }

    /// 생각을 시작한 시각 (thinking 파일을 만든 때). 대화창에 몇 초째인지 보여 준다
    var thinkingSince: Date? {
        (try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("thinking").path))?[.modificationDate] as? Date
    }

    func start() {
        writeCommands()
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        hotKey = HotKey(keyCode: Self.hotKeyCode, modifiers: Self.hotKeyMods)
        hotKey?.onDown = { [weak self] in self?.keyDown() }
        hotKey?.onUp = { [weak self] in self?.keyUp() }
    }

    private func keyDown() {
        guard !isOff else {
            say?(Line(text: "말하는 고양이가 꺼져 있다냥. 메뉴의 🧠 로 켜 줘라냥.", urgent: true))
            return
        }
        let w = DispatchWorkItem { [weak self] in
            self?.holding = true
            self?.chat.startVoice(sendWhenDone: true)
        }
        hold = w
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdSeconds, execute: w)
    }

    private func keyUp() {
        hold?.cancel()
        hold = nil
        if holding {
            holding = false
            chat.stopVoice()
        } else if !isOff {
            chat.toggle()
            if chat.isVisible { opened?() }
        }
    }

    private func poll() {
        loadQuota()
        queue.async { [weak self] in
            guard let self else { return }
            let out = self.dir.appendingPathComponent("out")
            let files = ((try? FileManager.default.contentsOfDirectory(at: out, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            for f in files {
                defer { try? FileManager.default.removeItem(at: f) }
                guard let d = try? Data(contentsOf: f), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                      let text = (o["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { continue }
                let line = Line(text: text, urgent: o["urgent"] as? Bool ?? false, id: o["id"] as? String, kind: o["kind"] as? String)
                DispatchQueue.main.async { self.say?(line) }
            }
            let acts = ((try? FileManager.default.contentsOfDirectory(at: self.dir.appendingPathComponent("act"), includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            for f in acts {
                defer { try? FileManager.default.removeItem(at: f) }
                guard let d = try? Data(contentsOf: f), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                      let tool = o["tool"] as? String, let arg = o["arg"] as? String else { continue }
                let detail = o["detail"] as? String ?? ""
                let name = f.lastPathComponent
                let app = tool == "open_app" ? Self.findApp(arg) : nil
                DispatchQueue.main.async { self.act(tool, arg, detail, app: app, file: name) }
            }
        }
    }

    // MARK: 시키면 하기

    private func writeCommands() {
        let list = commands.map { ["id": $0.id, "title": $0.title] }
        guard let d = try? JSONSerialization.data(withJSONObject: list, options: [.prettyPrinted]) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("commands.json")
        try? d.write(to: url, options: .atomic)
        chmod(url.path, 0o600)
    }

    /// 대화로 시킨 일을 정해진 코드로만 한다. cat_mind 가 이미 검사했지만 여기서도 한 번 더 본다
    private func act(_ tool: String, _ arg: String, _ detail: String, app: URL?, file: String) {
        var ok = false, result = ""
        switch tool {
        case "open_app":
            if let app { NSWorkspace.shared.openApplication(at: app, configuration: .init()); ok = true; result = app.deletingPathExtension().lastPathComponent }
            else { result = "그런 앱을 못 찾음" }
        case "open_url":
            if let u = URL(string: arg), u.scheme == "https", u.host != nil { ok = NSWorkspace.shared.open(u) } else { result = "https 주소가 아님" }
        case "command":
            if let c = commands.first(where: { $0.id == arg }) { c.run(); ok = true; result = c.title } else { result = "모르는 명령" }
        case "timer":
            if let m = Double(arg), m > 0, m <= 24 * 60 {
                let text = detail.isEmpty ? "\(Self.minutes(m)) 됐다냥." : detail
                DispatchQueue.main.asyncAfter(deadline: .now() + m * 60) { [weak self] in
                    self?.trick?("blink")
                    self?.say?(Line(text: "⏰ " + text, urgent: true))
                }
                ok = true
                result = Self.minutes(m) + " 뒤 (앱을 끄면 사라진다)"
            }
        default: result = "모르는 일"
        }
        Log.write("고양이가 시킨 일: \(tool) \(arg.prefix(60)) → \(ok ? "됨" : "안 됨 (\(result))")")
        let done = dir.appendingPathComponent("act/done")
        try? FileManager.default.createDirectory(at: done, withIntermediateDirectories: true)
        let o: [String: Any] = ["tool": tool, "arg": arg, "ok": ok, "result": result, "ts": Date().timeIntervalSince1970]
        if let d = try? JSONSerialization.data(withJSONObject: o) {
            let url = done.appendingPathComponent(file)
            try? d.write(to: url, options: .atomic)
            chmod(url.path, 0o600)
        }
    }

    /// 이름으로 앱 찾기: Finder 이름(한국어)·파일 이름이 같은 것 먼저, 없으면 앞이 같은 것
    static func findApp(_ name: String) -> URL? {
        let q = name.lowercased().replacingOccurrences(of: ".app", with: "").trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return nil }
        let apps = AppIndex.scan()
        return (apps.first { $0.name.lowercased() == q || $0.file.lowercased() == q }
            ?? apps.first { $0.name.lowercased().hasPrefix(q) || $0.file.lowercased().hasPrefix(q) })?.url
    }

    static func minutes(_ m: Double) -> String {
        m >= 60 && m.truncatingRemainder(dividingBy: 60) == 0 ? "\(Int(m / 60))시간" : m < 1 ? "\(Int(m * 60))초" : "\(Int(m))분"
    }

    /// 돌고 있는 코딩 작업 한 줄: "🛠 Claude Code · Meowgent 작업 중 · 3분째"
    var tasksLine: String? {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent("tasks.json")),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let run = o["running"] as? [[String: Any]], let first = run.first else { return nil }
        let mins = Int((Date().timeIntervalSince1970 - (first["started"] as? Double ?? 0)) / 60)
        let more = run.count > 1 ? " 외 \(run.count - 1)개" : ""
        return "🛠 \(first["agent"] as? String ?? "") · \(first["repo"] as? String ?? "") 작업 중\(more) · \(mins)분째"
    }

    // MARK: 한도 · 피곤함

    private func loadQuota() {
        let url = dir.appendingPathComponent("quota.json")
        let mod = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        if mod != quotaStamp, let d = try? Data(contentsOf: url), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            quotaStamp = mod
            let wins = (o["windows"] as? [[String: Any]] ?? []).compactMap { w -> Quota.Window? in
                guard let name = w["name"] as? String, let used = w["used"] as? Double, let r = w["resets_at"] as? Double else { return nil }
                return Quota.Window(name: name, used: used, resetsAt: Date(timeIntervalSince1970: r))
            }
            quota = Quota(windows: wins, limitedUntil: (o["limited_until"] as? Double).map { Date(timeIntervalSince1970: $0) })
        }
        // 졸기 시작·깨기는 한 번씩만 말한다 (앱을 켰을 때의 상태는 말하지 않는다)
        let sleepy = sleepyUntil != nil
        if let was = wasSleepy, was != sleepy {
            if sleepy {
                say?(Line(text: "하암… Codex 한도를 다 써서 졸리다냥. \(Self.when(sleepyUntil!))까지 잠깐 자겠다냥.", urgent: false))
            } else {
                trick?("stretch")
                say?(Line(text: "푹 잤다냥. 한도가 다시 찼다냥.", urgent: false))
            }
        }
        wasSleepy = sleepy
    }

    /// 한도가 바닥나 쉬는 동안: 바닥난 창이 리셋되는 시각
    var sleepyUntil: Date? {
        guard let q = quota else { return nil }
        let now = Date()
        let ends = q.windows.filter { $0.used >= 100 && $0.resetsAt > now }.map(\.resetsAt) + [q.limitedUntil].compactMap { $0 }.filter { $0 > now }
        return ends.max()
    }

    /// 피곤함 0~100: 한도를 가장 많이 쓴 창의 비율 (리셋이 지난 창은 0). 바닥나면 100
    var tiredness: Double {
        if sleepyUntil != nil { return 100 }
        let now = Date()
        return quota?.windows.map { $0.resetsAt > now ? $0.used : 0 }.max() ?? 0
    }

    /// "Codex 5시간 0% · 이번 주 16%" 또는 "😴 05:51까지 졸림"
    var quotaLine: String? {
        if let s = sleepyUntil { return "😴 Codex 한도 바닥 · \(Self.when(s))까지 졸림" }
        guard let q = quota, !q.windows.isEmpty else { return nil }
        let now = Date()
        return "Codex " + q.windows.map { "\($0.name) \(Int(($0.resetsAt > now ? $0.used : 0).rounded()))%" }.joined(separator: " · ")
    }

    static func when(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : "M/d (E) HH:mm"
        return f.string(from: d)
    }

    /// 사용자가 건 말을 mind/in 에 놓는다
    func send(_ text: String) {
        let ctx = Context.shared.snapshot
        var o: [String: Any] = ["text": text, "ts": Date().timeIntervalSince1970]
        if let app = ctx.app, !ctx.blocked { o["app"] = app }
        let inbox = dir.appendingPathComponent("in")
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let url = inbox.appendingPathComponent("\(Int(Date().timeIntervalSince1970 * 1000)).json")
        guard let d = try? JSONSerialization.data(withJSONObject: o) else { return }
        try? d.write(to: url, options: .atomic)
        chmod(url.path, 0o600)
        // 대화 중 되물은 질문이 열려 있으면 이 말이 그 답이다 (버튼을 안 눌러도 질문이 남지 않게)
        if let ask = openAsk(), ask.followup { answer(askID: ask.id, choices: [text], via: "chat") }
    }

    // MARK: 메뉴

    /// 💬 말 걸기 (말하는 고양이가 켜져 있을 때만)
    func addTalkItem(to menu: NSMenu) {
        if !isOff { menu.addItem("💬 고양이한테 말 걸기 (\(Self.hotKeyName))", #selector(talk), target: self) }
    }

    /// 🧠 말하는 고양이 켜고 끄기 (메뉴 막대 › 🐈 고양이 설정)
    func addToggle(to menu: NSMenu) {
        let t = menu.addItem("🧠 말하는 고양이 (Codex)", #selector(toggle), target: self)
        t.state = isOff ? .off : .on
    }

    /// 🔋 Codex 한도 한 줄 (🤖 에이전트·한도)
    func addQuotaLine(to menu: NSMenu) {
        guard !isOff, let q = quotaLine else { return }
        let i = NSMenuItem(title: "🔋 " + q, action: nil, keyEquivalent: ""); i.isEnabled = false; menu.addItem(i)
    }

    @objc func talk() {
        guard !isOff else { return }
        chat.show()
        opened?()
    }

    // MARK: 대화창이 읽는 것

    struct Message { let role: String; let text: String; let ts: Double }

    /// mind/conversation.jsonl 의 마지막 limit 줄
    func conversation(limit: Int) -> [Message] {
        guard let s = try? String(contentsOf: dir.appendingPathComponent("conversation.jsonl"), encoding: .utf8) else { return [] }
        return s.split(separator: "\n").suffix(limit).compactMap { line in
            guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let role = o["role"] as? String, let text = o["text"] as? String else { return nil }
            return Message(role: role, text: text, ts: o["ts"] as? Double ?? 0)
        }
    }

    struct Ask {
        let id: String
        let text: String
        let choices: [String]
        let multi: Bool        // 여러 개 고르기 (체크 상자)
        let followup: Bool     // 대화 중 되물은 것: 대화창에 글로 답해도 그 답이 된다
    }

    /// 아직 안 답한 고양이 질문 중 가장 최근 것 (inbox/mind-*.json). 이름 끝 숫자(초 또는 밀리초)로 새것을 고른다
    func openAsk() -> Ask? {
        let inbox = dataDir.appendingPathComponent("inbox")
        func stamp(_ u: URL) -> Double {
            let n = Double(u.deletingPathExtension().lastPathComponent.split(separator: "-").last ?? "") ?? 0
            return n > 1e11 ? n / 1000 : n
        }
        let files = ((try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("mind-") && !$0.lastPathComponent.hasPrefix("mind-todo-") && $0.pathExtension == "json" }
            .sorted { stamp($0) > stamp($1) }
        for f in files {
            guard let d = try? Data(contentsOf: f), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let text = o["text"] as? String, o["kind"] as? String != "todo" else { continue }
            if let exp = o["expires"] as? Double, exp < Date().timeIntervalSince1970 { continue }
            let choices = (o["choices"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String ?? $0["id"] as? String }
            return Ask(id: f.deletingPathExtension().lastPathComponent, text: text, choices: choices,
                       multi: o["multi"] as? Bool ?? false, followup: o["followup"] as? Bool ?? false)
        }
        return nil
    }

    /// 고양이 질문에 답: 고양이 메뉴에서 답할 때와 같이 inbox/done 으로 옮긴다 (cat_mind 가 대화 기록으로 가져간다).
    /// 여러 개 골랐으면 answer 는 "A, B", answers 는 목록. via "chat" = 대화창에 글로 답함 (그 말엔 cat_mind 가 따로 답한다)
    func answer(askID: String, choice: String) { answer(askID: askID, choices: [choice]) }

    func answer(askID: String, choices: [String], via: String? = nil) {
        let fm = FileManager.default
        let src = dataDir.appendingPathComponent("inbox/\(askID).json")
        let done = dataDir.appendingPathComponent("inbox/done")
        guard !choices.isEmpty, let d = try? Data(contentsOf: src), var o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
        o["answer"] = choices.joined(separator: ", ")
        if o["multi"] as? Bool == true { o["answers"] = choices }
        if let via { o["via"] = via }
        o["resolved"] = Date().timeIntervalSince1970
        try? fm.createDirectory(at: done, withIntermediateDirectories: true)
        let dest = done.appendingPathComponent(src.lastPathComponent)
        guard let out = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]),
              (try? out.write(to: dest, options: .atomic)) != nil else { return }
        chmod(dest.path, 0o600)
        try? fm.removeItem(at: src)
    }

    /// 받아 적기에 힌트로 주는 말: 고양이 부르는 말 + 프로젝트 이름
    var voiceHints: [String] {
        var h = ["냥이", "고양이", "냥전트", "Meowgent", "Codex", "Claude"]
        if let d = try? Data(contentsOf: dataDir.appendingPathComponent("projects.json")),
           let p = try? JSONSerialization.jsonObject(with: d) as? [String: String] {
            h += p.values.compactMap { $0.split(separator: ":").first.map { $0.trimmingCharacters(in: .whitespaces) } }
        }
        return h
    }

    @objc func toggle() {
        let off = dir.appendingPathComponent("off")
        if isOff {
            try? FileManager.default.removeItem(at: off)
            say?(Line(text: "다시 말해 주겠다냥.", urgent: true))
        } else {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: off.path, contents: nil)
            say?(Line(text: "알겠다냥. 나도 조용한 게 좋다냥.", urgent: true))
        }
        Log.write("말하는 고양이 \(isOff ? "끔" : "켬")")
    }
}
