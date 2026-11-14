import SwiftUI
import XRayCore

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        NavigationSplitView {
            List(SidebarItem.allCases, selection: $model.selection) { item in
                Label(item.title, systemImage: item.systemImage)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
            .safeAreaInset(edge: .bottom) {
                ScanStatusView()
                    .padding(10)
            }
        } detail: {
            Group {
                if !model.hasData && model.lastScan != nil {
                    EmptyStateView()
                } else {
                    detail(for: model.selection ?? .live)
                }
            }
            .navigationTitle(model.selection?.title ?? "S2A Claude X-Ray")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    if model.selection != .live && model.selection != .trace {
                        Picker("Период", selection: $model.period) {
                            ForEach(Period.allCases) { period in
                                Text(period.title).tag(period)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 420)
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await model.rescan() }
                    } label: {
                        Label("Обновить", systemImage: "arrow.clockwise")
                    }
                    .help("Перечитать новые записи (⌘R)")
                    .disabled(model.isScanning)
                }
            }
        }
    }

    @ViewBuilder
    private func detail(for item: SidebarItem) -> some View {
        switch item {
        case .live: LiveView()
        case .trace: TraceView()
        case .overview: OverviewView()
        case .sessions: SessionsView()
        case .projects: BreakdownView(dimension: .project)
        case .models: BreakdownView(dimension: .model)
        case .insights: InsightsView()
        case .reports: ReportsView()
        }
    }
}

/// Footer of the sidebar: when the data was last read.
struct ScanStatusView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            if model.isScanning {
                ProgressView().controlSize(.small)
                Text("Чтение логов…")
            } else if let last = model.lastScan {
                Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(Palette.good)
                Text("Обновлено \(last.formatted(date: .omitted, time: .standard))")
            } else {
                Text("Ожидание…")
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .help("Записей: \(model.priced.count). Новые строки логов подхватываются автоматически.")
    }
}
