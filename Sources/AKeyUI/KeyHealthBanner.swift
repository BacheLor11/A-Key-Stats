import SwiftUI
import AppKit
import AKeyKit

/// 键盘采集异常时的提示条。
///
/// 触控板一路（MultitouchSupport）不吃「输入监控」权限，键盘那一路吃 —— 权限没了、
/// 或者键盘根本不是本机的 HID 设备，界面上只会安静地少掉一类数据，很难自己发现。
/// 所以只要键盘不通就摆一条在最上面，把原因和下一步直接写清楚。
struct KeyHealthBanner: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.aks) private var theme
    @State private var dismissed = false
    @State private var copied = false

    private struct Model {
        var title: String
        var detail: String
        var symbol: String
        var tint: Color
        var canDismiss: Bool
    }

    var body: some View {
        if let model = model, !dismissed {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: model.symbol)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(model.tint)
                    .padding(.top, 1.5)

                VStack(alignment: .leading, spacing: 3) {
                    Text(model.title)
                        .font(AKSFont.sans(12.5, weight: .medium))
                        .foregroundColor(theme.ink)
                    Text(model.detail)
                        .font(AKSFont.sans(11.5))
                        .foregroundColor(theme.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                HStack(spacing: 7) {
                    Button(copied ? "已复制" : "复制诊断") { copyDiagnosis() }
                        .buttonStyle(AKSPrimaryButtonStyle(filled: false))
                    Button("重新检测") { state.recheckKeyboard() }
                        .buttonStyle(AKSPrimaryButtonStyle(filled: false))
                    if state.keyHealth.state != .tapOnly {
                        Button("打开输入监控") { openListenEventSettings() }
                            .buttonStyle(AKSPrimaryButtonStyle())
                    }
                    if model.canDismiss {
                        Button {
                            dismissed = true
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .buttonStyle(AKSPrimaryButtonStyle(filled: false))
                    }
                }
                .fixedSize()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(model.tint.opacity(theme.isDark ? 0.16 : 0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(model.tint.opacity(0.26), lineWidth: 0.8)
            )
            .padding(.horizontal, 26)
            .padding(.top, 18)
        }
    }

    // MARK: 文案

    private var model: Model? {
        let health = state.keyHealth
        switch health.state {
        case .ok:
            return nil

        case .noAccess:
            return Model(
                title: "键盘没有记上：输入监控没授权",
                detail: "macOS 不允许 A-Key-Stats 读键盘事件。触控板和鼠标不吃这个权限，所以它们还在照常记。去「隐私与安全性 → 输入监控」把 A-Key-Stats 打开即可。",
                symbol: "exclamationmark.triangle",
                tint: theme.accent2,
                canDismiss: false
            )

        case .hidden:
            return Model(
                title: "键盘没有记上：系统里看不到任何键盘设备",
                detail: hiddenDetail(health),
                symbol: "exclamationmark.triangle",
                tint: theme.accent2,
                canDismiss: false
            )

        case .tapOnly:
            return Model(
                title: "键盘在用系统事件兜底记录",
                detail: "这台机器上没有可见的键盘 HID 设备（键盘多半接在别的机器上，走通用控制 / 远程桌面 / KVM 进来），按键已从事件层接住并计数，只是记不到具体是哪块键盘。",
                symbol: "keyboard",
                tint: theme.accent,
                canDismiss: true
            )
        }
    }

    private func hiddenDetail(_ health: KeyboardHealth) -> String {
        if let last = health.lastKeyAt {
            let formatter = RelativeDateTimeFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.unitsStyle = .full
            let ago = formatter.localizedString(for: last, relativeTo: Date())
            return "授权是开着的（上一次记到按键是\(ago)），但现在枚举不到键盘。通常是：键盘没连到这台机器（KVM / 远程桌面 / 通用控制），或者重新安装后授权失效了 —— 去「输入监控」把它关掉再打开一次。"
        }
        return "授权是开着的，但枚举不到任何键盘 HID 设备。先确认键盘真的连着这台机器；如果是刚重新安装过，去「输入监控」把 A-Key-Stats 关掉再打开一次（授权绑在签名身份上，重装会失效）。"
    }

    // MARK: 动作

    private func openListenEventSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    /// 把体检结果拼成一段可粘贴的文字，出问题时直接发过来就能定位
    private func copyDiagnosis() {
        let health = state.keyHealth
        let last = health.lastKeyAt.map { ISO8601DateFormatter().string(from: $0) } ?? "—"
        let text = """
        A-Key-Stats \(AKSBundle.version) 键盘诊断
        状态: \(health.state.rawValue)
        输入监控: \(health.access)
        可见键盘: \(health.keyboards.isEmpty ? "（空）" : health.keyboards.joined(separator: "、"))
        HID 事件: \(health.hidEvents) · 事件层: \(health.tapEvents)
        最近按键: \(last)
        系统: \(ProcessInfo.processInfo.operatingSystemVersionString)
        """
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
        copied = true
    }
}
