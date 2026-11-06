import SwiftUI
import AKeyKit

// MARK: - 概览

struct DashboardView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.aks) private var theme

    private var stats: PeriodStats { state.currentStats }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                AKSPageHeader(
                    kicker: state.periodKicker,
                    title: state.periodHeadline,
                    lede: state.periodSummary,
                    trailing: AnyView(
                        HStack(spacing: 14) {
                            Picker("", selection: $state.overviewPanels) {
                                ForEach(AppState.OverviewPanels.allCases) { panel in
                                    Text(panel.title).tag(panel)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .frame(width: 132)
                            .help("决定概览里触控板和鼠标怎么显示")
                        }
                    )
                )

                PeriodTabs()

                AKSCard {
                    HStack(alignment: .top, spacing: 26) {
                        AKSKPI(value: AppState.shortNumber(stats.keyTotal),
                               label: "按键次数",
                               hint: state.statsPeriod == .today
                                   ? "含修饰键"
                                   : "日均 \(AppState.shortNumber(stats.dailyKeyAverage))")
                        AKSKPI(value: AppState.shortNumber(stats.clickTotal),
                               label: "鼠标点击",
                               hint: "左 \(AppState.shortNumber(stats.clicks.left)) · 右 \(AppState.shortNumber(stats.clicks.right))",
                               tint: theme.accent)
                        AKSKPI(value: travel(stats.padTravelCentimeters),
                               label: "手指行程",
                               hint: "触控板轨迹累计",
                               tint: theme.accent2)
                        AKSKPI(value: duration(stats.activeSeconds),
                               label: "活跃时长",
                               hint: stats.dayCount > 1 ? "\(stats.dayCount) 天累计" : "间隔 < 60 秒算连续")
                    }
                }

                HStack(alignment: .top, spacing: 18) {
                    AKSCard(padding: 16) {
                        VStack(alignment: .leading, spacing: 12) {
                            AKSMeta(text: "Keyboard · \(state.layoutID.shortName)")
                            KeyboardHeatView(layout: state.layout,
                                             counts: stats.keys,
                                             showLabels: false)
                                .frame(height: 168)
                            HeatScaleBar(info: .forKeys(stats.keys), compact: true)
                            AKSHairline()
                            Text("最高频 \(state.currentTopKeys.first?.label ?? "—") · \(AppState.shortNumber(state.currentTopKeys.first?.count ?? 0)) 次")
                                .font(AKSFont.sans(11))
                                .foregroundColor(theme.inkSoft)
                        }
                    }

                    if state.overviewPanels.showsTrackpad {
                        AKSCard(padding: 16) {
                            VStack(alignment: .leading, spacing: 12) {
                                AKSMeta(text: "Trackpad", color: theme.accent2)
                                TrackpadHeatView(grid: stats.padGrid,
                                                 points: state.statsPeriod == .today ? state.padTrajectory : [],
                                                 progress: 1,
                                                 showTrail: false)
                                    .frame(height: 168)
                                HeatScaleBar(info: .forGrid(stats.padGrid), compact: true)
                                AKSHairline()
                                Text("接触 \(AppState.shortNumber(stats.padContacts)) 帧 · 峰值面积 \(String(format: "%.2f", stats.padMaxContact))")
                                    .font(AKSFont.sans(11))
                                    .foregroundColor(theme.inkSoft)
                                    .lineLimit(1)
                            }
                        }
                        .frame(width: state.overviewPanels.showsMouse ? 286 : 360)
                    }

                    if state.overviewPanels.showsMouse {
                        AKSCard(padding: 16) {
                            VStack(alignment: .leading, spacing: 12) {
                                AKSMeta(text: "Mouse")
                                MouseHeatView(grid: stats.mouseGrid,
                                              leftClicks: stats.clicks.left,
                                              rightClicks: stats.clicks.right,
                                              showLabels: false)
                                    .frame(height: 168)
                                HeatScaleBar(info: .forGrid(stats.mouseGrid), compact: true)
                                AKSHairline()
                                Text("点击 \(AppState.shortNumber(stats.clickTotal)) · 滚轮 \(AppState.shortNumber(stats.clicks.scroll))")
                                    .font(AKSFont.sans(11))
                                    .foregroundColor(theme.inkSoft)
                                    .lineLimit(1)
                            }
                        }
                        .frame(width: state.overviewPanels.showsTrackpad ? 196 : 240)
                    }
                }

                HStack(alignment: .top, spacing: 18) {
                    AKSCard {
                        VStack(alignment: .leading, spacing: 14) {
                            ACTitle(text: state.statsPeriod == .today ? "24 小时活跃度" : "24 小时活跃度 · 累计",
                                    meta: "Hourly")
                            ActivityBars(values: stats.hourly, tint: theme.accent)
                                .frame(height: 96)
                            if state.statsPeriod != .today {
                                Text("把整个周期的按键按小时堆起来 —— 一天的形状会从噪声里浮出来。")
                                    .font(AKSFont.sans(10.5))
                                    .foregroundColor(theme.inkSoft.opacity(0.85))
                            }
                        }
                    }
                    AKSCard {
                        VStack(alignment: .leading, spacing: 12) {
                            ACTitle(text: "最常按的键", meta: state.statsPeriod == .today ? "Today" : "Top 12")
                            if state.currentTopKeys.isEmpty {
                                Text("还没有数据 —— 敲几个键试试")
                                    .font(AKSFont.sans(11.5))
                                    .foregroundColor(theme.inkSoft)
                                    .padding(.vertical, 12)
                            } else {
                                KeyRankList(rows: state.currentTopKeys, tint: theme.accent2)
                            }
                        }
                    }
                    .frame(width: 320)
                }
            }
            .padding(26)
        }
    }

    /// 手指行程按量级换单位，累计到几公里时别顶着六位厘米数
    private func travel(_ centimeters: Double) -> String {
        if centimeters >= 100_000 { return String(format: "%.1f km", centimeters / 100_000) }
        if centimeters >= 200 { return String(format: "%.0f m", centimeters / 100) }
        return String(format: "%.0f cm", centimeters)
    }

    private func duration(_ seconds: Int) -> String {
        if seconds >= 86_400 { return String(format: "%.1f 天", Double(seconds) / 86_400) }
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 { return "\(hours)h\(minutes)m" }
        return "\(minutes)m"
    }
}

