import Foundation

/// A message's markdown cut into the blocks the web UI's renderer (Redcarpet, with fenced
/// code, tables and autolinks) draws: headings, paragraphs, fenced and indented code, lists
/// that nest, quotes, tables and rules. What is inside a block — emphasis, code spans, links —
/// is left as written, for the screen's inline renderer. The rules are CommonMark's and GFM's
/// where agents lean on them; anything this does not recognise is a paragraph, shown as typed.
public enum MarkdownBlock: Hashable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case code(String, language: String?)
    case list(MarkdownList)
    case quote([MarkdownBlock])
    case table(MarkdownTable)
    case rule

    public static func blocks(of text: String) -> [MarkdownBlock] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        var parser = MarkdownParser(lines: lines)
        return parser.parse()
    }

    /// A fenced or indented code block, which the screen draws with a Copy button.
    public var isCode: Bool {
        if case .code = self { return true }
        return false
    }

    /// Whether a paragraph here, however deep, holds a link — written as one or bare.
    public var containsLink: Bool {
        switch self {
        case let .paragraph(text): return text.contains("](") || !MarkdownAutolink.matches(in: text).isEmpty
        case let .list(list): return list.items.contains { $0.contains(where: \.containsLink) }
        case let .quote(blocks): return blocks.contains(where: \.containsLink)
        case .heading, .code, .table, .rule: return false
        }
    }

    /// Every code block, however deep in a list or a quote.
    public var codeBlocks: [String] {
        switch self {
        case let .code(code, _): return [code]
        case let .list(list): return list.items.flatMap { $0.flatMap(\.codeBlocks) }
        case let .quote(blocks): return blocks.flatMap(\.codeBlocks)
        case .heading, .paragraph, .table, .rule: return []
        }
    }
}

public struct MarkdownList: Hashable, Sendable {
    public var ordered: Bool
    /// The first item's number, as typed: a list may start at 3.
    public var start: Int
    /// Each item's own blocks: a paragraph, and whatever is nested under it.
    public var items: [[MarkdownBlock]]

    public init(ordered: Bool, start: Int = 1, items: [[MarkdownBlock]]) {
        self.ordered = ordered
        self.start = start
        self.items = items
    }

    /// The marker before item `index`: "3." in an ordered list, a bullet otherwise.
    public func marker(at index: Int, depth: Int = 0) -> String {
        if ordered { return "\(start + index)." }
        return ["•", "◦", "▪"][depth % 3]
    }
}

public struct MarkdownTable: Hashable, Sendable {
    public enum Alignment: Hashable, Sendable { case leading, center, trailing }

    public var header: [String]
    public var alignments: [Alignment]
    /// Each row cut or padded to the header's width, as GFM does.
    public var rows: [[String]]

    public init(header: [String], alignments: [Alignment], rows: [[String]]) {
        self.header = header
        self.alignments = alignments
        self.rows = rows
    }

    /// Column widths for a table drawn `available` wide. Columns that fit keep their natural
    /// width, the last stretched to the edge. Otherwise the widest are capped at one width, so their text wraps and the table
    /// meets the edge — but no column goes under `floor`, and past that the table is wider than
    /// `available` and scrolls, as the web's `table-wrapper` does.
    public static func columnWidths(natural: [Double], available: Double, floor: Double = 72) -> [Double] {
        guard available > 0, !natural.isEmpty else { return natural }
        let total = natural.reduce(0, +)
        if total <= available {
            // The web's table is at least as wide as its box; the last column takes the rest.
            return natural.dropLast() + [natural[natural.count - 1] + available - total]
        }
        let target = max(available, floor * Double(natural.count))
        var remaining = target
        var left = natural.count
        var cap = target / Double(left)
        for width in natural.sorted() where width <= cap {
            remaining -= width
            left -= 1
            if left > 0 { cap = remaining / Double(left) }
        }
        cap = max(cap, floor)
        return natural.map { min($0, cap) }
    }
}

extension [MarkdownBlock] {
    /// Whether any block has code, so a Copy button has to be reachable.
    public var containsCode: Bool { contains { !$0.codeBlocks.isEmpty } }

    /// Whether any paragraph has a link, whose long-press menu has to be reachable.
    public var containsLink: Bool { contains(where: \.containsLink) }
}

/// Bare URLs in a run of prose, which the web's `autolink` makes links. As character offsets,
/// so the screen can mark the same span of an `AttributedString`. Trailing punctuation that
/// ends a sentence is left out, and a closing parenthesis is kept only when the URL opened one.
public enum MarkdownAutolink {
    public struct Match: Hashable, Sendable {
        public var offset: Int
        public var length: Int
        public var url: URL
    }

