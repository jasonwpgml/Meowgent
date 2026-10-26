import ApplicationServices
import Foundation

/// 손쉬운 사용(AX) API 얇은 래퍼.
enum AX {
    static func element(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success, let v,
              CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func string(_ el: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
        return v as? String
    }

    static func int(_ el: AXUIElement, _ attr: String) -> Int? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
        return (v as? NSNumber)?.intValue
    }

    static func children(_ el: AXUIElement) -> [AXUIElement] {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &v) == .success,
              let arr = v as? [AXUIElement] else { return [] }
        return arr
    }

    static func isSettable(_ el: AXUIElement, _ attr: String) -> Bool {
        var b = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(el, attr as CFString, &b) == .success && b.boolValue
    }

    static func pid(_ el: AXUIElement) -> pid_t? {
        var p: pid_t = 0
        return AXUIElementGetPid(el, &p) == .success ? p : nil
    }

    static func set(_ el: AXUIElement, _ attr: String, _ value: CFTypeRef) -> AXError {
        AXUIElementSetAttributeValue(el, attr as CFString, value)
    }

    /// 사람이 읽을 만한 이름: title → description → placeholder → 자식 텍스트.
    static func label(_ el: AXUIElement, deep: Bool = false) -> String? {
        for a in [kAXTitleAttribute, kAXDescriptionAttribute, "AXPlaceholderValue", kAXHelpAttribute] {
            if let s = string(el, a)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { return clip(s) }
        }
        if let role = string(el, kAXRoleAttribute), ["AXStaticText", "AXButton", "AXLink", "AXMenuItem", "AXCell"].contains(role),
           let s = string(el, kAXValueAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
            return clip(s)
        }
        if let titleEl = element(el, "AXTitleUIElement"), let s = string(titleEl, kAXValueAttribute), !s.isEmpty {
            return clip(s)
        }
        return deep ? descendantText(el) : nil
    }

    /// 웹·Electron 버튼은 이름 없이 안쪽 텍스트/아이콘 설명만 있는 경우가 많다 → 얕게 넓이 우선 탐색.
    static func descendantText(_ root: AXUIElement, maxNodes: Int = 30, maxDepth: Int = 3) -> String? {
        var queue: [(AXUIElement, Int)] = children(root).prefix(10).map { ($0, 1) }
        var parts: [String] = []
        var visited = 0
        while !queue.isEmpty && visited < maxNodes {
            let (el, depth) = queue.removeFirst()
            visited += 1
            let role = string(el, kAXRoleAttribute)
            if role == "AXStaticText", let s = string(el, kAXValueAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                parts.append(s)
            } else if let d = string(el, kAXDescriptionAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty {
                parts.append(d)
            } else if depth < maxDepth {
                queue.append(contentsOf: children(el).prefix(10).map { ($0, depth + 1) })
            }
            if parts.joined(separator: " ").count > 80 { break }
        }
        return parts.isEmpty ? nil : clip(parts.joined(separator: " "))
    }

    static func clip(_ s: String, _ n: Int = 120) -> String {
        s.count > n ? String(s.prefix(n)) + "…" : s
    }

    static func isSecure(role: String?, subrole: String?) -> Bool {
        role == "AXSecureTextField" || subrole == "AXSecureTextField"
    }
}