/// 四个周期并排：既是切换器，也顺手做「一眼看全」的总览条
struct PeriodTabs: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.aks) private var theme

    var body: some View {
        HStack(spacing: 0) {
            ForEach(StatsPeriod.allCases) { period in
                tab(period)
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(theme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .stroke(theme.border, lineWidth: 0.7)
                )
                .shadow(color: theme.shadow, radius: 6, x: 0, y: 2)
        )
    }

    private func tab(_ period: StatsPeriod) -> some View {
        let stats = state.stats(for: period)
        let active = state.statsPeriod == period
        return Button {
            state.statsPeriod = period
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(period.title)
                        .font(AKSFont.sans(11.5, weight: active ? .medium : .regular))
                        .foregroundColor(active ? theme.ink : theme.inkSoft)
                    Text(period.englishTitle.uppercased())
                        .font(AKSFont.mono(7.5))
                        .foregroundColor(theme.inkSoft.opacity(active ? 0.7 : 0.45))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                Text(AppState.shortNumber(stats.keyTotal))
                    .font(AKSFont.serif(21, bold: active))
                    .foregroundColor(active ? theme.accent2 : theme.ink.opacity(0.7))
                Text(stats.dayCount > 0 ? "\(stats.dayCount) 天" : "暂无")
                    .font(AKSFont.mono(8.5))
                    .foregroundColor(theme.inkSoft.opacity(0.75))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(active ? theme.accent2.opacity(0.08) : Color.clear)
            )
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(active ? theme.accent2 : Color.clear)
                    .frame(height: 1.5)
                    .padding(.horizontal, 14)
                    .offset(y: -1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(period.englishTitle) · 按键 \(stats.keyTotal) · 点击 \(stats.clickTotal) · \(stats.dayCount) 天")
    }
}

struct ACTitle: View {
    @Environment(\.aks) private var theme
    var text: String
    var meta: String

    var body: some View {
        HStack {
            Text(text)
                .font(AKSFont.sans(13, weight: .medium))
                .foregroundColor(theme.ink)
            Spacer()
            AKSMeta(text: meta)
        }
    }
}

/// 24 根柱子
struct ActivityBars: View {
    @Environment(\.aks) private var theme
    var values: [Int]
    var tint: Color

    var body: some View {
        let peak = max(values.max() ?? 0, 1)
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                VStack(spacing: 4) {
                    Capsule()
                        .fill(value == 0 ? theme.border.opacity(0.5) : tint.opacity(value == peak ? 1 : 0.62))
                        .frame(height: max(3, CGFloat(value) / CGFloat(peak) * 78))
                    if index % 6 == 0 {
                        Text("\(index)")
                            .font(AKSFont.mono(8))
                            .foregroundColor(theme.inkSoft.opacity(0.7))
                    } else {
                        Text(" ").font(AKSFont.mono(8))
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

// MARK: - 键盘页

struct KeyboardPage: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.aks) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                AKSPageHeader(
                    kicker: "Keyboard",
                    title: "每一颗键的磨损",
                    lede: "颜色越深按得越多。按住不放只算一次，自动重复不计。",
                    trailing: AnyView(
                        Picker("", selection: $state.layoutID) {
                            ForEach(KeyboardLayoutID.allCases) { id in
                                Text(id.shortName).tag(id)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 300)
                    )
                )

                AKSCard(padding: 20) {
                    VStack(alignment: .leading, spacing: 14) {
                        KeyboardHeatView(layout: state.layout, counts: state.today.keys)
                            .frame(height: state.layoutID == .ansiFull ? 250 : 236)
                        HeatScaleBar(info: .forKeys(state.today.keys))
                    }
                }

                HStack(alignment: .top, spacing: 18) {
                    AKSCard {
                        VStack(alignment: .leading, spacing: 12) {
                            ACTitle(text: "排行", meta: "Top 12")
                            KeyRankList(rows: state.topKeys, tint: theme.accent)
                        }
                    }
                    AKSCard {
                        VStack(alignment: .leading, spacing: 10) {
                            ACTitle(text: "计数口径", meta: "How")
                            Text("· 走 IOHIDManager 读物理按键，和输入法无关\n· 同一颗键按住只记 1 次\n· 只存「次数」，不存顺序、不存字符\n· 修饰键（⌘⌥⌃⇧）也会被统计")
                                .font(AKSFont.sans(11.5))
                                .foregroundColor(theme.inkSoft)
                                .lineSpacing(5)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(width: 320)
                }
            }
            .padding(26)
        }
    }
}

// MARK: - 触控板页

struct TrackpadPage: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.aks) private var theme
    @State private var showVideoSheet = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                AKSPageHeader(
                    kicker: "Trackpad",
                    title: "手指在板子上磨出的形状",
                    lede: "热力来自真实接触点（MultitouchSupport 逐帧读取），轨迹是降采样后的原始路径。",
                    trailing: AnyView(
                        HStack(spacing: 12) {
                            if state.isExportingVideo {
                                HStack(spacing: 7) {
                                    ProgressView(value: state.videoProgress)
                                        .progressViewStyle(.linear)
                                        .frame(width: 84)
                                    Text("渲染 \(Int(state.videoProgress * 100))%")
                                        .font(AKSFont.mono(10))
                                        .foregroundColor(theme.inkSoft)
                                }
                            } else if let note = state.trajectoryExportNote ?? state.videoExportNote {
                                Text(note)
                                    .font(AKSFont.sans(10.5))
                                    .foregroundColor(theme.inkSoft)
                                    .lineLimit(2)
                                    .frame(maxWidth: 190, alignment: .trailing)
                            }
                            TrajectoryExportMenu(showVideoSheet: $showVideoSheet)
                        }
                    )
                )

                HStack(alignment: .top, spacing: 18) {
                    AKSCard(padding: 18) {
                        VStack(spacing: 12) {
                            TrackpadHeatView(grid: state.today.padGrid,
                                             points: state.padTrajectory,
                                             progress: state.replayProgress,
                                             showTrail: state.showTrail)
                                .frame(height: 360)
                            HeatScaleBar(info: .forGrid(state.today.padGrid))
                            HStack(spacing: 12) {
                                Toggle("叠加轨迹", isOn: $state.showTrail)
                                    .toggleStyle(.switch)
                                    .controlSize(.mini)
                                Spacer()
                                Text(state.isReplaying ? "回放中…" : "轨迹 \(state.padTrajectory.count) 点")
                                    .font(AKSFont.mono(10.5))
                                    .foregroundColor(theme.inkSoft)
                                Button(state.isReplaying ? "停止" : "回放") {
                                    if state.isReplaying {
                                        state.stopReplay()
                                    } else {
                                        state.startReplay()
                                    }
                                }
                                .buttonStyle(AKSPrimaryButtonStyle(filled: false))
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 18) {
                        AKSCard {
                            VStack(alignment: .leading, spacing: 12) {
                                ACTitle(text: "今日", meta: "Stats")
                                AKSStatRow(label: "接触帧", value: AppState.shortNumber(state.today.padContacts))
                                AKSStatRow(label: "轨迹里程", value: String(format: "%.0f cm", state.padTravelCentimeters))
                                AKSStatRow(label: "峰值接触面积", value: String(format: "%.2f", state.today.padMaxContact))
                                AKSStatRow(label: "双指滚动", value: "\(state.today.clicks.padScroll)")
                                AKSStatRow(label: "轨迹文件", value: byteText(state.trajectoryBytes))
                            }
                        }
                        AKSCard {
                            VStack(alignment: .leading, spacing: 10) {
                                ACTitle(text: "识别到的设备", meta: "Devices")
                                if state.padDevices.isEmpty {
                                    Text("没找到触控设备")
                                        .font(AKSFont.sans(11.5))
                                        .foregroundColor(theme.inkSoft)
                                } else {
                                    ForEach(state.padDevices, id: \.locationID) { device in
                                        HStack(spacing: 8) {
                                            Circle()
                                                .fill(device.kind == .mouse ? theme.accent2 : theme.accent)
                                                .frame(width: 6, height: 6)
                                            Text(device.displayName)
                                                .font(AKSFont.sans(11.5))
                                                .foregroundColor(theme.ink)
                                                .lineLimit(1)
                                            Spacer()
                                            Text(kindText(device.kind))
                                                .font(AKSFont.mono(9.5))
                                                .foregroundColor(theme.inkSoft)
                                        }
                                    }
                                }
                                AKSHairline()
                                Text("Y 轴方向如果画反了，去设置里翻一下")
                                    .font(AKSFont.sans(10.5))
                                    .foregroundColor(theme.inkSoft.opacity(0.8))
                            }
                        }
                    }
                    .frame(width: 320)
                }
            }
            .padding(26)
        }
    
        .sheet(isPresented: $showVideoSheet) {
            TrajectoryVideoSheet(isPresented: $showVideoSheet)
        }
    }

    private func kindText(_ kind: MTDeviceInfo.Kind) -> String {
        switch kind {
        case .trackpad: return "trackpad"
        case .builtInTrackpad: return "built-in"
        case .mouse: return "mouse"
        case .unknown: return "unknown"
        }
    }

    private func byteText(_ bytes: Int) -> String {
        AppState.byteText(bytes)
    }
}

