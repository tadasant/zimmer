import SwiftUI
import ZimmerKit

/// A message's text as the web UI's transcript renders it (`ApplicationHelper#markdown`):
/// headings, paragraphs, lists that nest, quotes, tables, rules and fenced code, each block
/// drawn as a block. Inside them, emphasis, code spans and links are inline markdown. A code
/// block or a table wider than the screen scrolls sideways in its own box, so nothing in a
/// message can widen the page. A link, written as one or bare, opens on a tap and offers
/// Copy Link and Share on a long press.
struct MarkdownText: View {
    /// The text, already cut into blocks (`MarkdownBlock.blocks(of:)`).
    let blocks: [MarkdownBlock]
    /// Tool traffic's monospaced face, rather than the prose face.
    var monospaced = false
    var proseColor: Color = Theme.ink

    var body: some View {
        MarkdownBlocks(blocks: blocks, style: MarkdownStyle(monospaced: monospaced, color: proseColor))
    }
}

/// The face and ink of the prose in a message: a quote softens it, tool traffic is monospaced.
struct MarkdownStyle {
    var monospaced: Bool
    var color: Color
    /// How many lists deep, for the bullet: •, ◦, ▪.
    var listDepth = 0

    var font: Font { monospaced ? Theme.mono : .subheadline }

    /// The same face for UIKit, which draws the paragraphs that hold links.
    var uiFont: UIFont {
        monospaced
            ? .monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .regular)
            : .preferredFont(forTextStyle: .subheadline)
    }
}

private struct MarkdownBlocks: View {
    let blocks: [MarkdownBlock]
    let style: MarkdownStyle
    var spacing: CGFloat = 8

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block, style: style)
            }
        }
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let style: MarkdownStyle
    /// Read so a change of text size redraws the paragraphs UIKit draws, whose font is resolved
    /// here rather than by SwiftUI.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        switch block {
        case let .heading(level, text):
            VStack(alignment: .leading, spacing: 4) {
                Text(MarkdownInline.transcript(text))
                    .font(Self.headingFont(level))
                    .foregroundStyle(level >= 4 ? Theme.inkSoft : Theme.ink)
                // The web rules off a first-level heading.
                if level == 1 { Rectangle().fill(Theme.rule).frame(height: 1) }
            }
            .padding(.top, level <= 2 ? 4 : 0)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("markdown.heading")
        case let .paragraph(text):
            let attributed = MarkdownInline.transcript(text)
            if attributed.runs.contains(where: { $0.link != nil }) {
                // SwiftUI's Text opens a link and offers nothing on a long press; a text view
                // gives the system's link menu, with Copy Link.
                LinkText(text: style.attributed(attributed))
                    // A text view has no baseline of its own; this keeps a list's bullet level
                    // with the first line rather than the last.
                    .alignmentGuide(.firstTextBaseline) { _ in style.uiFont.ascender }
                    .accessibilityIdentifier("markdown.links")
            } else {
                Text(attributed)
                    .font(style.font)
                    .foregroundStyle(style.color)
            }
        case let .code(code, _):
            CodeBlock(code: code)
        case let .list(list):
            MarkdownListView(list: list, style: style)
        case let .quote(blocks):
            // The web's blockquote: a bar in the accent down the left, the words softened.
            MarkdownBlocks(blocks: blocks, style: MarkdownStyle(monospaced: style.monospaced, color: Theme.inkSoft, listDepth: style.listDepth))
                .padding(.leading, 12)
                .padding(.vertical, 2)
                .overlay(alignment: .leading) {
                    Capsule().fill(Theme.accent.opacity(0.7)).frame(width: 3)
                }
                .accessibilityIdentifier("markdown.quote")
        case let .table(table):
            MarkdownTableView(table: table)
        case .rule:
            Rectangle().fill(Theme.rule).frame(height: 1).padding(.vertical, 4)
        }
    }

    /// The web's `prose-sm` steps, a size down from a page's: the transcript is the smaller face.
    private static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title3.weight(.semibold)
        case 2: return .headline
        case 3: return .subheadline.weight(.semibold)
        default: return .footnote.weight(.semibold)
        }
    }
}

