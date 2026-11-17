import AppKit
import ApplicationServices

private let axCallback: AXObserverCallback = { _, element, notification, refcon in
    guard let refcon else { return }
    let me = Unmanaged<AppWatcher>.fromOpaque(refcon).takeUnretainedValue()
    me.handle(notification as String, element: element)
}

/// 앱 전환(NSWorkspace) + 창 제목·포커스·값 변경(AXObserver). 메인 스레드 전용.
final class AppWatcher {
    private let store: Store
    let text: TextCapture
    let browser: BrowserWatcher
    private var observers: [pid_t: AXObserver] = [:]
    private var manualAXSet: Set<pid_t> = []
    private var current: NSRunningApplication?
    private var currentAppElement: AXUIElement?
    private var lastWindowKey = ""
    private var titleDebounce: Timer?
    /// 문맥(앱·탭·창)이 바뀌기 직전. 막힌 곳에서 방금 한 복사를 바뀐 문맥으로 잘못 기록하지 않게 클립보드를 먼저 확인한다.
    var beforeContextChange: (() -> Void)?

    init(store: Store, text: TextCapture, browser: BrowserWatcher) {
        self.store = store
        self.text = text
        self.browser = browser
    }

    func start() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.activated(app)
        }
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.observers.removeValue(forKey: app.processIdentifier)
            self?.manualAXSet.remove(app.processIdentifier)
        }
        if let front = NSWorkspace.shared.frontmostApplication { activated(front) }
    }

    private func activated(_ app: NSRunningApplication) {
        if app.bundleIdentifier == Bundle.main.bundleIdentifier { return }
        beforeContextChange?()
        text.appDeactivated()
        current = app
        let pid = app.processIdentifier
        let bundle = app.bundleIdentifier
        let name = app.localizedName
        let blocked = Privacy.isBlocked(bundle: bundle)

        Context.shared.update {
            $0.app = name; $0.bundle = bundle; $0.pid = pid
            $0.window = nil; $0.url = nil
            $0.appBlocked = blocked; $0.urlBlocked = false; $0.incognito = false
            // 목록 밖 브라우저(Firefox 등)는 주소를 읽을 방법이 없어 늘 모르는 상태 = 막힘
            $0.urlUnknown = BrowserWatcher.isBrowser(bundle) || BrowserWatcher.isOtherBrowser(bundle)
            $0.ready = true
        }
        var e = Event("app", payload: ["event": "activate"], privacy: blocked ? "blocked" : "none")
        e.app = name; e.bundle = bundle; e.pid = pid
        store.write(e)
        lastWindowKey = ""

        guard !blocked else { currentAppElement = nil; return }
        let appEl = AXUIElementCreateApplication(pid)
        currentAppElement = appEl
        enableElectronAX(app, appEl)
        attachObserver(pid: pid, appEl: appEl)
        refreshWindow()
        text.focusChanged(appElement: appEl, pid: pid, bundle: bundle, appName: name, observer: observers[pid])
    }

    /// Electron 앱은 AX 트리를 기본으로 꺼 둔다. 처음 활성화될 때 한 번만 켜 달라고 요청한다.
    private func enableElectronAX(_ app: NSRunningApplication, _ appEl: AXUIElement) {
        let pid = app.processIdentifier
        guard !manualAXSet.contains(pid), let url = app.bundleURL else { return }
        manualAXSet.insert(pid)
        let electron = url.appendingPathComponent("Contents/Frameworks/Electron Framework.framework")
        if FileManager.default.fileExists(atPath: electron.path) {
            let r = AX.set(appEl, "AXManualAccessibility", kCFBooleanTrue)
            Log.write("AXManualAccessibility \(app.bundleIdentifier ?? "?") → \(r.rawValue)")
        }
    }

    private func attachObserver(pid: pid_t, appEl: AXUIElement) {
        guard observers[pid] == nil else { return }
        var obs: AXObserver?
        guard AXObserverCreate(pid, axCallback, &obs) == .success, let obs else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for n in [kAXFocusedWindowChangedNotification, kAXFocusedUIElementChangedNotification,
                  kAXTitleChangedNotification, kAXValueChangedNotification, kAXMainWindowChangedNotification] {
            AXObserverAddNotification(obs, appEl, n as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        observers[pid] = obs
    }

    func handle(_ notification: String, element: AXUIElement) {
        guard let app = current, let pid = AX.pid(element), pid == app.processIdentifier else { return }
        let browserApp = BrowserWatcher.isBrowser(app.bundleIdentifier)
        switch notification {
        case kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification:
            beforeContextChange?()
            refreshWindow()
        case kAXTitleChangedNotification:
            // 브라우저 제목이 바뀌면 탭이 바뀌었을 수 있다: 새 주소를 읽기 전까지는 직전 주소로 판정하지 않는다
            if browserApp {
                beforeContextChange?()
                Context.shared.update { if $0.pid == pid { $0.urlUnknown = true } }
            }
            // 터미널·브라우저 등은 제목이 연달아 바뀐다 → 0.4초 몰아서 처리
            titleDebounce?.invalidate()
            titleDebounce = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
                self?.refreshWindow()
            }
        case kAXFocusedUIElementChangedNotification:
            if let appEl = currentAppElement {
                text.focusChanged(appElement: appEl, pid: pid, bundle: app.bundleIdentifier,
                                  appName: app.localizedName, observer: observers[pid])
            }
        case kAXValueChangedNotification:
            text.valueChanged()
        default:
            break
        }
    }

    func refreshWindow() {
        guard let app = current, let appEl = currentAppElement else { return }
        let win = AX.element(appEl, kAXFocusedWindowAttribute)
        let title = win.flatMap { AX.string($0, kAXTitleAttribute) } ?? ""
        let doc = win.flatMap { AX.string($0, kAXDocumentAttribute) }
        let key = "\(app.processIdentifier)|\(title)"
        let browserBundle = BrowserWatcher.isBrowser(app.bundleIdentifier) ? app.bundleIdentifier : nil
        if key != lastWindowKey {
            lastWindowKey = key
            Context.shared.update {
                $0.window = title.isEmpty ? nil : title
                if browserBundle != nil { $0.url = nil; $0.urlUnknown = true }
            }
            // 브라우저는 새 주소를 먼저 읽고 나서 창 기록을 남긴다 (못 읽으면 모르는 상태 = 막힘으로 남는다)
            if let b = browserBundle { browser.refresh(bundle: b) }
            let s = Context.shared.snapshot
            var e = Event("window", privacy: s.blocked ? "blocked" : "none")
            if let doc, !s.blocked { e.payload["document"] = Privacy.sanitize(url: doc) ?? doc }
            e.fillContext(s)
            store.write(e)
        } else if let b = browserBundle {
            browser.refresh(bundle: b)
        }
    }
}
