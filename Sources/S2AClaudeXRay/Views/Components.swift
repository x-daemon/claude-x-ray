import Charts
import SwiftUI
import XRayCore

/// Headline number with a label and an optional caption.
struct StatTile: View {
    let title: String
    let value: String
    var caption: String? = nil
    var systemImage: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage).foregroundStyle(.secondary)
                }
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let caption {
                Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.hairline))
    }
}

/// Titled container for a chart or a block of details.
struct Card<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Spacer()
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.hairline))
    }
}

/// Small floating box shown by chart hover layers.
struct ChartTooltip: View {
    let title: String
    let rows: [(label: String, value: String, color: Color?)]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold))
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 6) {
                    if let color = row.color {
                        RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
                    }
                    Text(row.label).font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    Text(row.value).font(.caption).monospacedDigit()
                }
            }
        }
        .padding(8)
        .frame(minWidth: 160)
        .background(RoundedRectangle(cornerRadius: 8).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.hairline))
    }
}

/// Shown when no transcripts were found.
struct EmptyStateView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ContentUnavailableView {
            Label("Логи Claude Code не найдены", systemImage: "tray")
        } description: {
            VStack(spacing: 6) {
                Text("S2A Claude X-Ray читает транскрипты сессий Claude Code (*.jsonl). Искали здесь:")
                ForEach(model.directories, id: \.self) { url in
                    Text(url.path).font(.system(.caption, design: .monospaced))
                }
                Text("Запустите Claude Code хотя бы раз или укажите другую папку в настройках.")
            }
        } actions: {
            SettingsLink { Text("Открыть настройки") }
            Button("Пересканировать") { Task { await model.fullRescan() } }
        }
    }
}

extension View {
    /// Y axis labelled in dollars.
    func usdYAxis() -> some View {
        chartYAxis {
            AxisMarks { value in
                AxisGridLine().foregroundStyle(Palette.hairline)
                AxisValueLabel {
                    if let amount = value.as(Double.self) {
                        Text(Fmt.usd(amount))
                    }
                }
            }
        }
    }

    /// Y axis labelled in tokens (K/M).
    func tokenYAxis() -> some View {
        chartYAxis {
            AxisMarks { value in
                AxisGridLine().foregroundStyle(Palette.hairline)
                AxisValueLabel {
                    if let amount = value.as(Double.self) {
                        Text(Fmt.tokens(Int(amount)))
                    } else if let amount = value.as(Int.self) {
                        Text(Fmt.tokens(amount))
                    }
                }
            }
        }
    }
}
