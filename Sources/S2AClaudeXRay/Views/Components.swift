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

/// StatTiles in one row of equal widths; when each would be narrower than `minWidth` (an iPad in
/// portrait), as many per row as fit, in rows of equal columns.
struct TileRow: Layout {
    var minWidth: CGFloat = 140
    var spacing: CGFloat = 12

    private func columns(_ width: CGFloat, _ count: Int) -> Int {
        max(1, min(count, Int((width + spacing) / (minWidth + spacing))))
    }

    private func rows(_ subviews: Subviews, width: CGFloat) -> (cell: CGFloat, rows: [(range: Range<Int>, height: CGFloat)]) {
        let count = subviews.count
        let columns = columns(width, count)
        let cell = (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        var rows: [(range: Range<Int>, height: CGFloat)] = []
        for start in stride(from: 0, to: count, by: columns) {
            let range = start..<min(start + columns, count)
            let height = range.map { subviews[$0].sizeThatFits(ProposedViewSize(width: cell, height: nil)).height }.max() ?? 0
            rows.append((range, height))
        }
        return (cell, rows)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        guard let width = proposal.width, width.isFinite else {
            let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
            return CGSize(width: sizes.reduce(0) { $0 + $1.width } + spacing * CGFloat(sizes.count - 1), height: sizes.map(\.height).max() ?? 0)
        }
        let layout = rows(subviews, width: width)
        let height = layout.rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(layout.rows.count - 1)
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let layout = rows(subviews, width: bounds.width)
        var y = bounds.minY
        for row in layout.rows {
            for (column, index) in row.range.enumerated() {
                let height = subviews[index].sizeThatFits(ProposedViewSize(width: layout.cell, height: nil)).height
                subviews[index].place(
                    // Centred in the row, as in an HStack.
                    at: CGPoint(x: bounds.minX + CGFloat(column) * (layout.cell + spacing), y: y + (row.height - height) / 2),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: layout.cell, height: height)
                )
            }
            y += row.height + spacing
        }
    }
}

/// Cards side by side, top-aligned, with widths shared as an HStack shares them; one under the
/// other when the row has less than `minWidth` per card (an iPad in portrait).
struct CardRow: Layout {
    var minWidth: CGFloat = 360
    var spacing: CGFloat = 16

    private func sideBySide(_ width: CGFloat, _ count: Int) -> Bool {
        count < 2 || width >= minWidth * CGFloat(count) + spacing * CGFloat(count - 1)
    }

    /// The least flexible card first, each between its minimum and maximum width.
    private func widths(_ width: CGFloat, _ subviews: Subviews) -> [CGFloat] {
        let ranges = subviews.map { view -> (low: CGFloat, high: CGFloat) in
            let low = view.sizeThatFits(ProposedViewSize(width: 0, height: nil)).width
            let high = view.sizeThatFits(ProposedViewSize(width: .infinity, height: nil)).width
            return (low, max(low, high))
        }
        var result = [CGFloat](repeating: 0, count: subviews.count)
        var remaining = max(0, width - spacing * CGFloat(subviews.count - 1))
        let order = ranges.indices.sorted { ranges[$0].high - ranges[$0].low < ranges[$1].high - ranges[$1].low }
        for (position, index) in order.enumerated() {
            let share = remaining / CGFloat(order.count - position)
            result[index] = min(max(share, ranges[index].low), ranges[index].high)
            remaining -= result[index]
        }
        return result
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        guard let width = proposal.width, width.isFinite else {
            let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
            return CGSize(width: sizes.reduce(0) { $0 + $1.width } + spacing * CGFloat(sizes.count - 1), height: sizes.map(\.height).max() ?? 0)
        }
        if sideBySide(width, subviews.count) {
            let heights = zip(subviews, widths(width, subviews)).map { $0.sizeThatFits(ProposedViewSize(width: $1, height: nil)).height }
            return CGSize(width: width, height: heights.max() ?? 0)
        }
        let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
        return CGSize(width: width, height: heights.reduce(0, +) + spacing * CGFloat(heights.count - 1))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        if sideBySide(bounds.width, subviews.count) {
            var x = bounds.minX
            for (view, width) in zip(subviews, widths(bounds.width, subviews)) {
                view.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading, proposal: ProposedViewSize(width: width, height: nil))
                x += width + spacing
            }
        } else {
            var y = bounds.minY
            for view in subviews {
                let height = view.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height
                view.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: height))
                y += height + spacing
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
                    // labelWidth when there is room; in a narrow card (an iPad in portrait) less, so
                    // that the bar keeps its minimum. The same width in every row.
                    .frame(minWidth: 0, maxWidth: labelWidth, alignment: .leading)
                    .layoutPriority(1)

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
                    .frame(minWidth: 48)
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
