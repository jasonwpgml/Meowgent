import AppKit

/// 메뉴바 고양이 손 = 배터리 표시.
/// 회색 손이 배터리 양만큼 아래부터 차고, 전원이 연결돼 있으면 (충전 중이든 아니든) 큰 젤리 자리(원래 비어 있는 곳)에 번개,
/// 손 맨 아래 (번개 아래, 손 아래 가장자리에 걸쳐) 에 배터리 숫자를 흰 글씨·검은 테두리로.
/// 숫자를 손 옆에 붙이면 항목이 넓어져 꽉 찬 메뉴 막대에서 노치 뒤로 숨어서 (2026-11-11 확인) 손 안에 넣었다.
/// 채워진 부분의 색은 맥이 얼마나 바쁜지: 평소엔 메뉴 막대 글자색(흰색·검은색), 바쁘면 주황, 많이 바쁘면 빨강.
/// 배터리가 없는 맥은 그냥 손만 (평소 템플릿 / 바쁘면 색칠).
enum MenuBarIcon {
    /// 손 그림 (실제 사진에서 딴 것, assets/menubar-paw). 번들 밖에서 돌릴 때는 시스템 발바닥으로 대신한다
    static let paw: NSImage? = {
        let img = Bundle.main.image(forResource: "MenuBarPaw") ?? NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: nil)
        img?.isTemplate = true
        return img
    }()

    /// 숫자가 손 아래로 걸쳐 내려갈 자리 (pt). 그림은 15×18 손 + 이만큼
    private static let below: CGFloat = 3
    private static let numberSize: CGFloat = 7

    /// percent 가 nil 이면 배터리 없는 맥: 손만 (fill 이 nil 이면 템플릿).
    /// 배터리가 있으면 흰 글씨·검은 테두리 숫자 때문에 템플릿으로 못 그려서 (템플릿은 알파만 본다)
    /// 메뉴 막대가 어두운지(dark) 보고 손 색을 직접 정한다. 메뉴 막대 밝기가 바뀌면 다시 불러야 한다.
    /// 메뉴 막대는 템플릿 그림에 준 contentTintColor 도 무시해서 (2026-11-11 확인) 바쁠 때 색도 직접 칠한다
    static func image(percent: Int?, plugged: Bool, fill: NSColor?, dark: Bool) -> NSImage? {
        guard let paw else { return nil }
        guard let percent else {
            let out = NSImage(size: paw.size, flipped: false) { r in masked(paw, fill ?? .black, r.size).draw(in: r); return true }
            out.isTemplate = fill == nil
            return out
        }
        let ink = fill ?? (dark ? .white : .black)
        let base = (dark ? NSColor.white : NSColor.black).withAlphaComponent(0.32)
        let size = NSSize(width: paw.size.width, height: paw.size.height + below)
        let out = NSImage(size: size, flipped: false) { r in
            let pr = NSRect(x: r.minX, y: r.minY + below, width: paw.size.width, height: paw.size.height)   // 손 자리
            masked(paw, base, pr.size).draw(in: pr)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: NSRect(x: pr.minX, y: pr.minY, width: pr.width, height: pr.height * CGFloat(max(0, min(100, percent))) / 100)).addClip()
            masked(paw, ink, pr.size).draw(in: pr)
            NSGraphicsContext.restoreGraphicsState()
            if plugged {
                ink.setFill()
                bolt(in: pr).fill()
            }
            // 숫자: 검은 테두리를 먼저, 흰 글씨를 위에. 아랫선을 그림 바닥 바로 위에 두면 몸통이 손 아래 가장자리에 걸친다
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: numberSize, weight: .heavy), .kern: -0.2]
            let text = "\(percent)" as NSString
            let w = text.size(withAttributes: attrs).width
            let at = NSPoint(x: r.midX - w / 2, y: r.minY + 0.5)
            text.draw(at: at, withAttributes: attrs.merging([.strokeColor: NSColor.black, .strokeWidth: 10.0]) { $1 })
            text.draw(at: at, withAttributes: attrs.merging([.foregroundColor: NSColor.white]) { $1 })
            return true
        }
        out.isTemplate = false
        return out
    }

    /// 손 모양으로 오린 단색 그림
    private static func masked(_ img: NSImage, _ color: NSColor, _ size: NSSize) -> NSImage {
        NSImage(size: size, flipped: false) { b in
            color.set()
            b.fill()
            img.draw(in: b, from: .zero, operation: .destinationIn, fraction: 1)
            return true
        }
    }

    /// 큰 젤리 자리 (15×18pt 손에서 위로부터 9.8~14.5pt, 가로 2.8~10.8pt) 가운데에 들어가는 번개
    private static func bolt(in r: NSRect) -> NSBezierPath {
        let s = r.width / 15
        func p(_ x: CGFloat, _ yFromTop: CGFloat) -> NSPoint { NSPoint(x: r.minX + (x - 0.75) * s, y: r.maxY - yFromTop * s) }
        let path = NSBezierPath()
        path.move(to: p(8.4, 9.6)); path.line(to: p(5.4, 12.7)); path.line(to: p(7.3, 12.7))
        path.line(to: p(6.6, 15.0)); path.line(to: p(9.6, 11.8)); path.line(to: p(7.7, 11.8))
        path.close()
        return path
    }
}
