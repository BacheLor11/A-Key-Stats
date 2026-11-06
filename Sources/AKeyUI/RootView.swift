import SwiftUI
import AKeyKit

// MARK: - 主窗口根视图

public struct RootView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.colorScheme) private var scheme

    public init() {}

    public var body: some View {
        HStack(spacing: 0) {
            SidebarView()
                .frame(width: 196)
            Rectangle()
                .fill(AKSScheme.of(scheme).border)
                .frame(width: 1)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(AKSScheme.of(scheme).bg)
        }
        .environment(\.aks, AKSScheme.of(scheme))
        .background(AKSScheme.of(scheme).bg)
    }

    @ViewBuilder
    private var content: some View {
        switch state.page {
        case .dashboard: DashboardView()
        case .keyboard: KeyboardPage()
        case .trackpad: TrackpadPage()
        case .mouse: MousePage()
        case .tester: TesterView()
        case .history: HistoryView()
        case .settings: SettingsView()
        }
    }
}

struct SidebarView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.aks) private var theme
    @State private var confirmReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("A-Key-Stats")
                    .font(AKSFont.serif(19))
                    .foregroundColor(theme.ink)
                Text("按键与妙控板热力")
                    .font(AKSFont.sans(10.5))
                    .foregroundColor(theme.inkSoft)
            }
            .padding(.horizontal, 18)
            .padding(.top, 46)
            .padding(.bottom, 22)

            VStack(spacing: 2) {
                ForEach(AppState.Page.allCases) { page in
                    SidebarItem(page: page, selected: state.page == page) {
                        state.page = page
                    }
                }
            }

            Spacer(minLength: 12)

            VStack(alignment: .leading, spacing: 10) {
                AKSHairline()

                // 记录开关：一眼看出在不在记，一点就切
                Button {
                    state.togglePause()
                } label: {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(state.isPaused ? theme.inkSoft.opacity(0.5) : theme.accent2)
                            .frame(width: 7, height: 7)
                        Text(state.isPaused ? "开始记录" : "记录中 · 点击暂停")
                            .font(AKSFont.sans(11, weight: .medium))
                            .foregroundColor(state.isPaused ? theme.inkSoft : theme.ink)
                        Spacer()
                        Image(systemName: state.isPaused ? "play.fill" : "pause.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(state.isPaused ? theme.inkSoft : theme.accent2)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(state.isPaused ? theme.bg.opacity(0.6) : theme.accent2.opacity(0.10))
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(state.isPaused ? "恢复统计" : "暂停统计（检测页仍然可用）")

                Button {
                    confirmReset = true
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "trash")
                            .font(.system(size: 10, weight: .medium))
                        Text("清除全部数据")
                            .font(AKSFont.sans(11))
                        Spacer()
                    }
                    .foregroundColor(theme.inkSoft)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                HStack {
                    Spacer()
                    Text("v\(AKSBundle.version)")
                        .font(AKSFont.mono(9))
                        .foregroundColor(theme.inkSoft.opacity(0.55))
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 14)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(theme.surface.opacity(0.35))
        .alert("清除全部数据？", isPresented: $confirmReset) {
            Button("取消", role: .cancel) {}
            Button("清除", role: .destructive) { state.resetAll() }
        } message: {
            Text("所有每日计数与触控板轨迹都会被删掉，不可恢复。")
        }
    }
}

struct SidebarItem: View {
    @Environment(\.aks) private var theme
    var page: AppState.Page
    var selected: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: page.symbol)
                    .font(.system(size: 11.5, weight: .medium))
                    .frame(width: 15)
                Text(page.title)
                    .font(AKSFont.sans(12.5, weight: selected ? .medium : .regular))
                Spacer()
            }
            .foregroundColor(selected ? theme.ink : theme.inkSoft)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? theme.bg : (hovering ? theme.bg.opacity(0.5) : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .onHover { hovering = $0 }
    }
}

// MARK: - 菜单栏面板

public struct PanelView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.colorScheme) private var scheme

    var onOpen: () -> Void
    var onQuit: () -> Void
    /// 面板总宽（含外边距）。
    ///
    /// 独立 app 用默认 346；作为 A-Kit 插件时由宿主传它算出来的宽度，
    /// 这样同一份视图两边都能铺满，不会一边 330 一边 296 被裁。
    var width: CGFloat
    /// 是否显示右上角电源键。
    ///
    /// 独立运行时它是「退出 A-Key-Stats」；插件形态下这个按钮会把整个 A-Kit 退掉，
    /// 所以宿主里直接不给这个入口。
    var allowsQuit: Bool

    public init(onOpen: @escaping () -> Void,
                onQuit: @escaping () -> Void,
                width: CGFloat = 346,
                allowsQuit: Bool = true) {
        self.onOpen = onOpen
        self.onQuit = onQuit
        self.width = width
        self.allowsQuit = allowsQuit
    }

    public var body: some View {
        PanelContent(onOpen: onOpen, onQuit: onQuit,
                     totalWidth: width, allowsQuit: allowsQuit)
            .environmentObject(state)
            .environment(\.aks, AKSScheme.of(scheme))
    }
}

private struct PanelContent: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.aks) private var theme
    var onOpen: () -> Void
    var onQuit: () -> Void
    var totalWidth: CGFloat = 346
    var allowsQuit: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    AKSMeta(text: "Today")
                    Text("A-Key-Stats")
                        .font(AKSFont.serif(17))
                        .foregroundColor(theme.ink)
                }
                Spacer()
                Text(state.today.date)
                    .font(AKSFont.mono(10))
                    .foregroundColor(theme.inkSoft)
            }

            HStack(alignment: .top, spacing: 14) {
                AKSKPI(value: AppState.shortNumber(state.today.keyTotal), label: "按键")
                AKSKPI(value: AppState.shortNumber(state.today.clickTotal), label: "点击")
                AKSKPI(value: String(format: "%.0f", state.padTravelCentimeters), label: "厘米行程")
            }

            KeyboardHeatView(layout: state.layout,
                             counts: state.today.keys,
                             showLabels: false)
                .frame(height: 74)

            HStack(spacing: 8) {
                Button(state.isPaused ? "继续记录" : "暂停记录") { state.togglePause() }
                    .buttonStyle(AKSPrimaryButtonStyle(filled: false))
                Spacer()
                Button("打开") { onOpen() }
                    .buttonStyle(AKSPrimaryButtonStyle())
                if allowsQuit {
                    Button {
                        onQuit()
                    } label: {
                        Image(systemName: "power")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(AKSPrimaryButtonStyle(filled: false))
                }
            }
        }
        .padding(16)
        .frame(width: max(totalWidth - 16, 240))
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(theme.border, lineWidth: 0.8)
                )
                .shadow(color: theme.shadow, radius: 14, y: 6)
        )
        .padding(8)
    }
}
