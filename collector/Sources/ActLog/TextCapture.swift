import AppKit
import ApplicationServices

/// 입력 텍스트 수집. 키 이벤트로 글자를 복원하지 않고(한글은 조합 전 자모만 보인다),
/// 포커스된 입력창의 값(AXValue)을 읽어 직전 커밋 값과 비교해 "새로 들어간 글"만 남긴다.
/// 커밋 시점: Enter / 포커스 이동 / 입력 정지 N초.  모든 메서드는 메인 스레드에서 호출.
final class TextCapture {
    private let store: Store
    var aiResponses: AIResponseCapture?
    private var element: AXUIElement?
    private var pid: pid_t = 0
    private var bundle: String?
    private var appName: String?
    private var role = ""
    private var fieldLabel: String?
    private var placeholder: String?
    private var isAIField = false
    private var pastedChars = 0
    private var baseline = ""
    private var latest = ""
    private var keysSinceCommit = 0
    private var startedAt: Double?
    private var largeDocument = false
    private var idleTimer: Timer?
    private var refreshTimer: Timer?
    private var observedElement: AXUIElement?
    private weak var observer: AXObserver?

    private static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    init(store: Store) { self.store = store }

    /// 포커스가 바뀌었다: 이전 입력창을 커밋하고 새 입력창을 붙잡는다.
    func focusChanged(appElement: AXUIElement, pid: pid_t, bundle: String?, appName: String?, observer: AXObserver?) {
        commit(reason: "focus")
        detach()
        guard let f = AX.element(appElement, kAXFocusedUIElementAttribute) else { return }
        attach(f, pid: pid, bundle: bundle, appName: appName, observer: observer)
    }

    func appDeactivated() {
        commit(reason: "app_switch")
        detach()
    }

    private func attach(_ f: AXUIElement, pid: pid_t, bundle: String?, appName: String?, observer: AXObserver?) {
        let role = AX.string(f, kAXRoleAttribute) ?? ""
        let subrole = AX.string(f, kAXSubroleAttribute)
        secureFocus = AX.isSecure(role: role, subrole: subrole)
        if secureFocus {
            // 비밀번호 칸: 값은 절대 읽지 않는다. 존재만 남긴다.
            var e = Event("text", payload: ["field_role": "secure"], privacy: "secure_gap")
            e.fillContext()
            store.write(e)
            return
        }
        if let b = bundle, Privacy.config.textSkipBundles.contains(b) { return }
        guard TextCapture.textRoles.contains(role) || AX.isSettable(f, kAXValueAttribute) else { return }

        element = f
        self.pid = pid
        self.bundle = bundle
        self.appName = appName
        self.role = role
        fieldLabel = AX.label(f)
        placeholder = AX.string(f, "AXPlaceholderValue")
        isAIField = Privacy.aiChat(url: Context.shared.snapshot.url, bundle: bundle) != nil
        pastedChars = 0
        let v = readValue()
        baseline = v ?? ""
        latest = baseline
        keysSinceCommit = 0
        startedAt = nil

        // 앱 단위 알림을 못 받는 앱이 있어 입력창 자체에도 값 변경 알림을 건다.
        if let observer {
            AXObserverAddNotification(observer, f, kAXValueChangedNotification as CFString, nil)
            observedElement = f
            self.observer = observer
        }
    }

    private func detach() {
        if let observer, let observedElement {
            AXObserverRemoveNotification(observer, observedElement, kAXValueChangedNotification as CFString)
        }
        observedElement = nil
        element = nil
        secureFocus = false
        idleTimer?.invalidate(); idleTimer = nil
        refreshTimer?.invalidate(); refreshTimer = nil
    }

    /// 값을 읽는다. 아주 긴 문서(편집기 본문 등)는 diff 비용 때문에 내용을 건너뛴다.
    private func readValue() -> String? {
        guard let element else { return nil }
        if let n = AX.int(element, kAXNumberOfCharactersAttribute), n > Privacy.config.largeDocumentChars {
            largeDocument = true
            return nil
        }
        largeDocument = false
        let v = AX.string(element, kAXValueAttribute)
        // 빈 입력창이 안내 문구("메시지를 입력하세요" 등)를 값으로 돌려주는 앱이 있다
        if let v, let placeholder, !placeholder.isEmpty, v == placeholder { return "" }
        return v
    }

    /// AX 값 변경 알림.
    func valueChanged() {
        guard element != nil else { return }
        guard let v = readValue() else { return }
        latest = v
        if keysSinceCommit == 0 {
            // 키 입력 없이 바뀐 값 = 프로그램이 바꾼 것 (전송 후 비우기, 자동 갱신 등) → 기준선만 옮긴다.
            baseline = v
        }
    }