/// Each item's marker beside its blocks, so a wrapped line and a nested list hang under the
/// item's text rather than under its bullet.
private struct MarkdownListView: View {
    let list: MarkdownList
    let style: MarkdownStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(list.items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: list.marker(at: index, depth: style.listDepth))
                        .font(style.font.monospacedDigit())
                        .foregroundStyle(Theme.inkSoft)
                        .frame(minWidth: list.ordered ? 18 : 10, alignment: .trailing)
                    MarkdownBlocks(blocks: item, style: MarkdownStyle(monospaced: style.monospaced, color: style.color, listDepth: style.listDepth + 1), spacing: 4)
                }
            }
        }
        .accessibilityIdentifier("markdown.list")
    }
}

/// A table as the web's `table-wrapper` draws one: a header on a well, rows ruled apart, in a
/// rounded box. Columns wider than the screen wrap; a table that still does not fit scrolls.
private struct MarkdownTableView: View {
    let table: MarkdownTable
    @State private var width: CGFloat = 0

    var body: some View {
        let columns = table.header.count
        let cells = Array((table.header + table.rows.flatMap { $0 }).enumerated())
        ScrollView(.horizontal, showsIndicators: false) {
            MarkdownTableLayout(columns: columns, available: width) {
                ForEach(cells, id: \.offset) { index, text in
                    cell(text, row: index / columns, column: index % columns)
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.rule))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityIdentifier("markdown.table")
    }

    private func cell(_ text: String, row: Int, column: Int) -> some View {
        let header = row == 0
        let alignment = table.alignments.indices.contains(column) ? table.alignments[column] : .leading
        return Text(MarkdownInline.transcript(text))
            .font(header ? .caption.weight(.semibold) : .footnote)
            .foregroundStyle(header ? Theme.inkSoft : Theme.ink)
            .multilineTextAlignment(Self.textAlignment(alignment))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: Self.frameAlignment(alignment))
            .background(header ? Theme.well : Color.clear)
            .overlay(alignment: .bottom) {
                if row < table.rows.count { Rectangle().fill(Theme.rule).frame(height: 1) }
            }
    }

    private static func textAlignment(_ alignment: MarkdownTable.Alignment) -> TextAlignment {
        switch alignment {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    private static func frameAlignment(_ alignment: MarkdownTable.Alignment) -> Alignment {
        switch alignment {
        case .leading: return .topLeading
        case .center: return .top
        case .trailing: return .topTrailing
        }
    }
}

/// Cells in rows of `columns`, each column as wide as `MarkdownTable.columnWidths` gives it
/// for the width the table is shown in, and each row as tall as its tallest cell there.
private struct MarkdownTableLayout: Layout {
    let columns: Int
    /// The width of the box the table scrolls in: a scroll view proposes no width of its own.
    let available: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let (widths, heights) = measure(subviews)
        return CGSize(width: widths.reduce(0, +), height: heights.reduce(0, +))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (widths, heights) = measure(subviews)
        var y = bounds.minY
        for (row, height) in heights.enumerated() {
            var x = bounds.minX
            for (column, width) in widths.enumerated() {
                let index = row * columns + column
                guard index < subviews.count else { break }
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: width, height: height))
                x += width
            }
            y += height
        }
    }

    private func measure(_ subviews: Subviews) -> (widths: [CGFloat], heights: [CGFloat]) {
        guard columns > 0 else { return ([], []) }
        var natural = Array(repeating: 0.0, count: columns)
        for (index, subview) in subviews.enumerated() {
            natural[index % columns] = max(natural[index % columns], Double(subview.sizeThatFits(.unspecified).width.rounded(.up)))
        }
        let widths = MarkdownTable.columnWidths(natural: natural, available: Double(available)).map { CGFloat($0) }
        let rows = (subviews.count + columns - 1) / columns
        let heights = (0..<rows).map { row in
            (0..<columns).reduce(CGFloat(0)) { tallest, column in
                let index = row * columns + column
                guard index < subviews.count else { return tallest }
                return max(tallest, subviews[index].sizeThatFits(ProposedViewSize(width: widths[column], height: nil)).height)
            }
        }
        return (widths, heights)
    }
}

