import SwiftUI
import AKeyKit

// MARK: - 检测模型
//
// 检测页的语义是「键盘有没有哑键」：手扫过一遍，按到的键就留下高亮，
// 亮满即通过。所以这里有两套键集合：
//   · testedKeys —— 这次测试里触发过的键，只增不减，直到点「重置测试」
//   · pressedKeys —— 此刻正按着的键，只用来画更实的强调
//
// 性能上做了两件事（以前快速扫键会卡死）：
//   1. 状态全写在内部影子结构里，UI 只订阅一个 snapshot，节流到 60Hz 才发一次。
//   2. 键盘交给 Canvas 一次画完，不再为每个键帽建 View / tooltip / 动画。

@MainActor
public final class TesterStore: ObservableObject {
    public struct Row: Identifiable {
        public let id = UUID()
        public var label: String
        public var gap: Double?       // 距同一颗键上次按下的间隔（秒）
        public var hold: Double?      // 按住时长（秒）
        public var chatter: Bool
        public var at: Date
    }

    /// 一次发布的数据快照
    public struct Snapshot {
        public var pressedKeys: Set<UInt16> = []
        public var testedKeys: Set<UInt16> = []
        public var pressedButtons: Set<Int> = []
        public var rows: [Row] = []
        public var keyCount = 0
        public var chatterCount = 0
        public var mouseCount = 0
        public var mouseChatter = 0
        public var doubleClicks = 0
        public var scrollCount = 0
        public var fastestGap: Double?
        public var averageHold: Double?
        public var lastLabel = "—"
        public var lastDevice = ""
        public var buttonCounts: [Int: Int] = [:]
    }

    /// 同一颗键抬起后 50ms 内又按下 → 判为连键
    static let chatterWindow: Double = 0.05
    /// 鼠标按钮同一窗口更短
    static let buttonChatterWindow: Double = 0.04
    /// UI 刷新上限（约 33Hz）。事件本身不丢，只是合并成更少的重绘。
    /// 实测整页光栅化 ~8ms，60Hz 会把主线程吃满；键帽高亮 33Hz 眼睛看不出来。
    static let publishInterval: UInt64 = 30_000_000

    @Published public private(set) var snapshot = Snapshot()

    // 对外只读便捷属性（不单独触发刷新，跟着 snapshot 一起走）
    public var pressedKeys: Set<UInt16> { snapshot.pressedKeys }
    public var testedKeys: Set<UInt16> { snapshot.testedKeys }
    public var pressedButtons: Set<Int> { snapshot.pressedButtons }
    public var rows: [Row] { snapshot.rows }
    public var keyCount: Int { snapshot.keyCount }
    public var chatterCount: Int { snapshot.chatterCount }
    public var mouseCount: Int { snapshot.mouseCount }
    public var mouseChatter: Int { snapshot.mouseChatter }
    public var doubleClicks: Int { snapshot.doubleClicks }
    public var scrollCount: Int { snapshot.scrollCount }
    public var fastestGap: Double? { snapshot.fastestGap }
    public var averageHold: Double? { snapshot.averageHold }
    public var lastLabel: String { snapshot.lastLabel }
    public var lastDevice: String { snapshot.lastDevice }
    public var buttonCounts: [Int: Int] { snapshot.buttonCounts }

    private var s = Snapshot()
    private var publishPending = false

    private var downAt: [UInt16: Date] = [:]
    private var lastDownAt: [UInt16: Date] = [:]
    private var lastUpAt: [UInt16: Date] = [:]
    private var holds: [Double] = []
    private var labelForCode: [UInt16: String] = [:]
    private var lastButtonDownAt: [Int: Date] = [:]

    public init() {}

    public func reset() {
        s = Snapshot()
        downAt.removeAll(); lastDownAt.removeAll(); lastUpAt.removeAll()
        holds.removeAll(); labelForCode.removeAll(); lastButtonDownAt.removeAll()
        flushNow()
    }

    /// 立刻把影子状态推给 UI（重置、离屏渲染造数据时用，绕过节流）
    public func flushNow() {
        publishPending = false
        snapshot = s
    }

