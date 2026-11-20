import SwiftUI
import XRayCore

/// Settings tab: receive cloud sessions' transcripts live through a tunnel to this Mac.
struct CloudReceiverSettings: View {
    @Environment(AppModel.self) private var model
    @State private var portText = ""
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(L("Облачные сессии Claude Code могут сами отправлять сюда свой лог после каждого шага: промпты, ответы, размышления, вызовы инструментов, контекст и токены каждого запроса. X-Ray покажет их так же подробно, как сессии на этом Mac, почти вживую."))
                    .fixedSize(horizontal: false, vertical: true)

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle(L("Принимать логи облачных сессий"), isOn: Binding(
                            get: { model.receiverEnabled },
                            set: { model.setReceiverEnabled($0) }
                        ))
                        statusRow
                        HStack(spacing: 8) {
                            Text(L("Порт")).foregroundStyle(.secondary)
                            TextField("47318", text: $portText)
                                .frame(width: 80)
                                .onSubmit { applyPort() }
                            Text(L("приём только с этого Mac (127.0.0.1); снаружи — через туннель"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 8) {
                            Text(L("Токен доступа")).foregroundStyle(.secondary)
                            Text(masked(model.receiverToken))
                                .font(.system(.body, design: .monospaced))
                            Button(copied ? L("Скопировано") : L("Скопировать")) {
                                Clipboard.copy(model.receiverToken)
                                copied = true
                            }
                            Button(L("Новый")) {
                                model.regenerateReceiverToken()
                                copied = false
                            }
                            .help(L("Создать новый токен. Старый перестанет приниматься."))
                        }
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Text(L("Как подключить")).font(.headline)
                step(1, L("Сделайте X-Ray доступным из облака. Проще всего через Tailscale Funnel: установите Tailscale (бесплатно), войдите и выполните в Терминале команду ниже. Она напечатает адрес вида `https://ваш-mac.имя-сети.ts.net`."))
                CommandBox(command: "tailscale funnel --bg \(model.receiverPort)")
                Text(LocalizedStringKey(L("Если Tailscale установлен из App Store, команда `tailscale` лежит здесь: `/Applications/Tailscale.app/Contents/MacOS/Tailscale`.")))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                step(2, L("Напишите в облачной сессии Claude: «Подключи X-Ray: <адрес из шага 1>». Claude настроит облачную среду (вы подтвердите изменение) и попросит токен доступа через защищённую форму: вставьте туда токен отсюда. В чат токен не пишите."))
                step(3, L("Новые облачные сессии начнут присылать лог сами. Они появятся в «Сессиях», «Обзоре» и Live-трассе, а их логи лежат в `~/Library/Application Support/S2AClaudeXRay/cloud`."))

                Text(L("Лог передаётся только на ваш Mac через ваш туннель. Пока Mac спит или X-Ray закрыт, облачная сессия копит новые строки и досылает их со следующим шагом. X-Ray на нескольких компьютерах (Mac и Windows) подключается так же, по адресу каждого: облачные сессии присылают лог на все сразу, и выключенный компьютер не задерживает остальные."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
        }
        .onAppear { portText = String(model.receiverPort) }
    }

    @ViewBuilder
    private var statusRow: some View {
        let status = model.receiverStatus
        if !model.receiverEnabled {
            Label(L("Выключено"), systemImage: "pause.circle").foregroundStyle(.secondary)
        } else if let error = status.error {
            Label(L("Не удалось открыть порт \(status.port): \(error)"), systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Palette.critical)
        } else if status.listening {
            VStack(alignment: .leading, spacing: 3) {
                Label(L("Принимает на 127.0.0.1:\(status.port)"), systemImage: "dot.radiowaves.left.and.right")
                    .foregroundStyle(Palette.good)
                if let last = status.lastUpload {
                    Text(L("Последняя передача \(Fmt.dateTime(last)) · \(status.lastPath ?? "") · всего строк \(status.lines)"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(L("Облачные сессии ещё ничего не присылали."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if status.rejectedAuth > 0 {
                    Text(L("Отклонено запросов с неверным токеном: \(status.rejectedAuth)"))
                        .font(.caption)
                        .foregroundStyle(Palette.warning)
                }
            }
        } else {
            Label(L("Запускается…"), systemImage: "hourglass").foregroundStyle(.secondary)
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number)")
                .font(.callout.weight(.semibold))
                .foregroundStyle(Palette.accent)
                .frame(width: 16)
            Text(LocalizedStringKey(text))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func masked(_ token: String) -> String {
        guard token.count > 12 else { return token.isEmpty ? "—" : token }
        return String(token.prefix(9)) + "…" + String(token.suffix(4))
    }

    private func applyPort() {
        if let port = UInt16(portText.trimmingCharacters(in: .whitespaces)), port >= 1024 {
            model.setReceiverPort(port)
        }
        portText = String(model.receiverPort)
    }
}

/// A shell command with a copy button.
struct CommandBox: View {
    let command: String
    @State private var copied = false

    var body: some View {
        HStack {
            Text(command)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
            Spacer()
            Button(copied ? L("Скопировано") : L("Скопировать")) {
                Clipboard.copy(command)
                copied = true
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.emptyCell))
    }
}
