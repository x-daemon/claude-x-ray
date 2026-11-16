import AppKit
import SwiftUI
import XRayCore

/// Explains an empty screen: which folders X-Ray reads, what they hold, when Claude Code
/// last wrote a log on this Mac, and why cloud sessions never show up here.
struct SourcesHelpView: View {
    @Environment(AppModel.self) private var model
    let title: String
    let systemImage: String
    var message: String? = nil

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                VStack(spacing: 8) {
                    Image(systemName: systemImage)
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 4)
                    Text(title)
                        .font(.title2.weight(.semibold))
                    Text(lastWriteLine)
                        .foregroundStyle(.secondary)
                    if let message {
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: 560)
                    }
                }
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 28)
                .padding(.bottom, 4)

                SourceFoldersCard()
                CloudSessionsCard()
            }
            .frame(maxWidth: 720)
            .padding(20)
            .frame(maxWidth: .infinity)
        }
    }

    private var lastWriteLine: String {
        guard let newest = model.newestTranscript else {
            return "На этом Mac пока нет ни одного лога Claude Code."
        }
        return "Последняя запись в логах на этом Mac: \(Fmt.dateTime(newest)), \(Fmt.ago(model.now.timeIntervalSince(newest)))."
    }
}

/// The folders X-Ray reads and what each one holds.
struct SourceFoldersCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card(title: "Где X-Ray ищет логи", subtitle: "транскрипты сессий, *.jsonl") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(model.sourceStats.enumerated()), id: \.offset) { _, source in
                    HStack(spacing: 10) {
                        Image(systemName: source.exists ? "folder.fill" : "folder.badge.questionmark")
                            .foregroundStyle(source.exists ? Palette.accent : Color.secondary)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text((source.directory.path as NSString).abbreviatingWithTildeInPath)
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                            Text(status(of: source))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 12)
                        if source.exists {
                            Button("Показать в Finder") {
                                NSWorkspace.shared.open(source.directory)
                            }
                            .controlSize(.small)
                        }
                    }
                }
                Divider()
                HStack(spacing: 8) {
                    SettingsLink { Text("Изменить папки…") }
                    Button("Импортировать лог…") {
                        TranscriptImportPanel.run(model: model)
                    }
                    Button("Пересканировать") {
                        Task { await model.fullRescan() }
                    }
                    Spacer()
                }
                .controlSize(.small)
            }
        }
    }

    private func status(of source: SourceStat) -> String {
        guard source.exists else { return "папки нет" }
        guard source.files > 0 else { return "логов нет" }
        var text = Fmt.plural(source.files, "лог", "лога", "логов")
        if let newest = source.newestModification {
            text += " · последний изменён \(Fmt.dateTime(newest)), \(Fmt.ago(model.now.timeIntervalSince(newest)))"
        }
        return text
    }
}

/// Why cloud sessions are missing, and how to run Claude Code so that X-Ray sees it live.
struct CloudSessionsCard: View {
    var body: some View {
        Card(title: "Облачные сессии сюда не попадают") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Сессии Claude Code в облаке (claude.ai/code, мобильное приложение Claude, облачная среда в Claude Desktop) выполняются на серверах Anthropic, и их логи остаются там. X-Ray видит только сессии, которые идут на этом Mac:")
                    .fixedSize(horizontal: false, vertical: true)
                way("terminal", "**Терминал:** `claude` в папке проекта.")
                way("macwindow", "**Claude Desktop:** сессия Code в локальной среде, а не в облачной.")
                way(
                    "antenna.radiowaves.left.and.right",
                    "**Remote Control:** `claude remote-control` в папке проекта. Сессия идёт на этом Mac, управлять ею можно из приложения Claude на телефоне или в браузере, а X-Ray показывает её вживую."
                )
                way(
                    "icloud.and.arrow.down",
                    "**Облачные сессии вживую:** «Настройки → Облако». Каждая облачная сессия сама присылает сюда свой лог после каждого шага через туннель к этому Mac."
                )
                way(
                    "square.and.arrow.down",
                    "**Разово:** попросите облачную сессию прислать свой лог («пришли лог сессии для X-Ray») и перетащите файл в окно X-Ray."
                )
                way(
                    "gauge.with.dots.needle.33percent",
                    "**Лимиты всего аккаунта**, включая облако и чаты, X-Ray берёт из строки статуса Claude Code: «Настройки → Лимиты аккаунта»."
                )
            }
            .font(.callout)
        }
    }

    private func way(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(Palette.accent)
                .frame(width: 20)
            Text(LocalizedStringKey(text))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
