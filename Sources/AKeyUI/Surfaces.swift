import SwiftUI
import AKeyKit

// MARK: - 触控板

/// 网格热力 + 可选轨迹叠加（可回放）。
/// 绘制拆三层：板面 / 裁剪过的热力与轨迹 / 边线与标注。
struct TrackpadHeatView: View {
    @Environment(\.aks) private var theme

    var grid: HeatGrid
    var points: [TrajPoint] = []
    var progress: Double = 1
    var showTrail = false
    var aspect: CGFloat = 1.39        // 妙控板 16.0 × 11.5 cm

    /// 95 分位归一化：单个疯掉的格子不会把整张图压平
    private var peak: Double {
        let values = grid.cells.filter { $0 > 0 }.map(Double.init).sorted()
        guard !values.isEmpty else { return 1 }
        let index = min(values.count - 1, Int(Double(values.count) * 0.95))
        return max(values[index], 1)
    }

    var body: some View {
        GeometryReader { geo in
            let padWidth = min(geo.size.width, geo.size.height * aspect)
            let padHeight = padWidth / aspect
            let rect = CGRect(x: (geo.size.width - padWidth) / 2,
                              y: (geo.size.height - padHeight) / 2,
                              width: padWidth, height: padHeight)
            let radius = min(padWidth, padHeight) * 0.055
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)

            ZStack(alignment: .topLeading) {
                shape.fill(theme.bg)
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)

                heatLayer
                    .frame(width: rect.width, height: rect.height)
                    .clipShape(shape)
                    .offset(x: rect.minX, y: rect.minY)

                trailLayer(limit: trailLimit)
                    .frame(width: rect.width, height: rect.height)
                    .clipShape(shape)
                    .offset(x: rect.minX, y: rect.minY)
                    .opacity(showTrail ? 1 : 0)

                shape.stroke(theme.border, lineWidth: 1)
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)

                RoundedRectangle(cornerRadius: radius * 0.75, style: .continuous)
                    .stroke(theme.border.opacity(0.45), lineWidth: 0.5)
                    .frame(width: max(rect.width - 12, 4), height: max(rect.height - 12, 4))
                    .offset(x: rect.minX + 6, y: rect.minY + 6)

                Text("TRACKPAD")
                    .font(AKSFont.sans(8, weight: .medium))
                    .foregroundColor(theme.inkSoft.opacity(0.45))
                    .offset(x: rect.minX + 13, y: rect.minY + 10)
            }
        }
    }

    private var trailLimit: Int {
        guard points.count > 1 else { return 0 }
        return max(2, Int(Double(points.count) * min(max(progress, 0), 1)))
    }

    private var heatLayer: some View {
        Canvas { context, size in
            let cw = size.width / CGFloat(HeatGrid.cols)
            let ch = size.height / CGFloat(HeatGrid.rows)
            for row in 0..<HeatGrid.rows {
                for col in 0..<HeatGrid.cols {
                    let value = Double(grid.cell(row: row, col: col))
                    guard value > 0 else { continue }
                    let f = pow(value / peak, 0.5)
                    guard f > 0.12 else { continue }        // 零星一两帧的格子不画，免得满屏雪花
                    let cell = CGRect(x: CGFloat(col) * cw, y: CGFloat(row) * ch,
                                      width: cw + 0.5, height: ch + 0.5)
                    context.fill(Path(cell), with: .color(theme.heat(min(1, f))))
                }
            }
        }
    }

    private func trailLayer(limit: Int) -> some View {
        Canvas { context, size in
            guard limit > 1 else { return }
            // 按接触点 id 分组：双指滚动时两根手指各有各的线，
            // 不分组的会变成两点交替、连成一整片 Z 字
            var groups: [UInt16: [TrajPoint]] = [:]
            for index in 0..<limit {
                let p = points[index]
                groups[p.id, default: []].append(p)
            }

            var path = Path()
            for (_, list) in groups {
                guard list.count > 1 else { continue }
                for index in 0..<list.count {
                    let p = list[index]
                    let point = CGPoint(x: CGFloat(p.x) * size.width,
                                        y: CGFloat(p.y) * size.height)
                    if index == 0 || p.t - list[index - 1].t > 0.25 {
                        path.move(to: point)      // 抬手指的间隔断开，避免连出假线
                    } else {
                        path.addLine(to: point)
                    }
                }
            }

            // 点太多时压淡一点，整天轨迹叠在一起也不至于糊成墨块
            let alpha = groups.count > 40 ? 0.45 : (groups.count > 12 ? 0.65 : 0.85)
            context.stroke(path, with: .color(theme.bg.opacity(0.70)),
                           style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
            context.stroke(path, with: .color(theme.accent2.opacity(alpha)),
                           style: StrokeStyle(lineWidth: 0.95, lineCap: .round, lineJoin: .round))
        }
    }
}

// MARK: - 鼠标

/// 鼠标外形（俯视）+ 表面接触热力 + 左右键计数
struct MouseHeatView: View {
    @Environment(\.aks) private var theme

