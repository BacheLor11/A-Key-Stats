import SwiftUI
import AKeyKit

/// 外设信号提示。
///
/// 只有判定成立时才出现在对应页面最上面 —— 平时整块不存在，侧栏、设置里也没有任何入口。
/// 内容尽量克制：先说人话结论，再摆证据（次数、比例、样本），最后一句怎么办。
struct HardwareNote: View {
    let finding: HardwareFinding

    @EnvironmentObject private var state: AppState
    @Environment(\.aks) private var theme

    private var tint: Color {
        finding.level == .warning ? theme.accent2 : theme.accent
    }

    private var symbol: String {
        switch finding.kind {
        case .keyboard: return "keyboard.badge.ellipsis"
        case .mouse: return "computermouse"
        case .trackpad: return "rectangle.and.hand.point.up.left"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(tint.opacity(theme.isDark ? 0.20 : 0.10))
                    .frame(width: 27, height: 27)
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(tint)
            }

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(finding.headline)
                        .font(AKSFont.sans(12.5, weight: .medium))
                        .foregroundColor(theme.ink)
                    Text(finding.level == .warning ? "建议排查" : "留意一下")
                        .font(AKSFont.mono(9))
                        .foregroundColor(tint)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(tint.opacity(0.13)))
                }

                Text(finding.detail)
                    .font(AKSFont.sans(11.5))
                    .foregroundColor(theme.inkSoft)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(alignment: .top, spacing: 22) {
                    ForEach(finding.rows) { row in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.label)
                                .font(AKSFont.sans(10))
                                .foregroundColor(theme.inkSoft.opacity(0.85))
                            Text(row.value)
                                .font(AKSFont.mono(10.5))
                                .foregroundColor(theme.ink)
                                .lineLimit(1)
                        }
                    }
                }
                .padding(.top, 1)

                Text(finding.advice)
                    .font(AKSFont.sans(10.5))
                    .foregroundColor(theme.inkSoft.opacity(0.9))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)

                Text("统计信号，不是诊断结论。数据只在本机，不记录按键内容和光标位置。")
                    .font(AKSFont.sans(9.5))
                    .foregroundColor(theme.inkSoft.opacity(0.6))
            }

            Spacer(minLength: 12)

            Button("知道了") { state.dismissHardwareNote(finding.id) }
                .buttonStyle(AKSPrimaryButtonStyle(filled: false))
                .fixedSize()
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(tint.opacity(theme.isDark ? 0.13 : 0.055))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(tint.opacity(0.24), lineWidth: 0.8)
        )
    }
}
