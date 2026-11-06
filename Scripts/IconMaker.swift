import AppKit
import CoreGraphics
import Foundation

// 把生成的原图裁成 macOS 规范的应用图标：
// 1) 自动找出原图里那块圆角方形的边界（去掉外面的白底）
// 2) 重画到 1024 画布上，内容占 824×824（Apple 的网格），四周透明
// 3) 用超级椭圆路径裁剪 + 一点点外投影
// 4) 输出 iconset 各尺寸，交给 iconutil 打成 icns

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: IconMaker <in.png> <out.iconset>")
    exit(2)
}
let inURL = URL(fileURLWithPath: args[1])
let outDir = URL(fileURLWithPath: args[2])

guard let src = NSImage(contentsOf: inURL),
      let srcCG = src.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    print("读不到输入图")
    exit(3)
}

let w = srcCG.width, h = srcCG.height
var pixels = [UInt8](repeating: 0, count: w * h * 4)
let space = CGColorSpaceCreateDeviceRGB()
guard let probe = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: w * 4, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    exit(4)
}
probe.draw(srcCG, in: CGRect(x: 0, y: 0, width: w, height: h))

// 找出非白区域（原图外侧是纯白）
func isContent(_ x: Int, _ y: Int) -> Bool {
    let i = (y * w + x) * 4
    let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
    return !(r > 248 && g > 248 && b > 248)
}
var minX = w, minY = h, maxX = 0, maxY = 0
for y in stride(from: 0, to: h, by: 2) {
    for x in stride(from: 0, to: w, by: 2) where isContent(x, y) {
        if x < minX { minX = x }
        if x > maxX { maxX = x }
        if y < minY { minY = y }
        if y > maxY { maxY = y }
    }
}
if maxX <= minX || maxY <= minY {
    minX = 0; minY = 0; maxX = w - 1; maxY = h - 1
}
let crop = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
print("内容区域: \(crop)")

func makeIcon(size: Int) -> CGImage? {
    guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                              bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.interpolationQuality = .high

    let scale = CGFloat(size) / 1024.0
    // Apple 的图标网格：1024 画布里内容占 824，留 100 的边
    let content = CGRect(x: 100 * scale, y: 100 * scale,
                         width: 824 * scale, height: 824 * scale)
    let radius = 185 * scale

    // 圆角路径（近似 macOS 的连续圆角，视觉上足够）
    let path = CGPath(roundedRect: content, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // 投影：只在内容外侧一点，别糊
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6 * scale),
                  blur: 18 * scale,
                  color: CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 0.18))
    ctx.addPath(path)
    ctx.setFillColor(CGColor(red: 0.984, green: 0.980, blue: 0.969, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    if let cropped = srcCG.cropping(to: crop) {
        ctx.draw(cropped, in: content)
    }
    ctx.restoreGState()

    // 极细描边，贴在浅色背景上不糊边
    ctx.saveGState()
    ctx.addPath(path)
    ctx.setStrokeColor(CGColor(red: 0.10, green: 0.10, blue: 0.10, alpha: 0.08))
    ctx.setLineWidth(max(0.6, 2 * scale))
    ctx.strokePath()
    ctx.restoreGState()

    return ctx.makeImage()
}

try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let variants: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]

for (size, name) in variants {
    guard let image = makeIcon(size: size) else { continue }
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: size, height: size)
    guard let data = rep.representation(using: .png, properties: [:]) else { continue }
    try? data.write(to: outDir.appendingPathComponent(name))
}

if let big = makeIcon(size: 1024) {
    let rep = NSBitmapImageRep(cgImage: big)
    try? rep.representation(using: .png, properties: [:])?
        .write(to: outDir.deletingLastPathComponent().appendingPathComponent("AppIcon-1024.png"))
}
print("✓ iconset 输出到 \(outDir.path)")
