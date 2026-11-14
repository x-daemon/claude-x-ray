import AppKit
import SwiftUI
import UniformTypeIdentifiers
import XRayCore

/// Report preview and export (Markdown, CSV).
struct ReportsView: View {
    @Environment(AppModel.self) private var model
    @State private var status: String?

    var body: some View {
        let events = model.periodEvents
        let insights = InsightEngine(pricing: model.pricing).analyze(events)
        let markdown = ReportExporter.markdown(
            title: "S2A Claude X-Ray — отчёт об использовании Claude Code",
            periodLabel: model.period.title,
            events: events,
            insights: insights
        )
        let stamp = Fmt.isoDay(model.now)

        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button {
                    save(markdown, name: "claude-xray-\(stamp).md", type: UTType(filenameExtension: "md") ?? .plainText)
                } label: {
                    Label("Markdown…", systemImage: "doc.richtext")
                }
                Button {
                    save(ReportExporter.dailyCSV(events), name: "claude-xray-daily-\(stamp).csv", type: .commaSeparatedText)
                } label: {
                    Label("CSV по дням…", systemImage: "tablecells")
                }
                Button {
                    save(ReportExporter.sessionsCSV(SessionAnalytics.sessions(events)), name: "claude-xray-sessions-\(stamp).csv", type: .commaSeparatedText)
                } label: {
                    Label("CSV по сессиям…", systemImage: "list.bullet.rectangle")
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(markdown, forType: .string)
                    status = "Отчёт скопирован в буфер обмена"
                } label: {
                    Label("Копировать", systemImage: "doc.on.doc")
                }
                Spacer()
                if let status {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            }

            Text("Период: \(model.period.title). Отчёт строится только из локальных логов, ничего не отправляется в сеть.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView {
                Text(markdown)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Palette.card))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.hairline))
        }
        .padding(20)
    }

    private func save(_ text: String, name: String, type: UTType) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            status = "Сохранено: \(url.lastPathComponent)"
        } catch {
            status = "Не удалось сохранить: \(error.localizedDescription)"
        }
    }
}
