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
