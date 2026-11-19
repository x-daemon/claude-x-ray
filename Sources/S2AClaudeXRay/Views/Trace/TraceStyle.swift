import SwiftUI
import XRayCore

/// Icons and colors for trace items and live states.
/// Identity colors: user = orange, model = blue, tools = aqua, context = violet;
/// status colors (warning/critical/good) only for states and errors, always with an icon and a label.
enum TraceStyle {
    static func icon(for kind: ActivityKind) -> String {
        switch kind {
        case .prompt: return "person.fill"
        case .queued: return "tray.and.arrow.down"
        case .interrupted: return "stop.circle"
        case .thinking: return "brain"
        case .reply: return "text.bubble"
        case .toolCall: return "wrench.and.screwdriver"
        case .toolResult: return "arrow.turn.down.left"
        case .hook: return "link"
        case .compact: return "arrow.down.right.and.arrow.up.left"
        case .context: return "square.stack.3d.up"
        case .apiError: return "exclamationmark.octagon"
        case .note: return "info.circle"
        }
    }

    static func color(for kind: ActivityKind) -> Color {
        switch kind {
        case .prompt, .queued: return Palette.user
        case .thinking, .reply: return Palette.model
        case .toolCall, .toolResult: return Palette.tool
        case .context, .compact: return Palette.context
        case .hook, .note: return Palette.other
        case .interrupted: return Palette.warning
        case .apiError: return Palette.critical
        }
    }

    static func label(for kind: ActivityKind) -> String {
        switch kind {
        case .prompt: return L("Промпт")
        case .queued: return L("Сообщение")
        case .interrupted: return L("Прерывание")
        case .thinking: return L("Размышление")
        case .reply: return L("Ответ")
        case .toolCall: return L("Инструмент")
        case .toolResult: return L("Результат")
        case .hook: return L("Хук")
        case .compact: return L("Сжатие")
        case .context: return L("Контекст")
        case .apiError: return L("Ошибка")
        case .note: return L("Заметка")
        }
    }

    static func icon(for state: LiveState) -> String {
        switch state {
        case .runningTool: return "hammer.fill"
        case .runningSubagent: return "person.2.fill"
        case .thinking: return "brain"
        case .writing: return "text.cursor"
        case .waitingForUser: return "checkmark.bubble"
        case .quiet: return "ellipsis.bubble"
        case .interrupted: return "stop.circle"
        case .error: return "exclamationmark.octagon.fill"
        case .idle: return "moon.zzz"
        }
    }

    static func color(for state: LiveState) -> Color {
        switch state {
        case .runningTool, .runningSubagent: return Palette.tool
        case .thinking, .writing: return Palette.model
        case .waitingForUser: return Palette.good
        case .quiet: return Palette.other
        case .interrupted: return Palette.warning
        case .error: return Palette.critical
        case .idle: return Palette.other
        }
    }

    static func icon(for category: ToolDescriber.Category) -> String {
        switch category {
        case .shell: return "terminal"
        case .read: return "doc.text"
        case .write: return "pencil"
        case .search: return "magnifyingglass"
        case .web: return "globe"
        case .agent: return "person.2"
        case .skill: return "sparkles"
        case .mcp: return "puzzlepiece.extension"
        case .planning: return "checklist"
        case .other: return "hammer"
        }
    }

    static func color(for status: MCPStatus) -> Color {
        switch status {
        case .connected: return Palette.good
        case .pending: return Palette.warning
        case .failed: return Palette.critical
        case .needsAuth: return Palette.serious
        case .usedOnly: return Palette.other
        }
    }

    static func icon(for status: MCPStatus) -> String {
        switch status {
        case .connected: return "checkmark.circle.fill"
        case .pending: return "hourglass"
        case .failed: return "xmark.octagon.fill"
        case .needsAuth: return "key.fill"
        case .usedOnly: return "circle.dashed"
        }
    }

    static func title(for outcome: TurnOutcome) -> String {
        switch outcome {
        case .inProgress: return L("идёт")
        case .completed: return L("завершён")
        case .interrupted: return L("прерван")
        case .failed: return L("ошибка")
        }
    }

    static func color(for outcome: TurnOutcome) -> Color {
        switch outcome {
        case .inProgress: return Palette.model
        case .completed: return Palette.good
        case .interrupted: return Palette.warning
        case .failed: return Palette.critical
        }
    }
}

/// Small capsule label.
struct Chip: View {
    let text: String
    var systemImage: String? = nil
    var tint: Color = Palette.other

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage {
                Image(systemName: systemImage).foregroundStyle(tint)
            }
            Text(text).lineLimit(1)
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(tint.opacity(0.13)))
    }
}

/// Lays out children left to right, wrapping to new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var width: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            width = max(width, x - spacing)
        }
        return CGSize(width: proposal.width ?? width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Monospaced, selectable block for prompts, commands and outputs.
struct DetailBlock: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Palette.emptyCell))
    }
}