    /// Compiled once. Immutable after initialisation, so sharing it across threads is safe.
    private struct Pattern: @unchecked Sendable {
        let regex = try! NSRegularExpression(pattern: "https?://[^\\s<>\"'`]+", options: [.caseInsensitive])
    }
    private static let url = Pattern()

    public static func matches(in text: String) -> [Match] {
        guard text.contains("://") else { return [] }
        let pattern = url.regex
        let range = NSRange(text.startIndex..., in: text)
        return pattern.matches(in: text, range: range).compactMap { result in
            guard let found = Range(result.range, in: text) else { return nil }
            var candidate = text[found]
            while let last = candidate.last {
                if ".,;:!?*_".contains(last) {
                    candidate = candidate.dropLast()
                } else if last == ")", candidate.filter({ $0 == ")" }).count > candidate.filter({ $0 == "(" }).count {
                    candidate = candidate.dropLast()
                } else {
                    break
                }
            }
            guard let url = URL(string: String(candidate)), url.host != nil else { return nil }
            return Match(offset: text.distance(from: text.startIndex, to: candidate.startIndex), length: candidate.count, url: url)
        }
    }
}

// MARK: - The parser

private struct MarkdownParser {
    let lines: [String]
    var index = 0

    mutating func parse() -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
        }
        while index < lines.count {
            let line = lines[index]
            if Line.isBlank(line) {
                flush()
                index += 1
            } else if let fence = Line.fence(line) {
                flush()
                blocks.append(readFence(fence))
            } else if let heading = Line.heading(line) {
                flush()
                blocks.append(heading)
                index += 1
            } else if let table = tableStarting(at: index) {
                // A table may follow a paragraph's line directly, as GFM's does.
                flush()
                blocks.append(table)
            } else if !paragraph.isEmpty, let level = Line.setextLevel(line) {
                blocks.append(.heading(level: level, text: paragraph.joined(separator: "\n")))
                paragraph = []
                index += 1
            } else if Line.isRule(line) {
                flush()
                blocks.append(.rule)
                index += 1
            } else if Line.quoteContent(line) != nil {
                flush()
                blocks.append(readQuote())
            } else if let marker = Line.listMarker(line),
                      paragraph.isEmpty || (!marker.content.isEmpty && (!marker.ordered || marker.number == 1)) {
                // Only a list starting at 1 may interrupt a paragraph, so "in\n2024. The" is prose.
                flush()
                blocks.append(readList(marker))
            } else if paragraph.isEmpty, Line.indent(line) >= 4 {
                blocks.append(readIndentedCode())
            } else {
                paragraph.append(line.trimmingCharacters(in: .whitespaces))
                index += 1
            }
        }
        flush()
        return blocks
    }

    /// From the opening fence to a closing one of the same character, at least as long. An
    /// unclosed fence runs to the end, as a renderer shows it.
    private mutating func readFence(_ fence: Line.Fence) -> MarkdownBlock {
        index += 1
        var code: [String] = []
        while index < lines.count {
            let line = lines[index]
            index += 1
            if Line.closes(line, fence) { break }
            code.append(Line.dropIndent(line, upTo: fence.indent))
        }
        return .code(code.joined(separator: "\n"), language: fence.language)
    }

    private mutating func readIndentedCode() -> MarkdownBlock {
        var code: [String] = []
        while index < lines.count {
            let line = lines[index]
            if Line.isBlank(line) {
                code.append("")
            } else if Line.indent(line) >= 4 {
                code.append(Line.dropIndent(line, upTo: 4))
            } else {
                break
            }
            index += 1
        }
        while code.last == "" { code.removeLast() }
        return .code(code.joined(separator: "\n"), language: nil)
    }

    /// `>` lines, and the lines that lazily continue the quote's last paragraph.
    private mutating func readQuote() -> MarkdownBlock {
        var inner: [String] = []
        while index < lines.count {
            let line = lines[index]
            if let content = Line.quoteContent(line) {
                inner.append(content)
            } else if let last = inner.last, !Line.isBlank(last), !Line.isBlank(line), !Line.startsBlock(line) {
                inner.append(line)
            } else {
                break
            }
            index += 1
        }
        var parser = MarkdownParser(lines: inner)
        return .quote(parser.parse())
    }

    /// Items of one kind, each holding the lines indented to its content, which are parsed
    /// as blocks of their own: that is how a list nests.
    private mutating func readList(_ first: Line.ListMarker) -> MarkdownBlock {
        var items: [[String]] = []
        var current = [first.content]
        var contentIndent = first.contentIndent
        var markerIndent = first.indent
        index += 1
        while index < lines.count {
            let line = lines[index]
            if Line.isBlank(line) {
                current.append("")
            } else if Line.indent(line) >= contentIndent {
                current.append(Line.dropIndent(line, upTo: contentIndent))
            } else if let marker = Line.listMarker(line), marker.indent > markerIndent, !Line.isRule(line) {
                // Indented past this item's marker but short of its text — `  - b` under
                // `1. a` — is still nested, as Redcarpet nests it.
                current.append(Line.dropIndent(line, upTo: contentIndent))
            } else if let marker = Line.listMarker(line), marker.ordered == first.ordered, !Line.isRule(line) {
                items.append(current)
                current = [marker.content]
                contentIndent = marker.contentIndent
                markerIndent = marker.indent
            } else if let last = current.last, !Line.isBlank(last), !Line.startsBlock(line) {
                current.append(line.trimmingCharacters(in: .whitespaces))
            } else {
                break
            }
            index += 1
        }
        items.append(current)
        let parsed = items.map { lines -> [MarkdownBlock] in
            var parser = MarkdownParser(lines: lines)
            return parser.parse()
        }
        return .list(MarkdownList(ordered: first.ordered, start: first.number, items: parsed))
    }

    /// A header row, a delimiter row with as many cells, then rows until a blank line or
    /// another block.
    private mutating func tableStarting(at start: Int) -> MarkdownBlock? {
        guard start + 1 < lines.count, lines[start].contains("|"),
              let alignments = Line.delimiterRow(lines[start + 1]) else { return nil }
        let header = Line.cells(lines[start])
        guard header.count == alignments.count else { return nil }
        index = start + 2
        var rows: [[String]] = []
        while index < lines.count, !Line.isBlank(lines[index]), !Line.startsBlock(lines[index]) {
            let cells = Line.cells(lines[index])
            rows.append((0..<header.count).map { $0 < cells.count ? cells[$0] : "" })
            index += 1
        }
        return .table(MarkdownTable(header: header, alignments: alignments, rows: rows))
    }
}

