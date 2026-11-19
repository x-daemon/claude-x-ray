import XCTest
@testable import XRayCore

final class L10nTests: XCTestCase {
    override func tearDown() {
        L10n.language = .ru
        super.tearDown()
    }

    func testTextsFollowTheLanguage() {
        L10n.language = .ru
        XCTAssertEqual(L("Сессии"), "Сессии")
        XCTAssertEqual(L("\(5) мин назад"), "5 мин назад")
        L10n.language = .en
        XCTAssertEqual(L("Сессии"), "Sessions")
        XCTAssertEqual(L("\(5) мин назад"), "5 min ago")
        L10n.language = .de
        XCTAssertEqual(L("\(5) мин назад"), "vor 5 Min.")
        XCTAssertEqual(L10n.tr("Сессии"), "Sitzungen")
        XCTAssertEqual(L("Текст, которого нет в каталоге \(1)"), "Текст, которого нет в каталоге 1", "missing keys fall back to Russian")
    }

    func testInterpolationBuildsTheCatalogKey() {
        let name = "Bash"
        let text: LocalizedText = "Выполняет \(name)"
        XCTAssertEqual(text.key, "Выполняет {0}")
        XCTAssertEqual(text.arguments, ["Bash"])
        L10n.language = .en
        XCTAssertEqual(L("Выполняет \(name)"), "Running Bash")
    }

    func testPlaceholdersAreFilledInOnePass() {
        XCTAssertEqual(L10n.format("{0} и {1}", ["{1}", "b"]), "{1} и b")
        XCTAssertEqual(L10n.format("{0} {2}", ["a"]), "a {2}")
    }

    func testPlurals() {
        L10n.language = .ru
        XCTAssertEqual([1, 2, 5, 11, 21, 22].map { Fmt.plural($0, "запрос", "запроса", "запросов") },
                       ["1 запрос", "2 запроса", "5 запросов", "11 запросов", "21 запрос", "22 запроса"])
        L10n.language = .en
        XCTAssertEqual([1, 2, 21].map { Fmt.plural($0, "запрос", "запроса", "запросов") }, ["1 request", "2 requests", "21 requests"])
        L10n.language = .de
        XCTAssertEqual(Fmt.ago(3 * 86_400), "vor 3 Tagen")
        XCTAssertEqual(Fmt.ago(86_400), "vor 1 Tag")
    }

    func testUnitsAndDates() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let date = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 17, minute: 23)))
        L10n.language = .ru
        XCTAssertEqual(Fmt.duration(2 * 3600 + 5 * 60), "2 ч 05 мин")
        XCTAssertEqual(Fmt.dateTime(date, calendar: calendar), "14.11 17:23")
        L10n.language = .en
        XCTAssertEqual(Fmt.duration(2 * 3600 + 5 * 60), "2 h 05 min")
        XCTAssertEqual(Fmt.bytes(2048), "2 KB")
        XCTAssertEqual(Fmt.dateTime(date, calendar: calendar), "14 Nov 17:23")
        L10n.language = .de
        XCTAssertEqual(Fmt.duration(2 * 3600 + 5 * 60), "2 Std. 05 Min.")
        XCTAssertEqual(Fmt.dateTime(date, calendar: calendar), "14.11. 17:23")
    }

    func testSystemLanguage() {
        XCTAssertEqual(L10n.resolve("system", preferred: ["fr-CH", "de-CH", "en-US"]), .de)
        XCTAssertEqual(L10n.resolve("system", preferred: ["ru_RU"]), .ru)
        XCTAssertEqual(L10n.resolve("system", preferred: ["fr-FR"]), .en)
        XCTAssertEqual(L10n.resolve("de", preferred: ["ru-RU"]), .de)
        XCTAssertEqual(L10n.resolve(nil, preferred: []), .en)
    }

    func testCatalogIsCompleteAndStoredKeysTranslate() {
        XCTAssertFalse(L10n.catalog.strings.isEmpty)
        for (key, entry) in L10n.catalog.strings {
            XCTAssertNotNil(entry["en"], key)
            XCTAssertNotNil(entry["de"], key)
        }
        L10n.language = .en
        XCTAssertEqual(L10n.tr(PricingTable.default.sourceNote), "API price list as of 2026-11-03")
        XCTAssertEqual(ToolDescriber.Category.read.title, "Reading")
    }
}
