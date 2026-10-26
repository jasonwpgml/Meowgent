// 앱 아이콘: 원화 sit_front.png 첫 칸을 크림색 둥근 네모 위에 올려 AppIcon.icns로 만든다.
// 사용: swift tools/make_icon.swift pet/assets/original-cat/current/sit_front.png collector/AppIcon.icns
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let src = NSImage(contentsOfFile: args[1]), let rep = src.representations.first as? NSBitmapImageRep else {
    FileHandle.standardError.write("사용: make_icon.swift <시트.png> <출력.icns>\n".data(using: .utf8)!); exit(1)
}
let cell = rep.pixelsHigh                       // 한 줄짜리 정사각 칸
guard let sheet = rep.cgImage, let first = sheet.cropping(to: CGRect(x: 0, y: 0, width: cell, height: cell)) else { exit(1) }

// 그림의 실제 경계(투명 아닌 부분) — RGBA 버퍼로 읽는다
var buf = [UInt8](repeating: 0, count: cell * cell * 4)
let cs = CGColorSpaceCreateDeviceRGB()
let probe = CGContext(data: &buf, width: cell, height: cell, bitsPerComponent: 8, bytesPerRow: cell * 4, space: cs,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
probe.draw(first, in: CGRect(x: 0, y: 0, width: cell, height: cell))
var minX = cell, minY = cell, maxX = 0, maxY = 0
for y in 0..<cell { for x in 0..<cell where buf[(y * cell + x) * 4 + 3] > 25 {
    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) } }
let bw = maxX - minX + 1, bh = maxY - minY + 1
// CGContext 버퍼는 아래가 y=0 이므로 자를 때는 위아래를 뒤집는다
let cat = first.cropping(to: CGRect(x: minX, y: cell - 1 - maxY, width: bw, height: bh))!

let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: tmp)
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

func render(_ px: Int, _ name: String) {
    let img = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: img)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ctx
    ctx.cgContext.interpolationQuality = .none
    let s = CGFloat(px)
    let inset = s * 0.1                                  // macOS 아이콘 그리드: 전체의 80%가 몸체
    let body = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    NSColor(calibratedRed: 0.96, green: 0.89, blue: 0.76, alpha: 1).setFill()
    NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225).fill()
    // 고양이: 몸체의 72% 높이에 맞추되 정수 배율로 (도트가 또렷하게)
    let scale = max(1, floor(body.height * 0.72 / CGFloat(bh)))
    let w = CGFloat(bw) * scale, h = CGFloat(bh) * scale
    let dst = NSRect(x: body.midX - w / 2, y: body.minY + (body.height - h) * 0.42, width: w, height: h)
    ctx.cgContext.draw(cat, in: dst)
    NSGraphicsContext.restoreGraphicsState()
    try! img.representation(using: .png, properties: [:])!.write(to: tmp.appendingPathComponent(name))
}
for (px, names) in [(16, ["icon_16x16.png"]), (32, ["icon_16x16@2x.png", "icon_32x32.png"]), (64, ["icon_32x32@2x.png"]),
                    (128, ["icon_128x128.png"]), (256, ["icon_128x128@2x.png", "icon_256x256.png"]),
                    (512, ["icon_256x256@2x.png", "icon_512x512.png"]), (1024, ["icon_512x512@2x.png"])] {
    for n in names { render(px, n) }
}
let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", tmp.path, "-o", args[2]]
try! p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "아이콘 생성: \(args[2]) (고양이 \(bw)×\(bh)px)" : "iconutil 실패")
exit(p.terminationStatus)
