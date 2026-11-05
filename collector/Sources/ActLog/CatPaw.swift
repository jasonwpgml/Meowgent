import AppKit

/// 메뉴바용 고양이 발바닥. 시스템 pawprint는 발가락이 길쭉한 강아지 발이라 직접 그린다.
/// 고양이 발: 발가락 젤리 네 개가 동글고 비슷한 크기로 모여 있고, 큰 젤리는 아래가 세 갈래로 둥글다.
/// 18×18pt 템플릿 이미지라 다크·라이트 모드에 맞춰 색이 바뀐다.
enum CatPaw {
    static let size: CGFloat = 18

    /// 큰 젤리: 위는 한 덩어리로 둥글고, 아래는 세 갈래
    static func mainPad() -> NSBezierPath {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: 3.5, y: 6.4))
        p.curve(to: NSPoint(x: 14.5, y: 6.4), controlPoint1: NSPoint(x: 3.5, y: 11.0), controlPoint2: NSPoint(x: 14.5, y: 11.0))
        // 오른쪽 갈래 → 오목 → 가운데 갈래 → 오목 → 왼쪽 갈래
        p.curve(to: NSPoint(x: 11.2, y: 3.8), controlPoint1: NSPoint(x: 14.9, y: 3.6), controlPoint2: NSPoint(x: 12.0, y: 2.2))
        p.curve(to: NSPoint(x: 6.8, y: 3.8), controlPoint1: NSPoint(x: 10.8, y: 1.0), controlPoint2: NSPoint(x: 7.2, y: 1.0))
        p.curve(to: NSPoint(x: 3.5, y: 6.4), controlPoint1: NSPoint(x: 6.0, y: 2.2), controlPoint2: NSPoint(x: 3.1, y: 3.6))
        p.close()
        return p
    }

    /// 발가락 젤리 네 개: 바깥 둘은 조금 낮게, 안쪽 둘은 높게
    static let toes: [NSRect] = [
        ellipse(3.4, 11.0, 3.5, 3.9),
        ellipse(7.1, 13.9, 3.6, 4.0),
        ellipse(10.9, 13.9, 3.6, 4.0),
        ellipse(14.6, 11.0, 3.5, 3.9),
    ]

    static func ellipse(_ cx: CGFloat, _ cy: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
        NSRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
    }

    static func image(description: String? = nil) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            NSColor.black.setFill()
            mainPad().fill()
            for r in toes { NSBezierPath(ovalIn: r).fill() }
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = description
        return img
    }
}