/// 「导出轨迹」下拉：今天 / 最近 7 天 / 全部历史
struct TrajectoryExportMenu: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.aks) private var theme

    @Binding var showVideoSheet: Bool

    var body: some View {
        Menu {
            Section("视频") {
                Button("导出回放视频…") { showVideoSheet = true }
                    .disabled(state.videoDays.isEmpty)
            }
            Section("CSV（0–1 归一化坐标）") {
                ForEach(TrajectoryExport.Scope.allCases) { scope in
                    Button(scope.title) { state.exportTrajectory(scope) }
                }
            }
        } label: {
            HStack(spacing: 5) {
                if state.isExportingTrajectory {
                    ProgressView().controlSize(.small).scaleEffect(0.65).frame(width: 12, height: 12)
                } else {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 10.5, weight: .semibold))
                }
                Text(state.isExportingTrajectory ? "导出中…" : "导出轨迹")
                    .font(AKSFont.sans(12.5, weight: .medium))
            }
            .foregroundColor(theme.accent)
            .padding(.horizontal, 11)
            .padding(.vertical, 5.5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(theme.accent.opacity(theme.isDark ? 0.18 : 0.06))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(theme.accent.opacity(theme.isDark ? 0.35 : 0.22), lineWidth: 1))
            )
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(state.isExportingTrajectory || state.isExportingVideo)
        .help("导出回放视频，或把原始轨迹导成 CSV")
    }
}

