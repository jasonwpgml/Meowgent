import AppKit
// 사진에서 잰 젤리 + Vision 실루엣 → 메뉴바 아이콘
// 좌표는 잘라낸 그림 기준 (원본 x 600~1220, y 520~1300, 왼쪽 위 0,0, 아래로 +)
let a = CommandLine.arguments, out = a[3]
let ox = 600, oy = 520
// 아이콘으로 쓸 범위 (잘라낸 그림 기준)
let cx0 = 15, cy0 = 40, cx1 = 575, cy1 = 720
let W = cx1 - cx0, H = cy1 - cy0

func rgba(_ p: String) -> NSBitmapImageRep {
    let r = NSBitmapImageRep(data: NSImage(contentsOfFile: p)!.tiffRepresentation!)!
    let c = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: r.pixelsWide, pixelsHigh: r.pixelsHigh, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: r.pixelsWide * 4, bitsPerPixel: 32)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: c)
    r.draw(in: NSRect(x: 0, y: 0, width: r.pixelsWide, height: r.pixelsHigh)); NSGraphicsContext.restoreGraphicsState()
    return c
}
let photo = rgba(a[1]), mask = rgba(a[2])
let pp = photo.bitmapData!, mp = mask.bitmapData!, pw = photo.pixelsWide, mw = mask.pixelsWide

// 실루엣: Vision 마스크. 손목 아래 왼쪽은 다른 앞발과 붙어 있어 사진의 팔 가장자리 기울기로 자른다
var sil = [Float](repeating: 0, count: W * H)
for y in 0..<H { for x in 0..<W {
    let cx = x + cx0, cy = y + cy0
    var on = mp[((cy + oy) * mw + cx + ox) * 4] > 127
    if cy > 560 && Double(cx) < 40 + Double(cy - 560) * 0.15 { on = false }
    sil[y * W + x] = on ? 1 : 0
} }
func blur(_ s: [Float], _ r: Int) -> [Float] {
    // 그림 밖은 0으로 본다 (가장자리에서 모양이 번지지 않게)
    let n = Float(2 * r + 1)
    var t = [Float](repeating: 0, count: W * H), o = t
    for y in 0..<H { var acc: Float = 0
        for x in 0..<min(r, W) { acc += s[y * W + x] }
        for x in 0..<W {
            if x + r < W { acc += s[y * W + x + r] }
            if x - r - 1 >= 0 { acc -= s[y * W + x - r - 1] }
            t[y * W + x] = acc / n } }
    for x in 0..<W { var acc: Float = 0
        for y in 0..<min(r, H) { acc += t[y * W + x] }
        for y in 0..<H {
            if y + r < H { acc += t[(y + r) * W + x] }
            if y - r - 1 >= 0 { acc -= t[(y - r - 1) * W + x] }
            o[y * W + x] = acc / n } }
    return o
}

