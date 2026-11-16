import AppKit
import SwiftUI
import XRayCore

/// CI/debug aid. With `XRAY_SNAPSHOT_DIR` set, the app opens every screen (and every
/// live-trace tab) in light and dark appearance, saves a PNG of the main window for
/// each into that folder, writes `snapshots.log` and quits.
/// `XRAY_SNAPSHOT_SCREENS=live,trace` limits the captures to those screens.
@MainActor
enum SnapshotRunner {
    static var directory: URL? {
        ProcessInfo.processInfo.environment["XRAY_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static var screens: Set<String>? {
        ProcessInfo.processInfo.environment["XRAY_SNAPSHOT_SCREENS"].map {
            Set($0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        }
    }

    static func runIfRequested(model: AppModel) {
        guard let directory else { return }
        Task { @MainActor in
            await run(model: model, directory: directory)
            NSApp.terminate(nil)
        }
    }

    private static func run(model: AppModel, directory: URL) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var log: [String] = []

        // Wait for the first scan and for the main window.
        for _ in 0..<120 {
            if model.lastScan != nil && !model.isScanning && mainWindow() != nil { break }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        log.append("events: \(model.priced.count), activity items: \(model.activity.count), trace sessions: \(model.traceSessions.count)")
        if let status = model.liveStatus {
            log.append("live state: \(status.state.title) — \(status.state.detail ?? "")")
        }
        if let usage = model.planUsage {
            log.append("plan usage: 5h \(usage.fiveHour?.usedPercentage ?? -1)%, 7d \(usage.sevenDay?.usedPercentage ?? -1)%, captured \(usage.capturedAt)")
        } else {
            log.append("plan usage: none")
        }
        guard let window = mainWindow() else {
            log.append("no main window; windows: \(NSApp.windows.map { "\($0.title) \($0.frame)" })")
            write(log, to: directory)
            return
        }
        // Taller than most CI screens: frames set directly are not limited to the visible area.
        let top = (window.screen ?? NSScreen.main)?.visibleFrame.maxY ?? 900
        window.setFrame(NSRect(x: 0, y: top - 1300, width: 1440, height: 1300), display: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        log.append("window \(window.windowNumber) \(window.frame)")

        // S2A in light and dark on every screen; the neutral theme on a few screens for comparison.
        let passes: [(theme: AppTheme, mode: String, appearance: NSAppearance.Name, items: [SidebarItem], tabs: [TraceTab])] = [
            (.s2a, "light", .aqua, SidebarItem.allCases, TraceTab.allCases),
            (.s2a, "dark", .darkAqua, SidebarItem.allCases, TraceTab.allCases),
            (.system, "light", .aqua, [.live, .trace, .overview], [.feed]),
        ]
        for pass in passes {
            let items = pass.items.filter { screens?.contains($0.rawValue) ?? true }
            guard !items.isEmpty else { continue }
            UserDefaults.standard.set(pass.theme.rawValue, forKey: AppTheme.storageKey)
            NSApp.appearance = NSAppearance(named: pass.appearance)
            let prefix = "\(pass.theme.rawValue)-\(pass.mode)"
            for item in items {
                model.selection = item
                if item == .sessions {
                    model.selectedSessionID = SessionAnalytics.sessions(model.periodEvents).first?.id
                }
                if item == .trace {
                    // Without recent activity every tab shows the same explanation.
                    for tab in model.traceSessions.isEmpty ? [.feed] : pass.tabs {
                        model.traceTab = tab
                        log.append(await capture(window, name: "\(prefix)-\(item.rawValue)-\(tab.rawValue)", directory: directory))
                    }
                } else {
                    log.append(await capture(window, name: "\(prefix)-\(item.rawValue)", directory: directory))
                    if item == .live {
                        scrollToBottom(window)
                        log.append(await capture(window, name: "\(prefix)-\(item.rawValue)-bottom", directory: directory))
                    }
                }
            }
        }
        UserDefaults.standard.set(AppTheme.s2a.rawValue, forKey: AppTheme.storageKey)
        model.selection = .live
        write(log, to: directory)
    }

    /// Scrolls the detail pane (the largest scroll view in the window) to its end.
    private static func scrollToBottom(_ window: NSWindow) {
        guard let content = window.contentView else { return }
        let scrollViews = allSubviews(of: content).compactMap { $0 as? NSScrollView }
        guard let scroll = scrollViews.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }),
              let document = scroll.documentView else { return }
        let maxY = max(0, document.frame.height - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: document.isFlipped ? maxY : 0))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private static func allSubviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { allSubviews(of: $0) }
    }

    private static func mainWindow() -> NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.canBecomeMain && $0.frame.width > 400 }
    }

    private static func capture(_ window: NSWindow, name: String, directory: URL) async -> String {
        try? await Task.sleep(nanoseconds: 1_600_000_000)
        let url = directory.appendingPathComponent(name + ".png")
        if let image = windowServerImage(of: window), let data = png(image) {
            do {
                try data.write(to: url)
                return "\(name): window server, \(data.count) bytes"
            } catch {
                return "\(name): \(error)"
            }
        }
        guard let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return "\(name): no bitmap" }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return "\(name): no png" }
        do {
            try data.write(to: url)
            return "\(name): cacheDisplay, \(data.count) bytes"
        } catch {
            return "\(name): \(error)"
        }
    }

    /// Image of our own window from the window server. Looked up at run time because the
    /// API is deprecated; an app may capture its own windows without screen-recording access.
    private static func windowServerImage(of window: NSWindow) -> CGImage? {
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW),
              let symbol = dlsym(handle, "CGWindowListCreateImage") else { return nil }
        let create = unsafeBitCast(symbol, to: CreateImage.self)
        let includingWindow: UInt32 = 1 << 3
        let boundsIgnoreFraming: UInt32 = 1 << 0
        let bestResolution: UInt32 = 1 << 3
        return create(.null, includingWindow, UInt32(window.windowNumber), boundsIgnoreFraming | bestResolution)?.takeRetainedValue()
    }

    private static func png(_ image: CGImage) -> Data? {
        guard image.width > 1, image.height > 1 else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    private static func write(_ log: [String], to directory: URL) {
        try? (log.joined(separator: "\n") + "\n").write(to: directory.appendingPathComponent("snapshots.log"), atomically: true, encoding: .utf8)
    }
}