    // MARK: 事件

    public func handle(_ event: LiveInputEvent, layout: KeyboardLayout) {
        let now = event.at
        switch event.kind {
        case .keyDown:
            let label = layout.label(event.code) ?? String(format: "0x%02X", event.code)
            let gap = lastDownAt[event.code].map { now.timeIntervalSince($0) }
            let chatter = lastUpAt[event.code].map { now.timeIntervalSince($0) < Self.chatterWindow } ?? false

            downAt[event.code] = now
            lastDownAt[event.code] = now
            labelForCode[event.code] = label
            s.pressedKeys.insert(event.code)
            s.testedKeys.insert(event.code)     // ★ 触发过就留下高亮，不再随抬手消失
            s.keyCount += 1
            s.lastLabel = label
            s.lastDevice = event.device
            if chatter { s.chatterCount += 1 }
            if let gap, gap > 0 {
                s.fastestGap = min(s.fastestGap ?? gap, gap)
            }

            s.rows.insert(Row(label: label, gap: gap, hold: nil, chatter: chatter, at: now), at: 0)
            if s.rows.count > 14 { s.rows.removeLast() }

        case .keyUp:
            s.pressedKeys.remove(event.code)
            lastUpAt[event.code] = now
            if let start = downAt[event.code] {
                let hold = now.timeIntervalSince(start)
                holds.append(hold)
                if holds.count > 40 { holds.removeFirst() }
                s.averageHold = holds.reduce(0, +) / Double(holds.count)
                // 补上这一行的按住时长（最近一条还没有 hold 的同名行）
                let label = labelForCode[event.code]
                if let index = s.rows.firstIndex(where: { $0.hold == nil && $0.label == label }) {
                    s.rows[index].hold = hold
                }
                downAt.removeValue(forKey: event.code)
            }

        case .mouseDown:
            let button = Int(event.code)
            if let last = lastButtonDownAt[button] {
                let gap = now.timeIntervalSince(last)
                if gap < Self.buttonChatterWindow { s.mouseChatter += 1 }
                else if gap < 0.35 { s.doubleClicks += 1 }
            }
            lastButtonDownAt[button] = now
            s.pressedButtons.insert(button)
            s.mouseCount += 1
            s.buttonCounts[button, default: 0] += 1

        case .mouseUp:
            s.pressedButtons.remove(Int(event.code))

        case .duplicateKey:
            // 系统把一次按下报了两次：统计里已经去掉，这里只记成异常
            let label = layout.label(event.code) ?? String(format: "0x%02X", event.code)
            s.chatterCount += 1
            s.testedKeys.insert(event.code)     // 它确实被触发了，该亮
            s.rows.insert(Row(label: label, gap: 0, hold: nil, chatter: true, at: now), at: 0)
            if s.rows.count > 14 { s.rows.removeLast() }
        }

        schedulePublish()
    }

    public func noteScroll(pad: Bool) {
        s.scrollCount += 1
        _ = pad
        schedulePublish()
    }

    // MARK: 节流发布

    private func schedulePublish() {
        guard !publishPending else { return }
        publishPending = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: TesterStore.publishInterval)
            guard let self, self.publishPending else { return }
            self.publishPending = false
            self.snapshot = self.s
        }
    }
}

// MARK: - 检测页

/// 有些键在 IOHID 层根本拿不到事件：`fn` 由键盘固件 / 系统直接处理（NSEvent 的
/// flagsChanged 里能看到，但物理 usage 不走 0x07 键盘页）。把它们算进覆盖率分母，
/// 「亮满即通过」就永远达不成，反而误报哑键 —— 所以单独列出来，不参与判定。
/// 万一某块键盘真的上报了，它也照样会亮。
enum TesterKeys {
    static let unmeasurable: Set<UInt16> = [63]   // kVK_Function
}

struct TesterView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        // 拆一层：让键盘的重绘只落在 TesterContent 里，
        // 不把整个侧栏 + 页面结构都带着重算。
        TesterContent(tester: state.tester)
    }
}

