import SwiftUI
import AKeyKit

// MARK: - 热力刻度
//
// 三个视图把数值映射成颜色的口径都是
//     f = pow(value / peak, gamma)   →   theme.heat(f)
// 光给一条「少 → 多」的渐变条是不够的：换个周期 peak 就变了，
// 同一个墨蓝在不同图上代表的绝对量完全不同。所以图例必须跟着
// 真实的 peak / gamma 走，把刻度反算成「多少次 / 多少帧」。
struct HeatScaleInfo {
    /// f = 1 对应的实际数值（键盘是次数，触控板/鼠标是接触帧）
    var peak: Double
    /// 上色用的幂次，和视图里必须一致
    var gamma: Double
    var unit: String
    var hasData: Bool

    /// heat() 在 0.55 处正好是墨蓝，之后转赭石 —— 图例上标出这个转折
    static let pivot = 0.55

    /// 图上 f 处的颜色，对应多少实际数值
    func value(at fraction: Double) -> Double {
        guard peak > 0 else { return 0 }
        return peak * pow(min(max(fraction, 0), 1), 1 / max(gamma, 0.01))
    }

    static func forKeys(_ counts: [String: Int]) -> HeatScaleInfo {
        let peak = max(counts.values.max() ?? 0, 1)
        return HeatScaleInfo(peak: Double(peak), gamma: 0.45, unit: "次",
                             hasData: counts.values.contains { $0 > 0 })
    }

    /// 热力网格用 95 分位当峰值（单个疯掉的格子不该把整张图压平），
    /// 所以图例刻度也得按同一个 95 分位算，不能用 max
    static func forGrid(_ grid: HeatGrid) -> HeatScaleInfo {
        let values = grid.cells.filter { $0 > 0 }.map(Double.init).sorted()
        var peak: Double = 1
        if !values.isEmpty {
            let index = min(values.count - 1, Int(Double(values.count) * 0.95))
            peak = max(values[index], 1)
        }
        return HeatScaleInfo(peak: peak, gamma: 0.5, unit: "帧", hasData: !values.isEmpty)
    }
}

/// 图表下方的色阶条：渐变 + 三档刻度 + 一句口径说明
struct HeatScaleBar: View {
    @Environment(\.aks) private var theme

    var info: HeatScaleInfo
    /// 概览页小卡片里用：只有一根细条和首尾两个数
    var compact = false

    private var barHeight: CGFloat { compact ? 6 : 8 }
    private var tickFont: Font { AKSFont.mono(compact ? 8.5 : 9.5) }

    var body: some View {
        // 没数据时整条不画：一张空图下面挂一条看不懂的色阶只是噪音
        if info.hasData {
            VStack(alignment: .leading, spacing: compact ? 3.5 : 7) {
                geometryBar
                ticks
                if !compact {
                    Text("左端墨蓝是低频、右端赭石是高频，中间刻度就是转色点。刻度按当前峰值伸缩，换个周期同一个颜色代表的量会变。")
                        .font(AKSFont.sans(9.5))
                        .foregroundColor(theme.inkSoft.opacity(0.72))
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var geometryBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // 逐段填 heat(f)，保证和键帽/网格用的是同一条曲线 ——
                // LinearGradient 会在 sRGB 里做线性插值，中段颜色会偏
                Canvas { context, size in
                    let steps = 64
                    let width = size.width / CGFloat(steps)
                    for index in 0..<steps {
                        let f = Double(index) / Double(steps - 1)
                        let rect = CGRect(x: CGFloat(index) * width, y: 0,
                                          width: width + 0.6, height: size.height)
                        context.fill(Path(rect), with: .color(theme.heat(f)))
                    }
                }

                // 墨蓝 → 赭石的分界
                Rectangle()
                    .fill(theme.surface.opacity(0.65))
                    .frame(width: 1, height: barHeight)
                    .offset(x: max(0, geo.size.width * HeatScaleInfo.pivot - 0.5))
            }
            .clipShape(Capsule())
            .overlay(Capsule().stroke(theme.border, lineWidth: 0.5))
        }
        .frame(height: barHeight)
    }

    private var ticks: some View {
        HStack(spacing: 0) {
            Text("0")
            Spacer(minLength: 2)
            Text(topLabel)
        }
        .font(tickFont)
        .foregroundColor(theme.inkSoft)
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .overlay(alignment: .leading) {
            // 中间刻度要正好压在条的转色点上，所以不能用三等分的 HStack
            GeometryReader { geo in
                Text(midLabel)
                    .font(tickFont)
                    .foregroundColor(theme.inkSoft)
                    .lineLimit(1)
                    .fixedSize()
                    .position(x: geo.size.width * HeatScaleInfo.pivot,
                              y: geo.size.height / 2)
            }
        }
    }

    private var midLabel: String {
        info.hasData ? number(info.value(at: HeatScaleInfo.pivot)) : " "
    }

    private var topLabel: String {
        info.hasData ? "\(number(info.peak)) \(info.unit)" : "—"
    }

    private func number(_ value: Double) -> String {
        if value <= 0 { return "0" }
        if value < 10 { return String(format: "%.1f", value) }
        return AppState.shortNumber(Int(value.rounded()))
    }
}
