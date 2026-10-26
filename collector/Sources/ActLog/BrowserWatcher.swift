import AppKit

/// 브라우저 현재 탭의 URL·제목 (AppleScript).
/// osascript 자식 프로세스로 돌리면 허용 창이 안 뜨고 조용히 거부된다(launchd로 띄운 경우 특히).
/// 그래서 ActLog 자신이 권한을 요청하고(AEDeterminePermissionToAutomateTarget) 스크립트도 직접 실행한다.
final class BrowserWatcher {
    private let store: Store
    var aiResponses: AIResponseCapture?
    private let queue = DispatchQueue(label: "actlog.browser")
    private var running = false
    private var pending: String?
    private var lastURL: String?
    private var pollTimer: Timer?
    /// 브라우저별 Apple Events 권한: nil = 아직 모름, true = 허용, false = 거부/불가
    private var permission: [String: Bool] = [:]
    private var asking: Set<String> = []
    private var recentSearches: [String: Date] = [:]

    static let chromium: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary", "company.thebrowser.Browser",
        "com.brave.Browser", "com.microsoft.edgemac", "com.naver.Whale", "com.vivaldi.Vivaldi",
        "org.chromium.Chromium", "com.operasoftware.Opera",
    ]
    static let safari: Set<String> = ["com.apple.Safari", "com.apple.SafariTechnologyPreview"]

    static func isBrowser(_ bundle: String?) -> Bool {
        guard let bundle else { return false }
        return chromium.contains(bundle) || safari.contains(bundle)
    }

    init(store: Store) {
        self.store = store
        // 제목이 안 바뀌는 단일 페이지 앱의 주소 변경 대비: 브라우저가 앞에 있을 때 5초마다 확인
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            let s = Context.shared.snapshot
            if BrowserWatcher.isBrowser(s.bundle), let b = s.bundle { self?.refresh(bundle: b) }
        }
    }

    /// 메인 스레드에서 호출.
    func refresh(bundle: String) {
        switch permission[bundle] {
        case .none:
            askPermission(bundle)
            return
        case .some(false):
            return
        case .some(true):
            break
        }
        if running { pending = bundle; return }
        running = true
        // NSAppleScript는 메인 스레드에서. 스크립트 안에 2초 타임아웃이 있고 보통 수십 ms.
        let result = BrowserWatcher.query(bundle: bundle)
        running = false
        if let result { apply(bundle: bundle, result) }
        if let p = pending { pending = nil; DispatchQueue.main.async { self.refresh(bundle: p) } }
    }

    /// 사용자가 허용/거부를 누를 때까지 막히므로 별도 큐에서 묻는다.
    private func askPermission(_ bundle: String) {
        guard !asking.contains(bundle) else { return }
        asking.insert(bundle)
        queue.async { [weak self] in
            let target = NSAppleEventDescriptor(bundleIdentifier: bundle)
            let status = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, true)
            DispatchQueue.main.async {
                guard let self else { return }
                self.asking.remove(bundle)
                switch status {
                case noErr:
                    self.permission[bundle] = true
                    Log.write("브라우저 제어 허용됨: \(bundle)")
                    self.refresh(bundle: bundle)
                case OSStatus(procNotFound):
                    break   // 브라우저가 아직 안 떠 있음 → 다음에 다시 묻는다
                default:
                    self.permission[bundle] = false
                    Log.write("브라우저 제어 불가 (\(status)): \(bundle) — 시스템 설정 > 개인정보 보호 및 보안 > 자동화에서 허용 후 다시 시작")
                }
            }
        }
    }

    private func apply(bundle: String, _ raw: (url: String, title: String, incognito: Bool)) {
        let r = (url: Privacy.sanitize(url: raw.url) ?? raw.url, title: raw.title, incognito: raw.incognito)
        // 응답이 오는 사이에 다른 앱으로 넘어갔으면 버린다
        guard Context.shared.snapshot.bundle == bundle else { return }
        let blocked = Privacy.isBlocked(url: r.url)
        Context.shared.update {
            $0.url = (blocked || r.incognito) ? nil : r.url
            $0.urlBlocked = blocked
            $0.incognito = r.incognito
        }
        let key = r.incognito ? "incognito" : (blocked ? "blocked:" + (URL(string: r.url)?.host ?? "") : r.url)
        guard key != lastURL else { return }
        lastURL = key

        if r.incognito || blocked {
            var e = Event("browser", payload: ["reason": r.incognito ? "incognito" : "blocked_domain"], privacy: "blocked")
            e.fillContext()
            store.write(e)
            return
        }
        var e = Event("browser", payload: ["title": r.title])
        e.fillContext()
        e.url = r.url
        store.write(e)

        // 같은 검색어가 주소만 바뀌어 반복되는 경우(구글 AI 모드에서 대화를 이어갈 때 등)는 30분 안에 한 번만
        if let q = Privacy.searchQuery(from: r.url), recentSearches[q.engine + "\u{1F}" + q.query].map({ Date().timeIntervalSince($0) > 1800 }) ?? true {
            recentSearches[q.engine + "\u{1F}" + q.query] = Date()
            if recentSearches.count > 500 { recentSearches = recentSearches.filter { Date().timeIntervalSince($0.value) < 1800 } }
            let (redacted, masked) = Privacy.redact(q.query)
            var s = Event("search", payload: ["engine": q.engine, "query": redacted], privacy: masked ? "masked" : "none")
            s.fillContext()
            s.url = r.url
            store.write(s)
            // 구글 AI 모드의 첫 질문은 검색창에서 시작해 새 페이지가 열리므로 여기서 답변 수집을 시작한다
            if q.engine == "google_ai_mode", Privacy.config.captureAIResponses, let pid = Context.shared.snapshot.pid {
                aiResponses?.start(prompt: q.query, ai: "google_ai_mode", pid: pid, bundle: bundle,
                                   appName: s.app, webArea: nil, url: r.url, window: s.window)
            }
        }
    }

    private static func query(bundle: String) -> (url: String, title: String, incognito: Bool)? {
        let script: String
        if chromium.contains(bundle) {
            script = """
            with timeout of 2 seconds
              tell application id "\(bundle)"
                if (count of windows) = 0 then return ""
                set w to front window
                set m to "normal"
                try
                  set m to mode of w
                end try
                return (URL of active tab of w) & linefeed & (title of active tab of w) & linefeed & m
              end tell
            end timeout
            """
        } else {
            script = """
            with timeout of 2 seconds
              tell application id "\(bundle)"
                if (count of documents) = 0 then return ""
                return (URL of front document) & linefeed & (name of front document) & linefeed & "normal"
              end tell
            end timeout
            """
        }
        var err: NSDictionary?
        guard let out = NSAppleScript(source: script)?.executeAndReturnError(&err).stringValue else {
            if let err { Log.write("브라우저 주소 읽기 실패 \(bundle): \(err[NSAppleScript.errorNumber] ?? "?") \(err[NSAppleScript.errorMessage] ?? "")") }
            return nil
        }
        let parts = out.components(separatedBy: "\n")
        guard parts.count >= 2, !parts[0].isEmpty else { return nil }
        return (parts[0], parts[1], parts.count > 2 && parts[2] == "incognito")
    }
}
