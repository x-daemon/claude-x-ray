import SwiftUI
import UIKit
import XRayCore

/// CI aid. With the launch argument `-XRaySnapshots full` (or `short`) the app waits for its first
/// sync, then opens one screen after another. For each it writes the screen's name to
/// Documents/snapshots/next.txt and waits until the CI script has taken the simulator's screenshot
/// and deleted the file. Ends with Documents/snapshots/finished and log.txt.
@MainActor
enum IPadSnapshots {
    static var plan: String? { UserDefaults.standard.string(forKey: "XRaySnapshots") }
    static var isRequested: Bool { plan != nil }

    static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("snapshots", isDirectory: true)
    }

    enum Shot {
        case screen(SidebarItem)
        case trace(TraceTab)
        case sessionDetail
        case settingsPage(IPadSettingsPage)

        var name: String {
            switch self {
            case .screen(let item): return item.rawValue
            case .trace(let tab): return "trace-\(tab.rawValue)"
            case .sessionDetail: return "session-detail"
            case .settingsPage(let page):
                switch page {
                case .computer: return "settings-computer"
                case .addComputer: return "settings-add"
                case .appearance: return "settings-appearance"
                case .pricing: return "settings-pricing"
                case .plan: return "settings-plan"
                }
            }
        }
    }

    struct Pass {
        let name: String
        let landscape: Bool
        let dark: Bool
        let shots: [Shot]
    }

    static func passes(_ plan: String, computer: UUID?) -> [Pass] {
        let traceTabs = TraceTab.allCases.map { Shot.trace($0) }
        var settings: [Shot] = [.screen(.settings), .settingsPage(.appearance), .settingsPage(.pricing), .settingsPage(.plan)]
        if let computer { settings.insert(.settingsPage(.computer(computer)), at: 1) }
        let everything: [Shot] = [.screen(.live)] + traceTabs + [
            .screen(.overview), .screen(.sessions), .sessionDetail, .screen(.projects), .screen(.models),
            .screen(.insights), .screen(.reports),
        ] + settings
        if plan == "short" {
            return [Pass(name: "portrait-light", landscape: false, dark: false, shots: [
                .screen(.live), .trace(.feed), .trace(.llm), .screen(.overview), .screen(.sessions), .screen(.insights), .screen(.reports), .screen(.settings),
            ])]
        }
        return [
            Pass(name: "portrait-light", landscape: false, dark: false, shots: everything),
            Pass(name: "portrait-dark", landscape: false, dark: true, shots: [
                .screen(.live), .trace(.feed), .trace(.llm), .screen(.overview), .screen(.insights), .screen(.reports), .screen(.settings),
            ]),
            Pass(name: "landscape-light", landscape: true, dark: false, shots: [
                .screen(.live), .trace(.feed), .trace(.flow), .trace(.timeline), .screen(.overview), .screen(.sessions), .sessionDetail,
                .screen(.projects), .screen(.insights), .screen(.reports), .screen(.settings),
            ]),
            Pass(name: "landscape-dark", landscape: true, dark: true, shots: [.screen(.live), .trace(.feed), .screen(.overview)]),
        ]
    }

    static func run(model: AppModel, sync: DesktopSync) async {
        guard let plan else { return }
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: directory)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var log: [String] = []

        // The first complete sync, then a scan of what came in.
        let started = Date()
        while Date().timeIntervalSince(started) < 180 {
            if sync.lastSync != nil, model.hasData, !model.isScanning, sync.summaryState == .live { break }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await model.rescan()
        log.append("first sync after \(Int(Date().timeIntervalSince(started))) s: \(sync.summaryState.title)")
        for computer in sync.computers {
            let status = sync.status[computer.id]
            log.append("computer \(computer.name) (\(computer.platform ?? "?")): files \(status?.files ?? 0), bytes \(status?.bytes ?? 0), remote files \(status?.info?.files ?? -1)")
        }
        log.append("events: \(model.priced.count), activity items: \(model.activity.count), trace sessions: \(model.traceSessions.count)")
        if let status = model.liveStatus {
            log.append("live state: \(status.state.title)")
        }
        if let usage = model.planUsage {
            log.append("plan usage: 5h \(usage.fiveHour?.usedPercentage ?? -1)%, 7d \(usage.sevenDay?.usedPercentage ?? -1)%")
        } else {
            log.append("plan usage: none")
        }

        for pass in passes(plan, computer: sync.computers.first?.id) {
            UserDefaults.standard.set(pass.dark ? AppAppearance.dark.rawValue : AppAppearance.light.rawValue, forKey: AppAppearance.storageKey)
            setOrientation(landscape: pass.landscape)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            for shot in pass.shots {
                await show(shot, model: model)
                try? await Task.sleep(nanoseconds: 1_600_000_000)
                let name = "\(pass.name)-\(shot.name)"
                if await capture(name) {
                    log.append(name)
                } else {
                    log.append("\(name): no screenshot")
                }
            }
        }
        UserDefaults.standard.set(AppAppearance.auto.rawValue, forKey: AppAppearance.storageKey)
        try? Data((log.joined(separator: "\n") + "\n").utf8).write(to: directory.appendingPathComponent("log.txt"))
        try? Data().write(to: directory.appendingPathComponent("finished"))
    }

    private static func show(_ shot: Shot, model: AppModel) async {
        switch shot {
        case .screen(let item):
            model.selection = item
            // The report compares with the previous period: a week has one in the demo data.
            model.period = item == .reports ? .week : .month
        case .trace(let tab):
            model.selection = .trace
            model.traceTab = tab
        case .sessionDetail:
            model.selection = .sessions
            model.period = .month
            try? await Task.sleep(nanoseconds: 800_000_000)
            if let session = SessionAnalytics.sessions(model.periodEvents).max(by: { $0.cost < $1.cost }) {
                model.detailPath.append(SessionRoute(id: session.id))
            }
        case .settingsPage(let page):
            model.selection = .settings
            try? await Task.sleep(nanoseconds: 800_000_000)
            model.detailPath.append(page)
        }
    }

    /// Asks the CI script for a screenshot; true once it was taken.
    private static func capture(_ name: String) async -> Bool {
        let request = directory.appendingPathComponent("next.txt")
        try? Data(name.utf8).write(to: request, options: .atomic)
        for _ in 0..<300 {
            if !FileManager.default.fileExists(atPath: request.path) { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        try? FileManager.default.removeItem(at: request)
        return false
    }

    private static func setOrientation(landscape: Bool) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: landscape ? .landscapeRight : .portrait)) { _ in }
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }
}
