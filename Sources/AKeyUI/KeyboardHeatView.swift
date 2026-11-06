import SwiftUI
import AKeyKit

/// 画出来的实体键盘，每键按次数上色
struct KeyboardHeatView: View {
    @Environment(\.aks) private var theme

    var layout: KeyboardLayout
    var counts: [String: Int]
    var showLabels = true
    var maxHeight: CGFloat = .infinity
    /// 检测页用：此刻正被按住的键，画成实心高亮而不是热力色
    var pressed: Set<UInt16> = []

    @State private var hovered: UInt16?

    private var peak: Int { max(counts.values.max() ?? 0, 1) }

    var body: some View {
        GeometryReader { geo in
            let unitW = geo.size.width / layout.widthUnits
            let unitH = geo.size.height / max(layout.heightUnits, 0.001)
            let unit = min(unitW, unitH)
            let offsetX = (geo.size.width - unit * layout.widthUnits) / 2
            let offsetY = (geo.size.height - unit * layout.heightUnits) / 2

            ZStack(alignment: .topLeading) {
                ForEach(layout.keys) { key in
                    keyCap(key, unit: unit)
                        .offset(x: offsetX + key.x * unit, y: offsetY + key.y * unit)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .frame(maxHeight: maxHeight)
    }

    private func fraction(_ code: UInt16) -> Double {
        let value = counts[String(code)] ?? 0
        guard value > 0 else { return 0 }
        // 幂次压缩：低频键别一上来就很深，高频键也别糊成一片
        let ratio = pow(Double(value) / Double(peak), 0.45)
        return min(1, max(0.08, ratio))
    }

    @ViewBuilder
    private func keyCap(_ key: KeyCap, unit: CGFloat) -> some View {
        let f = fraction(key.code)
        let isHovered = hovered == key.code
        let isDown = pressed.contains(key.code)
        // 没按过的键：深色下不能再用 bg —— 卡片本身也是深色，键帽会糊成一片黑块。
        // 抬到 surface 一级，键盘的格子感才出得来。
        let idleFill = theme.isDark ? theme.surface : theme.bg
        let fill = isDown ? theme.accent2 : (f > 0 ? theme.heat(f) : idleFill)
        let text = (isDown || f > 0.62) ? Color.white : theme.ink
        let fontSize = max(5.5, min(unit * 0.30, key.w > 1.2 ? 10.5 : 9.5))

        RoundedRectangle(cornerRadius: max(2, unit * 0.14), style: .continuous)
            .fill(fill)
            .overlay(
                RoundedRectangle(cornerRadius: max(2, unit * 0.14), style: .continuous)
                    .stroke(isDown ? theme.accent2 : (isHovered ? theme.accent2 : theme.border.opacity(f > 0 ? 0.25 : 1)),
                            lineWidth: isDown ? 1.6 : (isHovered ? 1.4 : 0.6))
            )
            .overlay(alignment: .center) {
                if showLabels && unit > 12 {
                    Text(key.label)
                        .font(AKSFont.sans(fontSize, weight: (f > 0.3 || isDown) ? .medium : .regular))
                        .foregroundColor(text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .padding(.horizontal, 1)
                }
            }
            .frame(width: key.w * unit, height: key.h * unit)
            .help("\(key.label) · \(counts[String(key.code)] ?? 0) 次")
            .onHover { inside in
                hovered = inside ? key.code : (hovered == key.code ? nil : hovered)
            }
            .animation(.easeOut(duration: 0.12), value: isDown)
            .animation(.easeOut(duration: 0.35), value: f)
    }
}

/// 排行榜：某键 · 次数 · 占比条
struct KeyRankList: View {
    @Environment(\.aks) private var theme
    var rows: [(label: String, count: Int)]
    var tint: Color

    var body: some View {
        let peak = max(rows.map { $0.count }.max() ?? 1, 1)
        VStack(spacing: 7) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 10) {
                    Text(row.label)
                        .font(AKSFont.mono(11.5, weight: .medium))
                        .foregroundColor(theme.ink)
                        .frame(width: 66, alignment: .leading)
                        .lineLimit(1)
                    AKSBar(fraction: Double(row.count) / Double(peak), tint: tint, height: 4)
                    Text("\(row.count)")
                        .font(AKSFont.mono(10.5))
                        .foregroundColor(theme.inkSoft)
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                        .frame(width: 66, alignment: .trailing)
                }
            }
        }
    }
}