private struct TesterContent: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.aks) private var theme
    @ObservedObject var tester: TesterStore

    private var layout: KeyboardLayout { state.layout }

    /// 当前配列里可测的键（去重，剔除 fn 这类系统层按键）
    private var measurableCodes: Set<UInt16> {
        Set(layout.keys.map(\.code)).subtracting(TesterKeys.unmeasurable)
    }

    private var coveredCount: Int {
        measurableCodes.intersection(tester.testedKeys).count
    }

    private var missingLabels: [String] {
        let tested = tester.testedKeys
        var seen: Set<UInt16> = []
        var list: [String] = []
        for key in layout.keys where measurableCodes.contains(key.code) && !tested.contains(key.code) {
            if seen.insert(key.code).inserted { list.append(key.label) }
        }
        return list
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                AKSPageHeader(
                    kicker: "Diagnostics",
                    title: "按下去，看它诚不诚实",
                    lede: "手扫一遍键盘：按过的键会一直亮着，亮满就说明没有哑键。这里不写进任何统计。",
                    trailing: AnyView(
                        Button("重置测试") { tester.reset() }
                            .buttonStyle(AKSPrimaryButtonStyle(filled: false))
                    )
                )

                AKSCard {
                    HStack(alignment: .top, spacing: 26) {
                        AKSKPI(value: "\(coveredCount)/\(measurableCodes.count)", label: "已覆盖按键",
                               hint: missingLabels.isEmpty ? "全部亮满" : "还剩 \(missingLabels.count) 颗没按",
                               tint: missingLabels.isEmpty ? theme.accent : theme.ink)
                        AKSKPI(value: "\(tester.keyCount)", label: "按下次数", hint: "含修饰键与重复")
                        AKSKPI(value: "\(tester.chatterCount)", label: "连键次数",
                               hint: tester.chatterCount == 0 ? "未发现异常" : "50ms 内重复触发",
                               tint: tester.chatterCount == 0 ? theme.accent : theme.accent2)
                        AKSKPI(value: ms(tester.averageHold), label: "平均按住", hint: "按下到抬起")
                        AKSKPI(value: ms(tester.fastestGap), label: "最短间隔", hint: "同一颗键两次")
                    }
                }

                HStack(alignment: .top, spacing: 18) {
                    AKSCard(padding: 20) {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 4) {
                                    AKSMeta(text: "此刻按着", color: theme.accent2)
                                    Text(tester.pressedKeys.isEmpty ? "—" : tester.lastLabel)
                                        .font(AKSFont.serif(30))
                                        .foregroundColor(theme.ink)
                                }
                                Spacer()
                                if !tester.lastDevice.isEmpty {
                                    Text(tester.lastDevice)
                                        .font(AKSFont.mono(9.5))
                                        .foregroundColor(theme.inkSoft)
                                        .lineLimit(1)
                                }
                            }
                            AKSHairline()

                            TesterKeyboardView(layout: layout,
                                               tested: tester.testedKeys,
                                               pressed: tester.pressedKeys)
                                .frame(height: layout.id == .ansiFull ? 230 : 216)

                            HStack(spacing: 10) {
                                AKSBar(fraction: measurableCodes.isEmpty ? 0 : Double(coveredCount) / Double(measurableCodes.count),
                                       tint: missingLabels.isEmpty ? theme.accent : theme.accent2,
                                       height: 4)
                                Text(missingLabels.isEmpty ? "全部通过" : "还剩 \(missingLabels.count) 颗")
                                    .font(AKSFont.mono(10))
                                    .foregroundColor(theme.inkSoft)
                            }

                            Text(missingLabels.isEmpty
                                 ? "每颗键都被读到过一次，没有哑键。"
                                 : "还没按到：\(missingLabels.prefix(18).joined(separator: " "))" +
                                   (missingLabels.count > 18 ? " …" : ""))
                                .font(AKSFont.sans(10.5))
                                .foregroundColor(theme.inkSoft)
                                .lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true)

                            Text("虚线键（fn）由键盘固件直接处理，系统层收不到，不参与判定。")
                                .font(AKSFont.sans(10))
                                .foregroundColor(theme.inkSoft.opacity(0.8))
                        }
                    }

                    VStack(alignment: .leading, spacing: 18) {
                        AKSCard {
                            VStack(alignment: .leading, spacing: 10) {
                                ACTitle(text: "最近按键", meta: "Last 14")
                                if tester.rows.isEmpty {
                                    Text("随便敲几个键")
                                        .font(AKSFont.sans(11.5))
                                        .foregroundColor(theme.inkSoft)
                                        .padding(.vertical, 8)
                                } else {
                                    HStack {
                                        Text("键").frame(width: 58, alignment: .leading)
                                        Text("间隔").frame(width: 62, alignment: .trailing)
                                        Text("按住").frame(width: 62, alignment: .trailing)
                                        Spacer()
                                        Text("判定").frame(width: 52, alignment: .trailing)
                                    }
                                    .font(AKSFont.sans(9.5, weight: .medium))
                                    .foregroundColor(theme.inkSoft)
                                    AKSHairline()
                                    ForEach(tester.rows.prefix(9)) { row in
                                        HStack {
                                            Text(row.label)
                                                .font(AKSFont.mono(11, weight: .medium))
                                                .frame(width: 58, alignment: .leading)
                                                .lineLimit(1)
                                            Text(ms(row.gap))
                                                .font(AKSFont.mono(10.5))
                                                .frame(width: 62, alignment: .trailing)
                                            Text(ms(row.hold))
                                                .font(AKSFont.mono(10.5))
                                                .frame(width: 62, alignment: .trailing)
                                            Spacer()
                                            Text(row.chatter ? "连键" : "正常")
                                                .font(AKSFont.sans(10, weight: row.chatter ? .medium : .regular))
                                                .foregroundColor(row.chatter ? theme.accent2 : theme.inkSoft)
                                                .frame(width: 52, alignment: .trailing)
                                        }
                                        .foregroundColor(theme.ink)
                                        .padding(.vertical, 4)
                                    }
                                }
                            }
                        }

                        AKSCard {
                            VStack(alignment: .leading, spacing: 10) {
                                ACTitle(text: "怎么算连键", meta: "How")
                                Text("· 同一颗键抬起后 50ms 内又自己按下\n· 机械轴触点氧化、薄膜老化常见\n· 鼠标按键用 40ms 判定\n· 偶发一两次多半是手快，反复出现才值得换键")
                                    .font(AKSFont.sans(11))
                                    .foregroundColor(theme.inkSoft)
                                    .lineSpacing(5)
                                    .fixedSize(horizontal: false, vertical: true)
                                AKSHairline()
                                Text("系统重复上报已挡掉 \(state.dedupedKeyEvents) 次" +
                                     (state.unmappedKeyCount > 0 ? " · 未识别键码 \(state.unmappedKeyCount) 次" : ""))
                                    .font(AKSFont.mono(10))
                                    .foregroundColor(theme.inkSoft.opacity(0.85))
                            }
                        }
                    }
                    .frame(width: 330)
                }

                AKSCard(padding: 20) {
                    VStack(alignment: .leading, spacing: 14) {
                        ACTitle(text: "鼠标按键", meta: "Mouse")
                        HStack(spacing: 12) {
                            ButtonPill(title: "左键", active: tester.pressedButtons.contains(0),
                                       count: tester.buttonCounts[0] ?? 0)
                            ButtonPill(title: "右键", active: tester.pressedButtons.contains(1),
                                       count: tester.buttonCounts[1] ?? 0)
                            ButtonPill(title: "中键", active: tester.pressedButtons.contains(2),
                                       count: tester.buttonCounts[2] ?? 0)
                            Spacer()
                        }
                        AKSHairline()
                        HStack(spacing: 26) {
                            AKSKPI(value: "\(tester.mouseCount)", label: "按下次数")
                            AKSKPI(value: "\(tester.doubleClicks)", label: "双击", hint: "350ms 内两下")
                            AKSKPI(value: "\(tester.mouseChatter)", label: "连点",
                                   tint: tester.mouseChatter == 0 ? theme.accent : theme.accent2)
                            AKSKPI(value: "\(state.today.clicks.scroll)", label: "滚轮", hint: "鼠标滚轮")
                            AKSKPI(value: "\(state.today.clicks.padScroll)", label: "触控滚动",
                                   hint: "触控板双指", tint: theme.accent2)
                        }
                    }
                }
            }
            .padding(26)
        }
    }

    private func ms(_ seconds: Double?) -> String {
        guard let seconds else { return "—" }
        return String(format: "%.0f ms", seconds * 1000)
    }
}

