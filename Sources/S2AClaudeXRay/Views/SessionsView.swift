import Charts
import SwiftUI
import XRayCore

/// Sortable table of sessions with a detail pane for the selected one.
struct SessionsView: View {
    @Environment(AppModel.self) private var model
    @State private var sortOrder = [KeyPathComparator(\SessionSummary.cost, order: .reverse)]
    @State private var query = ""

    var body: some View {
        @Bindable var model = model
        let events = model.periodEvents
        let sessions = SessionAnalytics.sessions(events)
        let rows = filter(sessions).sorted(using: sortOrder)

        #if os(macOS)
        VSplitView {
            Table(rows, selection: $model.selectedSessionID, sortOrder: $sortOrder) {
                TableColumn(L("Начало"), value: \.start) { session in
                    Text(Fmt.dateTime(session.start)).monospacedDigit()
                }
                .width(min: 90, ideal: 100)
                TableColumn(L("Проект"), value: \.projectName)
                TableColumn(L("Ветка")) { session in
                    Text(session.gitBranch ?? "—").foregroundStyle(.secondary)
                }
                TableColumn(L("Модели")) { session in
                    Text(session.modelsLabel)
                }
                TableColumn(L("Длительность"), value: \.duration) { session in
                    Text(Fmt.duration(session.duration)).monospacedDigit()
                }
                TableColumn(L("Запросы"), value: \.requests) { session in
                    Text("\(session.requests)").monospacedDigit()
                }
                TableColumn(L("Пик контекста"), value: \.peakContextTokens) { session in
                    Text(Fmt.tokens(session.peakContextTokens)).monospacedDigit()
                }
                TableColumn(L("Кэш"), value: \.cacheHitRate) { session in
                    Text(Fmt.percent(session.cacheHitRate)).monospacedDigit()
                }
                TableColumn("USD", value: \.cost) { session in
                    Text(Fmt.usd(session.cost)).monospacedDigit()
                }
            }
            .frame(maxWidth: .infinity, minHeight: 220, maxHeight: .infinity)

            Group {
                if let id = model.selectedSessionID, let session = sessions.first(where: { $0.id == id }) {
                    SessionDetailView(session: session, events: events.filter { $0.event.sessionID == id })
                } else {
                    ContentUnavailableView(L("Выберите сессию"), systemImage: "cursorarrow.click", description: Text(L("Детали, рост контекста и стоимость каждого запроса.")))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 240, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .searchable(text: $query, prompt: L("Проект, ветка или модель"))
        #else
        // iPad: a list; a tap opens the session's details.
        List {
            Section {
                ForEach(rows) { session in
                    NavigationLink(value: SessionRoute(id: session.id)) {
                        SessionRow(session: session)
                    }
                    .listRowBackground(Palette.card)
                }
            } header: {
                HStack {
                    Text(Fmt.plural(rows.count, "сессия", "сессии", "сессий"))
                    Spacer()
                    SessionSortMenu(sortOrder: $sortOrder)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(Palette.page == nil ? .automatic : .hidden)
        .overlay {
            if rows.isEmpty {
                ContentUnavailableView(query.isEmpty ? L("Нет сессий за этот период") : L("Ничего не найдено"), systemImage: "list.bullet.rectangle")
            }
        }
        .navigationDestination(for: SessionRoute.self) { route in
            if let session = sessions.first(where: { $0.id == route.id }) {
                SessionDetailView(session: session, events: events.filter { $0.event.sessionID == route.id })
                    .navigationTitle(session.projectName)
                    .background { Palette.page?.ignoresSafeArea() }
            } else {
                ContentUnavailableView(L("Сессии нет в выбранном периоде"), systemImage: "list.bullet.rectangle")
            }
        }
        .searchable(text: $query, prompt: L("Проект, ветка или модель"))
        #endif
    }

    private func filter(_ sessions: [SessionSummary]) -> [SessionSummary] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return sessions }
        return sessions.filter {
            $0.projectPath.localizedCaseInsensitiveContains(needle)
                || ($0.gitBranch ?? "").localizedCaseInsensitiveContains(needle)
                || $0.modelsLabel.localizedCaseInsensitiveContains(needle)
        }
    }
}

struct SessionDetailView: View {
    let session: SessionSummary
    let events: [PricedEvent]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text(session.projectPath).font(.headline).textSelection(.enabled)
                    Spacer()
                    Text("\(Fmt.dateTime(session.start)) – \(Fmt.dateTime(session.end))").foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    StatTile(title: L("Стоимость"), value: Fmt.usd(session.cost), caption: L("\(Fmt.usd(session.summary.costPerRequest)) за запрос"))
                    StatTile(title: L("Токены"), value: Fmt.tokens(session.totalTokens), caption: L("вывод \(Fmt.tokens(session.summary.tokens.output))"))
                    StatTile(title: L("Пик контекста"), value: Fmt.tokens(session.peakContextTokens), caption: L("средний \(Fmt.tokens(Int(session.summary.averageContextTokens)))"))
                    StatTile(title: L("Кэш"), value: Fmt.percent(session.cacheHitRate), caption: L("запись \(Fmt.usd(session.summary.cost.cacheWrite))"))
                    StatTile(title: L("Субагенты"), value: Fmt.usd(session.sidechainCost), caption: session.cost > 0 ? Fmt.percent(session.sidechainCost / session.cost) + L(" стоимости") : nil)
                }

                Card(title: L("Рост контекста"), subtitle: L("токенов в промпте на каждый запрос")) {
                    Chart(events) { priced in
                        LineMark(
                            x: .value(L("Время"), priced.event.timestamp),
                            y: .value(L("Контекст"), Double(priced.event.tokens.contextTokens))
                        )
                        .foregroundStyle(by: .value(L("Тип"), priced.event.isSidechain ? L("Субагент") : L("Основная сессия")))
                        .lineStyle(StrokeStyle(lineWidth: 2))
                    }
                    .chartForegroundStyleScale(domain: [L("Основная сессия"), L("Субагент")], range: [Palette.model, Palette.subagent])
                    .tokenYAxis()
                    .frame(height: 170)
                }

                Card(title: L("Стоимость запросов"), subtitle: L("запись в кэш выделена отдельно")) {
                    Chart(events) { priced in
                        BarMark(
                            x: .value(L("Время"), priced.event.timestamp),
                            y: .value("USD", priced.cost.total - priced.cost.cacheWrite),
                            width: .fixed(4)
                        )
                        .foregroundStyle(by: .value(L("Статья"), L("Остальное")))
                        BarMark(
                            x: .value(L("Время"), priced.event.timestamp),
                            y: .value("USD", priced.cost.cacheWrite),
                            width: .fixed(4)
                        )
                        .foregroundStyle(by: .value(L("Статья"), L("Запись в кэш")))
                    }
                    .chartForegroundStyleScale(domain: [L("Остальное"), L("Запись в кэш")], range: [Palette.primary, Palette.component(L("Запись в кэш"))])
                    .usdYAxis()
                    .frame(height: 150)
                }
            }
            .padding(16)
        }
    }
}

