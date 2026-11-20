import SwiftUI
import UniformTypeIdentifiers
import XRayCore

/// The iPad's version of the Mac's "no logs" screen: X-Ray needs a computer to read from, or
/// the computer has nothing yet.
struct SourcesHelpView: View {
    @Environment(AppModel.self) private var model
    @Environment(DesktopSync.self) private var sync
    let title: String
    let systemImage: String
    var message: String? = nil

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                VStack(spacing: 8) {
                    Image(systemName: sync.computers.isEmpty ? "ipad.and.arrow.forward" : systemImage)
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 4)
                    Text(sync.computers.isEmpty ? L("Подключите компьютер") : title)
                        .font(.title2.weight(.semibold))
                    Text(subtitle)
                        .foregroundStyle(.secondary)
                    if let message, !sync.computers.isEmpty {
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: 560)
                    }
                }
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 28)

                if !sync.computers.isEmpty {
                    Card(title: L("Компьютеры")) {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(sync.computers) { computer in
                                ComputerRow(computer: computer, status: sync.status[computer.id])
                            }
                        }
                    }
                }
                ConnectStepsCard()
            }
            .frame(maxWidth: 720)
            .padding(20)
            .frame(maxWidth: .infinity)
        }
    }

    private var subtitle: String {
        if sync.computers.isEmpty {
            return L("X-Ray на iPad показывает логи Claude Code ваших компьютеров: Mac или Windows с X-Ray 0.9 или новее.")
        }
        if case .downloading(let done, let total, _) = sync.summaryState {
            return L("Скачиваются логи: \(done) из \(total).")
        }
        guard let newest = model.newestTranscript else {
            return L("С компьютеров пока не пришло ни одного лога.")
        }
        return L("Последняя запись в логах: \(Fmt.dateTime(newest)), \(Fmt.ago(model.now.timeIntervalSince(newest))).")
    }
}

/// How to connect the iPad to a computer.
struct ConnectStepsCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card(title: L("Как подключить")) {
            VStack(alignment: .leading, spacing: 10) {
                step("1.circle", L("На компьютере установите X-Ray 0.9 или новее (Mac или Windows) и откройте «Настройки → iPad»."))
                step("2.circle", L("Включите «Разрешить iPad читать логи». Если облачные сессии ещё не подключены, сделайте X-Ray доступным через Tailscale: `tailscale funnel --bg 47318`."))
                step("3.circle", L("Наведите камеру iPad на QR-код и откройте ссылку в X-Ray. Или скопируйте ссылку и вставьте её здесь: «Настройки → Добавить компьютер»."))
                Button {
                    model.selection = .settings
                } label: {
                    Label(L("Открыть настройки"), systemImage: "gearshape")
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
            }
            .font(.callout)
        }
    }

    private func step(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon).foregroundStyle(Palette.accent).frame(width: 22)
            Text(LocalizedStringKey(text)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The iPad's version of the account-limits hint: the limits come from a computer whose X-Ray
/// is connected to Claude Code's status line.
struct AccountLimitsSetup: View {
    var body: some View {
        Text(L("Реальный процент 5‑часового и недельного лимита аккаунта приходит с компьютера, где X-Ray подключён к строке статуса Claude Code: «Настройки → Лимиты аккаунта» в X-Ray на Mac или Windows. Цифры появятся здесь после следующего ответа Claude Code там."))
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The visual report of the selected period, shared as PDF or as data (Markdown, CSV).
struct ReportsView: View {
    @Environment(AppModel.self) private var model
    @State private var status: String?

    var body: some View {
        let stamp = Fmt.isoDay(model.now)
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ShareLink(
                    item: ReportFile(kind: .pdf, model: model),
                    preview: SharePreview(L("S2A Claude X-Ray — отчёт \(stamp).pdf"), image: Image(systemName: "doc.richtext"))
                ) {
                    Label(L("Поделиться PDF"), systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)

                Menu {
                    ShareLink(item: ReportFile(kind: .markdown, model: model), preview: SharePreview("claude-xray-\(stamp).md")) {
                        Label("Markdown", systemImage: "doc.text")
                    }
                    ShareLink(item: ReportFile(kind: .dailyCSV, model: model), preview: SharePreview("claude-xray-daily-\(stamp).csv")) {
                        Label(L("CSV по дням"), systemImage: "tablecells")
                    }
                    ShareLink(item: ReportFile(kind: .sessionsCSV, model: model), preview: SharePreview("claude-xray-sessions-\(stamp).csv")) {
                        Label(L("CSV по сессиям"), systemImage: "tablecells")
                    }
                    Divider()
                    Button {
                        Clipboard.copy(ReportFile.markdown(model))
                        status = L("Отчёт скопирован в буфер обмена")
                    } label: {
                        Label(L("Копировать как Markdown"), systemImage: "doc.on.doc")
                    }
                } label: {
                    Label(L("Данные"), systemImage: "tablecells")
                }
                .buttonStyle(.bordered)

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
}

/// A report file made when the user picks where to share it, not before.
struct ReportFile: Transferable {
    enum Kind: Sendable { case pdf, markdown, dailyCSV, sessionsCSV }

    let kind: Kind
    let model: AppModel

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .pdf) { file in
            try await file.data()
        }
        .exportingCondition { $0.kind == .pdf }
        .suggestedFileName { $0.fileName }
        DataRepresentation(exportedContentType: UTType(filenameExtension: "md") ?? .plainText) { file in
            try await file.data()
        }
        .exportingCondition { $0.kind == .markdown }
        .suggestedFileName { $0.fileName }
        DataRepresentation(exportedContentType: .commaSeparatedText) { file in
            try await file.data()
        }
        .exportingCondition { $0.kind == .dailyCSV || $0.kind == .sessionsCSV }
        .suggestedFileName { $0.fileName }
    }

    var fileName: String {
        let stamp = Fmt.isoDay(Date())
        switch kind {
        case .pdf: return L("S2A Claude X-Ray — отчёт \(stamp).pdf")
        case .markdown: return "claude-xray-\(stamp).md"
        case .dailyCSV: return "claude-xray-daily-\(stamp).csv"
        case .sessionsCSV: return "claude-xray-sessions-\(stamp).csv"
        }
    }

    enum Failure: Error { case pdf }

    @MainActor
    func data() throws -> Data {
        switch kind {
        case .pdf:
            guard let data = ReportPDF.data(for: model) else { throw Failure.pdf }
            return data
        case .markdown:
            return Data(Self.markdown(model).utf8)
        case .dailyCSV:
            return Data(ReportExporter.dailyCSV(model.periodEvents).utf8)
        case .sessionsCSV:
            return Data(ReportExporter.sessionsCSV(SessionAnalytics.sessions(model.periodEvents)).utf8)
        }
    }

    @MainActor
    static func markdown(_ model: AppModel) -> String {
        let events = model.periodEvents
        return ReportExporter.markdown(
            title: L("S2A Claude X-Ray — отчёт об использовании Claude Code"),
            periodLabel: model.period.title,
            events: events,
            insights: InsightEngine(pricing: model.pricing).analyze(events)
        )
    }
}
