import SwiftUI
import ZimmerKit

/// The web composer's "/" typeahead: the session's skills that match what follows the "/",
/// ten at most with the rest counted, each put into the draft with a tap. It opens above the
/// field, where the quick replies were, as the web's dropdown opens over the composer.
struct SlashCommandList: View {
    let matches: [SlashCommand]
    let choose: (SlashCommand) -> Void

    private static let rowHeight: CGFloat = 46
    /// About four and a half rows: enough to see there are more, without covering the page.
    private static let maxHeight: CGFloat = 207

    var body: some View {
        let shown = Array(matches.prefix(SlashCommand.shownLimit))
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, command in
                        if index > 0 { Theme.rule.frame(height: 1) }
                        Button { choose(command) } label: { row(command) }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("slash.\(command.name)")
                    }
                }
            }
            .frame(height: min(CGFloat(shown.count) * Self.rowHeight, Self.maxHeight))
            if matches.count > shown.count {
                Theme.rule.frame(height: 1)
                Text("+\(matches.count - shown.count) more (keep typing to narrow)")
                    .font(.caption)
                    .foregroundStyle(Theme.inkMute)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
        }
        .themeCard(radius: Theme.smallRadius)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("slash.list")
    }

    /// The web's row: the command, what kind it is, and its description on one line.
    private func row(_ command: SlashCommand) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: "/\(command.name)")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.ink)
                if let description = command.description, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(Theme.inkSoft)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Text("skill")
                .font(.caption2)
                .foregroundStyle(Theme.inkMute)
        }
        .padding(.horizontal, 12)
        .frame(height: Self.rowHeight)
        .contentShape(Rectangle())
    }
}
