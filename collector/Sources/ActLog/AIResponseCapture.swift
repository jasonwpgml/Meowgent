import AppKit
import ApplicationServices

/// AI에게 질문을 보낸 뒤 화면에 나온 "답변"을 저장한다.
/// 질문 직후 페이지 글 전체를 한 번 찍어 두고, 2초마다 다시 읽어 더 이상 바뀌지 않으면(답변 완료)
/// 질문 문장 뒤에 새로 생긴 부분만 잘라 `ai_response`로 남긴다. 메인 스레드 전용.
final class AIResponseCapture {
    private let store: Store
    private var job: Job?
    private var timer: Timer?

    private struct Job {
        let prompt: String
        let ai: String
        let pid: pid_t
        let bundle: String?
        let appName: String?
        let url: String?
        let window: String?
        var webArea: AXUIElement?
        let before: String
        let startedAt: Date
        var last: String
        var lastChange: Date
        var method: String
    }

    init(store: Store) { self.store = store }

    func start(prompt: String, ai: String, pid: pid_t, bundle: String?, appName: String?,
               webArea: AXUIElement?, url: String?, window: String?) {
        if job != nil { finish(partial: true) }   // 이전 답변을 기다리던 중이면 지금까지 것으로 마감
        let web = webArea ?? AIResponseCapture.findWebArea(pid: pid)
        let (text, method) = web.flatMap { AIResponseCapture.pageText($0) } ?? ("", "none")
        job = Job(prompt: prompt, ai: ai, pid: pid, bundle: bundle, appName: appName, url: url, window: window,
                  webArea: web, before: text, startedAt: Date(), last: text, lastChange: Date(), method: method)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }
    }

    private func poll() {
        guard var j = job else { timer?.invalidate(); return }
        var read = j.webArea.flatMap { AIResponseCapture.pageText($0) }
        if read == nil || read?.0.isEmpty == true {
            // 페이지가 새로 로드되면(검색 → AI 모드 등) 예전 요소는 무효 → 앞 창에서 다시 찾는다
            if let w = AIResponseCapture.findWebArea(pid: j.pid) {
                j.webArea = w
                read = AIResponseCapture.pageText(w)
            }
        }
        let now = Date()
        if let (text, method) = read, !text.isEmpty {
            j.method = method
            if text != j.last { j.last = text; j.lastChange = now }
        }
        job = j
        let elapsed = now.timeIntervalSince(j.startedAt)
        let stableFor = now.timeIntervalSince(j.lastChange)
        let changed = j.last != j.before
        if (changed && elapsed > 4 && stableFor >= 4) || elapsed > 240 {
            finish(partial: elapsed > 240)
        }
    }

    private func finish(partial: Bool) {
        timer?.invalidate(); timer = nil
        guard let j = job else { return }
        job = nil
        let answer = AIResponseCapture.extractAnswer(before: j.before, after: j.last, prompt: j.prompt)
        let elapsed = Int(Date().timeIntervalSince(j.startedAt))
        guard !answer.isEmpty else {
            Log.write("AI 답변 추출 실패 (\(j.ai), 방법 \(j.method), 페이지 \(j.last.count)자)")
            return
        }
        var text = answer
        var payload: [String: Any] = ["ai": j.ai, "prompt": AX.clip(j.prompt, 300), "chars": answer.count,
                                      "wait_s": elapsed, "method": j.method]
        let limit = Privacy.config.maxAIResponseChars
        if text.count > limit { text = String(text.prefix(limit)); payload["truncated"] = true }
        if partial { payload["partial"] = true }
        let (redacted, masked) = Privacy.redact(text)
        payload["text"] = redacted
        var e = Event("ai_response", payload: payload, privacy: masked ? "masked" : "none")
        e.app = j.appName; e.bundle = j.bundle; e.pid = j.pid; e.url = j.url; e.window = j.window
        store.write(e)
    }

    /// 질문 이후에 새로 생긴 글 = 답변.
    /// 1) 전/후 페이지의 공통 앞·뒤(메뉴, "AI는 실수할 수 있습니다" 같은 꼬리말)를 떼고
    /// 2) 그 안에서 질문 문장이 마지막으로 나온 곳 뒤만 남긴다 (화면에 질문이 다시 표시되므로).
    static func extractAnswer(before: String, after: String, prompt: String) -> String {
        var mid = before.isEmpty ? after : TextCapture.diff(old: before, new: after).0
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !p.isEmpty {
            if let r = mid.range(of: p, options: .backwards) {
                mid = String(mid[r.upperBound...])
            } else if p.count > 40, let r = mid.range(of: String(p.prefix(40)), options: .backwards) {
                var rest = mid[r.upperBound...]
                if let tail = rest.range(of: String(p.suffix(20))) { rest = rest[tail.upperBound...] }
                mid = String(rest)
            }
        }
        // 웹 페이지의 아이콘·이미지 자리표시 문자(U+FFFC) 제거
        mid = mid.replacingOccurrences(of: "\u{FFFC}", with: "")
        return mid.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 입력창에서 위로 올라가며 웹 페이지 영역(AXWebArea)을 찾는다.
    static func webArea(containing el: AXUIElement) -> AXUIElement? {
        var cur: AXUIElement? = el
        for _ in 0..<40 {
            guard let c = cur else { return nil }
            if AX.string(c, kAXRoleAttribute) == "AXWebArea" { return c }
            cur = AX.element(c, kAXParentAttribute)
        }
        return nil
    }

    /// 앱의 앞 창에서 웹 페이지 영역을 찾는다 (넓이 우선, 노드 수 제한).
    static func findWebArea(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        guard let win = AX.element(app, kAXFocusedWindowAttribute) else { return nil }
        var queue: [(AXUIElement, Int)] = [(win, 0)]
        var visited = 0
        while !queue.isEmpty && visited < 1500 {
            let (el, depth) = queue.removeFirst()
            visited += 1
            if AX.string(el, kAXRoleAttribute) == "AXWebArea" { return el }
            if depth < 16 { queue.append(contentsOf: AX.children(el).map { ($0, depth + 1) }) }
        }
        return nil
    }

    /// 페이지 글 전체. Chrome·Safari는 "텍스트 마커"로 한 번에 읽을 수 있고, 안 되면 글자 요소를 모은다.
    static func pageText(_ web: AXUIElement) -> (String, String)? {
        var range: CFTypeRef?
        if AXUIElementCopyParameterizedAttributeValue(web, "AXTextMarkerRangeForUIElement" as CFString, web, &range) == .success,
           let range {
            var s: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(web, "AXStringForTextMarkerRange" as CFString, range, &s) == .success,
               let str = s as? String, !str.isEmpty {
                return (str, "textmarker")
            }
        }
        var parts: [String] = []
        var queue: [AXUIElement] = [web]
        var visited = 0
        while !queue.isEmpty && visited < 8000 {
            let el = queue.removeFirst()
            visited += 1
            if AX.string(el, kAXRoleAttribute) == "AXStaticText" {
                if let v = AX.string(el, kAXValueAttribute), !v.isEmpty { parts.append(v) }
            } else {
                queue.append(contentsOf: AX.children(el))
            }
        }
        return parts.isEmpty ? nil : (parts.joined(separator: "\n"), "tree")
    }
}
