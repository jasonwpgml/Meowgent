import AppKit
import ApplicationServices

private func tapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                         refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if let refcon {
        Unmanaged<InputTap>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
    }
    return Unmanaged.passUnretained(event)
}

/// 읽기 전용(listen-only) 이벤트 탭. 키 "내용"은 보지 않는다: 횟수와 Enter 여부, ⌘·⌃ 조합(단축키 힌트용)만.
/// 콜백은 전용 스레드에서 돌고, 여기서는 세기·큐에 넣기만 한다 (느리면 시스템이 탭을 꺼 버린다).
final class InputTap {
    var onKey: ((_ isReturn: Bool, _ shift: Bool) -> Void)?
    var onPaste: (() -> Void)?
    /// ⌘나 ⌃와 함께 누른 조합 ("⇧⌘T"). 그냥 타자·⌥만 누른 글자는 오지 않는다
    var onChord: ((String) -> Void)?
    var onClick: ((_ point: CGPoint, _ button: String, _ ts: Double, _ mono: UInt64) -> Void)?

    private var tap: CFMachPort?
    private let lock = NSLock()
    private var keys = 0, clicks = 0, scrolls = 0
    private var mouseDistance = 0.0
    private var lastPoint: CGPoint?
    private(set) var reenabled = 0
    private var thread: Thread?

    var isEnabled: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    func start() -> Bool {
        if tap != nil { return true }
        let types: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown,
                                    .scrollWheel, .mouseMoved, .leftMouseDragged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                        eventsOfInterest: mask, callback: tapCallback,
                                        userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            return false
        }
        tap = t
        let th = Thread {
            let src = CFMachPortCreateRunLoopSource(nil, t, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
            CGEvent.tapEnable(tap: t, enable: true)
            CFRunLoopRun()
        }
        th.name = "actlog.tap"
        th.qualityOfService = .userInteractive
        th.start()
        thread = th
        return true
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            lock.lock(); reenabled += 1; lock.unlock()
        case .keyDown:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            let isReturn = code == 36 || code == 76
            let shift = event.flags.contains(.maskShift)
            let repeatKey = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            lock.lock(); keys += 1; lock.unlock()
            let f = event.flags
            if !repeatKey, let onChord,
               let chord = Keys.chord(keyCode: Int(code), control: f.contains(.maskControl), option: f.contains(.maskAlternate),
                                      shift: shift, command: f.contains(.maskCommand)) {
                DispatchQueue.main.async { onChord(chord) }
            }
            // Cmd+V (물리 키 위치라 한글 자판에서도 같다). 내용은 메인 스레드에서 클립보드로 읽는다
            if code == 9 && event.flags.contains(.maskCommand) && !repeatKey, let onPaste {
                DispatchQueue.main.async { onPaste() }
            } else if !repeatKey, let onKey {
                DispatchQueue.main.async { onKey(isReturn, shift) }
            }
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            lock.lock(); clicks += 1; lock.unlock()
            let button = type == .leftMouseDown ? "left" : (type == .rightMouseDown ? "right" : "other")
            onClick?(event.location, button, Date().timeIntervalSince1970, clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
        case .scrollWheel:
            lock.lock(); scrolls += 1; lock.unlock()
        case .mouseMoved, .leftMouseDragged:
            let p = event.location
            lock.lock()
            if let l = lastPoint { mouseDistance += hypot(p.x - l.x, p.y - l.y) }
            lastPoint = p
            lock.unlock()
        default:
            break
        }
    }

    /// 1분 집계를 꺼내고 0으로 되돌린다.
    func drain() -> (keys: Int, clicks: Int, scrolls: Int, mouse: Int) {
        lock.lock(); defer { lock.unlock() }
        let r = (keys, clicks, scrolls, Int(mouseDistance))
        keys = 0; clicks = 0; scrolls = 0; mouseDistance = 0
        return r
    }
}

/// 클릭한 위치의 UI 요소 → "button 'Commit'" 같은 의미 있는 대상.
final class ClickResolver {
    private let store: Store
    /// 기록해도 되는 왼쪽 클릭마다: 단축키 힌트 판단용 (클릭한 요소의 프로세스 번호와 함께)
    var onShortcutClick: ((ShortcutClick, pid_t?) -> Void)?
    private let systemWide = AXUIElementCreateSystemWide()

    private static let actionable: Set<String> = [
        "AXButton", "AXLink", "AXMenuItem", "AXMenuBarItem", "AXCheckBox", "AXRadioButton", "AXPopUpButton",
        "AXMenuButton", "AXDisclosureTriangle", "AXTab", "AXCell", "AXRow", "AXTextField", "AXTextArea",
        "AXComboBox", "AXSearchField", "AXSlider", "AXIncrementor", "AXDockItem", "AXSwitch",
    ]

