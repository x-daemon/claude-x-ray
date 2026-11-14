import AppKit
import Foundation
import Observation
import SwiftUI
import XRayCore

enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case live, overview, sessions, projects, models, insights, reports

    var id: Self { self }

    var title: String {
        switch self {
        case .live: return "Сейчас"
        case .overview: return "Обзор"
        case .sessions: return "Сессии"
        case .projects: return "Проекты"
        case .models: return "Модели"
        case .insights: return "Оптимизация"
        case .reports: return "Отчёты"
        }
    }

    var systemImage: String {
        switch self {
        case .live: return "waveform.path.ecg"
        case .overview: return "chart.bar.xaxis"
        case .sessions: return "list.bullet.rectangle"
        case .projects: return "folder"
        case .models: return "cpu"
        case .insights: return "lightbulb"
        case .reports: return "doc.text"
        }
    }
}

enum Period: String, CaseIterable, Identifiable {
    case today, week, month, quarter, all

    var id: Self { self }

    var title: String {
        switch self {
        case .today: return "Сегодня"
        case .week: return "7 дней"
        case .month: return "30 дней"
        case .quarter: return "90 дней"
        case .all: return "Всё время"
        }
    }

    /// Calendar-aligned interval ending at the end of today; `nil` for `.all` without data.
    func interval(now: Date, firstEvent: Date?, calendar: Calendar = .current) -> DateInterval? {
        let todayStart = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: todayStart) ?? now
        func daysBack(_ days: Int) -> DateInterval {
            DateInterval(start: calendar.date(byAdding: .day, value: -days, to: todayStart) ?? todayStart, end: tomorrow)
        }
        switch self {
        case .today: return DateInterval(start: todayStart, end: tomorrow)
        case .week: return daysBack(6)
        case .month: return daysBack(29)
        case .quarter: return daysBack(89)
        case .all:
            guard let firstEvent else { return nil }
            return DateInterval(start: min(calendar.startOfDay(for: firstEvent), todayStart), end: tomorrow)
        }
    }
}

/// App state: scans transcripts, keeps priced events, persists settings.
@MainActor
@Observable
final class AppModel {
    // MARK: Data

    private(set) var priced: [PricedEvent] = []
    private(set) var windows: [UsageWindow] = []
    private(set) var lastScan: Date?
    private(set) var lastScanResult: ScanResult?
    private(set) var isScanning = false
    private(set) var now = Date()
    /// Model display names ordered by all-time cost; fixes each model's chart color.
    private(set) var modelOrder: [String] = []

    // MARK: Settings

    private(set) var pricing: PricingTable
    private(set) var directories: [URL]
    private(set) var plan: SubscriptionPlan

    // MARK: UI state

    var selection: SidebarItem? = .live
    var period: Period = .month

    @ObservationIgnored private var store = UsageStore()
    private let ingestor = TranscriptIngestor()
    @ObservationIgnored private var watcher: DirectoryWatcher?
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var rescanQueued = false
    @ObservationIgnored private var started = false
    @ObservationIgnored private var tickCount = 0
    private let settings = SettingsStore()

    static let otherSeries = "Другие"
    static let maxColoredModels = 7

    init() {
        let settings = SettingsStore()
        pricing = settings.loadPricing()
        directories = settings.directories ?? ClaudeDataLocator.defaultProjectDirectories()
        plan = settings.plan
        Task { @MainActor [weak self] in self?.start() }
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        restartWatching()
        ticker = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        Task { await rescan() }
    }

    private func tick() {
        now = Date()
        tickCount += 1
        // FSEvents covers live updates; a slow poll catches folders created later.
        if tickCount % 4 == 0 {
            Task { await rescan() }
        }
    }

    private func restartWatching() {
        watcher?.stop()
        let existing = directories.filter { FileManager.default.fileExists(atPath: $0.path) }.map(\.path)
        guard !existing.isEmpty else {
            watcher = nil
            return
        }
        let watcher = DirectoryWatcher(paths: existing) { [weak self] in
            Task { @MainActor in await self?.rescan() }
        }
        watcher.start()
        self.watcher = watcher
    }

    // MARK: Scanning

    /// Reads whatever was appended to the transcripts since the last scan.
    func rescan() async {
        if isScanning {
            rescanQueued = true
            return
        }
        isScanning = true
        let result = await ingestor.scan(directories: directories)
        let changed = store.merge(result.events)
        if changed > 0 || lastScan == nil {
            recompute()
        }
        lastScanResult = result
        lastScan = Date()
        now = Date()
        isScanning = false

        if rescanQueued {
            rescanQueued = false
            await rescan()
        }
    }

    /// Forgets everything and reads all transcripts again.
    func fullRescan() async {
        await ingestor.reset()
        store.removeAll()
        priced = []
        windows = []
        lastScan = nil
        await rescan()
    }

    private func recompute() {
        priced = pricing.price(store.events)
        windows = UsageWindows.compute(priced)
        modelOrder = Analytics.group(priced) { ModelCatalog.displayName(for: $0.model) }.map(\.key)
    }