    var grid: HeatGrid
    var leftClicks: Int
    var rightClicks: Int
    var showLabels = true

    private var peak: Double {
        let values = grid.cells.filter { $0 > 0 }.map(Double.init).sorted()
        guard !values.isEmpty else { return 1 }
        let index = min(values.count - 1, Int(Double(values.count) * 0.95))
        return max(values[index], 1)
    }

    var body: some View {
        GeometryReader { geo in
            let bodyHeight = min(geo.size.height, geo.size.width * 1.7)
            let bodyWidth = bodyHeight / 1.7
            let rect = CGRect(x: (geo.size.width - bodyWidth) / 2,
                              y: (geo.size.height - bodyHeight) / 2,
                              width: bodyWidth, height: bodyHeight)
            let shape = MouseShape()

            ZStack(alignment: .topLeading) {
                shape.fill(theme.surface)
                    .overlay(shape.stroke(theme.border, lineWidth: 1))
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)

                heatLayer
                    .frame(width: rect.width, height: rect.height)
                    .clipShape(shape)
                    .offset(x: rect.minX, y: rect.minY)

                // 左右键分界 + 滚轮
                Path { path in
                    let splitY = rect.height * 0.30
                    path.move(to: CGPoint(x: rect.width * 0.16, y: splitY))
                    path.addLine(to: CGPoint(x: rect.width * 0.84, y: splitY))
                    path.move(to: CGPoint(x: rect.width * 0.5, y: rect.height * 0.07))
                    path.addLine(to: CGPoint(x: rect.width * 0.5, y: splitY))
                }
                .stroke(theme.surface.opacity(0.85), lineWidth: 2.2)
                .overlay(
                    Path { path in
                        let splitY = rect.height * 0.30
                        path.move(to: CGPoint(x: rect.width * 0.16, y: splitY))
                        path.addLine(to: CGPoint(x: rect.width * 0.84, y: splitY))
                        path.move(to: CGPoint(x: rect.width * 0.5, y: rect.height * 0.07))
                        path.addLine(to: CGPoint(x: rect.width * 0.5, y: splitY))
                    }
                    .stroke(theme.inkSoft.opacity(0.35), lineWidth: 0.7)
                )
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)

                Capsule()
                    .stroke(theme.surface.opacity(0.9), lineWidth: 3)
                    .overlay(Capsule().stroke(theme.inkSoft.opacity(0.4), lineWidth: 0.7))
                    .frame(width: rect.width * 0.10, height: rect.height * 0.10)
                    .offset(x: rect.minX + rect.width * 0.45,
                            y: rect.minY + rect.height * 0.155)

                Text("MOUSE")
                    .font(AKSFont.sans(8, weight: .medium))
                    .foregroundColor(theme.inkSoft.opacity(0.4))
                    .offset(x: rect.minX + rect.width * 0.5 - 16,
                            y: rect.minY + rect.height - 24)
            }
        }
    }

    private var heatLayer: some View {
        Canvas { context, size in
            let cw = size.width / CGFloat(HeatGrid.cols)
            let ch = size.height / CGFloat(HeatGrid.rows)
            for row in 0..<HeatGrid.rows {
                for col in 0..<HeatGrid.cols {
                    let value = Double(grid.cell(row: row, col: col))
                    guard value > 0 else { continue }
                    let f = pow(value / peak, 0.5)
                    guard f > 0.12 else { continue }
                    let cell = CGRect(x: CGFloat(col) * cw, y: CGFloat(row) * ch,
                                      width: cw + 0.5, height: ch + 0.5)
                    context.fill(Path(cell), with: .color(theme.heat(min(1, f))))
                }
            }
        }
    }
}

/// 俯视鼠标轮廓：顶部两个圆肩、下部略收
struct MouseShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addCurve(to: CGPoint(x: rect.maxX, y: rect.minY + h * 0.30),
                      control1: CGPoint(x: rect.minX + w * 0.84, y: rect.minY),
                      control2: CGPoint(x: rect.maxX, y: rect.minY + h * 0.12))
        path.addCurve(to: CGPoint(x: rect.midX, y: rect.maxY),
                      control1: CGPoint(x: rect.maxX, y: rect.minY + h * 0.74),
                      control2: CGPoint(x: rect.minX + w * 0.84, y: rect.maxY))
        path.addCurve(to: CGPoint(x: rect.minX, y: rect.minY + h * 0.30),
                      control1: CGPoint(x: rect.minX + w * 0.16, y: rect.maxY),
                      control2: CGPoint(x: rect.minX, y: rect.minY + h * 0.74))
        path.addCurve(to: CGPoint(x: rect.midX, y: rect.minY),
                      control1: CGPoint(x: rect.minX, y: rect.minY + h * 0.12),
                      control2: CGPoint(x: rect.minX + w * 0.16, y: rect.minY))
        path.closeSubpath()
        return path
    }
}