// MARK: - 鼠标页

struct MousePage: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.aks) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                AKSPageHeader(
                    kicker: "Mouse",
                    title: "鼠标也不只是点了多少下",
                    lede: "Magic Mouse 整块上表面都是电容面，接触点同样能读到。"
                )

                HStack(alignment: .top, spacing: 18) {
                    AKSCard(padding: 18) {
                        VStack(spacing: 10) {
                            MouseHeatView(grid: state.today.mouseGrid,
                                          leftClicks: state.today.clicks.left,
                                          rightClicks: state.today.clicks.right)
                                .frame(height: 340)
                            HeatScaleBar(info: .forGrid(state.today.mouseGrid))
                            HStack(spacing: 22) {
                                Label("左键 \(state.today.clicks.left)", systemImage: "cursorarrow.click")
                                Label("右键 \(state.today.clicks.right)", systemImage: "cursorarrow.click.2")
                                Label("滚轮 \(state.today.clicks.scroll)", systemImage: "arrow.up.arrow.down")
                            }
                            .font(AKSFont.mono(10.5))
                            .foregroundColor(theme.inkSoft)
                            .labelStyle(.titleAndIcon)
                        }
                    }
                    VStack(alignment: .leading, spacing: 18) {
                        AKSCard {
                            VStack(alignment: .leading, spacing: 12) {
                                ACTitle(text: "点击", meta: "Clicks")
                                AKSStatRow(label: "左键", value: "\(state.today.clicks.left)")
                                AKSStatRow(label: "右键", value: "\(state.today.clicks.right)")
                                AKSStatRow(label: "中键", value: "\(state.today.clicks.middle)")
                                AKSStatRow(label: "滚轮", value: "\(state.today.clicks.scroll)")
                            }
                        }
                        AKSCard {
                            VStack(alignment: .leading, spacing: 12) {
                                ACTitle(text: "表面", meta: "Surface")
                                AKSStatRow(label: "接触帧", value: AppState.shortNumber(state.today.mouseContacts))
                                AKSStatRow(label: "滑动里程", value: String(format: "%.0f cm", state.today.mouseTravel * 20))
                                if !state.storedDeviceNames.mice.isEmpty {
                                    AKSHairline()
                                    ForEach(state.storedDeviceNames.mice.prefix(3), id: \.self) { name in
                                        Text(name)
                                            .font(AKSFont.mono(10.5))
                                            .foregroundColor(theme.inkSoft)
                                    }
                                }
                            }
                        }
                    }
                    .frame(width: 320)
                }
            }
            .padding(26)
        }
    }
}

