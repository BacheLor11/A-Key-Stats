import Foundation
import CoreGraphics
import CoreText
import CoreVideo
import AVFoundation

// MARK: - 轨迹回放视频
//
// 就是把触控板页那块 TrackpadHeatView 的回放录下来：
// 同样的热力底图、同样的「底色宽边 + 赭石细线」双层描边、同样的按 finger 分段。
// 画面里只有那块触控板，不加标题、时钟、进度条。
//
// 逐帧用 Core Graphics 画进位图，再交给 AVAssetWriter 编 H.264。
// 不走 SwiftUI 的 ImageRenderer：那玩意儿每帧要跑一遍布局和视图 diff，
// 几百帧下来是分钟级；这里直接画 CGPath，一帧几毫秒。
//
// 推进方式和 App 回放一致：按点位索引均匀走，不按真实时间。
// 一天的活动可能横跨十几小时，按真实时间放会有一大半是静止的。
public enum TrajectoryVideo {

    public struct Config: Sendable {
        public var width: Int
        public var height: Int
        public var fps: Int
        /// nil = 跟 App 回放同一套规则（时间跨度 ÷ 8，限 1.2–12 秒）
        public var duration: Double?
        public var dark: Bool
        /// 触控板物理比例（Magic Trackpad 16.0 × 11.5 cm）
        public var padWidthCM: Double
        public var padHeightCM: Double

        public init(width: Int = 1600,
                    height: Int = 1150,
                    fps: Int = 30,
                    duration: Double? = nil,
                    dark: Bool = false,
                    padWidthCM: Double = 16.0,
                    padHeightCM: Double = 11.5) {
            self.width = width
            self.height = height
            self.fps = fps
            self.duration = duration
            self.dark = dark
            self.padWidthCM = padWidthCM
            self.padHeightCM = padHeightCM
        }

        public var padAspect: CGFloat { CGFloat(padWidthCM / padHeightCM) }

        /// 与 App 回放一致的时长规则：跨度 ÷ 8，最短 1.2 秒、最长 12 秒
        public static func autoDuration(span: Double) -> Double {
            min(max(span / 8.0, 1.2), 12.0)
        }
    }

    public struct Outcome: Sendable {
        public let url: URL
        public let frames: Int
        public let seconds: Double
        public let bytes: Int
        public let points: Int
        public let travelCM: Double
        /// true 表示用的是 App 那套自动时长
        public let automaticDuration: Bool
    }

    public enum Failure: LocalizedError {
        case noData(String)
        case tooFewPoints(Int)
        case cannotWrite(String)
        case encode(String)

        public var errorDescription: String? {
            switch self {
            case .noData(let day): return "\(day) 没有轨迹数据"
            case .tooFewPoints(let n): return "只有 \(n) 个轨迹点，画不出轨迹"
            case .cannotWrite(let path): return "写不进 \(path)"
            case .encode(let message): return "编码失败：\(message)"
            }
        }
    }

    // MARK: 主入口

