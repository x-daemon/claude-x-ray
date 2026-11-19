import AppKit
import Foundation
import Observation
import SwiftUI
import XRayCore

enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case live, trace, overview, sessions, projects, models, insights, reports

    var id: Self { self }

    var title: String {
        switch self {
        case .live: return L("Сейчас")
        case .trace: return L("Live-трасса")
        case .overview: return L("Обзор")
        case .sessions: return L("Сессии")
        case .projects: return L("Проекты")
        case .models: return L("Модели")
        case .insights: return L("Оптимизация")
        case .reports: return L("Отчёты")
        }
    }

    var systemImage: String {
        switch self {
        case .live: return "waveform.path.ecg"
        case .trace: return "point.3.connected.trianglepath.dotted"
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
        case .today: return L("Сегодня")
        case .week: return L("7 дней")
        case .month: return L("30 дней")
        case .quarter: return L("90 дней")
        case .all: return L("Всё время")
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
    /// Recent activity (prompts, tool calls, results, context updates) for the live trace.
    private(set) var activity = ActivityStore()
    /// Plan usage of the whole account, as Claude Code last reported it to its status line.
    private(set) var planUsage: PlanUsage?
    /// Whether X-Ray is connected to Claude Code's status line.
    private(set) var statusLineState: StatusLineInstaller.State = .notInstalled
    /// The receiver for transcripts pushed by cloud sessions.
    private(set) var receiverStatus = TranscriptReceiver.Status()
    private(set) var receiverEnabled = UserDefaults.standard.bool(forKey: "receiver.enabled")
    private(set) var receiverPort: UInt16 = {
        let stored = UserDefaults.standard.integer(forKey: "receiver.port")
        return (1024...65535).contains(stored) ? UInt16(stored) : TranscriptReceiver.defaultPort
    }()
    private(set) var receiverToken = ""

    // MARK: Settings

    private(set) var pricing: PricingTable
    private(set) var directories: [URL]
    private(set) var plan: SubscriptionPlan

    // MARK: UI state

    var selection: SidebarItem? = .live
    var period: Period = .month
    /// Session shown in the live trace; `nil` follows the most recently active one.
    var pinnedTraceSession: String?
    var traceTab: TraceTab = .feed
    /// Selected row of the sessions table.
    var selectedSessionID: String?

    @ObservationIgnored private var store = UsageStore()
    @ObservationIgnored private var receiver: TranscriptReceiver?
    private let ingestor = TranscriptIngestor()
    @ObservationIgnored private var watcher: DirectoryWatcher?
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var rescanQueued = false
    @ObservationIgnored private var started = false
    @ObservationIgnored private var tickCount = 0
    private let settings = SettingsStore()

    static var otherSeries: String { L("Другие") }
    static let maxColoredModels = 7
    /// How far back the live trace reads transcripts.
    static let activityRetention: TimeInterval = 3 * 86_400

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
        startReceiverIfNeeded()
        restartWatching()
        reloadPlanUsage()
        refreshStatusLineState()
        ticker = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        Task { await rescan() }
        SnapshotRunner.runIfRequested(model: self)
    }

    private func tick() {
        now = Date()
        tickCount += 1
        reloadPlanUsage()
        // FSEvents covers live updates; a slow poll catches folders created later.
        if tickCount % 4 == 0 {
            Task { await rescan() }
        }
        if tickCount % 40 == 0 {
            activity.prune(now: now)
        }
    }

    private func restartWatching() {
        watcher?.stop()
        let existing = scanDirectories.filter { FileManager.default.fileExists(atPath: $0.path) }.map(\.path)
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
        reloadPlanUsage()
        let result = await ingestor.scan(
            directories: scanDirectories,
            activitySince: Date().addingTimeInterval(-Self.activityRetention)
        )
        let changed = store.merge(result.events)
        if changed > 0 || lastScan == nil {
            recompute()
        }
        if !result.activities.isEmpty {
            activity.merge(result.activities, now: Date())
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
        activity.removeAll()
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

    /// The configured folders plus X-Ray's own folders (imported logs, logs pushed by cloud
    /// sessions) once they exist.
    var scanDirectories: [URL] {
        var result = directories
        for folder in [XRayPaths.imported, XRayPaths.cloud]
        where FileManager.default.fileExists(atPath: folder.path)
            && !result.contains(where: { $0.standardizedFileURL == folder.standardizedFileURL }) {
            result.append(folder)
        }
        return result
    }

    // MARK: Cloud receiver

    /// Starts the receiver when it is switched on, or when `XRAY_RECEIVER_PORT` /
    /// `XRAY_RECEIVER_TOKEN` are set (used by CI).
    private func startReceiverIfNeeded() {
        let environment = ProcessInfo.processInfo.environment
        if let port = environment["XRAY_RECEIVER_PORT"].flatMap(UInt16.init), let token = environment["XRAY_RECEIVER_TOKEN"], !token.isEmpty {
            receiverPort = port
            receiverToken = token
            receiverEnabled = true
        } else {
            receiverToken = TranscriptReceiver.loadOrCreateToken()
        }
        if receiverEnabled {
            startReceiver()
        }
    }

    private func startReceiver() {
        try? FileManager.default.createDirectory(at: XRayPaths.cloud, withIntermediateDirectories: true)
        if receiver == nil {
            receiver = TranscriptReceiver { [weak self] status in
                Task { @MainActor in self?.receiverStatus = status }
            }
        }
        receiver?.start(port: receiverPort, token: receiverToken)
        restartWatching()
    }

    func setReceiverEnabled(_ enabled: Bool) {
        receiverEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "receiver.enabled")
        if enabled {
            startReceiver()
        } else {
            receiver?.stop()
        }
    }

    func setReceiverPort(_ port: UInt16) {
        guard port != receiverPort, port >= 1024 else { return }
        receiverPort = port
        UserDefaults.standard.set(Int(port), forKey: "receiver.port")
        if receiverEnabled {
            startReceiver()
        }
    }

    /// Replaces the access token; cloud sessions need the new one (re-enter it in the cloud environment).
    func regenerateReceiverToken() {
        receiverToken = TranscriptReceiver.createToken()
        if receiverEnabled {
            startReceiver()
        }
    }

    // MARK: Account plan usage

    func reloadPlanUsage() {
        let loaded = PlanUsageFile.load()
        if loaded != planUsage {
            planUsage = loaded
        }
    }

    func refreshStatusLineState() {
        statusLineState = StatusLineInstaller.state()
    }

    /// Connects X-Ray to Claude Code's status line. Returns an error message on failure.
    func installStatusLine() -> String? {
        defer { refreshStatusLineState() }
        do {
            try StatusLineInstaller.install()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func uninstallStatusLine() -> String? {
        defer { refreshStatusLineState() }
        do {
            try StatusLineInstaller.uninstall()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: Import

    /// Copies transcripts (`.jsonl`, or `.zip` archives of them) into X-Ray's import folder,
    /// for example logs of cloud sessions. Returns how many files were taken.
    @discardableResult
    func importTranscripts(_ urls: [URL]) -> Int {
        let fileManager = FileManager.default
        let target = XRayPaths.imported.appendingPathComponent("sessions", isDirectory: true)
        try? fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        var imported = 0
        for url in urls {
            switch url.pathExtension.lowercased() {
            case "jsonl":
                let destination = target.appendingPathComponent(url.lastPathComponent)
                try? fileManager.removeItem(at: destination)
                if (try? fileManager.copyItem(at: url, to: destination)) != nil {
                    imported += 1
                }
            case "zip":
                let unzip = Process()
                unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                unzip.arguments = ["-x", "-k", url.path, target.path]
                if (try? unzip.run()) != nil {
                    unzip.waitUntilExit()
                    if unzip.terminationStatus == 0 {
                        imported += 1
                    }
                }
            default:
                continue
            }
        }
        if imported > 0 {
            restartWatching()
            Task { await rescan() }
        }
        return imported
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
            note: L10n.key("Добавлено вручную — проверьте цены.")
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

    /// Scanned folders and what each holds; before the first scan, the configured folders.
    var sourceStats: [SourceStat] {
        if let sources = lastScanResult?.sources, !sources.isEmpty { return sources }
        return directories.map { SourceStat(directory: $0, exists: FileManager.default.fileExists(atPath: $0.path)) }
    }

    /// When Claude Code last wrote a transcript in the scanned folders.
    var newestTranscript: Date? { lastScanResult?.newestModification }

    var periodInterval: DateInterval? {
        period.interval(now: now, firstEvent: priced.first?.event.timestamp)
    }

    var periodEvents: [PricedEvent] {
        Analytics.filter(priced, in: periodInterval)
    }

    /// The same length of time right before the selected period; nil for "all time".
    var previousPeriodInterval: DateInterval? {
        guard period != .all, let interval = periodInterval else { return nil }
        return DateInterval(start: interval.start.addingTimeInterval(-interval.duration), end: interval.start)
    }

    /// Events of the previous period, nil when there is nothing to compare with.
    var previousPeriodEvents: [PricedEvent]? {
        guard let interval = previousPeriodInterval,
              let first = priced.first?.event.timestamp, first < interval.end else { return nil }
        return Analytics.filter(priced, in: interval)
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

    // MARK: Live trace

    /// Sessions with recent activity, most recently active first.
    var traceSessions: [SessionActivity] { activity.sessions() }

    /// The session the live trace shows: the pinned one, or the most recently active.
    var traceSessionID: String? {
        if let pinnedTraceSession, activity.items.contains(where: { $0.sessionID == pinnedTraceSession }) {
            return pinnedTraceSession
        }
        return traceSessions.first?.id
    }

    func trace(for sessionID: String) -> SessionTrace {
        TraceBuilder.build(sessionID: sessionID, items: activity.items(forSession: sessionID), now: now)
    }

    /// What Claude is doing right now in the most recently active session.
    var liveStatus: LiveStatus? {
        guard let id = traceSessions.first?.id else { return nil }
        return trace(for: id).status
    }

    /// Priced usage of a session, keyed by API message id (joins trace steps with tokens and cost).
    func usageByMessage(sessionID: String) -> [String: PricedEvent] {
        var result: [String: PricedEvent] = [:]
        for item in priced where item.event.sessionID == sessionID {
            result[item.event.messageID] = item
        }
        return result
    }

    var menuBarTitle: String {
        var parts: [String] = []
        // The account's real 5-hour usage, while it is recent enough to trust.
        if let window = planUsage?.fiveHour, let captured = planUsage?.capturedAt,
           now.timeIntervalSince(captured) < 3 * 3600, !window.hasReset(at: now) {
            parts.append(Fmt.percent(window.fraction(at: now)))
        }
        if let window = activeWindow {
            parts.append(Fmt.usd(window.summary.cost.total))
        }
        if parts.isEmpty {
            return hasData ? "—" : "X-Ray"
        }
        return parts.joined(separator: " · ")
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
