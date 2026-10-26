import AppKit

extension NSMenu {
    /// target 이 받는 항목을 만들어 끝에 붙인다 (제목 + 셀렉터, 단축키 없음)
    @discardableResult
    func addItem(_ title: String, _ sel: Selector, target: AnyObject) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        i.target = target
        addItem(i)
        return i
    }
}
