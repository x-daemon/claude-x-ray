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
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
            .scrollContentBackground(Palette.sidebar == nil ? .automatic : .hidden)
            .background(Palette.sidebar ?? Color.clear)
            .safeAreaInset(edge: .top) {
                BrandHeader()
            }
            .safeAreaInset(edge: .bottom) {
                ScanStatusView()
                    .padding(10)
            }
        } detail: {
            Group {
                if !model.hasData && model.lastScan != nil {
                    SourcesHelpView(title: L("Логи Claude Code не найдены"), systemImage: "tray")
                } else {
                    detail(for: model.selection ?? .live)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                if let page = Palette.page {
                    page.ignoresSafeArea()
                }
            }
            .navigationTitle(model.selection?.title ?? "S2A Claude X-Ray")
            .dropDestination(for: URL.self) { urls, _ in
                // Session logs dropped on the window, for example from a cloud session.
                model.importTranscripts(urls) > 0
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    if model.selection != .live && model.selection != .trace {
                        Picker(L("Период"), selection: $model.period) {
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
                        Label(L("Обновить"), systemImage: "arrow.clockwise")
                    }
                    .help(L("Перечитать новые записи (⌘R)"))
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

/// Footer of the sidebar: when the data was last read and when Claude Code last wrote a log.
struct ScanStatusView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if model.isScanning {
                    ProgressView().controlSize(.small)
                    Text(L("Чтение логов…"))
                } else if let last = model.lastScan {
                    Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(Palette.good)
                    Text(L("Обновлено \(last.localized(date: .omitted, time: .standard))"))
                } else {
                    Text(L("Ожидание…"))
                }
                Spacer()
            }
            if model.lastScan != nil {
                Text(lastLogLine)
                    .padding(.leading, 22)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .help(helpText)
    }

    private var lastLogLine: String {
        guard let newest = model.newestTranscript else { return L("Логов на этом Mac нет") }
        return L("Последний лог: \(Fmt.ago(model.now.timeIntervalSince(newest)))")
    }

    private var helpText: String {
        let files = model.lastScanResult?.filesSeen ?? 0
        return L("\(Fmt.plural(files, "лог", "лога", "логов")), \(Fmt.plural(model.priced.count, "ответ", "ответа", "ответов")) модели. Новые строки логов подхватываются автоматически. Облачные сессии сюда не попадают: их логи остаются на серверах Anthropic.")
    }
}
