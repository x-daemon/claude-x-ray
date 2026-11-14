import AppKit
import SwiftUI
import XRayCore

/// Visual theme. S2A is the brand theme and the default; System keeps the neutral palette.
enum AppTheme: String, CaseIterable, Identifiable {
    case s2a, system

    static let storageKey = "appTheme"

    var id: Self { self }

    var title: String {
        switch self {
        case .s2a: return "S2A"
        case .system: return "Системная"
        }
    }

    var subtitle: String {
        switch self {
        case .s2a: return "Фирменные цвета S2A: фиолетовый, циан и глубокий ночной фон"
        case .system: return "Нейтральная палитра и системный акцент macOS"
        }
    }

    static var current: AppTheme {
        AppTheme(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .s2a
    }
}

/// Light / dark preference, independent of the theme.
enum AppAppearance: String, CaseIterable, Identifiable {
    case auto, light, dark

    static let storageKey = "appAppearance"

    var id: Self { self }

    var title: String {
        switch self {
        case .auto: return "Как в системе"
        case .light: return "Светлая"
        case .dark: return "Тёмная"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .auto: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// Chart, surface and status colors for the active theme.
///
/// Categorical slots follow a fixed, colorblind-checked order with separate light
/// and dark steps. The S2A order (violet, mint, amber, cyan, coral, blue, magenta,
/// lime) was chosen by enumerating all orders and validating each: worst adjacent
/// CVD ΔE 8.7 light / 8.8 dark (target 8), normal-vision ΔE 23.8 / 20.0 (floor 15).
/// Light mint, amber, cyan and lime sit below 3:1 on the light surface, so they are
/// always paired with labels, legends or tables. Status colors are never themed.
enum Palette {
    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(rgb: isDark ? dark : light)
        })
    }

    static var theme: AppTheme { AppTheme.current }
    private static var isS2A: Bool { theme == .s2a }

    // MARK: Categorical

    private static let neutralSeries: [Color] = [
        dynamic(light: 0x2A78D6, dark: 0x3987E5), // blue
        dynamic(light: 0xEB6834, dark: 0xD95926), // orange
        dynamic(light: 0x1BAF7A, dark: 0x199E70), // aqua
        dynamic(light: 0xEDA100, dark: 0xC98500), // yellow
        dynamic(light: 0xE87BA4, dark: 0xD55181), // magenta
        dynamic(light: 0x008300, dark: 0x0CA30C), // green
        dynamic(light: 0x6250D6, dark: 0x9085E9), // violet
        dynamic(light: 0xE34948, dark: 0xE66767), // red
    ]

    private static let s2aSeries: [Color] = [
        dynamic(light: 0x7153DD, dark: 0x856AF5), // S2A violet
        dynamic(light: 0x05AC7D, dark: 0x029E72), // mint
        dynamic(light: 0xEE9E10, dark: 0xC68206), // amber
        dynamic(light: 0x04A3BE, dark: 0x06A0BA), // cyan
        dynamic(light: 0xE05B4A, dark: 0xD95544), // coral
        dynamic(light: 0x2A71D6, dark: 0x377EE3), // blue
        dynamic(light: 0xD14BA0, dark: 0xCA449A), // magenta
        dynamic(light: 0x6EA518, dark: 0x5F9205), // lime
    ]

    static var series: [Color] { isS2A ? s2aSeries : neutralSeries }

    /// "Other" series and secondary marks.
    static let other = dynamic(light: 0x898781, dark: 0x898781)

    // MARK: Semantic roles (same meaning in every theme, hue picked per theme)

    /// Single-series charts and the main identity color.
    static var primary: Color { series[0] }
    static var model: Color { series[0] }
    static var user: Color { series[1] }
    static var tool: Color { isS2A ? series[3] : series[2] }
    static var context: Color { series[6] }
    static var subagent: Color { isS2A ? series[5] : series[4] }
    static var skill: Color { isS2A ? series[2] : series[3] }
    static var mcp: Color { isS2A ? series[7] : series[6] }

    // MARK: Sequential (near-zero recedes toward the surface in both modes)

    private static func ramp(_ light: [UInt32]) -> [Color] {
        zip(light, light.reversed()).map { dynamic(light: $0, dark: $1) }
    }

