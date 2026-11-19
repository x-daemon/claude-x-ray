import Foundation

/// An interface language of X-Ray.
public enum Language: String, CaseIterable, Identifiable, Sendable {
    case ru, en, de

    public var id: String { rawValue }

    /// The language's name in itself, for the language picker.
    public var nativeName: String {
        switch self {
        case .ru: return "Русский"
        case .en: return "English"
        case .de: return "Deutsch"
        }
    }
}

/// Interface language for every user-visible string: views, insights, reports, units, the menu.
///
/// Keys are the Russian texts themselves, with `{0}`, `{1}`… where values are interpolated. The
/// English and German texts live in `l10n/strings.json` at the repository root, shared with the
/// Windows app, and are generated into `Catalog.generated.swift` by `scripts/l10n.py`.
public enum L10n {
    /// The language in effect. Russian until the app applies the user's setting (and in tests).
    public static var language: Language = .ru

    /// The user's setting (`system`, `ru`, `en`, `de`) as a language; `system` and unknown values
    /// pick the first of the preferred languages X-Ray has, else English.
    public static func resolve(_ setting: String?, preferred: [String] = Locale.preferredLanguages) -> Language {
        if let setting, let language = Language(rawValue: setting) { return language }
        for tag in preferred {
            let code = tag.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
            if let language = Language(rawValue: code) { return language }
        }
        return .en
    }

    /// Dates and times in the interface language: the user's own regional format when it is in
    /// that language (de_CH stays de_CH), otherwise the language's usual one.
    public static var locale: Locale {
        if Locale.current.language.languageCode?.identifier == language.rawValue { return Locale.current }
        switch language {
        case .ru: return Locale(identifier: "ru_RU")
        case .en: return Locale(identifier: "en_GB")
        case .de: return Locale(identifier: "de_DE")
        }
    }

    struct Catalog: Decodable {
        let strings: [String: [String: String]]
        let plurals: [String: [String: String]]
    }

    static let catalog: Catalog = {
        (try? JSONDecoder().decode(Catalog.self, from: Data(catalogJSON.utf8))) ?? Catalog(strings: [:], plurals: [:])
    }()

    /// Marks a Russian text as a catalog key without translating it, for texts that are stored
    /// (a price table's notes) and translated where they are shown with `tr`.
    public static func key(_ key: String) -> String { key }

    /// The text for a Russian key in the current language; the key itself when there is none.
    /// For texts kept in data, such as a tool category's name.
    public static func tr(_ key: String) -> String {
        guard language != .ru, let text = catalog.strings[key]?[language.rawValue] else { return key }
        return text
    }

    /// Fills `{0}`, `{1}`… in one pass, so an argument that itself contains "{1}" stays as it is.
    public static func format(_ template: String, _ arguments: [String]) -> String {
        guard !arguments.isEmpty else { return template }
        var out = ""
        var i = template.startIndex
        while i < template.endIndex {
            if template[i] == "{",
               let close = template[i...].firstIndex(of: "}"),
               let index = Int(template[template.index(after: i)..<close]),
               index >= 0, index < arguments.count {
                out += arguments[index]
                i = template.index(after: close)
            } else {
                out.append(template[i])
                i = template.index(after: i)
            }
        }
        return out
    }

    /// A count with its word, given in Russian one/few/many: `plural(5, "запрос", "запроса",
    /// "запросов")` is `5 запросов`; English and German use the catalog's one|other forms. A form
    /// that contains `{n}` places the number itself (German "vor {n} Tagen").
    public static func plural(_ count: Int, _ one: String, _ few: String, _ many: String) -> String {
        let form: String
        if language == .ru {
            let n = abs(count) % 100
            let last = n % 10
            if (11...14).contains(n) {
                form = many
            } else if last == 1 {
                form = one
            } else if (2...4).contains(last) {
                form = few
            } else {
                form = many
            }
        } else {
            let forms = (catalog.plurals["\(one)|\(few)|\(many)"]?[language.rawValue] ?? "\(one)|\(many)").components(separatedBy: "|")
            form = abs(count) == 1 ? forms[0] : forms[forms.count - 1]
        }
        return form.contains("{n}") ? form.replacingOccurrences(of: "{n}", with: "\(count)") : "\(count) \(form)"
    }
}

/// A Russian interface text with the values interpolated into it: `L("Всего \(n) запросов")`
/// looks up "Всего {0} запросов" and fills in `n`.
public struct LocalizedText: ExpressibleByStringInterpolation, Sendable {
    public let key: String
    public let arguments: [String]

    public init(stringLiteral value: String) {
        key = value
        arguments = []
    }

    public init(stringInterpolation: Interpolation) {
        key = stringInterpolation.key
        arguments = stringInterpolation.arguments
    }

    public struct Interpolation: StringInterpolationProtocol, Sendable {
        var key = ""
        var arguments: [String] = []

        public init(literalCapacity: Int, interpolationCount: Int) {
            key.reserveCapacity(literalCapacity + 3 * interpolationCount)
        }

        public mutating func appendLiteral(_ literal: String) {
            key += literal
        }

        public mutating func appendInterpolation<T>(_ value: T) {
            key += "{\(arguments.count)}"
            arguments.append("\(value)")
        }
    }
}

/// The interface text in the current language.
public func L(_ text: LocalizedText) -> String {
    L10n.format(L10n.tr(text.key), text.arguments)
}

extension Date {
    /// `formatted(date:time:)` in the interface language rather than the system's.
    public func localized(date: Date.FormatStyle.DateStyle, time: Date.FormatStyle.TimeStyle) -> String {
        formatted(Date.FormatStyle(date: date, time: time, locale: L10n.locale))
    }
}
