import AppKit
import SwiftUI
import XRayCore

/// Popover of the menu bar item: the live window at a glance.
struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let today = UsageSummary.of(model.todayEvents)
        let burn = Analytics.burnRate(Array(model.priced.suffix(2_000)), now: model.now, window: 3600)

        VStack(alignment: .leading, spacing: 12) {
            HStack {
                BrandMark(size: 22)
                Text("S2A Claude X-Ray").font(.headline)
                Spacer()
                if model.isScanning {
                    ProgressView().controlSize(.small)
                }
            }

            if let status = model.liveStatus {
                MenuBarStatusLine(status: status)
            }

            WindowSummaryView(compact: true)

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                if let window = model.planUsage?.fiveHour {
                    PlanWindowRow(title: L("Лимит 5 ч"), window: window, now: model.now)
                }
                if let window = model.planUsage?.sevenDay {
                    PlanWindowRow(title: L("Неделя"), window: window, now: model.now)
                }
                GridRow {
                    Text(L("Сегодня")).foregroundStyle(.secondary)
                    Text(Fmt.usd(today.cost.total)).monospacedDigit()
                    Text(L("\(Fmt.tokens(today.tokens.total)) ток.")).foregroundStyle(.secondary)
                }
                GridRow {
                    Text(L("Темп за час")).foregroundStyle(.secondary)
                    Text(L("\(Fmt.usd(burn.costPerHour))/ч")).monospacedDigit()
                    Text(L("\(burn.requests) запр.")).foregroundStyle(.secondary)
                }
                GridRow {
                    Text(L("Кэш сегодня")).foregroundStyle(.secondary)
                    Text(today.requests > 0 ? Fmt.percent(today.tokens.cacheHitRate) : "—").monospacedDigit()
                    Text("")
                }
            }
            .font(.callout)

            Divider()

            HStack {
                Button(L("Открыть X-Ray")) {
                    openWindow(id: "main")
                    NSApp.activate()
                }
                .keyboardShortcut(.defaultAction)
                Button {
                    Task { await model.rescan() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help(L("Обновить"))
                SettingsLink {
                    Image(systemName: "gearshape")
                }
                .help(L("Настройки"))
                Spacer()
                Button(L("Выйти")) { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 340)
    }
}

/// Account limit window in the menu bar popover.
struct PlanWindowRow: View {
    let title: String
    let window: PlanUsage.Window
    let now: Date

    var body: some View {
        let fraction = window.fraction(at: now)
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(Fmt.percent(fraction))
                .monospacedDigit()
                .foregroundStyle(fraction >= 0.7 ? LimitGauge.color(for: fraction) : Color.primary)
            Text(window.hasReset(at: now) ? L("сброшен") : L("сброс через \(Fmt.span(window.resetsAt.timeIntervalSince(now)))"))
                .foregroundStyle(.secondary)
        }
    }
}

/// One-line live state for the menu bar popover, ticking every second.
struct MenuBarStatusLine: View {
    let status: LiveStatus

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: TraceStyle.icon(for: status.state))
                    .foregroundStyle(TraceStyle.color(for: status.state))
                    .symbolEffect(.pulse, isActive: status.state.isActive)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(status.state.title) · \(Fmt.shortDuration(status.elapsed(at: timeline.date)))")
                        .font(.callout.weight(.semibold))
                    if let detail = status.state.detail {
                        Text(detail).font(.system(.caption, design: .monospaced)).lineLimit(2)
                    }
                    Text(L("ответов модели \(status.stepsInTurn) · инструментов \(status.toolsInTurn)"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(TraceStyle.color(for: status.state).opacity(0.1)))
        }
    }
}