// MARK: - Canvas 键盘（检测页专用）//
// 一次画完，不建 View、不挂 tooltip、不做逐键动画 —— 快速扫键时才不会把主线程压住。
// 三种状态：没按过（浅底细边）/ 按过（赭石淡填充 + 明确描边）/ 正按着（实心）。

struct TesterKeyboardView: View {
    @Environment(\.aks) private var theme

    var layout: KeyboardLayout
    var tested: Set<UInt16>
    var pressed: Set<UInt16>

    var body: some View {
        Canvas { context, size in
            let unitW = size.width / layout.widthUnits
            let unitH = size.height / max(layout.heightUnits, 0.001)
            let unit = min(unitW, unitH)
            let ox = (size.width - unit * layout.widthUnits) / 2
            let oy = (size.height - unit * layout.heightUnits) / 2
            let radius = max(2, unit * 0.14)

            for key in layout.keys {
                let rect = CGRect(x: ox + key.x * unit + 0.5,
                                  y: oy + key.y * unit + 0.5,
                                  width: key.w * unit - 1,
                                  height: key.h * unit - 1)
                let path = Path(roundedRect: rect, cornerRadius: radius, style: .continuous)
                let isDown = pressed.contains(key.code)
                let isTested = tested.contains(key.code)
                let isUnmeasurable = TesterKeys.unmeasurable.contains(key.code) && !isTested

                let fill: Color = isDown ? theme.accent2
                    : (isTested ? theme.accent2.opacity(0.16) : theme.bg)
                let stroke: Color = isDown ? theme.accent2
                    : (isTested ? theme.accent2.opacity(0.8) : theme.border.opacity(0.9))
                context.fill(path, with: .color(fill))
                if isUnmeasurable {
                    // 虚线 = 这颗键系统层收不到，别拿它当哑键
                    context.stroke(path, with: .color(theme.border.opacity(0.85)),
                                   style: StrokeStyle(lineWidth: 0.8, dash: [3, 2.5]))
                } else {
                    context.stroke(path, with: .color(stroke),
                                   lineWidth: isDown ? 1.6 : (isTested ? 1.0 : 0.6))
                }

                guard unit > 12 else { continue }
                var fontSize = max(5.5, min(unit * 0.30, key.w > 1.2 ? 10.5 : 9.5))
                // Canvas 里的 Text 不会自动缩排，长标签自己算一遍宽度
                let room = rect.width - 3
                let rough = CGFloat(key.label.count) * fontSize * 0.62
                if rough > room { fontSize = max(5, fontSize * (room / rough)) }

                let color: Color = isDown ? .white : (isTested ? theme.accent2 : theme.inkSoft)
                let text = Text(key.label)
                    .font(AKSFont.sans(fontSize, weight: isTested ? .medium : .regular))
                    .foregroundColor(color)
                context.draw(text, at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center)
            }
        }
    }
}

struct ButtonPill: View {
    @Environment(\.aks) private var theme
    var title: String
    var active: Bool
    var count: Int

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(active ? theme.accent2 : theme.border)
                .frame(width: 6, height: 6)
            Text(title)
                .font(AKSFont.sans(11.5, weight: active ? .medium : .regular))
            Text("\(count)")
                .font(AKSFont.mono(10))
                .foregroundColor(theme.inkSoft)
        }
        .foregroundColor(active ? theme.ink : theme.inkSoft)
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(active ? theme.accent2.opacity(0.12) : theme.bg)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(active ? theme.accent2 : theme.border, lineWidth: active ? 1.2 : 0.7)
                )
        )
    }
}