    // MARK: Settings

    func setDirectories(_ urls: [URL]) {
        directories = urls
        settings.directories = urls
        restartWatching()
        Task { await fullRescan() }
    }

    func resetDirectories() {
        settings.directories = nil
        setDirectories(ClaudeDataLocator.defaultProjectDirectories())
    }

    func setPlan(_ plan: SubscriptionPlan) {
        self.plan = plan
        settings.plan = plan
    }

    func updatePricing(_ transform: (inout PricingTable) -> Void) {
        var table = pricing
        transform(&table)
        guard table != pricing else { return }
        pricing = table
        settings.savePricing(table)
        recompute()
    }

    func resetPricing() {
        updatePricing { $0 = .default }
    }

    func addPrice(prefix: String) {
        let id = prefix.trimmingCharacters(in: .whitespaces).lowercased()
        guard !id.isEmpty, !pricing.models.contains(where: { $0.modelPrefix == id }) else { return }
        // Start from the family's reference price so the new row is sensible right away.
        let family = ModelCatalog.family(of: id)
        let base = pricing.models.first { $0.modelPrefix == family.referencePrefix }
        let row = ModelPrice(
            modelPrefix: id,
            displayName: ModelCatalog.displayName(for: id),
            input: base?.input ?? 0,
            output: base?.output ?? 0,
            cacheRead: base?.cacheRead ?? 0,
            cacheWrite5m: base?.cacheWrite5m,
            cacheWrite1h: base?.cacheWrite1h,
            note: "Добавлено вручную — проверьте цены."
        )
        updatePricing { $0.models.append(row) }
    }

    func removePrice(prefix: String) {
        updatePricing { $0.models.removeAll { $0.modelPrefix == prefix } }
    }

    func priceBinding(_ prefix: String, _ keyPath: WritableKeyPath<ModelPrice, Double>) -> Binding<Double> {
        Binding(
            get: { [weak self] in
                self?.pricing.models.first { $0.modelPrefix == prefix }?[keyPath: keyPath] ?? 0
            },
            set: { [weak self] value in
                self?.updatePricing { table in
                    guard let index = table.models.firstIndex(where: { $0.modelPrefix == prefix }) else { return }
                    table.models[index][keyPath: keyPath] = max(0, value)
                }
            }
        )
    }

    // MARK: Derived data

    var hasData: Bool { !priced.isEmpty }

    var periodInterval: DateInterval? {
        period.interval(now: now, firstEvent: priced.first?.event.timestamp)
    }

    var periodEvents: [PricedEvent] {
        Analytics.filter(priced, in: periodInterval)
    }

    /// Bucket size for timeline charts of the selected period.
    var periodChartUnit: Calendar.Component {
        guard let interval = periodInterval else { return .day }
        if interval.duration <= 2 * 86_400 { return .hour }
        if interval.duration > 120 * 86_400 { return .weekOfYear }
        return .day
    }

    var activeWindow: UsageWindow? { UsageWindows.active(in: windows, at: now) }

    var peakWindow: UsageWindow? { UsageWindows.peak(in: windows, excludingActiveAt: now) }

    func events(since date: Date) -> [PricedEvent] {
        guard let index = priced.firstIndex(where: { $0.event.timestamp >= date }) else { return [] }
        return Array(priced[index...])
    }

    var todayEvents: [PricedEvent] { events(since: Calendar.current.startOfDay(for: now)) }

    var lastSevenDaysEvents: [PricedEvent] { events(since: now.addingTimeInterval(-7 * 86_400)) }

    /// Session of the most recent request.
    var currentSession: SessionSummary? {
        guard let last = priced.last else { return nil }
        let id = last.event.sessionID
        return SessionAnalytics.sessions(events(since: now.addingTimeInterval(-7 * 86_400)).filter { $0.event.sessionID == id }).first
    }

    var menuBarTitle: String {
        if let window = activeWindow {
            return Fmt.usd(window.summary.cost.total)
        }
        return hasData ? "—" : "X-Ray"
    }

    // MARK: Chart colors

    /// Series name for an event: its model's display name, or "Другие" past the colored slots.
    func seriesName(for event: UsageEvent) -> String {
        let name = ModelCatalog.displayName(for: event.model)
        guard let index = modelOrder.firstIndex(of: name), index < Self.maxColoredModels else {
            return Self.otherSeries
        }
        return name
    }

    /// Domain and colors for the series present in a chart; each model keeps the same color everywhere.
    func colorScale(for names: some Sequence<String>) -> (domain: [String], range: [Color]) {
        let present = Set(names)
        var domain: [String] = []
        var range: [Color] = []
        for (index, name) in modelOrder.prefix(Self.maxColoredModels).enumerated() where present.contains(name) {
            domain.append(name)
            range.append(Palette.series[index % Palette.series.count])
        }
        if present.contains(Self.otherSeries) {
            domain.append(Self.otherSeries)
            range.append(Palette.other)
        }
        return (domain, range)
    }
}
