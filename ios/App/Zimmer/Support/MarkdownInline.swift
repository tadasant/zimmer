import Foundation

/// Markdown read inline only, keeping line breaks and list markers: a paragraph stays a
/// paragraph, and a heading or code block cannot push a layout around.
enum MarkdownInline {
    static func attributed(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}
