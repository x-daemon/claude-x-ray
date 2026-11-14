import AppKit
import SwiftUI
import XRayCore

/// Chart and status colors. Categorical slots follow a fixed, colorblind-checked
/// order with separate light and dark steps; status colors are reserved for
/// insight severity and always shown with an icon and a label.
enum Palette {
    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(rgb: isDark ? dark : light)
        })
    }

    /// Categorical series slots, in order: blue, orange, aqua, yellow, magenta, green, violet, red.
    static let series: [Color] = [
        dynamic(light: 0x2A78D6, dark: 0x3987E5),
        dynamic(light: 0xEB6834, dark: 0xD95926),
        dynamic(light: 0x1BAF7A, dark: 0x199E70),
        dynamic(light: 0xEDA100, dark: 0xC98500),
        dynamic(light: 0xE87BA4, dark: 0xD55181),
        dynamic(light: 0x008300, dark: 0x0CA30C),
        dynamic(light: 0x6250D6, dark: 0x9085E9),
        dynamic(light: 0xE34948, dark: 0xE66767),
    ]

    /// "Other" series and secondary marks.
    static let other = dynamic(light: 0x898781, dark: 0x898781)

    /// Sequential blue ramp: near-zero recedes toward the surface in both modes.
    static let sequential: [Color] = {
        let light: [UInt32] = [0xCDE2FB, 0x9EC5F4, 0x6DA7EC, 0x3987E5, 0x256ABF, 0x184F95, 0x0D366B]
        return zip(light, light.reversed()).map { dynamic(light: $0, dark: $1) }
    }()

    static let emptyCell = dynamic(light: 0xF0EFEC, dark: 0x262624)
    static let card = dynamic(light: 0xFCFCFB, dark: 0x1F1F1E)
    static let hairline = dynamic(light: 0xE1E0D9, dark: 0x2C2C2A)

    static let good = Color(nsColor: NSColor(rgb: 0x0CA30C))
    static let warning = Color(nsColor: NSColor(rgb: 0xFAB219))
    static let serious = Color(nsColor: NSColor(rgb: 0xEC835A))
    static let critical = Color(nsColor: NSColor(rgb: 0xD03B3B))

    static func color(for severity: InsightSeverity) -> Color {
        switch severity {
        case .good: return good
        case .info: return series[0]
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

    /// Cost components, in the order they are stacked.
    static let componentOrder = ["Ввод", "Вывод", "Чтение кэша", "Запись в кэш", "Веб-поиск"]
    static let componentColors: [Color] = Array(series.prefix(5))
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