/// What one line is, read on its own.
private enum Line {
    struct Fence {
        var character: Character
        var length: Int
        var indent: Int
        var language: String?
    }

    struct ListMarker {
        var ordered: Bool
        var number: Int
        var content: String
        var contentIndent: Int
        /// Where the marker itself sits: a marker indented past it nests.
        var indent: Int
    }

    static func isBlank(_ line: String) -> Bool {
        line.allSatisfy(\.isWhitespace)
    }

    /// Leading whitespace in columns, a tab as four.
    static func indent(_ line: String) -> Int {
        var columns = 0
        for character in line {
            if character == " " { columns += 1 } else if character == "\t" { columns += 4 } else { break }
        }
        return columns
    }

    static func dropIndent(_ line: String, upTo columns: Int) -> String {
        var dropped = 0
        var rest = Substring(line)
        while dropped < columns, let first = rest.first, first == " " || first == "\t" {
            dropped += first == "\t" ? 4 : 1
            rest = rest.dropFirst()
        }
        return String(rest)
    }

    /// The line without the up-to-three spaces any block may start with, or nil if it is
    /// indented further (code, or a continuation).
    private static func unindented(_ line: String) -> Substring? {
        indent(line) <= 3 ? Substring(line).drop(while: { $0 == " " }) : nil
    }

    static func fence(_ line: String) -> Fence? {
        guard let rest = unindented(line), let character = rest.first, character == "`" || character == "~" else { return nil }
        let run = rest.prefix(while: { $0 == character })
        guard run.count >= 3 else { return nil }
        let info = rest.dropFirst(run.count).trimmingCharacters(in: .whitespaces)
        if character == "`", info.contains("`") { return nil }
        let language = info.split(whereSeparator: \.isWhitespace).first.map(String.init)
        return Fence(character: character, length: run.count, indent: indent(line), language: language)
    }

    static func closes(_ line: String, _ fence: Fence) -> Bool {
        guard let rest = unindented(line) else { return false }
        let run = rest.prefix(while: { $0 == fence.character })
        return run.count >= fence.length && rest.dropFirst(run.count).allSatisfy(\.isWhitespace)
    }

