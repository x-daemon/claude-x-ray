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
        if hours > 0 { return L("\(hours) ч \(pad2(minutes)) мин") }
        if minutes > 0 { return L("\(minutes) мин") }
        return L("\(seconds) с")
    }

    /// Short durations for steps and tools: `850 мс`, `4.2 с`, `3 мин 05 с`, `1 ч 02 мин`.
    public static func shortDuration(_ interval: TimeInterval) -> String {
        let value = max(0, interval)
        if value < 1 { return L("\(Int((value * 1000).rounded())) мс") }
        if value < 60 { return L("\(trimmed(value, digits: 1)) с") }
        let seconds = Int(value.rounded())
        if seconds < 3600 { return L("\(seconds / 60) мин \(pad2(seconds % 60)) с") }
        return duration(value)
    }

    /// Milliseconds from transcripts: `2128` -> `2.1 с`.
    public static func ms(_ milliseconds: Int) -> String {
        shortDuration(Double(milliseconds) / 1000)
    }

    /// `820 Б`, `12.3 КБ`, `4.5 МБ`.
    public static func bytes(_ count: Int) -> String {
        let value = Double(count)
        if value < 1024 { return L("\(count) Б") }
        if value < 1024 * 1024 { return L("\(trimmed(value / 1024, digits: 1)) КБ") }
        return L("\(trimmed(value / 1024 / 1024, digits: 1)) МБ")
    }

    /// A count with its word, given in Russian one/few/many: `plural(5, "раз", "раза", "раз")` ->
    /// `5 раз`; in English and German the catalog's one|other forms.
    public static func plural(_ count: Int, _ one: String, _ few: String, _ many: String) -> String {
        L10n.plural(count, one, few, many)
    }

    /// Time until an event: `45 мин`, `2 ч 10 мин`, `3 дня 4 ч`.
    public static func span(_ interval: TimeInterval) -> String {
        let seconds = max(0, interval)
        guard seconds >= 86_400 else { return duration(seconds) }
        let days = Int(seconds / 86_400)
        let hours = Int(seconds.truncatingRemainder(dividingBy: 86_400) / 3600)
        let dayText = plural(days, "день", "дня", "дней")
        return hours > 0 ? L("\(dayText) \(hours) ч") : dayText
    }

    /// How long ago, in the largest whole unit: `только что`, `12 мин назад`, `3 ч назад`, `4 дня назад`.
    public static func ago(_ interval: TimeInterval) -> String {
        let seconds = max(0, interval)
        if seconds < 60 { return L("только что") }
        if seconds < 3600 { return L("\(Int(seconds / 60)) мин назад") }
        if seconds < 86_400 { return L("\(Int(seconds / 3600)) ч назад") }
        return plural(Int(seconds / 86_400), "день назад", "дня назад", "дней назад")
    }

    /// `14.11 17:23` (`14 Nov 17:23` in English, `14.11. 17:23` in German).
    public static func dateTime(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.day, .month, .hour, .minute], from: date)
        return "\(dayMonth(day: c.day ?? 0, month: c.month ?? 1)) \(pad2(c.hour ?? 0)):\(pad2(c.minute ?? 0))"
    }

    private static let monthsEnglish = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// `14.11` in Russian, `14.11.` in German, `14 Nov` in English, where a numeric 11/14 would be misread.
    private static func dayMonth(day: Int, month: Int) -> String {
        switch L10n.language {
        case .en: return "\(day) \(monthsEnglish[max(0, min(11, month - 1))])"
        case .de: return "\(pad2(day)).\(pad2(month))."
        case .ru: return "\(pad2(day)).\(pad2(month))"
        }
    }

    private static func pad2(_ value: Int) -> String {
        value < 10 && value >= 0 ? "0\(value)" : "\(value)"
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
