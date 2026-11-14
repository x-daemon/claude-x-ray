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
                TableColumn("Начало", value: \.start) { session in
                    Text(Fmt.dateTime(session.start)).monospacedDigit()
                }
                .width(min: 90, ideal: 100)
                TableColumn("Проект", value: \.projectName)
                TableColumn("Ветка") { session in
                    Text(session.gitBranch ?? "—").foregroundStyle(.secondary)
                }
                TableColumn("Модели") { session in
                    Text(session.modelsLabel)
                }
                TableColumn("Длительность", value: \.duration) { session in
                    Text(Fmt.duration(session.duration)).monospacedDigit()
                }
                TableColumn("Запросы", value: \.requests) { session in
                    Text("\(session.requests)").monospacedDigit()
                }
                TableColumn("Пик контекста", value: \.peakContextTokens) { session in
                    Text(Fmt.tokens(session.peakContextTokens)).monospacedDigit()
                }
                TableColumn("Кэш", value: \.cacheHitRate) { session in
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
                    ContentUnavailableView("Выберите сессию", systemImage: "cursorarrow.click", description: Text("Детали, рост контекста и стоимость каждого запроса."))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 240, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .searchable(text: $query, prompt: "Проект, ветка или модель")
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
                    StatTile(title: "Стоимость", value: Fmt.usd(session.cost), caption: "\(Fmt.usd(session.summary.costPerRequest)) за запрос")
                    StatTile(title: "Токены", value: Fmt.tokens(session.totalTokens), caption: "вывод \(Fmt.tokens(session.summary.tokens.output))")
                    StatTile(title: "Пик контекста", value: Fmt.tokens(session.peakContextTokens), caption: "средний \(Fmt.tokens(Int(session.summary.averageContextTokens)))")
                    StatTile(title: "Кэш", value: Fmt.percent(session.cacheHitRate), caption: "запись \(Fmt.usd(session.summary.cost.cacheWrite))")
                    StatTile(title: "Субагенты", value: Fmt.usd(session.sidechainCost), caption: session.cost > 0 ? Fmt.percent(session.sidechainCost / session.cost) + " стоимости" : nil)
                }

                Card(title: "Рост контекста", subtitle: "токенов в промпте на каждый запрос") {
                    Chart(events) { priced in
                        LineMark(
                            x: .value("Время", priced.event.timestamp),
                            y: .value("Контекст", Double(priced.event.tokens.contextTokens))
                        )
                        .foregroundStyle(by: .value("Тип", priced.event.isSidechain ? "Субагент" : "Основная сессия"))
                        .lineStyle(StrokeStyle(lineWidth: 2))
                    }
                    .chartForegroundStyleScale(domain: ["Основная сессия", "Субагент"], range: [Palette.series[0], Palette.series[1]])
                    .tokenYAxis()
                    .frame(height: 170)
                }

                Card(title: "Стоимость запросов", subtitle: "запись в кэш выделена отдельно") {
                    Chart(events) { priced in
                        BarMark(
                            x: .value("Время", priced.event.timestamp),
                            y: .value("USD", priced.cost.total - priced.cost.cacheWrite),
                            width: .fixed(4)
                        )
                        .foregroundStyle(by: .value("Статья", "Остальное"))
                        BarMark(
                            x: .value("Время", priced.event.timestamp),
                            y: .value("USD", priced.cost.cacheWrite),
                            width: .fixed(4)
                        )
                        .foregroundStyle(by: .value("Статья", "Запись в кэш"))
                    }
                    .chartForegroundStyleScale(domain: ["Остальное", "Запись в кэш"], range: [Palette.series[0], Palette.series[3]])
                    .usdYAxis()
                    .frame(height: 150)
                }
            }
            .padding(16)
        }
    }
}
