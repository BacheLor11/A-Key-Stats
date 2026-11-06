import SwiftUI
import AppKit

// MARK: - 设计令牌（与 askb.app / A-Kit 同一套）

extension NSColor {
    convenience init(srgbHex: UInt32, alpha: CGFloat = 1) {
        let r = CGFloat((srgbHex >> 16) & 0xFF) / 255
        let g = CGFloat((srgbHex >> 8) & 0xFF) / 255
        let b = CGFloat(srgbHex & 0xFF) / 255
        self.init(srgbRed: r, green: g, blue: b, alpha: alpha)
    }
}

struct AKSScheme {
    var bg: Color
    var surface: Color
    var ink: Color
    var inkSoft: Color
    var accent: Color
    var accent2: Color
    var border: Color
    var shadow: Color
    var isDark: Bool = false

    static let light = AKSScheme(
        bg: Color(nsColor: NSColor(srgbHex: 0xFBFAF7)),
        surface: Color.white,
        ink: Color(nsColor: NSColor(srgbHex: 0x1A1A1A)),
        inkSoft: Color(nsColor: NSColor(srgbHex: 0x5B574E)),
        accent: Color(nsColor: NSColor(srgbHex: 0x34557A)),
        accent2: Color(nsColor: NSColor(srgbHex: 0xB5562E)),
        border: Color(nsColor: NSColor(srgbHex: 0xE7E2D8)),
        shadow: Color.black.opacity(0.07)
    )

    static let dark = AKSScheme(
        bg: Color(nsColor: NSColor(srgbHex: 0x15171A)),
        surface: Color(nsColor: NSColor(srgbHex: 0x202326)),
        ink: Color(nsColor: NSColor(srgbHex: 0xECE9E2)),
        inkSoft: Color(nsColor: NSColor(srgbHex: 0xA8A29A)),
        accent: Color(nsColor: NSColor(srgbHex: 0x7BA3CC)),
        accent2: Color(nsColor: NSColor(srgbHex: 0xD98A5E)),
        border: Color(nsColor: NSColor(srgbHex: 0x2E3236)),
        shadow: Color.black.opacity(0.45),
        isDark: true
    )

    static func of(_ scheme: ColorScheme) -> AKSScheme {
        scheme == .dark ? .dark : .light
    }

    /// 热力配色：米白 → 墨蓝 → 赭石
    func heat(_ fraction: Double) -> Color {
        let f = min(max(fraction, 0), 1)
        // 深色模式下起点用卡片底色，不然一片发白的键帽很刺眼
        let cold = isDark ? (r: 0.125, g: 0.137, b: 0.149)   // #202326
                          : (r: 0.949, g: 0.937, b: 0.910)   // #F2EFE8
        let mid = (r: 0.204, g: 0.333, b: 0.478)    // #34557A
        let hot = (r: 0.710, g: 0.337, b: 0.180)    // #B5562E
        let a: (r: Double, g: Double, b: Double)
        let b: (r: Double, g: Double, b: Double)
        let t: Double
        if f < 0.55 {
            a = cold; b = mid; t = f / 0.55
        } else {
            a = mid; b = hot; t = (f - 0.55) / 0.45
        }
        let e = pow(t, 0.85)
        return Color(.sRGB,
                     red: a.r + (b.r - a.r) * e,
                     green: a.g + (b.g - a.g) * e,
                     blue: a.b + (b.b - a.b) * e)
    }
}

private struct AKSSchemeKey: EnvironmentKey {
    static let defaultValue = AKSScheme.light
}

extension EnvironmentValues {
    var aks: AKSScheme {
        get { self[AKSSchemeKey.self] }
        set { self[AKSSchemeKey.self] = newValue }
    }
}

// MARK: - 字体

enum AKSFont {
    static func serif(_ size: CGFloat, bold: Bool = true) -> Font {
        .custom("Songti SC", size: size).weight(bold ? .bold : .regular)
    }
    static func sans(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - 通用组件

struct AKSCard<Content: View>: View {
    @Environment(\.aks) private var theme
    var padding: CGFloat = 18
    var radius: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(theme.border, lineWidth: 0.8)
            )
    }
}

/// 博客 `.card .meta` 那种小号全大写标签
struct AKSMeta: View {
    @Environment(\.aks) private var theme
    var text: String
    var color: Color? = nil

    var body: some View {
        Text(text.uppercased())
            .font(AKSFont.sans(10, weight: .medium))
            .tracking(0.9)
            .foregroundColor(color ?? theme.accent)
    }
}

struct AKSHairline: View {
    @Environment(\.aks) private var theme
    var body: some View {
        Rectangle().fill(theme.border).frame(height: 1)
    }
}

