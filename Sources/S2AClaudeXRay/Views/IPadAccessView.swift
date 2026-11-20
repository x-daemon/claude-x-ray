import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import XRayCore

/// Settings tab: let X-Ray on the iPad read this Mac's logs, read-only, through the same tunnel
/// that brings in cloud sessions.
struct IPadAccessSettings: View {
    @Environment(AppModel.self) private var model
    @State private var addressText = ""
    @State private var copied: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(L("X-Ray для iPad показывает всё то же, что и здесь: Live-трассу, сессии, обзор, оптимизацию и отчёты. Он копирует логи с этого Mac и считает всё сам. Доступ только на чтение и со своим токеном: токен облачных сессий читать логи не может."))
                    .fixedSize(horizontal: false, vertical: true)

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle(L("Разрешить iPad читать логи"), isOn: Binding(
                            get: { model.viewerEnabled },
                            set: { model.setViewerEnabled($0) }
                        ))
                        statusRow
                        HStack(spacing: 8) {
                            Text(L("Адрес")).foregroundStyle(.secondary)
                            TextField(model.detectedAddress ?? L("https://ваш-mac.имя-сети.ts.net"), text: $addressText)
                                .textFieldStyle(.roundedBorder)
                                .frame(minWidth: 300)
                                .onSubmit { model.setViewerAddress(addressText) }
                            Button(L("Найти")) { model.detectAddress() }
                                .help(L("Взять адрес этого Mac из Tailscale"))
                        }
                        Text(addressHint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            Text(L("Токен iPad")).foregroundStyle(.secondary)
                            Text(masked(model.viewerToken))
                                .font(.system(.body, design: .monospaced))
                            Button(copied == "token" ? L("Скопировано") : L("Скопировать")) {
                                Clipboard.copy(model.viewerToken)
                                copied = "token"
                            }
                            Button(L("Новый")) {
                                model.regenerateViewerToken()
                                copied = nil
                            }
                            .help(L("Создать новый токен. iPad придётся подключить заново."))
                        }
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if model.viewerEnabled, let link = model.viewerLink {
                    HStack(alignment: .top, spacing: 18) {
                        QRCodeView(text: link.url.absoluteString)
                            .frame(width: 180, height: 180)
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
                        VStack(alignment: .leading, spacing: 8) {
                            Text(L("Наведите камеру iPad на код")).font(.headline)
                            Text(L("Камера предложит открыть ссылку в X-Ray, и iPad подключится к этому Mac. Или скопируйте ссылку и вставьте её в X-Ray на iPad: «Настройки → Компьютеры → Добавить»."))
                                .fixedSize(horizontal: false, vertical: true)
                            Button(copied == "link" ? L("Скопировано") : L("Скопировать ссылку")) {
                                Clipboard.copy(link.url.absoluteString)
                                copied = "link"
                            }
                            Text(L("В ссылке есть токен: кто её получит, сможет читать ваши логи. Если она попала не туда, создайте новый токен."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                Text(L("Как подключить")).font(.headline)
                step(1, L("Сделайте X-Ray доступным для iPad. Если облачные сессии уже подключены, это сделано: iPad использует тот же адрес. Иначе установите Tailscale (бесплатно), войдите и выполните в Терминале команду ниже."))
                CommandBox(command: "tailscale funnel --bg \(model.receiverPort)")
                step(2, L("Установите X-Ray на iPad из Xcode: откройте `iPad/XRay.xcodeproj` из репозитория, выберите свой Apple ID в Signing и запустите на iPad. Подробно — в README."))
                step(3, L("Включите доступ выше и отсканируйте код камерой iPad. X-Ray на iPad скачает логи за выбранный период и дальше будет догружать новые строки каждые несколько секунд, пока открыт."))
                Text(L("Логи идут только с вашего Mac на ваш iPad через ваш туннель. Mac с X-Ray должен быть включён; пока он спит, iPad показывает то, что успел скачать. X-Ray на Windows подключается к iPad так же, и iPad может читать несколько компьютеров сразу."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
        }
        .onAppear {
            addressText = model.viewerAddress
            if model.detectedAddress == nil { model.detectAddress() }
        }
        .onChange(of: addressText) { _, value in
            model.setViewerAddress(value)
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        let status = model.receiverStatus
        if !model.viewerEnabled {
            Label(L("Выключено"), systemImage: "pause.circle").foregroundStyle(.secondary)
        } else if let error = status.error {
            Label(L("Не удалось открыть порт \(status.port): \(error)"), systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Palette.critical)
        } else if status.listening {
            VStack(alignment: .leading, spacing: 3) {
                Label(L("Ждёт iPad на 127.0.0.1:\(status.port)"), systemImage: "ipad.and.arrow.forward")
                    .foregroundStyle(Palette.good)
                if let last = status.lastViewerRequest {
                    Text(L("iPad последний раз обращался \(Fmt.ago(model.now.timeIntervalSince(last))) · запросов \(status.viewerRequests)"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(L("iPad ещё не подключался."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if status.viewerRejected > 0 {
                    Text(L("Отклонено запросов с неверным токеном: \(status.viewerRejected)"))
                        .font(.caption)
                        .foregroundStyle(Palette.warning)
                }
            }
        } else {
            Label(L("Запускается…"), systemImage: "hourglass").foregroundStyle(.secondary)
        }
    }

    private var addressHint: String {
        if !model.viewerAddress.isEmpty {
            return L("Адрес, по которому iPad находит этот Mac: адрес из `tailscale funnel` или `tailscale serve`.")
        }
        if let detected = model.detectedAddress {
            return L("Найден в Tailscale: \(detected). Впишите другой, если iPad видит этот Mac по другому адресу.")
        }
        return L("Tailscale не найден. Впишите адрес, по которому iPad находит этот Mac, например из `tailscale funnel`.")
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
        return String(token.prefix(10)) + "…" + String(token.suffix(4))
    }
}

/// A QR code, drawn with sharp edges at any size.
struct QRCodeView: View {
    let text: String

    var body: some View {
        if let image = Self.image(for: text) {
            Image(decorative: image, scale: 1)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .accessibilityLabel(L("QR-код для подключения iPad"))
        } else {
            Image(systemName: "qrcode").font(.largeTitle).foregroundStyle(.secondary)
        }
    }

    static func image(for text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}
