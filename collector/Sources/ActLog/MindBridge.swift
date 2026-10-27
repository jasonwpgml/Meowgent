import AppKit

/// 말하는 고양이(brain/cat_mind.py)와 앱을 잇는다. 둘은 데이터 폴더의 `mind/` 파일로만 이야기한다.
///  - mind/in/*.json   사용자가 고양이에게 건 말 (여기서 쓴다)
///  - mind/out/*.json  고양이가 할 말 (cat_mind 가 쓰고, 여기서 읽어 말풍선으로 보낸 뒤 지운다)
///  - mind/off         있으면 말하는 고양이를 끈다
///  - mind/alive.json  cat_mind 가 10초마다 남기는 신호
final class MindBridge: NSObject {
    struct Line { let text: String; let urgent: Bool }
    var say: ((Line) -> Void)?

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

    func start() {
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
        }
    }

    private func poll() {
        queue.async { [weak self] in
            guard let self else { return }
            let out = self.dir.appendingPathComponent("out")
            let files = ((try? FileManager.default.contentsOfDirectory(at: out, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            for f in files {
                defer { try? FileManager.default.removeItem(at: f) }
                guard let d = try? Data(contentsOf: f), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                      let text = (o["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { continue }
                let line = Line(text: text, urgent: o["urgent"] as? Bool ?? false)
                DispatchQueue.main.async { self.say?(line) }
            }
        }
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
    }

    // MARK: 메뉴

    func addMenuItems(to menu: NSMenu) {
        if !isOff { menu.addItem("💬 고양이한테 말 걸기 (\(Self.hotKeyName))", #selector(talk), target: self) }
        let t = menu.addItem("🧠 말하는 고양이 (Codex)", #selector(toggle), target: self)
        t.state = isOff ? .off : .on
    }

    @objc func talk() {
        guard !isOff else { return }
        chat.show()
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

    /// 아직 안 답한 고양이 질문 중 가장 최근 것 (inbox/mind-*.json)
    func openAsk() -> (id: String, text: String, choices: [String])? {
        let inbox = dataDir.appendingPathComponent("inbox")
        let files = ((try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("mind-") && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for f in files {
            guard let d = try? Data(contentsOf: f), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let text = o["text"] as? String else { continue }
            if let exp = o["expires"] as? Double, exp < Date().timeIntervalSince1970 { continue }
            let choices = (o["choices"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String ?? $0["id"] as? String }
            return (f.deletingPathExtension().lastPathComponent, text, choices)
        }
        return nil
    }

    /// 고양이 질문에 답: 고양이 메뉴에서 답할 때와 같이 inbox/done 으로 옮긴다 (cat_mind 가 대화 기록으로 가져간다)
    func answer(askID: String, choice: String) {
        let fm = FileManager.default
        let src = dataDir.appendingPathComponent("inbox/\(askID).json")
        let done = dataDir.appendingPathComponent("inbox/done")
        guard let d = try? Data(contentsOf: src), var o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
        o["answer"] = choice
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
            say?(Line(text: "다시 말할 수 있다냥. 반갑다냥!", urgent: true))
        } else {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: off.path, contents: nil)
            say?(Line(text: "알겠다냥. 조용히 옆에만 있겠다냥.", urgent: true))
        }
        Log.write("말하는 고양이 \(isOff ? "끔" : "켬")")
    }
}