    init(store: Store) { self.store = store }

    func resolve(point: CGPoint, button: String, ts: Double, mono: UInt64) {
        // AX 조회는 메인 스레드에서 한다. 클릭 지점이 ActLog 자신의 메뉴바 아이콘·메뉴면
        // 같은 프로세스 안에서 AppKit 접근성 코드가 돌게 되는데, 이걸 다른 스레드에서 하면 충돌한다
        // (2026-10-14 메뉴 열 때 EXC_BAD_ACCESS). 상대 앱이 느리면 최대 0.5초 막힐 수 있지만 우리 UI는 메뉴뿐이다.
        DispatchQueue.main.async { [self] in
            let snap = Context.shared.snapshot
            var hit: AXUIElement?
            guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hit) == .success,
                  let hit else { return }
            if AX.pid(hit) == getpid() { return }   // ActLog 자신의 메뉴 클릭은 기록하지 않는다
            var el = hit
            var target: AXUIElement?
            for _ in 0..<6 {
                if let role = AX.string(el, kAXRoleAttribute), ClickResolver.actionable.contains(role) { target = el; break }
                guard let parent = AX.element(el, kAXParentAttribute) else { break }
                el = parent
            }
            let t = target ?? hit
            let role = AX.string(t, kAXRoleAttribute) ?? "?"
            let subrole = AX.string(t, kAXSubroleAttribute)

            var e = Event("click")
            e.ts = ts
            e.mono = mono
            // 클릭 대상 앱 = 그 요소의 프로세스 (뒤쪽 창을 눌러 앱이 바뀌는 경우도 정확히)
            let pid = AX.pid(t)
            let app = pid.flatMap { NSRunningApplication(processIdentifier: $0) }
            e.pid = pid
            e.app = app?.localizedName
            e.bundle = app?.bundleIdentifier
            var payload: [String: Any] = ["button": button, "role": role]
            if let subrole { payload["subrole"] = subrole }

            let sameApp = pid != nil && pid == snap.pid
            let blocked = Privacy.isBlocked(bundle: e.bundle) || (sameApp && snap.blocked)
            if blocked {
                e.privacy = "blocked"
            } else if AX.isSecure(role: role, subrole: subrole) {
                e.privacy = "secure_gap"
            } else {
                // 안쪽 텍스트까지 뒤지는 건 버튼·링크·메뉴 같은 "누르는 것"일 때만 (빈 곳 클릭으로 대화 내용이 딸려오지 않게)
                let deep = target != nil && !["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXRow", "AXCell"].contains(role)
                if let label = AX.label(t, deep: deep) { payload["label"] = Privacy.redact(label).0 }
                if let id = AX.string(t, kAXIdentifierAttribute), !id.isEmpty { payload["id"] = AX.clip(id, 80) }
                if sameApp { e.window = snap.window; e.url = snap.url }
                if button == "left", let onShortcutClick {
                    onShortcutClick(shortcutClick(t, role: role, subrole: subrole, label: payload["label"] as? String, bundle: e.bundle), pid)
                }
            }
            e.payload = payload
            store.write(e)
        }
    }

    private func shortcutClick(_ el: AXUIElement, role: String, subrole: String?, label: String?, bundle: String?) -> ShortcutClick {
        var c = ShortcutClick(bundle: bundle, role: role, subrole: subrole, label: label)
        if role == "AXMenuItem" {
            c.menuKeys = Keys.menu(char: AX.string(el, kAXMenuItemCmdCharAttribute),
                                   virtualKey: AX.int(el, kAXMenuItemCmdVirtualKeyAttribute),
                                   modifiers: AX.int(el, kAXMenuItemCmdModifiersAttribute) ?? 0)
        } else if ["AXButton", "AXMenuButton", "AXTextField", "AXComboBox"].contains(role) || subrole == "AXTabButton" {
            // 웹 페이지 안쪽인지: 창에 닿을 때까지 부모를 올라가며 AXWebArea를 찾는다
            var p = AX.element(el, kAXParentAttribute)
            for _ in 0..<40 {
                guard let cur = p, let r = AX.string(cur, kAXRoleAttribute), r != "AXWindow", r != "AXApplication" else { break }
                if r == "AXWebArea" { c.inWeb = true; break }
                p = AX.element(cur, kAXParentAttribute)
            }
        }
        return c
    }
}
