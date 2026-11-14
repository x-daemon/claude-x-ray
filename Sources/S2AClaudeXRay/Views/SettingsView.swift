import AppKit
import SwiftUI
import XRayCore

struct SettingsView: View {
    var body: some View {
        TabView {
            AppearanceSettings()
                .tabItem { Label("Оформление", systemImage: "paintpalette") }
            SourcesSettings()
                .tabItem { Label("Источники", systemImage: "folder") }
            PricingSettings()
                .tabItem { Label("Цены", systemImage: "dollarsign.circle") }
            PlanSettings()
                .tabItem { Label("Подписка", systemImage: "person.crop.circle") }
        }
        .frame(width: 760, height: 500)
    }
}

/// Where transcripts are read from.
struct SourcesSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Папки с транскриптами Claude Code (*.jsonl). Обычно это ~/.claude/projects; если задан CLAUDE_CONFIG_DIR — его подпапка projects.")
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
                        .help("Убрать папку")
                    }
                }
            }
            .frame(minHeight: 140)

            HStack {
                Button("Добавить папку…") { addFolder() }
                Button("По умолчанию") { model.resetDirectories() }
                Spacer()
                Button("Пересканировать всё") { Task { await model.fullRescan() } }
            }

            if let result = model.lastScanResult {
                Text("Последнее чтение: файлов \(result.filesSeen), новых строк \(result.linesRead), за \(String(format: "%.2f", result.duration)) с. Всего запросов в базе: \(model.priced.count).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(result.errors, id: \.self) { error in
                    Text(error).font(.caption).foregroundStyle(Palette.critical)
                }
            }

            Text("Приложение только читает эти файлы и никуда не отправляет данные.")
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
            Text("USD за 1 млн токенов. \(model.pricing.sourceNote). Цены меняются — сверяйте с platform.claude.com/docs/en/about-claude/pricing. На подписке это API-эквивалент, а не списание.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Table(model.pricing.models) {
                TableColumn("Модель") { price in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(price.displayName)
                        Text(price.modelPrefix).font(.caption).foregroundStyle(.secondary)
                    }
                    .help(price.note ?? "")
                }
                .width(min: 140, ideal: 170)
                TableColumn("Ввод") { price in priceField(price.modelPrefix, \.input) }
                TableColumn("Вывод") { price in priceField(price.modelPrefix, \.output) }
                TableColumn("Чтение кэша") { price in priceField(price.modelPrefix, \.cacheRead) }
                TableColumn("Запись 5 мин") { price in priceField(price.modelPrefix, \.cacheWrite5m) }
                TableColumn("Запись 1 ч") { price in priceField(price.modelPrefix, \.cacheWrite1h) }
                TableColumn("") { price in
                    Button {
                        model.removePrice(prefix: price.modelPrefix)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Удалить строку")
                }
                .width(28)
            }

            HStack {
                TextField("id модели, например claude-sonnet-4-5", text: $newPrefix)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 280)
                Button("Добавить") {
                    model.addPrice(prefix: newPrefix)
                    newPrefix = ""
                }
                .disabled(newPrefix.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
                Button("Сбросить к стандартным") { model.resetPricing() }
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
            Picker("Тариф", selection: Binding(get: { model.plan }, set: { model.setPlan($0) })) {
                ForEach(SubscriptionPlan.allCases) { plan in
                    Text(plan.title).tag(plan)
                }
            }
            .pickerStyle(.radioGroup)

            Section {
                Text("На Pro и Max лимиты считаются в 5-часовых окнах, которые начинаются с первого запроса, и дополнительно за неделю. Точный размер лимита Anthropic не публикует, и в логах его нет. Поэтому X-Ray показывает API-эквивалент окна и сравнивает его с вашим самым загруженным окном в истории.")
                Text("Чем меньше API-эквивалент на задачу (кэш, короткий контекст, подходящая модель), тем медленнее расходуется лимит.")
            }
            .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding(10)
    }
}

/// Theme (S2A or System), light/dark preference and a preview of the active palette.
struct AppearanceSettings: View {
    @AppStorage(AppTheme.storageKey) private var themeRaw = AppTheme.s2a.rawValue
    @AppStorage(AppAppearance.storageKey) private var appearanceRaw = AppAppearance.auto.rawValue

    var body: some View {
        Form {
            Section("Тема") {
                Picker("Тема", selection: $themeRaw) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.title).tag(theme.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                Text((AppTheme(rawValue: themeRaw) ?? .s2a).subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Режим", selection: $appearanceRaw) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            }
            Section("Палитра") {
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
                    Text("акцент, поверхности и восемь цветов серий").font(.caption).foregroundStyle(.secondary)
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
                Label("модель", systemImage: "square.fill").foregroundStyle(Palette.model)
                Label("вы", systemImage: "square.fill").foregroundStyle(Palette.user)
                Label("инструменты", systemImage: "square.fill").foregroundStyle(Palette.tool)
                Label("контекст", systemImage: "square.fill").foregroundStyle(Palette.context)
                Label("субагенты", systemImage: "square.fill").foregroundStyle(Palette.subagent)
                Label("скиллы", systemImage: "square.fill").foregroundStyle(Palette.skill)
                Label("MCP", systemImage: "square.fill").foregroundStyle(Palette.mcp)
            }
            .font(.caption)
            .labelStyle(LegendLabelStyle())
            HStack(spacing: 8) {
                Chip(text: "хорошо", systemImage: "checkmark.circle.fill", tint: Palette.good)
                Chip(text: "внимание", systemImage: "exclamationmark.triangle.fill", tint: Palette.warning)
                Chip(text: "серьёзно", systemImage: "exclamationmark.circle.fill", tint: Palette.serious)
                Chip(text: "критично", systemImage: "xmark.octagon.fill", tint: Palette.critical)
            }
            Text("Цвета серий подобраны так, чтобы соседние оставались различимы при протанопии и дейтеранопии в светлом и тёмном режиме. Статусные цвета одинаковы во всех темах и всегда идут со значком и подписью.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }
}