    private static let neutralSequential = ramp([0xCDE2FB, 0x9EC5F4, 0x6DA7EC, 0x3987E5, 0x256ABF, 0x184F95, 0x0D366B])
    private static let s2aSequential = ramp([0xE6E5FF, 0xC7C3F9, 0xAAA2F3, 0x8F80EB, 0x7359DB, 0x583FAF, 0x402C84])

    static var sequential: [Color] { isS2A ? s2aSequential : neutralSequential }

    // MARK: Surfaces and chrome

    private static let neutralCard = dynamic(light: 0xFCFCFB, dark: 0x1F1F1E)
    private static let s2aCard = dynamic(light: 0xFBFBFE, dark: 0x14152C)
    private static let neutralHairline = dynamic(light: 0xE1E0D9, dark: 0x2C2C2A)
    private static let s2aHairline = dynamic(light: 0xE2E1ED, dark: 0x262844)
    private static let neutralEmpty = dynamic(light: 0xF0EFEC, dark: 0x262624)
    private static let s2aEmpty = dynamic(light: 0xECECF5, dark: 0x1D1F37)
    private static let s2aPage = dynamic(light: 0xF5F5FB, dark: 0x0A0B1C)
    private static let s2aSidebar = dynamic(light: 0xEEEDF8, dark: 0x101129)
    private static let s2aAccent = dynamic(light: 0x7153DD, dark: 0x8F78F7)

    static var card: Color { isS2A ? s2aCard : neutralCard }
    static var hairline: Color { isS2A ? s2aHairline : neutralHairline }
    static var emptyCell: Color { isS2A ? s2aEmpty : neutralEmpty }
    /// Window background behind cards; `nil` keeps the system background.
    static var page: Color? { isS2A ? s2aPage : nil }
    /// Sidebar background; `nil` keeps the system material.
    static var sidebar: Color? { isS2A ? s2aSidebar : nil }
    static var accent: Color { isS2A ? s2aAccent : .accentColor }

    /// The S2A mark: deep violet → violet → cyan.
    static let brandGradient = LinearGradient(
        colors: [Color(nsColor: NSColor(rgb: 0x301172)), Color(nsColor: NSColor(rgb: 0x7153DD)), Color(nsColor: NSColor(rgb: 0x0EB1CD))],
        startPoint: .bottomLeading,
        endPoint: .topTrailing
    )

    // MARK: Status (fixed in every theme, always with an icon and a label)

    static let good = Color(nsColor: NSColor(rgb: 0x0CA30C))
    static let warning = Color(nsColor: NSColor(rgb: 0xFAB219))
    static let serious = Color(nsColor: NSColor(rgb: 0xEC835A))
    static let critical = Color(nsColor: NSColor(rgb: 0xD03B3B))

    static func color(for severity: InsightSeverity) -> Color {
        switch severity {
        case .good: return good
        case .info: return primary
        case .warning: return warning
        case .critical: return critical
        }
    }

    static func icon(for severity: InsightSeverity) -> String {
        switch severity {
        case .good: return "checkmark.circle.fill"
        case .info: return "lightbulb.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .critical: return "xmark.octagon.fill"
        }
    }

    // MARK: Cost components

    /// Cost components, in the order they are stacked.
    static let componentOrder = ["Ввод", "Вывод", "Чтение кэша", "Запись в кэш", "Веб-поиск"]
    static var componentColors: [Color] { Array(series.prefix(5)) }

    static func component(_ name: String) -> Color {
        componentOrder.firstIndex(of: name).map { componentColors[$0] } ?? other
    }
}

extension NSColor {
    convenience init(rgb: UInt32) {
        self.init(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}

extension View {
    /// Applies the active theme: accent, light/dark preference and the page background.
    func themedWindow(appearance: AppAppearance) -> some View {
        tint(Palette.accent)
            .preferredColorScheme(appearance.colorScheme)
    }
}

/// App mark used in the sidebar and the menu bar popover.
struct BrandMark: View {
    var size: CGFloat = 32

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).fill(Palette.brandGradient)
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: size * 0.5, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// "S2A · Claude X-Ray" header at the top of the sidebar.
struct BrandHeader: View {
    var body: some View {
        HStack(spacing: 10) {
            BrandMark(size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text("S2A Claude X-Ray").font(.headline)
                Text("мониторинг Claude Code").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}
