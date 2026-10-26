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
        switch notification {
        case kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification:
            refreshWindow()
        case kAXTitleChangedNotification:
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
        if key != lastWindowKey {
            lastWindowKey = key
            Context.shared.update { $0.window = title.isEmpty ? nil : title }
            let s = Context.shared.snapshot
            var e = Event("window", privacy: s.blocked ? "blocked" : "none")
            if let doc, !s.blocked { e.payload["document"] = Privacy.sanitize(url: doc) ?? doc }
            e.fillContext(s)
            store.write(e)
        }
        if BrowserWatcher.isBrowser(app.bundleIdentifier) {
            browser.refresh(bundle: app.bundleIdentifier!)
        }
    }
}
