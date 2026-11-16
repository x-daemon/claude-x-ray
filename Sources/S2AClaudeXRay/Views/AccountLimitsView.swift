import AppKit
import SwiftUI
import UniformTypeIdentifiers
import XRayCore

/// The account's real plan limits, as Claude Code reports them to its status line. They count
/// everything that draws on the subscription: chats, cloud sessions, Cowork and this Mac.
struct AccountLimitsCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let now = model.now
        Card(title: "Лимиты аккаунта", subtitle: subtitle(now: now)) {
            if let usage = model.planUsage, !usage.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 28) {
                        if let window = usage.fiveHour {
                            LimitGauge(title: "5‑часовое окно", window: window, now: now)
                        }
                        if let window = usage.sevenDay {
                            LimitGauge(title: "Неделя", window: window, now: now)
                        }
                        if let spend = usage.spendLimit {
                            SpendGauge(spend: spend)
                        }
                    }
                    Text("Учитывает всё, что расходует подписку: чаты, облачные сессии, Cowork и сессии на этом Mac. Claude Code обновляет эти цифры после каждого своего ответа в Терминале на этом Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if now.timeIntervalSince(usage.capturedAt) > 3600 {
                        Label("Цифры на \(Fmt.dateTime(usage.capturedAt)). Обновятся после следующего ответа Claude Code на этом Mac.", systemImage: "clock.arrow.circlepath")
                            .font(.caption)
                            .foregroundStyle(Palette.warning)
                    }
                }
            } else {
                AccountLimitsSetup()
            }
        }
    }

    private func subtitle(now: Date) -> String? {
        guard let usage = model.planUsage else { return "из Claude Code" }
        return "из Claude Code · \(Fmt.ago(now.timeIntervalSince(usage.capturedAt)))"
    }
}

/// One limit window: used share, bar and reset time.
struct LimitGauge: View {
    let title: String
    let window: PlanUsage.Window
    let now: Date

    var body: some View {
        let fraction = window.fraction(at: now)
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Fmt.percent(fraction))
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("использовано").font(.caption).foregroundStyle(.secondary)
            }
            UsageBar(fraction: fraction, color: LimitGauge.color(for: fraction))
            Text(resetText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var resetText: String {
        if window.hasReset(at: now) {
            return "окно сброшено \(Fmt.dateTime(window.resetsAt))"
        }
        return "сброс \(Fmt.dateTime(window.resetsAt)) · через \(Fmt.span(window.resetsAt.timeIntervalSince(now)))"
    }

    static func color(for fraction: Double) -> Color {
        if fraction >= 0.9 { return Palette.critical }
        if fraction >= 0.7 { return Palette.warning }
        return Palette.accent
    }
}

/// Spend cap of a Claude apps gateway.
struct SpendGauge: View {
    let spend: PlanUsage.SpendLimit