    /// 입력 탭이 알려주는 키 입력 (내용은 모름, Enter 여부만).
    func keyPressed(isReturn: Bool, shift: Bool) {
        guard element != nil else { return }
        if isReturn && !shift && !(bundle.map { Privacy.config.editorBundles.contains($0) } ?? false) {
            // 앱이 Enter를 먼저 처리해 입력창을 비웠을 수 있다. 지금 읽은 값에 새 글이 있으면 그걸,
            // 아니면 마지막으로 읽어 둔 값으로 커밋한다.
            if let v = readValue(), !TextCapture.diff(old: baseline, new: v).0
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                latest = v
            }
            commit(reason: "enter", reread: false)
            return
        }
        keysSinceCommit += 1
        if startedAt == nil { startedAt = Date().timeIntervalSince1970 }
        // 값 변경 알림이 안 오는 앱 대비: 키 입력 0.25초 뒤 값을 다시 읽는다.
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
            guard let self, let v = self.readValue() else { return }
            self.latest = v
        }
        idleTimer?.invalidate()
        // AI 대화창은 메시지 하나가 토막 나지 않게 Enter·입력창 이동 때만 저장 (60초는 안전장치)
        let pause = isAIField ? 60 : Privacy.config.textIdlePauseSeconds
        idleTimer = Timer.scheduledTimer(withTimeInterval: pause, repeats: false) { [weak self] _ in
            self?.commit(reason: "idle")
        }
    }

    /// Cmd+V: 이번 입력 조각에 붙여넣은 글이 섞여 있다고 표시하기 위해.
    func notePaste(chars: Int) {
        guard element != nil else { return }
        pastedChars += chars
        keysSinceCommit += 1
        if startedAt == nil { startedAt = Date().timeIntervalSince1970 }
    }

    /// 지금 입력창 이름 (붙여넣기 기록용)
    var currentField: (role: String, label: String?)? { element == nil ? nil : (role, fieldLabel) }
    /// 지금 포커스가 비밀번호 칸에 있다 (값은 안 읽지만, 붙여넣기 내용도 남기면 안 된다)
    private(set) var secureFocus = false

    func commit(reason: String, reread: Bool = true) {
        idleTimer?.invalidate(); idleTimer = nil
        guard element != nil, keysSinceCommit > 0 || reason == "enter" else { return }
        if reread, let v = readValue() { latest = v }
        let keys = keysSinceCommit
        let started = startedAt
        let pasted = pastedChars
        pastedChars = 0
        keysSinceCommit = 0
        startedAt = nil

        var e = Event("text")
        e.fillContext()
        e.app = appName ?? e.app
        e.bundle = bundle ?? e.bundle
        e.pid = pid
        var payload: [String: Any] = ["reason": reason, "keys": keys, "field_role": role]
        if let fieldLabel { payload["field"] = fieldLabel }
        if let started { payload["started"] = started }

        if largeDocument {
            payload["text_unavailable"] = "large_document"
            e.payload = payload
            store.write(e)
            return
        }
        let (inserted, deleted) = TextCapture.diff(old: baseline, new: latest)
        baseline = latest
        let trimmed = inserted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }   // 지우기만 한 경우는 기록하지 않는다
        // 입력창을 떠날 때 조합 중이던 자음·모음 한두 개("ㅂ")는 버린다
        if trimmed.count <= 2 && trimmed.unicodeScalars.allSatisfy({ (0x3130...0x318F).contains($0.value) }) { return }
        if pasted > 0 { payload["pasted_chars"] = pasted }
        payload["deleted"] = deleted

        if Context.shared.snapshot.blocked || Privacy.isBlocked(bundle: bundle) {
            payload["chars"] = trimmed.count
            e.payload = payload
            e.privacy = "blocked"
            store.write(e)
            return
        }
        var text = trimmed
        if text.count > Privacy.config.maxTextChars {
            text = String(text.prefix(Privacy.config.maxTextChars))
            payload["truncated"] = true
        }
        let (redacted, masked) = Privacy.redact(text)
        payload["text"] = redacted
        payload["chars"] = trimmed.count
        let ai = Privacy.aiChat(url: e.url, bundle: e.bundle)
        if let ai {
            payload["kind"] = "ai_prompt"
            payload["ai"] = ai
        }
        e.payload = payload
        if masked { e.privacy = "masked" }
        store.write(e)

        // AI에게 보낸 질문이면 답변이 다 나올 때까지 지켜본다 (Enter로 보냈거나, 보내기 버튼 클릭 후 입력창을 떠난 경우)
        if let ai, Privacy.config.captureAIResponses, reason == "enter" || reason == "focus",
           Privacy.config.aiResponsesFromDesktopApps || Privacy.aiDesktopApps[bundle ?? ""] == nil,
           let element {
            aiResponses?.start(prompt: trimmed, ai: ai, pid: pid, bundle: bundle, appName: appName,
                               webArea: AIResponseCapture.webArea(containing: element), url: e.url, window: e.window)
        }
    }

    /// 공통 접두·접미를 뺀 가운데 = 새로 들어간 글. (지운 글자 수도 함께)
    static func diff(old: String, new: String) -> (String, Int) {
        let o = Array(old), n = Array(new)
        var p = 0
        while p < o.count && p < n.count && o[p] == n[p] { p += 1 }
        var s = 0
        while s < o.count - p && s < n.count - p && o[o.count - 1 - s] == n[n.count - 1 - s] { s += 1 }
        return (String(n[p..<(n.count - s)]), o.count - p - s)
    }
}
