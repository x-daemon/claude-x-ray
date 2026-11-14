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
                Image(systemName: "waveform.path.ecg").foregroundStyle(Palette.series[0])
                Text("S2A Claude X-Ray").font(.headline)
                Spacer()
                if model.isScanning {
                    ProgressView().controlSize(.small)
                }
            }

            WindowSummaryView(compact: true)

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text("Сегодня").foregroundStyle(.secondary)
                    Text(Fmt.usd(today.cost.total)).monospacedDigit()
                    Text("\(Fmt.tokens(today.tokens.total)) ток.").foregroundStyle(.secondary)
                }
                GridRow {
                    Text("Темп за час").foregroundStyle(.secondary)
                    Text("\(Fmt.usd(burn.costPerHour))/ч").monospacedDigit()
                    Text("\(burn.requests) запр.").foregroundStyle(.secondary)
                }
                GridRow {
                    Text("Кэш сегодня").foregroundStyle(.secondary)
                    Text(today.requests > 0 ? Fmt.percent(today.tokens.cacheHitRate) : "—").monospacedDigit()
                    Text("")
                }
            }
            .font(.callout)

            Divider()

            HStack {
                Button("Открыть X-Ray") {
                    openWindow(id: "main")
                    NSApp.activate()
                }
                .keyboardShortcut(.defaultAction)
                Button {
                    Task { await model.rescan() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Обновить")
                SettingsLink {
                    Image(systemName: "gearshape")
                }
                .help("Настройки")
                Spacer()
                Button("Выйти") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 340)
    }
}
