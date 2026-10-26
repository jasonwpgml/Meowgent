import AppKit
import ApplicationServices
import Carbon
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let dataDir = AppDelegate.resolveDataDir()
    static let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"

    /// 데이터 폴더: ~/Library/Application Support/Meowgent.
    /// 예전 이름(ActLog) 폴더만 있으면 옮기고, 옛 경로를 읽는 도구(brain 등)를 위해 심볼릭 링크를 남긴다.
    static func resolveDataDir() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let new = base.appendingPathComponent("Meowgent", isDirectory: true)
        let old = base.appendingPathComponent("ActLog", isDirectory: true)
        let fm = FileManager.default
        let oldIsLink = (try? fm.destinationOfSymbolicLink(atPath: old.path)) != nil
        if !fm.fileExists(atPath: new.path), fm.fileExists(atPath: old.path), !oldIsLink {
            do {
                try fm.moveItem(at: old, to: new)
                try fm.createSymbolicLink(at: old, withDestinationURL: new)
            } catch {
                return fm.fileExists(atPath: new.path) ? new : old
            }
        }
        return new
    }

    var store: Store!
    var tap = InputTap()
    var clicks: ClickResolver!
    var text: TextCapture!
    var browser: BrowserWatcher!
    var apps: AppWatcher!
    var system: SystemWatcher!
    var pet: PetController?
    let agents = AgentMonitor()
    lazy var quota = QuotaWatch(dataDir: dataDir)
    lazy var shortcuts = ShortcutCoach(dataDir: dataDir)
    var statusItem: NSStatusItem!
    var resumeTimer: Timer?
    var permissionTimer: Timer?
    var axStarted = false
    var tapStarted = false

    let agent = LaunchAgent()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 인스턴스 정리: launchd가 띄운 쪽(꺼지면 다시 켜 줌)이 주인이다.
        //  - launchd 쪽: 직접 열린 다른 ActLog가 있으면 종료시키고 이어받는다.
        //  - 직접 열린 쪽: 다른 ActLog가 있으면 빠지고, 없으면 기록을 시작한 뒤 launchd 쪽 실행을 요청한다.
        //    launchd 쪽이 뜨면 이 프로세스를 종료시킨다. 요청이 실패해도 이 프로세스가 계속 기록한다.
        let fromLaunchd = ProcessInfo.processInfo.environment["ACTLOG_LAUNCHD"] == "1"
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != getpid() }
        if fromLaunchd {
            others.forEach { $0.terminate() }
        } else if !others.isEmpty {
            exit(0)
        } else if agent.isLoaded {
            agent.kickstart()
        }
        let hadData = FileManager.default.fileExists(atPath: dataDir.appendingPathComponent("actlog.db").path)
        do {
            store = try Store(dir: dataDir)
        } catch {
            NSAlert(error: error).runModal()
            NSApp.terminate(nil)
            return
        }
        Log.url = dataDir.appendingPathComponent("actlog.log")
        Privacy.config = Config.load(dir: dataDir)
        Log.write("Meowgent \(AppDelegate.appVersion) 시작, DB: \(store.path.path)")
        // 활동 기록은 옵트인. 처음 켤 때 묻고, 이미 기록이 있던 설치는 켠 상태를 유지한다.
        if UserDefaults.standard.object(forKey: "recordingEnabled") == nil {
            UserDefaults.standard.set(hadData ? true : askRecordingConsent(), forKey: "recordingEnabled")
        }
        if !recordingEnabled { Context.shared.update { $0.paused = true } }
        store.write(Event("lifecycle", payload: ["event": "start", "version": AppDelegate.appVersion]), force: true)

        clicks = ClickResolver(store: store)
        text = TextCapture(store: store)
        browser = BrowserWatcher(store: store)
        let aiResponses = AIResponseCapture(store: store)
        text.aiResponses = aiResponses
        browser.aiResponses = aiResponses
        apps = AppWatcher(store: store, text: text, browser: browser)
        system = SystemWatcher(store: store, tap: tap)
        tap.onKey = { [weak self] isReturn, shift in
            self?.text.keyPressed(isReturn: isReturn, shift: shift)
            self?.pet?.onKey()
        }
        tap.onPaste = { [weak self] in
            guard let self else { return }
            let r = self.system.recordPaste(field: self.text.currentField)
            self.text.notePaste(chars: r.chars)
            if r.sensitive {
                let s = Context.shared.snapshot
                self.pet?.notify("🔑 방금 붙여넣은 거에 키·토큰·카드번호 같은 게 있다냥. 꼭 확인해 봐라냥\n붙여넣은 곳: \(s.app ?? "?")\(s.url.map { " · " + (URL(string: $0)?.host ?? "") } ?? "")", urgent: true)
            }
        }
        tap.onClick = { [weak self] p, b, ts, mono in self?.clicks.resolve(point: p, button: b, ts: ts, mono: mono) }
        tap.onChord = { [weak self] chord in self?.shortcuts.chord(chord) }
        clicks.onShortcutClick = { [weak self] c, pid in self?.shortcuts.clicked(c, pid: pid) }
        shortcuts.start()

        setupMenu()
        startPet()
        system.start()
        registerAgent()

        // 권한 요청: 손쉬운 사용(창 제목·입력창·클릭 대상) + 입력 모니터링(키·마우스 횟수)
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        if !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }
        startWhenPermitted()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.startWhenPermitted()
        }
    }

    var recordingEnabled: Bool { UserDefaults.standard.bool(forKey: "recordingEnabled") }

    /// 처음 실행: 활동 기록을 켤지 묻는다. 기본은 "고양이만".
    func askRecordingConsent() -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "고양이만 둘까요, 활동도 기록할까요?"
        a.informativeText = """
        Meowgent는 활동 기록을 켜면 앞에 있는 앱·창 제목, 브라우저 주소, 입력한 글, 클릭한 버튼, 복사·붙여넣기 내용을 이 맥 안에만 저장합니다 (~/Library/Application Support/Meowgent). 외부로 보내는 것은 없습니다.
        비밀번호 칸, 은행·결제 사이트, 시크릿 창, 터미널은 기록하지 않습니다.

        고양이만 두면 저장하지 않습니다. 고양이·단축키 힌트·사용량 리마인드는 그대로 동작합니다. 메뉴바에서 언제든 바꿀 수 있습니다.
        """
        a.addButton(withTitle: "고양이만")
        a.addButton(withTitle: "활동 기록도 켜기")
        return a.runModal() == .alertSecondButtonReturn
    }

    /// 권한은 실행 중에 나중에 허용될 수 있으니 될 때까지 다시 시도한다.
    func startWhenPermitted() {
        if !axStarted && AXIsProcessTrusted() {
            AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)
            apps.start()
            axStarted = true
            Log.write("손쉬운 사용 권한 확인 → 앱/창/입력 수집 시작")
        }
        // 권한 없이 만든 탭은 나중에 권한이 생겨도 이벤트를 못 받으므로, 권한 확인 후에만 만든다.
        if !tapStarted && (CGPreflightListenEventAccess() || AXIsProcessTrusted()) && tap.start() {
            tapStarted = true
            Log.write("입력 탭 시작")
        }
        if axStarted && tapStarted { permissionTimer?.invalidate(); permissionTimer = nil }
        updateStatusIcon()
    }

    // MARK: 메뉴바

    /// Meowgent 고양이 (그림 파일이 앱에 들어 있을 때만)
    func startPet() {
        guard UserDefaults.standard.object(forKey: "petEnabled") as? Bool ?? true else { return }
        let p = PetController(dataDir: dataDir)
        p.isPaused = { Context.shared.snapshot.paused }
        p.setPaused = { [weak self] on in on ? self?.pause(minutes: nil) : self?.resume() }
        p.contextLine = {
            let s = Context.shared.snapshot
            guard let app = s.app else { return nil }
            if s.blocked { return app }
            return s.window.map { "\(app) — \(String($0.prefix(40)))" } ?? app
        }
        p.agentSummary = { [weak self] in
            [self?.agents.summary ?? "", self?.quota.attention ?? ""].filter { !$0.isEmpty }.joined(separator: "\n")
        }
        p.extraMenu = { [weak self] m in
            self?.quota.addMenuItems(to: m)
            self?.shortcuts.addMenuItems(to: m)
        }
        shortcuts.show = { [weak p] h in p?.keyHint(h.keys, h.title) ?? false }
        quota.notify = { [weak p] n in p?.notify(n.text, urgent: n.urgent, validUntil: n.validUntil) }
        quota.codexFallback = { [weak self] in self?.agents.codexWindows ?? [] }
        agents.notify = { [weak p] n in p?.notify(n.text, urgent: n.urgent) }
        agents.frontBundle = { Context.shared.snapshot.bundle }
        agents.start()
        quota.start()
        p.start()
        pet = p
    }

    @objc func putToysAway() { pet?.trick("toy-off") }

    @objc func togglePet() {
        if let pet { pet.toggleHidden() } else { startPet() }
    }

    func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateStatusIcon()
    }

    func updateStatusIcon() {
        let s = Context.shared.snapshot
        let ok = axStarted && tap.isEnabled
        statusItem?.button?.title = s.paused ? "◌" : (ok ? "◉" : "◎")
        statusItem?.button?.toolTip = s.paused ? (recordingEnabled ? "Meowgent: 일시정지" : "Meowgent: 고양이만 (기록 꺼짐)") : (ok ? "Meowgent: 기록 중" : "Meowgent: 권한 필요")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = Context.shared.snapshot
        let ax = AXIsProcessTrusted(), input = CGPreflightListenEventAccess()
        func info(_ t: String) { let i = NSMenuItem(title: t, action: nil, keyEquivalent: ""); i.isEnabled = false; menu.addItem(i) }

        info(s.paused ? (recordingEnabled ? "⏸ 일시정지 중" : "○ 고양이만 (활동 기록 꺼짐)") : "● 활동 기록 중")
        info("손쉬운 사용: \(ax ? "허용됨" : "필요")  ·  입력 모니터링: \(input ? "허용됨" : "필요")")
        if IsSecureEventInputEnabled() { info("⚠︎ 다른 앱이 보안 입력 사용 중 (키 횟수 수집 중단)") }
        info("이번 실행 \(store.written)건 기록 · DB \(ByteCountFormatter.string(fromByteCount: store.sizeBytes, countStyle: .file))")
        menu.addItem(.separator())

        if s.paused {
            menu.addItem(recordingEnabled ? "다시 기록" : "활동 기록 켜기", #selector(resume), target: self)
        } else {
            menu.addItem("15분 일시정지", #selector(pause15), target: self)
            menu.addItem("1시간 일시정지", #selector(pause60), target: self)
            menu.addItem("활동 기록 끄기 (고양이만)", #selector(pauseManual), target: self)
        }
        menu.addItem(.separator())
        if !ax { menu.addItem("손쉬운 사용 권한 열기…", #selector(openAXSettings), target: self) }
        if !input { menu.addItem("입력 모니터링 권한 열기…", #selector(openInputSettings), target: self) }
        menu.addItem(pet?.isHidden == false ? "고양이 숨기기" : "고양이 보이기", #selector(togglePet), target: self)
        if pet?.hasToys == true { menu.addItem("🧺 고양이 장난감 치우기", #selector(putToysAway), target: self) }
        menu.addItem("데이터 폴더 열기", #selector(openData), target: self)
        menu.addItem("설정 파일(config.json) 열기", #selector(openConfig), target: self)
        let login = menu.addItem("로그인 시 자동 실행 · 꺼지면 다시 켜기", #selector(toggleLogin), target: self)
        login.state = agent.isInstalled ? .on : .off
        menu.addItem(.separator())
        menu.addItem("Meowgent 정보…", #selector(showAbout), target: self)
        menu.addItem("Meowgent 다시 시작", #selector(relaunch), target: self)
        menu.addItem("Meowgent 종료", #selector(quit), target: self)
    }

    func pause(minutes: Double?) {
        text.commit(reason: "pause")
        Context.shared.update { $0.paused = true }
        store.write(Event("lifecycle", payload: ["event": "pause", "minutes": minutes ?? -1]), force: true)
        resumeTimer?.invalidate()
        if minutes == nil { UserDefaults.standard.set(false, forKey: "recordingEnabled") }
        if let minutes {
            resumeTimer = Timer.scheduledTimer(withTimeInterval: minutes * 60, repeats: false) { [weak self] _ in self?.resume() }
        }
        updateStatusIcon()
    }

    @objc func pause15() { pause(minutes: 15) }
    @objc func pause60() { pause(minutes: 60) }
    @objc func pauseManual() { pause(minutes: nil) }
    @objc func resume() {
        resumeTimer?.invalidate()
        UserDefaults.standard.set(true, forKey: "recordingEnabled")
        Context.shared.update { $0.paused = false }
        store.write(Event("lifecycle", payload: ["event": "resume"]), force: true)
        updateStatusIcon()
    }

    @objc func openAXSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc func openInputSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }
    @objc func openData() { NSWorkspace.shared.open(dataDir) }
    @objc func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Meowgent \(AppDelegate.appVersion)"
        a.informativeText = """
        맥 화면 위를 돌아다니며 할 일을 챙겨 주는 검은 고양이.
        Made by JSonJh (https://github.com/jasonwpgml)

        고양이 그림은 실제 고양이 사진·영상의 실루엣을 따서 직접 찍었습니다. 글꼴 갈무리11(OFL), 참고한 공개 코드와 사진 출처는 "라이선스 보기"에 있습니다.
        """
        a.addButton(withTitle: "닫기")
        a.addButton(withTitle: "라이선스 보기")
        if a.runModal() == .alertSecondButtonReturn, let u = Bundle.main.url(forResource: "LICENSES", withExtension: "md") {
            NSWorkspace.shared.open(u)
        }
    }
    @objc func openConfig() { NSWorkspace.shared.open(dataDir.appendingPathComponent("config.json")) }
    /// 처음 한 번 자동 실행·재시작(LaunchAgent)을 설치한다. 사용자가 메뉴에서 끄면 그 뒤로는 건드리지 않는다.
    func registerAgent() {
        // 예전 방식(SMAppService) 등록이 남아 있으면 정리
        if SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.unregister() }
        let old = SMAppService.agent(plistName: "com.jason.actlog.agent.plist")
        if old.status != .notRegistered && old.status != .notFound { try? old.unregister() }
        agent.removeOld()

        guard !UserDefaults.standard.bool(forKey: "agentOptOut") else { return }
        if !agent.isInstalled || !agent.isLoaded {
            let ok = agent.install()
            Log.write("자동 실행·재시작 설치: \(ok ? "성공" : "실패")")
        }
    }

    @objc func toggleLogin() {
        if agent.isInstalled {
            UserDefaults.standard.set(true, forKey: "agentOptOut")
            agent.uninstall()   // launchd가 이 프로세스를 끝낸다 → 직접 다시 연다
            relaunchDirect()
        } else {
            UserDefaults.standard.set(false, forKey: "agentOptOut")
            _ = agent.install()   // launchd 쪽이 떠서 이 프로세스를 이어받는다
        }
    }

    /// 권한을 켠 뒤 반영이 안 될 때 (macOS가 실행 중인 앱엔 권한 변경을 늦게 알려 줌)
    @objc func relaunch() {
        text.commit(reason: "quit")
        store.write(Event("lifecycle", payload: ["event": "relaunch"]), force: true)
        if agent.isLoaded && ProcessInfo.processInfo.environment["ACTLOG_LAUNCHD"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(75) }   // launchd가 다시 띄운다
        } else {
            relaunchDirect()
        }
    }

    func relaunchDirect() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? p.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
    }

    @objc func quit() {
        text.commit(reason: "quit")
        store.write(Event("lifecycle", payload: ["event": "quit"]), force: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        text?.commit(reason: "quit")
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