    /// `# Title` to `###### Title`; a `#` with no space after it ("#1293") is not one.
    static func heading(_ line: String) -> MarkdownBlock? {
        guard let rest = unindented(line) else { return nil }
        let hashes = rest.prefix(while: { $0 == "#" })
        guard (1...6).contains(hashes.count) else { return nil }
        let after = rest.dropFirst(hashes.count)
        guard after.isEmpty || after.first == " " || after.first == "\t" else { return nil }
        var text = after.trimmingCharacters(in: .whitespaces)
        // A closing run of #s, set off by a space, is decoration.
        let closing = text.reversed().prefix(while: { $0 == "#" }).count
        if closing > 0 {
            let kept = text.dropLast(closing)
            if kept.isEmpty || kept.last == " " { text = kept.trimmingCharacters(in: .whitespaces) }
        }
        return .heading(level: hashes.count, text: text)
    }

    /// `===` under a paragraph makes it a first-level heading, `---` a second.
    static func setextLevel(_ line: String) -> Int? {
        guard let rest = unindented(line) else { return nil }
        let trimmed = rest.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first, first == "=" || first == "-", trimmed.allSatisfy({ $0 == first }) else { return nil }
        return first == "=" ? 1 : 2
    }

    /// Three or more of `-`, `*` or `_`, spaces allowed between.
    static func isRule(_ line: String) -> Bool {
        guard let rest = unindented(line) else { return false }
        let marks = rest.filter { !$0.isWhitespace }
        guard let first = marks.first, "-*_".contains(first), marks.count >= 3 else { return false }
        return marks.allSatisfy { $0 == first }
    }

    static func quoteContent(_ line: String) -> String? {
        guard let rest = unindented(line), rest.first == ">" else { return nil }
        var content = rest.dropFirst()
        if content.first == " " { content = content.dropFirst() }
        return String(content)
    }

    /// `-`, `*` or `+`, or a number and `.` or `)`, then a space or the end of the line.
    static func listMarker(_ line: String) -> ListMarker? {
        guard let rest = unindented(line), let first = rest.first else { return nil }
        let leading = indent(line)
        var ordered = false
        var number = 1
        var width: Int
        if "-*+".contains(first) {
            width = 1
        } else {
            let digits = rest.prefix(while: \.isASCII).prefix(while: \.isNumber)
            guard (1...9).contains(digits.count), let delimiter = rest.dropFirst(digits.count).first,
                  delimiter == "." || delimiter == ")" else { return nil }
            ordered = true
            number = Int(digits) ?? 1
            width = digits.count + 1
        }
        let after = rest.dropFirst(width)
        guard after.isEmpty || after.first == " " || after.first == "\t" else { return nil }
        let spaces = after.prefix(while: { $0 == " " }).count
        let content = after.trimmingCharacters(in: .whitespaces)
        // Five or more spaces after the marker start indented code in the item; one is the gap.
        let gap = content.isEmpty || spaces >= 5 ? 1 : spaces
        return ListMarker(ordered: ordered, number: number, content: content, contentIndent: leading + width + gap, indent: leading)
    }

    /// A line that starts a block of its own, so it cannot continue a paragraph lazily.
    static func startsBlock(_ line: String) -> Bool {
        fence(line) != nil || heading(line) != nil || isRule(line) || quoteContent(line) != nil
            || (listMarker(line).map { !$0.content.isEmpty } ?? false)
    }

    /// `| --- | :---: | ---: |`, as alignments, or nil if the line is not one.
    static func delimiterRow(_ line: String) -> [MarkdownTable.Alignment]? {
        guard line.contains("|") else { return nil }
        var alignments: [MarkdownTable.Alignment] = []
        for cell in cells(line) {
            let dashes = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else { return nil }
            switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
            case (true, true): alignments.append(.center)
            case (false, true): alignments.append(.trailing)
            default: alignments.append(.leading)
            }
        }
        return alignments
    }

    /// A row's cells: split on every `|` but an escaped one, as GFM splits them — inside a code
    /// span too.
    static func cells(_ line: String) -> [String] {
        var text = Substring(line.trimmingCharacters(in: .whitespaces))
        if text.first == "|" { text = text.dropFirst() }
        if text.last == "|", !text.hasSuffix("\\|") { text = text.dropLast() }
        var cells: [String] = []
        var cell = ""
        var characters = text.makeIterator()
        while let character = characters.next() {
            if character == "\\" {
                if let next = characters.next() {
                    if next == "|" { cell.append("|") } else { cell.append(character); cell.append(next) }
                } else {
                    cell.append(character)
                }
            } else if character == "|" {
                cells.append(cell.trimmingCharacters(in: .whitespaces))
                cell = ""
            } else {
                cell.append(character)
            }
        }
        cells.append(cell.trimmingCharacters(in: .whitespaces))
        return cells
    }
}
