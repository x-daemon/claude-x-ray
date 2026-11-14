import Foundation

/// Formatting helpers shared by the app, reports and tests.
public enum Fmt {
    private static let posix = Locale(identifier: "en_US_POSIX")

    /// `$0.42`, `$12.30`, `$1,234`.
    public static func usd(_ value: Double) -> String {
        let magnitude = abs(value)
        if magnitude >= 1000 {
            return "$" + grouped(Int(value.rounded()))
        }
        if magnitude > 0 && magnitude < 0.01 {
            return value < 0 ? "-<$0.01" : "<$0.01"
        }
        return String(format: "$%.2f", locale: posix, value)
    }

    /// `950`, `12.3K`, `4.56M`, `1.2B`.
    public static func tokens(_ value: Int) -> String {
        let v = Double(value)
        switch abs(v) {
        case 1_000_000_000...: return trimmed(v / 1_000_000_000, digits: 2) + "B"
        case 1_000_000...: return trimmed(v / 1_000_000, digits: 2) + "M"
        case 1_000...: return trimmed(v / 1_000, digits: 1) + "K"
        default: return "\(value)"
        }
    }

    /// `0.385` -> `39%`; small shares keep one decimal (`4.2%`).
    public static func percent(_ fraction: Double) -> String {
        let value = fraction * 100
        if value > 0 && value < 10 {
            return trimmed(value, digits: 1) + "%"
        }
        return "\(Int(value.rounded()))%"
    }

    /// `2 ч 05 мин`, `14 мин`, `40 с`.
    public static func duration(_ interval: TimeInterval) -> String {
        let seconds = Int(max(0, interval).rounded())
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 { return String(format: "%ld ч %02ld мин", hours, minutes) }
        if minutes > 0 { return "\(minutes) мин" }
        return "\(seconds) с"
    }

    /// `14.11 17:23`
    public static func dateTime(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.day, .month, .hour, .minute], from: date)
        return String(format: "%02ld.%02ld %02ld:%02ld", c.day ?? 0, c.month ?? 0, c.hour ?? 0, c.minute ?? 0)
    }

    /// `2026-11-14`
    public static func isoDay(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04ld-%02ld-%02ld", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Plain decimal for CSV, independent of the user's locale.
    public static func decimal(_ value: Double, digits: Int = 4) -> String {
        String(format: "%.\(digits)f", locale: posix, value)
    }

    private static func trimmed(_ value: Double, digits: Int) -> String {
        var text = String(format: "%.\(digits)f", locale: posix, value)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text
    }

    private static func grouped(_ value: Int) -> String {
        let digits = String(abs(value))
        var result = ""
        for (i, ch) in digits.reversed().enumerated() {
            if i > 0 && i % 3 == 0 { result.append(",") }
            result.append(ch)
        }
        return (value < 0 ? "-" : "") + String(result.reversed())
    }
}
