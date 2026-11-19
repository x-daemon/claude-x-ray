import AppKit
import SwiftUI
import XRayCore

struct SettingsView: View {
    var body: some View {
        TabView {
            AppearanceSettings()
                .tabItem { Label(L("Язык и оформление"), systemImage: "paintpalette") }
            SourcesSettings()
                .tabItem { Label(L("Источники"), systemImage: "folder") }
            AccountLimitsSettings()
                .tabItem { Label(L("Лимиты аккаунта"), systemImage: "gauge.with.dots.needle.33percent") }
            CloudReceiverSettings()
                .tabItem { Label(L("Облако"), systemImage: "icloud.and.arrow.down") }
            PricingSettings()
                .tabItem { Label(L("Цены"), systemImage: "dollarsign.circle") }
            PlanSettings()
                .tabItem { Label(L("Подписка"), systemImage: "person.crop.circle") }
        }
        .frame(width: 780, height: 600)
    }
}

/// Where transcripts are read from.
struct SourcesSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Папки с транскриптами Claude Code (*.jsonl). Обычно это ~/.claude/projects; если задан CLAUDE_CONFIG_DIR — его подпапка projects."))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            List {
                ForEach(model.directories, id: \.self) { url in
                    HStack {
                        Image(systemName: FileManager.default.fileExists(atPath: url.path) ? "folder.fill" : "questionmark.folder")
                        Text(url.path).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        Spacer()
                        Button {
                            model.setDirectories(model.directories.filter { $0 != url })
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help(L("Убрать папку"))
                    }
                }
            }
            .frame(minHeight: 140)

            HStack {
                Button(L("Добавить папку…")) { addFolder() }
                Button(L("По умолчанию")) { model.resetDirectories() }
                Button(L("Импортировать лог…")) { TranscriptImportPanel.run(model: model) }
                    .help(L("Скопировать лог сессии (.jsonl или .zip), например облачной, в папку импорта X-Ray"))
                Spacer()
                Button(L("Пересканировать всё")) { Task { await model.fullRescan() } }
            }

            if let result = model.lastScanResult {
                Text(L("Последнее чтение: файлов \(result.filesSeen), новых строк \(result.linesRead), за \(String(format: "%.2f", result.duration)) с. Всего запросов в базе: \(model.priced.count)."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(result.errors, id: \.self) { error in
                    Text(error).font(.caption).foregroundStyle(Palette.critical)
                }
            }

            Text(L("Приложение только читает эти файлы и никуда не отправляет данные."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let url = panel.url, !model.directories.contains(url) else { return }
        model.setDirectories(model.directories + [url])
    }
}

/// Editable API price list.
struct PricingSettings: View {
    @Environment(AppModel.self) private var model
    @State private var newPrefix = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("USD за 1 млн токенов. \(L10n.tr(model.pricing.sourceNote)). Цены меняются — сверяйте с platform.claude.com/docs/en/about-claude/pricing. На подписке это API-эквивалент, а не списание."))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Table(model.pricing.models) {
                TableColumn(L("Модель")) { price in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(price.displayName)
                        Text(price.modelPrefix).font(.caption).foregroundStyle(.secondary)
                    }
                    .help(price.note.map(L10n.tr) ?? "")
                }
                .width(min: 140, ideal: 170)
                TableColumn(L("Ввод")) { price in priceField(price.modelPrefix, \.input) }
                TableColumn(L("Вывод")) { price in priceField(price.modelPrefix, \.output) }
                TableColumn(L("Чтение кэша")) { price in priceField(price.modelPrefix, \.cacheRead) }
                TableColumn(L("Запись 5 мин")) { price in priceField(price.modelPrefix, \.cacheWrite5m) }
                TableColumn(L("Запись 1 ч")) { price in priceField(price.modelPrefix, \.cacheWrite1h) }
                TableColumn("") { price in
                    Button {
                        model.removePrice(prefix: price.modelPrefix)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help(L("Удалить строку"))
                }
                .width(28)
            }

            HStack {
                TextField(L("id модели, например claude-sonnet-4-5"), text: $newPrefix)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 280)
                Button(L("Добавить")) {
                    model.addPrice(prefix: newPrefix)
                    newPrefix = ""
                }
                .disabled(newPrefix.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
                Button(L("Сбросить к стандартным")) { model.resetPricing() }
            }
        }
        .padding(20)
    }

    private func priceField(_ prefix: String, _ keyPath: WritableKeyPath<ModelPrice, Double>) -> some View {
        TextField("", value: model.priceBinding(prefix, keyPath), format: .number.precision(.fractionLength(0...4)))
            .multilineTextAlignment(.trailing)
            .textFieldStyle(.roundedBorder)
            .monospacedDigit()
    }
}