extension MarkdownInline {
    /// A transcript block's inline markdown: code spans on a well, as the web's `inline-code`
    /// pill, and bare URLs made links, as the web's `autolink` makes them.
    static func transcript(_ text: String) -> AttributedString {
        var attributed = attributed(text)
        let codeSpans = attributed.runs
            .filter { $0.inlinePresentationIntent?.contains(.code) == true }
            .map(\.range)
        for range in codeSpans {
            attributed[range].swiftUI.backgroundColor = Theme.well
        }
        let plain = String(attributed.characters)
        for match in MarkdownAutolink.matches(in: plain) {
            let start = attributed.characters.index(attributed.startIndex, offsetBy: match.offset)
            let end = attributed.characters.index(start, offsetBy: match.length)
            // A link already, or a URL written as code, is left as it is.
            let untouched = attributed[start..<end].runs.allSatisfy {
                $0.link == nil && $0.inlinePresentationIntent?.contains(.code) != true
            }
            if untouched { attributed[start..<end].link = match.url }
        }
        return attributed
    }
}

/// A paragraph with links in it, drawn by a `UITextView` for the system's link handling: a tap
/// opens the link, and a long press shows its menu — Open Link, Copy Link, Share. The text can
/// be selected too. Sized like a `Text`: as wide as its longest line, up to the width offered.
private struct LinkText: UIViewRepresentable {
    let text: NSAttributedString

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.linkTextAttributes = [.foregroundColor: UIColor(Theme.accent)]
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        // Compared with what was last set, not what the view hands back, so a transcript's
        // refresh leaves a selection or an open link menu alone when the text is unchanged.
        guard context.coordinator.shown != text else { return }
        context.coordinator.shown = text
        view.attributedText = text
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var shown: NSAttributedString?
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let offered = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        let fitted = uiView.sizeThatFits(CGSize(width: offered ?? .greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
        let width = min(fitted.width.rounded(.up), offered ?? .greatestFiniteMagnitude)
        return CGSize(width: width, height: fitted.height.rounded(.up))
    }
}

extension MarkdownStyle {
    /// Inline markdown in UIKit's attributes, for `LinkText`: what SwiftUI's Text reads from the
    /// presentation intents — bold, italic, code, strikethrough — set as fonts and styles.
    func attributed(_ attributed: AttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let base = uiFont
        let ink = UIColor(color)
        for run in attributed.runs {
            let intent = run.inlinePresentationIntent ?? []
            var font = intent.contains(.code) ? UIFont.monospacedSystemFont(ofSize: base.pointSize, weight: .regular) : base
            var traits = font.fontDescriptor.symbolicTraits
            if intent.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
            if intent.contains(.emphasized) { traits.insert(.traitItalic) }
            if let descriptor = font.fontDescriptor.withSymbolicTraits(traits) { font = UIFont(descriptor: descriptor, size: font.pointSize) }
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
            if intent.contains(.code) { attributes[.backgroundColor] = UIColor(Theme.well) }
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link { attributes[.link] = link }
            result.append(NSAttributedString(string: String(attributed[run.range].characters), attributes: attributes))
        }
        return result
    }
}

/// A fenced code block as the web's `code_block_controller.js` draws one: the code in the
/// monospaced face on a well, scrolling sideways rather than wrapping, with a Copy button in
/// its corner that puts the code on the pasteboard and shows a check for a moment. The web
/// also colours the code by language (Rouge); here it is one colour.
struct CodeBlock: View {
    let code: String
    /// Bumped by each tap, so the check's reset follows the latest tap rather than the first.
    @State private var copies = 0
    @State private var copied = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(code)
                .font(Theme.mono)
                .foregroundStyle(Theme.ink)
                .padding(.leading, 10)
                // Room for the button at the end of the line, so the last characters can be
                // scrolled out from under it.
                .padding(.trailing, 40)
                .padding(.vertical, 8)
        }
        .background(Theme.well, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(alignment: .topTrailing) {
            Button {
                UIPasteboard.general.string = code
                copied = true
                copies += 1
                Haptics.success()
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(copied ? Theme.success : Theme.inkSoft)
                    .frame(width: 30, height: 30)
                    .background(Theme.well, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentTransition(.symbolEffect(.replace))
            }
            .accessibilityLabel(copied ? "Copied" : "Copy code")
            .accessibilityIdentifier("code.copy")
        }
        // A new tap cancels the wait before it, so the check stays two seconds past the last.
        .task(id: copies) {
            guard copies > 0 else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            copied = false
        }
    }
}
