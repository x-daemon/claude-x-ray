import AppKit
import SwiftUI
import UniformTypeIdentifiers
import XRayCore

/// The visual report of the selected period, with PDF export and the data exports (Markdown, CSV).
struct ReportsView: View {
    @Environment(AppModel.self) private var model
    @State private var status: String?

    var body: some View {
        let stamp = Fmt.isoDay(model.now)

        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    savePDF(name: "S2A Claude X-Ray — отчёт \(stamp).pdf")
                } label: {
                    Label("Сохранить PDF…", systemImage: "doc.richtext")
                }
                .keyboardShortcut("s", modifiers: .command)

                Menu {
                    Button("Markdown…") {
                        save(markdown(), name: "claude-xray-\(stamp).md", type: UTType(filenameExtension: "md") ?? .plainText)
                    }
                    Button("CSV по дням…") {
                        save(ReportExporter.dailyCSV(model.periodEvents), name: "claude-xray-daily-\(stamp).csv", type: .commaSeparatedText)
                    }
                    Button("CSV по сессиям…") {
                        save(ReportExporter.sessionsCSV(SessionAnalytics.sessions(model.periodEvents)), name: "claude-xray-sessions-\(stamp).csv", type: .commaSeparatedText)
                    }
                    Divider()
                    Button("Копировать как Markdown") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(markdown(), forType: .string)
                        status = "Отчёт скопирован в буфер обмена"
                    }
                } label: {
                    Label("Данные", systemImage: "tablecells")
                }
                .fixedSize()

                Spacer()
                if let status {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            Divider()

            ScrollView {
                ReportDocument()
                    .frame(maxWidth: 1180)
                    .padding(20)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func markdown() -> String {
        let events = model.periodEvents
        return ReportExporter.markdown(
            title: "S2A Claude X-Ray — отчёт об использовании Claude Code",
            periodLabel: model.period.title,
            events: events,
            insights: InsightEngine(pricing: model.pricing).analyze(events)
        )
    }

    private func savePDF(name: String) {
        guard let data = ReportPDF.data(for: model) else {
            status = "Не удалось построить PDF"
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
            status = "Сохранено: \(url.lastPathComponent)"
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            status = "Не удалось сохранить: \(error.localizedDescription)"
        }
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
