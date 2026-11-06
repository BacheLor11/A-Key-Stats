import SwiftUI
import AKeyKit

// MARK: - 历史

struct HistoryView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.aks) private var theme

    private var peak: Int {
        max(state.recentDays.map { $0.keyTotal }.max() ?? 1, 1)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                AKSPageHeader(
                    kicker: "History",
                    title: "这几天的节奏",
                    lede: "按天聚合：按键次数、点击、触控板里程。缺的天会留空位，不会把数据接歪。",
                    trailing: AnyView(
                        Button("导出 CSV") {
                            _ = state.exportCSV()
                        }
                        .buttonStyle(AKSPrimaryButtonStyle(filled: false))
                    )
                )

                AKSCard {
                    VStack(alignment: .leading, spacing: 14) {
                        ACTitle(text: "近 14 天按键量", meta: "Daily keys")
                        HStack(alignment: .bottom, spacing: 6) {
                            ForEach(Array(state.recentDays.enumerated()), id: \.offset) { _, day in
                                VStack(spacing: 6) {
                                    Text(AppState.shortNumber(day.keyTotal))
                                        .font(AKSFont.mono(8.5))
                                        .foregroundColor(theme.inkSoft)
                                        .lineLimit(1)
                                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                                        .fill(day.keyTotal == 0
                                              ? theme.border.opacity(0.4)
                                              : theme.accent.opacity(day.keyTotal == peak ? 1 : 0.55))
                                        .frame(height: max(6, CGFloat(day.keyTotal) / CGFloat(peak) * 150))
                                    Text(String(day.date.suffix(5)))
                                        .font(AKSFont.mono(9))
                                        .foregroundColor(theme.inkSoft)
                                }
                                .frame(maxWidth: .infinity)
                            }
                        }
                        .frame(height: 200, alignment: .bottom)
                    }
                }

                AKSCard {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text("日期").frame(width: 92, alignment: .leading)
                            Text("按键").frame(width: 70, alignment: .trailing)
                            Text("点击").frame(width: 60, alignment: .trailing)
                            Text("触控板里程").frame(width: 100, alignment: .trailing)
                            Text("活跃").frame(width: 70, alignment: .trailing)
                            Spacer()
                            Text("最忙的键").frame(width: 90, alignment: .trailing)
                        }
                        .font(AKSFont.sans(10, weight: .medium))
                        .foregroundColor(theme.inkSoft)
                        .padding(.bottom, 8)
                        AKSHairline()
                        ForEach(state.recentDays.reversed(), id: \.date) { day in
                            HStack {
                                Text(day.date)
                                    .font(AKSFont.mono(11))
                                    .frame(width: 92, alignment: .leading)
                                Text(AppState.shortNumber(day.keyTotal))
                                    .font(AKSFont.mono(11, weight: .medium))
                                    .frame(width: 70, alignment: .trailing)
                                Text("\(day.clickTotal)")
                                    .font(AKSFont.mono(11))
                                    .frame(width: 60, alignment: .trailing)
                                Text(String(format: "%.0f cm", day.padTravel * 20))
                                    .font(AKSFont.mono(11))
                                    .frame(width: 100, alignment: .trailing)
                                Text(activeText(day.activeSeconds))
                                    .font(AKSFont.mono(11))
                                    .frame(width: 70, alignment: .trailing)
                                Spacer()
                                Text(topKeyLabel(day))
                                    .font(AKSFont.sans(11))
                                    .frame(width: 90, alignment: .trailing)
                            }
                            .foregroundColor(day.keyTotal == 0 ? theme.inkSoft.opacity(0.55) : theme.ink)
                            .padding(.vertical, 8)
                            AKSHairline()
                        }
                    }
                }
            }
            .padding(26)
        }
    }

    private func activeText(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        return "\(seconds / 60)m"
    }

    private func topKeyLabel(_ day: DayStats) -> String {
        guard let best = day.keys.max(by: { $0.value < $1.value }), best.value > 0,
              let label = state.layout.label(UInt16(best.key) ?? 0) else { return "—" }
        return "\(label) \(best.value)"
    }
}

// MARK: - 设置

struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.aks) private var theme
    @State private var confirmReset = false
    @State private var exported: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                AKSPageHeader(
                    kicker: "Settings",
                    title: "权限与口径",
                    lede: "这里没有云、没有账号、没有上报。数据目录你可以随时打开自己看。",
                    trailing: AnyView(AKSTag(text: "v\(AKSBundle.version)"))
                )

                AKSCard {
                    VStack(alignment: .leading, spacing: 12) {
                        ACTitle(text: "输入监控权限", meta: "Permission")
                        HStack(spacing: 8) {
                            Circle()
                                .fill(permissionColor)
                                .frame(width: 7, height: 7)
                            Text(permissionText)
                                .font(AKSFont.sans(12))
                                .foregroundColor(theme.ink)
                            Spacer()
                            Button("请求授权") { state.requestPermission() }
                                .buttonStyle(AKSPrimaryButtonStyle())
                            Button("打开系统设置") { openPrivacySettings() }
                                .buttonStyle(AKSPrimaryButtonStyle(filled: false))
                        }
                        Text("授权绑定在 app 的签名身份上。重新构建后如果计数归零，回到「隐私与安全性 → 输入监控」把它关掉再打开一次即可。")
                            .font(AKSFont.sans(11))
                            .foregroundColor(theme.inkSoft)
                    }
                }

                AKSCard {
                    VStack(alignment: .leading, spacing: 14) {
                        ACTitle(text: "键盘配列", meta: "Layout")
                        Picker("", selection: $state.layoutID) {
                            ForEach(KeyboardLayoutID.allCases) { id in
                                Text(id.displayName).tag(id)
                            }
                        }
                        .pickerStyle(.radioGroup)
                        .labelsHidden()
                        AKSHairline()
                        Toggle("翻转触控板 Y 轴", isOn: $state.flipPadY)
                        Toggle("翻转鼠标 Y 轴", isOn: $state.flipMouseY)
                        Text("如果热力图上下颠倒，把对应开关切换一下。触控板的归一化原点在左下，默认已翻转。")
                            .font(AKSFont.sans(11))
                            .foregroundColor(theme.inkSoft)
                    }
                }

                AKSCard {
                    VStack(alignment: .leading, spacing: 14) {
                        ACTitle(text: "概览显示", meta: "Overview")
                        Picker("", selection: $state.overviewPanels) {
                            ForEach(AppState.OverviewPanels.allCases) { panel in
                                Text(panel.title).tag(panel)
                            }
                        }
                        .pickerStyle(.radioGroup)
                        .labelsHidden()
                        Text("只关心键盘的话，把触控板或鼠标收起来，概览会宽一点。")
                            .font(AKSFont.sans(11))
                            .foregroundColor(theme.inkSoft)
                    }
                }

                AKSCard {
                    VStack(alignment: .leading, spacing: 12) {
                        ACTitle(text: "采集", meta: "Capture")
                        HStack {
                            Text(state.isPaused ? "已暂停" : "正在记录")
                                .font(AKSFont.sans(12))
                                .foregroundColor(state.isPaused ? theme.accent2 : theme.accent)
                            Spacer()
                            Button(state.isPaused ? "开始记录" : "暂停记录") { state.togglePause() }
                                .buttonStyle(AKSPrimaryButtonStyle(filled: false))
                        }
                        Text("暂停只停止统计，检测页照常工作。滚动口径：触控板双指滚动单独记为「触控滚动」，不再混进鼠标的「滚轮」。")
                            .font(AKSFont.sans(11))
                            .foregroundColor(theme.inkSoft)
                        AKSHairline()
                        AKSStatRow(label: "键盘设备",
                                   value: state.storedDeviceNames.keyboards.joined(separator: "、").isEmpty
                                   ? "未授权 / 未检测到"
                                   : state.storedDeviceNames.keyboards.joined(separator: "、"),
                                   mono: false)
                        AKSStatRow(label: "数据目录", value: state.engine.dataDirectory.path, mono: false)
                    }
                }

                AKSCard {
                    VStack(alignment: .leading, spacing: 12) {
                        ACTitle(text: "数据", meta: "Data")
                        HStack(spacing: 10) {
                            Button("打开数据目录") {
                                NSWorkspace.shared.open(state.engine.dataDirectory)
                            }
                            .buttonStyle(AKSPrimaryButtonStyle(filled: false))
                            Button("导出 CSV") {
                                if let url = state.exportCSV() { exported = url.path }
                            }
                            .buttonStyle(AKSPrimaryButtonStyle(filled: false))
                            Spacer()
                            Button("清空全部数据") { confirmReset = true }
                                .buttonStyle(AKSPrimaryButtonStyle(danger: true))
                        }
                        if let exported {
                            Text("已导出到 \(exported)")
                                .font(AKSFont.sans(11))
                                .foregroundColor(theme.inkSoft)
                        }
                        Text("清空会删掉全部每日聚合与轨迹文件，不可恢复。")
                            .font(AKSFont.sans(11))
                            .foregroundColor(theme.inkSoft)
                    }
                }
            }
            .padding(26)
        }
        .alert("清空全部数据？", isPresented: $confirmReset) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) { state.resetAll() }
        } message: {
            Text("所有每日计数与触控板轨迹都会被删除。")
        }
    }

    private var permissionColor: Color {
        switch state.inputAccess {
        case .granted: return theme.accent
        case .denied: return theme.accent2
        case .unknown: return Color.orange
        }
    }

    private var permissionText: String {
        switch state.inputAccess {
        case .granted: return "已授权，键盘计数正常"
        case .denied: return "被拒绝 —— 键盘计数拿不到数据"
        case .unknown: return "还没授权"
        }
    }

    private func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }
}