    /// 在后台线程跑。
    @discardableResult
    public static func render(day: String,
                              kind: TrajKind = .pad,
                              to url: URL,
                              config: Config = Config(),
                              onProgress: ((Double) -> Void)? = nil) throws -> Outcome {
        let file = Store.shared.trajectoryURL(day: day, kind: kind)
        var points: [TrajPoint] = []
        try TrajectoryExport.forEachPoint(in: file) { points.append($0) }
        guard !points.isEmpty else { throw Failure.noData(day) }
        guard points.count >= 8 else { throw Failure.tooFewPoints(points.count) }

        let span = Double(points[points.count - 1].t) - Double(points[0].t)
        let automatic = config.duration == nil
        let seconds = config.duration ?? Config.autoDuration(span: span)
        let frames = max(2, Int((seconds * Double(config.fps)).rounded()))

        let painter = Painter(day: day, points: points, frames: frames, config: config)

        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        } catch {
            throw Failure.cannotWrite(url.path)
        }

        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: config.width,
            AVVideoHeightKey: config.height,
            AVVideoCompressionPropertiesKey: [
                // 画面大面积是纯色，只有细线，8Mbps 已经看不出块
                AVVideoAverageBitRateKey: 8_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: config.fps,
                AVVideoMaxKeyFrameIntervalKey: config.fps * 2
            ]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: config.width,
                kCVPixelBufferHeightKey as String: config.height
            ]
        )
        guard writer.canAdd(input) else { throw Failure.encode("这个尺寸不被支持") }
        writer.add(input)
        guard writer.startWriting() else {
            throw Failure.encode(writer.error?.localizedDescription ?? "无法开始写入")
        }
        writer.startSession(atSourceTime: .zero)

        var encoded = 0
        while encoded < frames {
            var spins = 0
            while !input.isReadyForMoreMediaData {
                usleep(2_000)
                spins += 1
                if spins > 20_000 { throw Failure.encode("编码器一直没有接收") }
            }
            guard let pool = adaptor.pixelBufferPool else {
                throw Failure.encode("像素缓冲池不可用")
            }
            var buffer: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard status == kCVReturnSuccess, let pixelBuffer = buffer else {
                throw Failure.encode("申请缓冲失败（\(status)）")
            }

            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pixelBuffer),
                                   width: config.width,
                                   height: config.height,
                                   bitsPerComponent: 8,
                                   bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                              | CGBitmapInfo.byteOrder32Little.rawValue) {
                painter.draw(frame: encoded, of: frames, into: ctx)
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

            adaptor.append(pixelBuffer,
                           withPresentationTime: CMTime(value: CMTimeValue(encoded),
                                                        timescale: CMTimeScale(config.fps)))
            encoded += 1
            onProgress?(Double(encoded) / Double(frames))
        }

        input.markAsFinished()

        // finishWriting 的回调要靠 runloop 驱动；后台线程里先借 semaphore 等，
        // 同时 run 一下当前 runloop 让它有机会回调。
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        while sem.wait(timeout: .now() + 0.01) == .timedOut {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }

        guard writer.status == .completed else {
            throw Failure.encode(writer.error?.localizedDescription ?? "写完成失败")
        }

        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let bytes = (attrs?[.size] as? NSNumber)?.intValue ?? 0

        return Outcome(url: url,
                       frames: frames,
                       seconds: seconds,
                       bytes: bytes,
                       points: points.count,
                       travelCM: painter.travelCM,
                       automaticDuration: automatic)
    }

    // MARK: 配色

    struct Palette {
        let surface: CGColor
        let bg: CGColor
        let border: CGColor
        let inkSoft: CGColor
        let trail: CGColor
        let cold: (Double, Double, Double)
        let mid: (Double, Double, Double)
        let hot: (Double, Double, Double)

        static func of(dark: Bool) -> Palette {
            if dark {
                return Palette(
                    surface: VideoColor.hex(0x202326),
                    bg: VideoColor.hex(0x15171A),
                    border: VideoColor.hex(0x2E3236),
                    inkSoft: VideoColor.hex(0xA8A29A),
                    trail: VideoColor.hex(0xD98A5E),
                    cold: (0.125, 0.137, 0.149),
                    mid: (0.482, 0.639, 0.800),
                    hot: (0.851, 0.541, 0.369)
                )
            }
            return Palette(
                surface: VideoColor.hex(0xFFFFFF),
                bg: VideoColor.hex(0xFBFAF7),
                border: VideoColor.hex(0xE7E2D8),
                inkSoft: VideoColor.hex(0x5B574E),
                trail: VideoColor.hex(0xB5562E),
                cold: (0.949, 0.937, 0.910),
                mid: (0.204, 0.333, 0.478),
                hot: (0.710, 0.337, 0.180)
            )
        }

        /// 与 App 里 AKSScheme.heat 同一套折线，只是输出 CGColor
        func heat(_ fraction: Double) -> CGColor {
            let f = min(max(fraction, 0), 1)
            let a: (Double, Double, Double)
            let b: (Double, Double, Double)
            let t: Double
            if f < 0.55 {
                a = cold; b = mid; t = f / 0.55
            } else {
                a = mid; b = hot; t = (f - 0.55) / 0.45
            }
            let e = pow(t, 0.85)
            return CGColor(srgbRed: a.0 + (b.0 - a.0) * e,
                           green: a.1 + (b.1 - a.1) * e,
                           blue: a.2 + (b.2 - a.2) * e,
                           alpha: 1)
        }
    }

    // MARK: 逐帧绘制

    final class Painter {
        let config: Config
        let palette: Palette
        let points: [TrajPoint]
        let day: String

        let W: CGFloat
        let H: CGFloat
        let padRect: CGRect
        let radius: CGFloat
        /// 以 App 里 360pt 高的组件为基准的缩放：线宽和字号按它等比放大
        let s: CGFloat

        /// 热力底图，预渲染一次。每帧重画 768 个格子太浪费。
        let heatLayer: CGImage?
        /// 双层描边拆成两张累积位图。
        /// 关键是「一遍描绘」：同一处不反复描边，alpha 就不会堆到饱和，
        /// 和 App 里每帧重画一遍的效果对得上。
        let wideLayer: CGContext
        let thinLayer: CGContext

        var drawn = 0
        var lastPoint: [UInt16: CGPoint] = [:]
        var lastTime: [UInt16: Float] = [:]
        /// 合成图缓存：accum 层没新增点时不必重建两张位图
        private var wideImage: CGImage?
        private var thinImage: CGImage?
        private var imagesDirty = true

        /// 细线透明度：和 App 一样，接触段（finger id）越多压得越淡
        let trailAlpha: CGFloat
        let travelCM: Double

        init(day: String, points: [TrajPoint], frames: Int, config: Config) {
            self.config = config
            let palette = Palette.of(dark: config.dark)
            self.palette = palette
            self.points = points
            self.day = day
            self.W = CGFloat(config.width)
            self.H = CGFloat(config.height)

            // 触控板按比例塞进画面，四周留 3.5% 边距
            let margin = min(W, H) * 0.035
            let maxW = W - margin * 2
            let maxH = H - margin * 2
            let padH = min(maxH, maxW / config.padAspect)
            let padW = padH * config.padAspect
            let plate = CGRect(x: (W - padW) / 2, y: (H - padH) / 2,
                               width: padW, height: padH)
            self.padRect = plate
            self.radius = min(padW, padH) * 0.055
            self.s = padH / 360

            self.heatLayer = Store.shared.load(day: day).flatMap {
                Self.makeHeatLayer($0.padGrid, size: plate.size, palette: palette)
            }

            func makeLayer() -> CGContext {
                CGContext(data: nil,
                          width: Int(padW),
                          height: Int(padH),
                          bitsPerComponent: 8,
                          bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                     | CGBitmapInfo.byteOrder32Little.rawValue)!
            }
            let wide = makeLayer()
            let thin = makeLayer()
            for layer in [wide, thin] {
                layer.setLineCap(.round)
                layer.setLineJoin(.round)
            }
            self.wideLayer = wide
            self.thinLayer = thin

            // 与 App 一致：按出现过的接触段数量决定细线浓淡
            let groups = Set(points.map { $0.id }).count
            self.trailAlpha = groups > 40 ? 0.45 : (groups > 12 ? 0.65 : 0.85)

            // 行程：抬手换位置的大跳不计
            var total = 0.0
            if points.count > 1 {
                for i in 1..<points.count {
                    let dx = Double(points[i].x - points[i - 1].x) * config.padWidthCM
                    let dy = Double(points[i].y - points[i - 1].y) * config.padHeightCM
                    let d = (dx * dx + dy * dy).squareRoot()
                    total += d > 3 ? 0 : d
                }
            }
            self.travelCM = total
        }

        // MARK: 帧

        func draw(frame: Int, of total: Int, into ctx: CGContext) {
            // 和 App 回放一样：按点位索引均匀推进
            let progress = total > 1 ? Double(frame) / Double(total - 1) : 1
            let limit = max(1, min(points.count, Int(Double(points.count) * progress)))
            advance(to: limit)

            ctx.setFillColor(palette.surface)
            ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))

            let plate = CGPath(roundedRect: padRect,
                               cornerWidth: radius, cornerHeight: radius,
                               transform: nil)
            ctx.addPath(plate)
            ctx.setFillColor(palette.bg)
            ctx.fillPath()

            ctx.saveGState()
            ctx.addPath(plate)
            ctx.clip()

            if let heatLayer {
                ctx.draw(heatLayer, in: padRect)
            }
            // 先铺底色宽边（把热力挖空），再压赭石细线 —— 和 App 的绘制顺序一致。
            // 没新增点的帧直接复用上一张，不然每帧都重建两张全尺寸位图。
            if imagesDirty {
                wideImage = wideLayer.makeImage()
                thinImage = thinLayer.makeImage()
                imagesDirty = false
            }
            if let image = wideImage {
                ctx.setAlpha(0.70)
                ctx.draw(image, in: padRect)
                ctx.setAlpha(1)
            }
            if let image = thinImage {
                ctx.setAlpha(trailAlpha)
                ctx.draw(image, in: padRect)
                ctx.setAlpha(1)
            }
            ctx.restoreGState()

            // 外框
            ctx.addPath(plate)
            ctx.setStrokeColor(palette.border)
            ctx.setLineWidth(max(1, 1 * s))
            ctx.strokePath()

            // 内圈细线
            let inner = padRect.insetBy(dx: 6 * s, dy: 6 * s)
            ctx.addPath(CGPath(roundedRect: inner,
                               cornerWidth: radius * 0.75,
                               cornerHeight: radius * 0.75,
                               transform: nil))
            ctx.setStrokeColor(palette.border.copy(alpha: 0.45) ?? palette.border)
            ctx.setLineWidth(max(0.5, 0.5 * s))
            ctx.strokePath()

            // 角标
            let font = CTFontCreateWithName("PingFang SC" as CFString, 8 * s, nil)
            text("TRACKPAD", font: font,
                 color: palette.inkSoft.copy(alpha: 0.45) ?? palette.inkSoft,
                 at: CGPoint(x: padRect.minX + 13 * s, y: padRect.maxY - 18 * s),
                 into: ctx)
        }

        // MARK: 增量描绘

        private func advance(to target: Int) {
            guard target > drawn else { return }
            let pw = padRect.width
            let ph = padRect.height

            // 本批新增的线段，**按 finger 分开收集**。
            //
            // 这里不能所有手指共用一条 CGMutablePath：addLine 接的是路径的
            // 「当前点」，而双指滚动时两根手指是逐帧交替采样的（本机一天里
            // 22.5% 的相邻点会换手指）。共用一条路径时，f1 的线会被接到 f2
            // 刚画到的位置上，整块板横穿出一条 Z 字。
            var batch: [UInt16: CGMutablePath] = [:]

            var i = drawn
            while i < target && i < points.count {
                let p = points[i]
                let pt = CGPoint(x: CGFloat(p.x) * pw, y: (1 - CGFloat(p.y)) * ph)
                let continues = lastTime[p.id].map { p.t - $0 <= 0.25 } ?? false
                if continues, let last = lastPoint[p.id] {
                    let path = batch[p.id] ?? CGMutablePath()
                    // 本批第一次出现这根手指：从上一批留在这个 finger 的落点接上
                    if path.isEmpty { path.move(to: last) }
                    path.addLine(to: pt)
                    batch[p.id] = path
                }
                // continues == false 是抬手指（或换了根手指拿到同一个 id）后的新起点。
                // 单点不产生笔画，等下一个点用 lastPoint 接，这里不用画。
                lastPoint[p.id] = pt
                lastTime[p.id] = p.t
                i += 1
            }

            for (_, path) in batch {
                wideLayer.setStrokeColor(palette.bg)
                wideLayer.setLineWidth(2.4 * s)
                wideLayer.addPath(path)
                wideLayer.strokePath()

                thinLayer.setStrokeColor(palette.trail)
                thinLayer.setLineWidth(0.95 * s)
                thinLayer.addPath(path)
                thinLayer.strokePath()
            }

            drawn = max(drawn, min(target, points.count))
            imagesDirty = true
        }

        // MARK: 热力底图

        /// 直接填 32×24 的格子，和 App 里 Canvas 画出来的完全一致。
        static func makeHeatLayer(_ grid: HeatGrid, size: CGSize, palette: Palette) -> CGImage? {
            let w = Int(size.width)
            let h = Int(size.height)
            guard w > 0, h > 0,
                  let ctx = CGContext(data: nil, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                                 | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return nil }

            // 95 分位归一化：单个疯掉的格子不会把整张图压平
            let values = grid.cells.filter { $0 > 0 }.map(Double.init).sorted()
            guard !values.isEmpty else { return nil }
            let peakIndex = min(values.count - 1, Int(Double(values.count) * 0.95))
            let peak = max(values[peakIndex], 1)

            let cw = size.width / CGFloat(HeatGrid.cols)
            let ch = size.height / CGFloat(HeatGrid.rows)
            for row in 0..<HeatGrid.rows {
                for col in 0..<HeatGrid.cols {
                    let value = Double(grid.cell(row: row, col: col))
                    guard value > 0 else { continue }
                    let f = pow(value / peak, 0.5)
                    guard f > 0.12 else { continue }
                    let rect = CGRect(x: CGFloat(col) * cw,
                                      y: size.height - CGFloat(row + 1) * ch,
                                      width: cw + 0.5,
                                      height: ch + 0.5)
                    ctx.setFillColor(palette.heat(min(1, f)))
                    ctx.fill(rect)
                }
            }
            return ctx.makeImage()
        }

        private func text(_ string: String, font: CTFont, color: CGColor,
                          at origin: CGPoint, into ctx: CGContext) {
            let attributes: [NSAttributedString.Key: Any] = [
                kCTFontAttributeName as NSAttributedString.Key: font,
                kCTForegroundColorAttributeName as NSAttributedString.Key: color
            ]
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: string, attributes: attributes))
            ctx.textMatrix = .identity
            ctx.textPosition = origin
            CTLineDraw(line, ctx)
        }
    }

    public static func meters(_ cm: Double) -> String {
        if cm >= 100_000 { return String(format: "%.2f km", cm / 100_000) }
        if cm >= 100 { return String(format: "%.1f m", cm / 100) }
        return String(format: "%.0f cm", cm)
    }
}

enum VideoColor {
    static func hex(_ value: UInt32, alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: alpha)
    }
}