struct AKSTag: View {
    @Environment(\.aks) private var theme
    var text: String
    var tint: Color? = nil

    var body: some View {
        Text(text)
            .font(AKSFont.sans(10.5, weight: .medium))
            .foregroundColor(tint ?? theme.inkSoft)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(theme.bg)
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(theme.border, lineWidth: 0.5))
            )
    }
}

struct AKSPrimaryButtonStyle: ButtonStyle {
    @Environment(\.aks) private var theme
    var filled = true
    var danger = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AKSFont.sans(12.5, weight: .medium))
            .foregroundColor(filled ? theme.bg : (danger ? theme.accent2 : theme.accent))
            .padding(.horizontal, 13)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(filled ? (danger ? theme.accent2 : theme.ink) : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(filled ? Color.clear : theme.border, lineWidth: 1)
                    )
            )
            .opacity(configuration.isPressed ? 0.72 : 1)
            .contentShape(Rectangle())
    }
}

// MARK: - 数据小件

struct AKSBar: View {
    @Environment(\.aks) private var theme
    var fraction: Double
    var tint: Color
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(theme.border.opacity(0.75))
                Capsule()
                    .fill(tint)
                    .frame(width: max(0, min(geo.size.width, geo.size.width * fraction)))
            }
        }
        .frame(height: height)
    }
}

struct AKSStatRow: View {
    @Environment(\.aks) private var theme
    var label: String
    var value: String
    var mono = true

    var body: some View {
        HStack {
            Text(label)
                .font(AKSFont.sans(12))
                .foregroundColor(theme.inkSoft)
            Spacer(minLength: 8)
            Text(value)
                .font(mono ? AKSFont.mono(12, weight: .medium) : AKSFont.sans(12, weight: .medium))
                .foregroundColor(theme.ink)
        }
    }
}

/// 大号数字 + 一句说明
struct AKSKPI: View {
    @Environment(\.aks) private var theme
    var value: String
    var label: String
    var hint: String? = nil
    var tint: Color? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(AKSFont.mono(26, weight: .semibold))
                .foregroundColor(tint ?? theme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(AKSFont.sans(11.5))
                .foregroundColor(theme.inkSoft)
            if let hint {
                Text(hint)
                    .font(AKSFont.sans(10))
                    .foregroundColor(theme.inkSoft.opacity(0.7))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AKSPageHeader: View {
    @Environment(\.aks) private var theme
    var kicker: String
    var title: String
    var lede: String
    var trailing: AnyView? = nil

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 7) {
                AKSMeta(text: kicker)
                Text(title)
                    .font(AKSFont.serif(30))
                    .foregroundColor(theme.ink)
                Text(lede)
                    .font(AKSFont.sans(12.5))
                    .foregroundColor(theme.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if let trailing { trailing }
        }
    }
}

struct AKSEmptyState: View {
    @Environment(\.aks) private var theme
    var symbol: String
    var title: String
    var message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .light))
                .foregroundColor(theme.inkSoft.opacity(0.55))
            Text(title)
                .font(AKSFont.sans(13, weight: .medium))
                .foregroundColor(theme.ink)
            Text(message)
                .font(AKSFont.sans(11.5))
                .foregroundColor(theme.inkSoft)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
    }
}

public enum AKSWindowColor {
    public static var dynamic: NSColor {
        NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(srgbHex: dark ? 0x15171A : 0xFBFAF7)
        }
    }
}

public enum AKSBundle {
    /// 版本号。
    ///
    /// 不能只读 `Bundle.main` —— 作为 A-Kit 插件运行时 `main` 是 A-Kit，
    /// 这里会显示成 A-Kit 的版本号（用户会以为工具版本错了）。
    /// 先按 dylib 反查出自己所在的 .app / .akitplugin，再退到 Bundle.main。
    public static var version: String {
        if let v = ownBundleValue("CFBundleShortVersionString") { return v }
        return (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"
    }

    private static func ownBundleValue(_ key: String) -> String? {
        var info = Dl_info()
        guard dladdr(#dsohandle, &info) != 0, let c = info.dli_fname else { return nil }
        var url = URL(fileURLWithPath: String(cString: c))
        for _ in 0..<8 {
            let ext = url.pathExtension
            if ext == "app" || ext == "akitplugin" {
                let plist = url.appendingPathComponent("Contents/Info.plist")
                if let d = try? Data(contentsOf: plist),
                   let dict = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any],
                   let v = dict[key] as? String {
                    return v
                }
                return nil
            }
            url = url.deletingLastPathComponent()
        }
        return nil
    }
}