/// Subscription plan: changes labels and explanations, not the numbers.
struct PlanSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Picker(L("Тариф"), selection: Binding(get: { model.plan }, set: { model.setPlan($0) })) {
                ForEach(SubscriptionPlan.allCases) { plan in
                    Text(plan.title).tag(plan)
                }
            }
            .pickerStyle(.radioGroup)

            Section {
                Text(L("На Pro и Max лимиты считаются в 5-часовых окнах, которые начинаются с первого запроса, и дополнительно за неделю. Точный размер лимита Anthropic не публикует, и в логах его нет. Поэтому X-Ray показывает API-эквивалент окна и сравнивает его с вашим самым загруженным окном в истории."))
                Text(L("Чем меньше API-эквивалент на задачу (кэш, короткий контекст, подходящая модель), тем медленнее расходуется лимит."))
            }
            .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding(10)
    }
}

/// Interface language, theme (S2A or System), light/dark preference and a preview of the palette.
struct AppearanceSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(AppTheme.storageKey) private var themeRaw = AppTheme.s2a.rawValue
    @AppStorage(AppAppearance.storageKey) private var appearanceRaw = AppAppearance.auto.rawValue
    @AppStorage(AppLanguage.storageKey) private var languageRaw = AppLanguage.system

    /// Applies a new language before the windows rebuild, then reads the logs again: activity
    /// titles are written in the language they were read in.
    private var languageSelection: Binding<String> {
        Binding(
            get: { languageRaw },
            set: { value in
                let before = L10n.language
                AppLanguage.save(value)
                languageRaw = value
                if L10n.language != before {
                    Task { await model.fullRescan() }
                }
            }
        )
    }

    var body: some View {
        Form {
            Section(L("Язык интерфейса")) {
                Picker(L("Язык интерфейса"), selection: languageSelection) {
                    Text(L("Как в системе")).tag(AppLanguage.system)
                    ForEach(Language.allCases) { option in
                        Text(option.nativeName).tag(option.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                Text(L("Меню, подсказки, разбор сессий и отчёты. «Как в системе» берёт язык macOS: русский, английский или немецкий, для других языков — английский. Системные пункты меню (Скрыть, Завершить) меняют язык после перезапуска."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section(L("Тема")) {
                Picker(L("Тема"), selection: $themeRaw) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.title).tag(theme.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                Text((AppTheme(rawValue: themeRaw) ?? .s2a).subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker(L("Режим"), selection: $appearanceRaw) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            }
            Section(L("Палитра")) {
                ThemePreview()
            }
        }
        .formStyle(.grouped)
        .padding(10)
    }
}

struct ThemePreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                BrandMark(size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("S2A Claude X-Ray").font(.headline)
                    Text(L("акцент, поверхности и восемь цветов серий")).font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 6) {
                ForEach(Array(Palette.series.enumerated()), id: \.offset) { index, color in
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 4).fill(color).frame(width: 36, height: 22)
                        Text("\(index + 1)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            FlowLayout(spacing: 12) {
                Label(L("модель"), systemImage: "square.fill").foregroundStyle(Palette.model)
                Label(L("вы"), systemImage: "square.fill").foregroundStyle(Palette.user)
                Label(L("инструменты"), systemImage: "square.fill").foregroundStyle(Palette.tool)
                Label(L("контекст"), systemImage: "square.fill").foregroundStyle(Palette.context)
                Label(L("субагенты"), systemImage: "square.fill").foregroundStyle(Palette.subagent)
                Label(L("скиллы"), systemImage: "square.fill").foregroundStyle(Palette.skill)
                Label("MCP", systemImage: "square.fill").foregroundStyle(Palette.mcp)
            }
            .font(.caption)
            .labelStyle(LegendLabelStyle())
            HStack(spacing: 8) {
                Chip(text: L("хорошо"), systemImage: "checkmark.circle.fill", tint: Palette.good)
                Chip(text: L("внимание"), systemImage: "exclamationmark.triangle.fill", tint: Palette.warning)
                Chip(text: L("серьёзно"), systemImage: "exclamationmark.circle.fill", tint: Palette.serious)
                Chip(text: L("критично"), systemImage: "xmark.octagon.fill", tint: Palette.critical)
            }
            Text(L("Цвета серий подобраны так, чтобы соседние оставались различимы при протанопии и дейтеранопии в светлом и тёмном режиме. Статусные цвета одинаковы во всех темах и всегда идут со значком и подписью."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }
}
