import SwiftUI
import XRayCore

/// Pages the iPad's settings push in the detail column.
enum IPadSettingsPage: Hashable {
    case computer(UUID)
    case addComputer
    case appearance
    case pricing
    case plan
}

/// The iPad's settings: the computers it reads, how much it downloads, and the app settings it
/// shares with the Mac (language and look, prices, plan).
struct IPadSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(DesktopSync.self) private var sync
    @State private var confirmDelete = false
    @State private var downloaded: Int64 = 0

    var body: some View {
        Form {
            Section {
                ForEach(sync.computers) { computer in
                    NavigationLink(value: IPadSettingsPage.computer(computer.id)) {
                        ComputerRow(computer: computer, status: sync.status[computer.id])
                    }
                }
                NavigationLink(value: IPadSettingsPage.addComputer) {
                    Label(L("Добавить компьютер"), systemImage: "plus.circle")
                }
            } header: {
                Text(L("Компьютеры"))
            } footer: {
                Text(L("В X-Ray на Mac или Windows откройте «Настройки → iPad» и наведите камеру iPad на QR-код. Можно добавить несколько компьютеров: X-Ray покажет их логи вместе."))
            }

            Section {
                Picker(L("Скачивать логи"), selection: Binding(get: { sync.retentionDays }, set: { sync.setRetention($0) })) {
                    ForEach(DesktopSync.retentionChoices, id: \.self) { days in
                        Text(Self.retentionTitle(days)).tag(days)
                    }
                }
                LabeledContent(L("Занято на iPad"), value: Fmt.bytes(Int(downloaded)))
                Button(L("Синхронизировать сейчас")) { sync.syncNow() }
                Button(L("Удалить скачанные логи"), role: .destructive) { confirmDelete = true }
            } header: {
                Text(L("Загрузка"))
            } footer: {
                Text(L("X-Ray скачивает логи, пока открыт, и затем каждые несколько секунд догружает новые строки. Копии не попадают в резервную копию iPad: их всегда можно скачать снова."))
            }

            Section(L("Приложение")) {
                NavigationLink(value: IPadSettingsPage.appearance) {
                    Label(L("Язык и оформление"), systemImage: "paintpalette")
                }
                NavigationLink(value: IPadSettingsPage.pricing) {
                    Label(L("Цены"), systemImage: "dollarsign.circle")
                }
                NavigationLink(value: IPadSettingsPage.plan) {
                    Label(L("Подписка"), systemImage: "person.crop.circle")
                }
            }

            Section {
                LabeledContent("S2A Claude X-Ray", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                Text(L("X-Ray на iPad читает только ваши компьютеры, по вашему туннелю, и никуда не отправляет данные."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(Palette.page == nil ? .automatic : .hidden)
        .navigationDestination(for: IPadSettingsPage.self) { page in
            Group {
                switch page {
                case .computer(let id): ComputerEditor(computerID: id)
                case .addComputer: ComputerEditor(computerID: nil)
                case .appearance: AppearanceSettings().navigationTitle(L("Язык и оформление"))
                case .pricing: PricingSettings().navigationTitle(L("Цены"))
                case .plan: PlanSettings().navigationTitle(L("Подписка"))
                }
            }
            .background { Palette.page?.ignoresSafeArea() }
            .scrollContentBackground(Palette.page == nil ? .automatic : .hidden)
        }
        .confirmationDialog(L("Удалить скачанные логи?"), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(L("Удалить"), role: .destructive) {
                sync.deleteDownloads()
                downloaded = 0
            }
        } message: {
            Text(L("На компьютерах ничего не удаляется. X-Ray скачает логи за выбранный период заново."))
        }
        .task(id: sync.lastSync) {
            downloaded = sync.downloadedBytes()
        }
    }

    static func retentionTitle(_ days: Int) -> String {
        switch days {
        case 7: return L("7 дней")
        case 30: return L("30 дней")
        case 90: return L("90 дней")
        case 365: return L("Год")
        default: return L("Всё время")
        }
    }
}

/// A computer in the list: name, address and how the connection is.
struct ComputerRow: View {
    let computer: Computer
    let status: DesktopSync.Status?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: computer.platform == "Windows" ? "pc" : "laptopcomputer")
                .font(.title2)
                .foregroundStyle(Palette.accent)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(computer.name).font(.headline)
                Text(computer.server.host ?? computer.server.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                let state = status?.state ?? .waiting
                Label(state.title, systemImage: state.icon)
                    .font(.caption)
                    .foregroundStyle(state.color)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Adds a computer from its link, or changes or removes one.
struct ComputerEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(DesktopSync.self) private var sync
    let computerID: UUID?
    @State private var address = ""
    @State private var token = ""
    @State private var name = ""
    @State private var linkText = ""
    @State private var problem: String?
    @State private var confirmRemove = false
    @State private var loaded = false

    private var computer: Computer? { computerID.flatMap { id in sync.computers.first { $0.id == id } } }

    var body: some View {
        Form {
            Section {
                PasteButton(payloadType: String.self) { strings in
                    if let text = strings.first { apply(text) }
                }
                TextField(L("Ссылка s2a-xray://… из X-Ray на компьютере"), text: $linkText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit { apply(linkText) }
            } header: {
                Text(L("Ссылка подключения"))
            } footer: {
                Text(L("Проще всего навести камеру iPad на QR-код в X-Ray на компьютере («Настройки → iPad»). Или скопируйте ссылку там, а здесь нажмите «Вставить»."))
            }

            Section {
                TextField(L("https://ваш-компьютер.имя-сети.ts.net"), text: $address)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField(computer == nil ? L("Токен iPad (xrayv_…)") : L("Новый токен, если менялся"), text: $token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField(L("Название, например «MacBook»"), text: $name)
            } header: {
                Text(L("Вручную"))
            }

            if let problem {
                Section {
                    Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Palette.critical)
                }
            }

            if let computer {
                let status = sync.status[computer.id]
                Section(L("Состояние")) {
                    let state = status?.state ?? .waiting
                    Label(state.title, systemImage: state.icon).foregroundStyle(state.color)
                    if let info = status?.info {
                        LabeledContent(L("Компьютер"), value: "\(info.name) · \(info.platform)")
                        LabeledContent(L("X-Ray"), value: info.version)
                        LabeledContent(L("Логов там"), value: "\(info.files) · \(Fmt.bytes(Int(info.bytes)))")
                    }
                    if let status, status.files > 0 {
                        LabeledContent(L("Скачано"), value: "\(status.files) · \(Fmt.bytes(Int(status.bytes)))")
                    }
                    if let last = status?.lastSync {
                        LabeledContent(L("Синхронизировано"), value: Fmt.ago(model.now.timeIntervalSince(last)))
                    }
                }
                Section {
                    Button(L("Удалить компьютер"), role: .destructive) { confirmRemove = true }
                } footer: {
                    Text(L("Скачанные с него логи тоже удалятся с iPad. На компьютере ничего не меняется."))
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(computer?.name ?? L("Новый компьютер"))
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(L("Сохранить")) { save() }
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || (computer == nil && token.isEmpty))
            }
        }
        .confirmationDialog(L("Удалить компьютер?"), isPresented: $confirmRemove, titleVisibility: .visible) {
            Button(L("Удалить"), role: .destructive) {
                if let id = computerID { sync.remove(id) }
                model.detailPath = NavigationPath()
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if let computer {
                address = computer.server.absoluteString
                name = computer.name
            }
        }
    }

    /// Fills the fields from a pasted link.
    private func apply(_ text: String) {
        guard let link = ViewerLink(text: text) else {
            problem = L("Это не ссылка X-Ray. Она начинается с s2a-xray://connect")
            return
        }
        problem = nil
        linkText = ""
        address = link.server.absoluteString
        token = link.token
        if let linkName = link.name { name = linkName }
        if computerID == nil {
            sync.add(link)
            model.detailPath = NavigationPath()
        }
    }

    private func save() {
        guard let server = ViewerLink.normalize(text: address) else {
            problem = L("Адрес должен начинаться с https:// (или http:// в своей сети)")
            return
        }
        if let id = computerID {
            if !token.isEmpty && !ViewerLink.isValidToken(token) {
                problem = L("Токен не похож на токен X-Ray")
                return
            }
            sync.update(id, server: server, name: name, token: token.isEmpty ? nil : token)
        } else {
            guard let link = ViewerLink(server: server, token: token, name: name) else {
                problem = L("Токен не похож на токен X-Ray")
                return
            }
            sync.add(link)
        }
        problem = nil
        model.detailPath = NavigationPath()
    }
}

/// Footer of the iPad's sidebar: whether the computers are reachable and when data last came in.
struct SyncStatusFooter: View {
    @Environment(AppModel.self) private var model
    @Environment(DesktopSync.self) private var sync

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if sync.computers.isEmpty {
                Label(L("Компьютер не подключён"), systemImage: "ipad.and.arrow.forward")
                Text(L("Настройки → Добавить компьютер"))
                    .padding(.leading, 22)
            } else {
                let state = sync.summaryState
                HStack(spacing: 6) {
                    if state.isDownloading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: state.icon).foregroundStyle(state.color)
                    }
                    Text(state.title).lineLimit(2)
                    Spacer(minLength: 0)
                }
                if let last = sync.lastSync {
                    Text(L("Обновлено \(last.localized(date: .omitted, time: .standard))"))
                        .padding(.leading, 22)
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .onTapGesture { model.selection = .settings }
    }
}

extension DesktopSync.State {
    var isDownloading: Bool {
        if case .downloading = self { return true }
        return false
    }

    var title: String {
        switch self {
        case .waiting: return L("Ожидание")
        case .connecting: return L("Подключение…")
        case .downloading(let done, let total, let bytes): return L("Загрузка \(done) из \(total) · \(Fmt.bytes(Int(bytes)))")
        case .live: return L("На связи")
        case .offline(let message): return L("Нет связи: \(message)")
        case .unauthorized: return L("Токен не подходит: подключите iPad заново по QR-коду")
        case .accessOff: return L("Доступ для iPad выключен в X-Ray на компьютере")
        case .failed(let message): return message
        }
    }

    var icon: String {
        switch self {
        case .waiting: return "pause.circle"
        case .connecting: return "hourglass"
        case .downloading: return "arrow.down.circle"
        case .live: return "dot.radiowaves.left.and.right"
        case .offline: return "wifi.exclamationmark"
        case .unauthorized: return "key.slash"
        case .accessOff: return "lock"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    var color: Color {
        switch self {
        case .live: return Palette.good
        case .offline, .accessOff: return Palette.warning
        case .unauthorized, .failed: return Palette.critical
        default: return .secondary
        }
    }
}