#if os(iOS)
/// A session opened from the iPad's list.
struct SessionRoute: Hashable {
    let id: String
}

/// One session in the iPad's list: project, cost, when, how long and how big.
struct SessionRow: View {
    let session: SessionSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(session.projectName).font(.headline).lineLimit(1)
                if let branch = session.gitBranch {
                    Text(branch).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(Fmt.usd(session.cost)).font(.headline).monospacedDigit()
            }
            HStack(spacing: 10) {
                Text(Fmt.dateTime(session.start))
                Text(Fmt.duration(session.duration))
                Text(Fmt.plural(session.requests, "запрос", "запроса", "запросов"))
                Text(L("контекст до \(Fmt.tokens(session.peakContextTokens))"))
                Text(L("кэш \(Fmt.percent(session.cacheHitRate))"))
                Spacer(minLength: 0)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
            Text(session.modelsLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }
}

/// How the iPad's session list is sorted.
struct SessionSortMenu: View {
    @Binding var sortOrder: [KeyPathComparator<SessionSummary>]

    var body: some View {
        Menu {
            Button(L("По стоимости")) { sortOrder = [KeyPathComparator(\SessionSummary.cost, order: .reverse)] }
            Button(L("Сначала новые")) { sortOrder = [KeyPathComparator(\SessionSummary.start, order: .reverse)] }
            Button(L("По длительности")) { sortOrder = [KeyPathComparator(\SessionSummary.duration, order: .reverse)] }
            Button(L("По числу запросов")) { sortOrder = [KeyPathComparator(\SessionSummary.requests, order: .reverse)] }
            Button(L("По пику контекста")) { sortOrder = [KeyPathComparator(\SessionSummary.peakContextTokens, order: .reverse)] }
        } label: {
            Label(L("Сортировка"), systemImage: "arrow.up.arrow.down")
                .font(.caption)
        }
    }
}
#endif
