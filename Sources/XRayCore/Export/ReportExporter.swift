import Foundation

/// Builds CSV and Markdown reports from analysed usage.
public enum ReportExporter {
    // MARK: CSV

    /// One row per day and model.
    public static func dailyCSV(_ events: [PricedEvent], calendar: Calendar = .current) -> String {
        var rows: [String: [String: UsageSummary]] = [:]
        for priced in events {
            let day = Fmt.isoDay(priced.event.timestamp, calendar: calendar)
            rows[day, default: [:]][priced.event.model, default: UsageSummary()].add(priced)
        }
        var lines = [
            "date,model,requests,input_tokens,output_tokens,thinking_tokens,cache_read_tokens,cache_write_5m_tokens,cache_write_1h_tokens,cache_hit_rate,api_equivalent_usd"
        ]
        for day in rows.keys.sorted() {
            for (model, s) in rows[day]!.sorted(by: { $0.key < $1.key }) {
                lines.append([
                    day, csvField(model), "\(s.requests)",
                    "\(s.tokens.input)", "\(s.tokens.output)", "\(s.tokens.thinking)",
                    "\(s.tokens.cacheRead)", "\(s.tokens.cacheWrite5m)", "\(s.tokens.cacheWrite1h)",
                    Fmt.decimal(s.tokens.cacheHitRate), Fmt.decimal(s.cost.total),
                ].joined(separator: ","))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func sessionsCSV(_ sessions: [SessionSummary]) -> String {
        var lines = [
            "session_id,project,git_branch,start,end,duration_min,models,requests,total_tokens,peak_context_tokens,cache_hit_rate,subagent_usd,api_equivalent_usd"
        ]
        let iso = ISO8601DateFormatter()
        for s in sessions {
            lines.append([
                csvField(s.id), csvField(s.projectPath), csvField(s.gitBranch ?? ""),
                iso.string(from: s.start), iso.string(from: s.end),
                Fmt.decimal(s.duration / 60, digits: 1),
                csvField(s.models.joined(separator: " ")),
                "\(s.requests)", "\(s.totalTokens)", "\(s.peakContextTokens)",
                Fmt.decimal(s.cacheHitRate), Fmt.decimal(s.sidechainCost), Fmt.decimal(s.cost),
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func csvField(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: Markdown

    public static func markdown(
        title: String,
        periodLabel: String,
        events: [PricedEvent],
        insights: [Insight],
        generatedAt: Date = Date()
    ) -> String {
        let summary = UsageSummary.of(events)
        let byModel = Analytics.group(events) { $0.model }
        let byProject = Analytics.group(events) { $0.projectName }
        let sessions = SessionAnalytics.sessions(events)
        let t = summary.tokens

        var md: [String] = []
        md.append("# \(title)")
        md.append("")
        md.append(L("Период: **\(periodLabel)** · сформирован \(Fmt.dateTime(generatedAt))"))
        md.append("")
        md.append(L("> Суммы — API-эквивалент по прайс-листу. На подписке Pro/Max они не списываются, но показывают, как быстро расходуются лимиты."))
        md.append("")
        md.append(L("## Итого"))
        md.append("")
        md.append(L("| Показатель | Значение |"))
        md.append("|---|---|")
        md.append(L("| API-эквивалент | \(Fmt.usd(summary.cost.total)) |"))
        md.append(L("| Запросов | \(summary.requests) |"))
        md.append(L("| Сессий | \(sessions.count) |"))
        md.append(L("| Токенов всего | \(Fmt.tokens(t.total)) |"))
        md.append(L("| Ввод / вывод | \(Fmt.tokens(t.input)) / \(Fmt.tokens(t.output)) |"))
        md.append(L("| Размышления (в выводе) | \(Fmt.tokens(t.thinking)) |"))
        md.append(L("| Чтение кэша / запись | \(Fmt.tokens(t.cacheRead)) / \(Fmt.tokens(t.cacheWrite)) |"))
        md.append(L("| Доля попаданий в кэш | \(Fmt.percent(t.cacheHitRate)) |"))
        md.append("")
        md.append(L("### Из чего складывается стоимость"))
        md.append("")
        md.append(L("| Статья | USD | Доля |"))
        md.append("|---|---|---|")
        let total = max(summary.cost.total, .leastNonzeroMagnitude)
        for (name, value) in [
            (L("Ввод"), summary.cost.input), (L("Вывод"), summary.cost.output),
            (L("Чтение кэша"), summary.cost.cacheRead), (L("Запись в кэш"), summary.cost.cacheWrite),
            (L("Веб-поиск"), summary.cost.webSearch),
        ] where value > 0 {
            md.append("| \(name) | \(Fmt.usd(value)) | \(Fmt.percent(value / total)) |")
        }
        md.append("")
        md.append(L("## По моделям"))
        md.append("")
        md.append(groupTable(byModel, total: total, name: { ModelCatalog.displayName(for: $0) }))
        md.append(L("## По проектам"))
        md.append("")
        md.append(groupTable(Array(byProject.prefix(15)), total: total, name: { $0 }))
        md.append(L("## Самые дорогие сессии"))
        md.append("")
        md.append(L("| Начало | Проект | Модели | Запросы | Пик контекста | USD |"))
        md.append("|---|---|---|---|---|---|")
        for s in sessions.prefix(10) {
            md.append("| \(Fmt.dateTime(s.start)) | \(s.projectName) | \(s.modelsLabel) | \(s.requests) | \(Fmt.tokens(s.peakContextTokens)) | \(Fmt.usd(s.cost)) |")
        }
        md.append("")
        md.append(L("## Оптимизация"))
        md.append("")
        if insights.isEmpty {
            md.append(L("Замечаний нет."))
        }
        for insight in insights {
            var heading = "### \(insight.severity.label): \(insight.title)"
            if let savings = insight.potentialSavings, savings > 0 {
                heading += L(" (до \(Fmt.usd(savings)))")
            }
            md.append(heading)
            md.append("")
            md.append("_\(insight.kind.label)._ \(insight.detail)")
            if let recommendation = insight.recommendation {
                md.append("")
                md.append(L("**Что сделать:** \(recommendation)"))
            }
            md.append("")
        }
        md.append("---")
        md.append("S2A Claude X-Ray")
        return md.joined(separator: "\n") + "\n"
    }

    private static func groupTable(_ groups: [GroupSummary], total: Double, name: (String) -> String) -> String {
        var lines = [L("| Название | Запросы | Токены | Кэш | USD | Доля |"), "|---|---|---|---|---|---|"]
        for g in groups {
            lines.append("| \(name(g.key)) | \(g.requests) | \(Fmt.tokens(g.totalTokens)) | \(Fmt.percent(g.cacheHitRate)) | \(Fmt.usd(g.cost)) | \(Fmt.percent(g.cost / total)) |")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