    var body: some View {
        let fraction = min(max(spend.usedPercentage / 100, 0), 1)
        VStack(alignment: .leading, spacing: 6) {
            Text("Лимит расходов").font(.caption).foregroundStyle(.secondary)
            Text(Fmt.percent(fraction))
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .monospacedDigit()
            UsageBar(fraction: fraction, color: LimitGauge.color(for: fraction))
            if let used = spend.usedUSD, let limit = spend.limitUSD {
                Text("\(Fmt.usd(used)) из \(Fmt.usd(limit))").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Shown until Claude Code has reported plan usage: how to connect, or that it is connected.
struct AccountLimitsSetup: View {
    @Environment(AppModel.self) private var model
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch model.statusLineState {
            case .installed:
                Label("Подключено. Цифры появятся после первого ответа Claude Code в Терминале на этом Mac: `claude` или `claude --remote-control`.", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            case .unreadable(let message):
                Text("Не удалось прочитать настройки Claude Code: \(message)")
                    .foregroundStyle(Palette.critical)
            default:
                Text("Реальный процент 5‑часового и недельного лимита всего аккаунта, включая чаты, облачные сессии и Cowork. Claude Code сообщает его своей строке статуса; X-Ray подключается к ней и запоминает цифры.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Подключить") {
                        error = model.installStatusLine()
                    }
                    SettingsLink { Text("Подробнее…") }
                }
                .controlSize(.small)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(Palette.critical)
            }
        }
        .font(.callout)
    }
}

/// Settings tab: connect X-Ray to Claude Code's status line, and import transcripts.
struct AccountLimitsSettings: View {
    @Environment(AppModel.self) private var model
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Claude Code после каждого ответа передаёт строке статуса процент 5‑часового и недельного лимита вашего аккаунта. Это реальные цифры подписки: они учитывают чаты, облачные сессии, Cowork и сессии на этом Mac. X-Ray подключается к строке статуса, запоминает эти цифры и показывает их на экране «Сейчас» и в строке меню.")
                .fixedSize(horizontal: false, vertical: true)

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    stateRow
                    HStack(spacing: 8) {
                        switch model.statusLineState {
                        case .installed:
                            Button("Отключить") { error = model.uninstallStatusLine() }
                        case .unreadable:
                            EmptyView()
                        default:
                            Button("Подключить") { error = model.installStatusLine() }
                                .keyboardShortcut(.defaultAction)
                        }
                        Spacer()
                    }
                    if let error {
                        Text(error).font(.caption).foregroundStyle(Palette.critical)
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let usage = model.planUsage {
                Text(lastReport(usage))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("X-Ray меняет только `statusLine` в \((StatusLineInstaller.settingsURL.path as NSString).abbreviatingWithTildeInPath), а прежний файл сохраняет рядом как settings.json.xray-backup. Строку статуса выполняет Claude Code в Терминале, в том числе с Remote Control. Если там уже была своя строка статуса, X-Ray оставляет её на экране и только запоминает цифры лимитов.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Text("Облачные сессии")
                .font(.headline)
            Text("Логи облачных сессий (claude.ai/code, мобильное приложение, облачная среда Claude Desktop) остаются на серверах Anthropic. Попросите сессию прислать свой лог («пришли лог сессии для X-Ray») и перетащите файл в окно X-Ray или импортируйте его здесь: сессия появится со всеми токенами, инструментами и стоимостью.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Импортировать лог сессии…") {
                TranscriptImportPanel.run(model: model)
            }
            Spacer()
        }
        .padding(20)
        .onAppear { model.refreshStatusLineState() }
    }

    @ViewBuilder
    private var stateRow: some View {
        switch model.statusLineState {
        case .notInstalled:
            Label("Не подключено", systemImage: "circle.dashed")
        case .otherStatusLine(let command):
            VStack(alignment: .leading, spacing: 4) {
                Label("Не подключено. Сейчас в Claude Code своя строка статуса, X-Ray её сохранит:", systemImage: "circle.dashed")
                Text(command).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
        case .installed(let wrapping):
            VStack(alignment: .leading, spacing: 4) {
                Label("Подключено", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Palette.good)
                if let wrapping {
                    Text("Ваша строка статуса по-прежнему показывается: \(wrapping)")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        case .unreadable(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Palette.critical)
        }
    }

    private func lastReport(_ usage: PlanUsage) -> String {
        var parts = ["Последние цифры: \(Fmt.dateTime(usage.capturedAt))"]
        if let window = usage.fiveHour {
            parts.append("5 ч \(Fmt.percent(window.fraction(at: model.now)))")
        }
        if let window = usage.sevenDay {
            parts.append("неделя \(Fmt.percent(window.fraction(at: model.now)))")
        }
        if let source = usage.model {
            parts.append("из сессии \(source)" + (usage.version.map { ", Claude Code \($0)" } ?? ""))
        }
        return parts.joined(separator: " · ")
    }
}

/// File picker for transcripts to import.
@MainActor
enum TranscriptImportPanel {
    static func run(model: AppModel) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        var types: [UTType] = [.zip]
        if let jsonl = UTType(filenameExtension: "jsonl") {
            types.insert(jsonl, at: 0)
        }
        panel.allowedContentTypes = types
        panel.message = "Логи сессий Claude Code (.jsonl) или архивы .zip с ними"
        panel.prompt = "Импортировать"
        guard panel.runModal() == .OK else { return }
        model.importTranscripts(panel.urls)
    }
}