// MARK: - 回放视频设置

/// 导出前的小面板：选哪一天、放多长。
/// 默认「跟回放一致」—— 就是 App 里点「回放」看到的那个节奏，不改变观感。
struct TrajectoryVideoSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.aks) private var theme
    @Binding var isPresented: Bool

    @State private var day = ""
    @State private var durationTag = "auto"

    private let options: [(tag: String, title: String, value: Double?)] = [
        ("auto", "跟回放一致（自动）", nil),
        ("15", "15 秒", 15),
        ("30", "30 秒", 30),
        ("60", "60 秒", 60)
    ]

    private var days: [String] {
        let list = state.videoDays
        return list.isEmpty ? [DayKey.of(Date())] : list
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            VStack(alignment: .leading, spacing: 6) {
                Text("导出回放视频")
                    .font(AKSFont.serif(19))
                    .foregroundColor(theme.ink)
                Text("把触控板页的回放录成 MP4（1600 × 1150），画面里只有那块触控板。")
                    .font(AKSFont.sans(11.5))
                    .foregroundColor(theme.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }

            AKSHairline()

            HStack {
                Text("哪一天").font(AKSFont.sans(12)).foregroundColor(theme.inkSoft)
                Spacer()
                Picker("", selection: $day) {
                    ForEach(days, id: \.self) { value in
                        Text(value).tag(value)
                    }
                }
                .labelsHidden()
                .frame(width: 176)
            }

            HStack {
                Text("放多长").font(AKSFont.sans(12)).foregroundColor(theme.inkSoft)
                Spacer()
                Picker("", selection: $durationTag) {
                    ForEach(options, id: \.tag) { option in
                        Text(option.title).tag(option.tag)
                    }
                }
                .labelsHidden()
                .frame(width: 176)
            }

            Text("自动时长 = 这段时间的跨度 ÷ 8，最短 1.2 秒、最长 12 秒 —— 和点「回放」时看到的节奏完全一致。")
                .font(AKSFont.sans(10))
                .foregroundColor(theme.inkSoft.opacity(0.72))
                .lineSpacing(2.5)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Spacer()
                Button("取消") { isPresented = false }
                    .buttonStyle(AKSPrimaryButtonStyle(filled: false))
                Button("导出…") {
                    let value = options.first { $0.tag == durationTag }?.value
                    let target = day
                    isPresented = false
                    // 等 sheet 收完再弹保存面板，否则面板会被 sheet 挡住
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        state.exportVideo(day: target, duration: value)
                    }
                }
                .buttonStyle(AKSPrimaryButtonStyle())
                .disabled(day.isEmpty || state.isExportingVideo)
            }
        }
        .padding(22)
        .frame(width: 420)
        .background(theme.surface)
        .onAppear {
            if day.isEmpty { day = days.first ?? DayKey.of(Date()) }
        }
    }
}

/// 只给离屏快照用：把上面那个面板单独拎出来，带主题渲一张。
public struct TrajectoryVideoSheetPreview: View {
    @Environment(\.colorScheme) private var scheme

    public init() {}

    public var body: some View {
        let theme = AKSScheme.of(scheme)
        TrajectoryVideoSheet(isPresented: .constant(true))
            .environment(\.aks, theme)
            .padding(28)
            .background(theme.bg)
    }
}