// 젤리 모양 (사진 격자에서 잰 값)
func ellipse(_ cx: CGFloat, _ cy: CGFloat, _ w: CGFloat, _ h: CGFloat, _ rot: CGFloat) -> NSBezierPath {
    let p = NSBezierPath(ovalIn: NSRect(x: -w/2, y: -h/2, width: w, height: h))
    var t = AffineTransform(translationByX: cx, byY: cy); t.rotate(byDegrees: rot); p.transform(using: t); return p
}
// 닫힌 점들을 부드러운 곡선으로 (Catmull-Rom)
func smooth(_ pts: [NSPoint]) -> NSBezierPath {
    let p = NSBezierPath(); let n = pts.count; p.move(to: pts[0])
    for i in 0..<n {
        let p0 = pts[(i - 1 + n) % n], p1 = pts[i], p2 = pts[(i + 1) % n], p3 = pts[(i + 2) % n]
        p.curve(to: p2, controlPoint1: NSPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                controlPoint2: NSPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
    }
    p.close(); return p
}
// MIX: 0 = 첫 사진(들어 올린 손, 귀여움), 1 = 두 번째 사진(분홍 젤리, 정확함). 메뉴바에 넣은 것은 0.8
let mix = CGFloat(Double(ProcessInfo.processInfo.environment["MIX"] ?? "0.8")!)
func lerp(_ p: CGFloat, _ q: CGFloat) -> CGFloat { p + (q - p) * mix }
// 첫 사진에서 잰 발가락 (중심x, 중심y, 폭, 높이, 기울기)
let toes1: [[CGFloat]] = [[203, 230, 105, 160, 6], [348, 215, 105, 170, -6], [132, 405, 110, 150, -18], [452, 345, 65, 110, 14]]
// 두 번째 사진(910×880)에서 잰 값을 첫 사진 젤리 묶음 크기로 옮긴 것: x' = 280.5 + (x-545)·0.67, y' = 365 + (y-505)·0.67
func map2(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: 280.5 + (x - 545) * 0.67, y: 365 + (y - 505) * 0.67) }
let toes2raw: [[CGFloat]] = [[452, 328, 155, 285, -5], [632, 295, 145, 250, 6], [307, 507, 150, 245, -8], [802, 480, 115, 240, 10]]
let toes2 = toes2raw.map { t -> [CGFloat] in let p = map2(t[0], t[1]); return [p.x, p.y, t[2] * 0.67, t[3] * 0.67, t[4]] }
var beans: [NSBezierPath] = zip(toes1, toes2).map { a, b in
    ellipse(lerp(a[0], b[0]), lerp(a[1], b[1]), lerp(a[2], b[2]), lerp(a[3], b[3]), lerp(a[4], b[4])) }
// 큰 젤리: 첫 사진은 둥근 사다리꼴, 두 번째 사진은 가운데가 솟고 양옆이 처진 세 갈래
let pad1 = [NSPoint(x: 215, y: 415), NSPoint(x: 290, y: 402), NSPoint(x: 345, y: 420), NSPoint(x: 395, y: 465),
            NSPoint(x: 435, y: 520), NSPoint(x: 445, y: 572), NSPoint(x: 418, y: 598), NSPoint(x: 330, y: 598),
            NSPoint(x: 240, y: 600), NSPoint(x: 168, y: 593), NSPoint(x: 150, y: 555), NSPoint(x: 163, y: 490), NSPoint(x: 188, y: 440)]
let pad2 = [(300, 740), (330, 690), (400, 660), (440, 600), (520, 555), (600, 580), (640, 650), (700, 680), (725, 740),
            (710, 810), (640, 835), (560, 822), (500, 835), (430, 845), (350, 835), (305, 800)].map { map2(CGFloat($0.0), CGFloat($0.1)) }
func bbox(_ p: [NSPoint]) -> NSRect {
    let xs = p.map(\.x), ys = p.map(\.y)
    return NSRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
}
if mix == 0 { beans.append(smooth(pad1)) } else {
    // 모양은 두 번째 사진(세 갈래), 자리와 크기는 두 사진 사이
    let b1 = bbox(pad1), b2 = bbox(pad2)
    let t = NSRect(x: lerp(b1.minX, b2.minX), y: lerp(b1.minY, b2.minY), width: lerp(b1.width, b2.width), height: lerp(b1.height, b2.height))
    beans.append(smooth(pad2.map { NSPoint(x: t.minX + ($0.x - b2.minX) / b2.width * t.width, y: t.minY + ($0.y - b2.minY) / b2.height * t.height) }))
}
// 젤리를 실루엣 크기 비트맵에 그린다 (위에서 아래로 좌표)
let br = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8, samplesPerPixel: 1, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceWhite, bytesPerRow: W, bitsPerPixel: 8)!
NSGraphicsContext.saveGraphicsState()
let ctx = NSGraphicsContext(bitmapImageRep: br)!; NSGraphicsContext.current = ctx
NSColor.black.setFill(); NSRect(x: 0, y: 0, width: W, height: H).fill()
// 위 변환: 잘라낸 그림 좌표(아래로 +) → 비트맵 좌표(위로 +)
let tf = NSAffineTransform(); tf.translateX(by: 0, yBy: CGFloat(H)); tf.scaleX(by: 1, yBy: -1); tf.translateX(by: CGFloat(-cx0), yBy: CGFloat(-cy0))
tf.concat()
NSColor.white.setFill(); beans.forEach { $0.fill() }
NSGraphicsContext.restoreGraphicsState()
let bd = br.bitmapData!
let beanF = (0..<(W * H)).map { Float(bd[$0]) / 255 }
// 1) 오목한 곳 메우기(닫기) → 2) 삐친 털 깎기(열기) → 3) 가장자리 매끄럽게
sil = blur(sil, 40).map { $0 > 0.3 ? 1 : 0 }
sil = blur(sil, 40).map { $0 > 0.62 ? 1 : 0 }
sil = blur(sil, 12).map { $0 > 0.5 ? 1 : 0 }
// 손목: 손바닥 아래는 곧은 두 변으로 (사진의 팔 폭, 아래로 살짝 좁아짐)
for y in 0..<H { let cy = y + cy0; guard cy >= 600 else { continue }
    let t = Double(cy - 600)
    let L = 34 + t * 0.12, R = 552 - t * 0.12
    for x in 0..<W { let cx = Double(x + cx0); sil[y * W + x] = (cx >= L && cx <= R) ? 1 : 0 } }
