import Charts
import SwiftUI
import XRayCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Copies text to the clipboard.
enum Clipboard {
    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}

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
                    Image(systemName: systemImage).foregroundStyle(Palette.accent)
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

/// Horizontal bar for a share of a limit. It draws its own colors: system progress bars turn
/// gray whenever the window is not active, which hid the warning and critical colors.
struct UsageBar: View {
    let fraction: Double
    var color: Color = Palette.accent
    var height: CGFloat = 8

    var body: some View {
        let clamped = min(max(fraction, 0), 1)
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.emptyCell)
                Capsule()
                    .fill(color)
                    .frame(width: clamped > 0 ? max(height, proxy.size.width * clamped) : 0)
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityValue(Fmt.percent(clamped))
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

/// One row of a ranked horizontal bar list.
struct RankedBarRow: Identifiable {
    let id: String
    let label: String
    var detail: String? = nil
    let value: Double
    let valueText: String
    var color: Color = Palette.primary
    /// Stacked parts of the bar (e.g. success / error / running); `nil` draws one solid bar.
    var segments: [(value: Double, color: Color)]? = nil
    var help: String? = nil
}

/// Labelled horizontal bars: label column, proportional bar, value. Used instead of
/// categorical bar charts so labels stay on the left and bars keep a readable thickness.
struct RankedBarList: View {
    let rows: [RankedBarRow]
    var labelWidth: CGFloat = 230

    var body: some View {
        let maxValue = max(rows.map(\.value).max() ?? 0, .leastNonzeroMagnitude)
        VStack(alignment: .leading, spacing: 7) {
            ForEach(rows) { row in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(row.label).lineLimit(1).truncationMode(.middle)
                        if let detail = row.detail {
                            Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .frame(width: labelWidth, alignment: .leading)

                    GeometryReader { geometry in
                        let width = max(2, geometry.size.width * CGFloat(row.value / maxValue))
                        HStack(spacing: 2) {
                            if let segments = row.segments, row.value > 0 {
                                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(segment.color)
                                        .frame(width: max(2, width * CGFloat(segment.value / row.value)))
                                }
                            } else {
                                RoundedRectangle(cornerRadius: 3).fill(row.color).frame(width: width)
                            }
                        }
                        .frame(height: 12)
                        .frame(maxHeight: .infinity, alignment: .center)
                    }
                    .frame(height: 18)

                    Text(row.valueText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 90, alignment: .trailing)
                }
                .font(.callout)
                .help(row.help ?? "\(row.label): \(row.valueText)")
            }
        }
    }
}

/// Legend entry: colored swatch, text in the secondary text color.
struct LegendLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
            configuration.title.foregroundStyle(.secondary)
        }
    }
}
