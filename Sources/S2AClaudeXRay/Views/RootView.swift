import SwiftUI
import XRayCore

struct RootView: View {
    @Environment(AppModel.self) private var model
    #if os(iOS)
    @Environment(DesktopSync.self) private var sync
    #endif

    var body: some View {
        @Bindable var model = model

        NavigationSplitView {
            List(selection: $model.selection) {
                ForEach(SidebarItem.screens) { item in
                    Label(item.title, systemImage: item.systemImage)
                }
                #if os(iOS)
                Section {
                    Label(SidebarItem.settings.title, systemImage: SidebarItem.settings.systemImage)
                        .tag(SidebarItem.settings)
                }
                #endif
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
            .scrollContentBackground(Palette.sidebar == nil ? .automatic : .hidden)
            .background(Palette.sidebar ?? Color.clear)
            .safeAreaInset(edge: .top) {
                BrandHeader()
            }
            .safeAreaInset(edge: .bottom) {
                #if os(iOS)
                SyncStatusFooter()
                    .padding(10)
                #else
                ScanStatusView()
                    .padding(10)
                #endif
            }
        } detail: {
            #if os(iOS)
            // A stack in the detail column: the session list pushes a session's details, the
            // settings their pages. A new screen in the sidebar starts from its root again.
            NavigationStack(path: $model.detailPath) {
                detailContent
            }
            .onChange(of: model.selection) { _, _ in
                model.detailPath = NavigationPath()
            }
            #else
            detailContent
            #endif
        }
    }

    private var detailContent: some View {
        @Bindable var model = model
        return Group {
            if isSettings {
                detail(for: model.selection ?? .live)
            } else if !model.hasData && model.lastScan != nil {
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
        #if os(macOS)
        .dropDestination(for: URL.self) { urls, _ in
            // Session logs dropped on the window, for example from a cloud session.
            model.importTranscripts(urls) > 0
        }
        #else
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .principal) {
                if model.selection != .live && model.selection != .trace && !isSettings {
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
                if !isSettings {
                    Button {
                        refresh()
                    } label: {
                        Label(L("Обновить"), systemImage: "arrow.clockwise")
                    }
                    .help(L("Перечитать новые записи (⌘R)"))
                    #if os(iOS)
                    .keyboardShortcut("r", modifiers: .command)
                    #endif
                    .disabled(model.isScanning)
                }
            }
        }
    }

    private var isSettings: Bool {
        #if os(iOS)
        return model.selection == .settings
        #else
        return false
        #endif
    }

    private func refresh() {
        #if os(iOS)
        // On the iPad new lines come from the computers: ask them first.
        sync.syncNow()
        #else
        Task { await model.rescan() }
        #endif
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
        #if os(iOS)
        case .settings: IPadSettingsView()
        #endif
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