// 손목 이음매의 턱을 없앤다
sil = blur(sil, 24).map { $0 > 0.5 ? 1 : 0 }
// 젤리 둘레에 털 테두리를 남긴다 (18px에서도 젤리가 바깥으로 터지지 않게)
let rim = blur(beanF, 34)
for i in 0..<(W * H) where rim[i] > 0.01 { sil[i] = 1 }
sil = blur(sil, 8).map { $0 > 0.5 ? 1 : 0 }
var alpha = [Float](repeating: 0, count: W * H)
for i in 0..<(W * H) { alpha[i] = sil[i] * (1 - Float(bd[i]) / 255) }

func gray(_ buf: [Float], _ w: Int, _ h: Int, _ name: String) {
    let r = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 2, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceWhite, bytesPerRow: w * 2, bitsPerPixel: 16)!
    let d = r.bitmapData!
    for i in 0..<(w * h) { d[i * 2] = 0; d[i * 2 + 1] = UInt8(max(0, min(255, buf[i] * 255))) }
    try! r.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
}
func shrink(_ h: Int) -> ([Float], Int) {
    let w = Int((Double(W) * Double(h) / Double(H)).rounded())
    var o = [Float](repeating: 0, count: w * h)
    for oy in 0..<h { for ox in 0..<w {
        let sx0 = ox * W / w, sx1 = max(sx0 + 1, (ox + 1) * W / w), sy0 = oy * H / h, sy1 = max(sy0 + 1, (oy + 1) * H / h)
        var acc: Float = 0
        for y in sy0..<sy1 { for x in sx0..<sx1 { acc += alpha[y * W + x] } }
        o[oy * w + ox] = acc / Float((sx1 - sx0) * (sy1 - sy0)) } }
    return (o, w)
}
gray(alpha, W, H, "full")
for h in [18, 36, 54] { let (o, w) = shrink(h); gray(o, w, h, "paw_\(h)"); print("paw_\(h): \(w)x\(h)") }
// 사진 위에 잰 젤리 겹쳐 보기
let ov = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: W * 3, bitsPerPixel: 24)!
let op = ov.bitmapData!
for i in 0..<(W * H) { let y = i / W + cy0 + oy, x = i % W + cx0 + ox, po = (y * pw + x) * 4, o = i * 3
    let b = Float(bd[i]) / 255
    if sil[i] == 0 { op[o] = pp[po] / 3; op[o+1] = pp[po+1] / 3; op[o+2] = 120 }
    else { op[o] = UInt8(Float(pp[po]) * (1 - b * 0.6) + 255 * b * 0.6); op[o+1] = UInt8(Float(pp[po+1]) * (1 - b * 0.6)); op[o+2] = UInt8(Float(pp[po+2]) * (1 - b * 0.6)) } }
try! ov.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/overlay2.png"))
