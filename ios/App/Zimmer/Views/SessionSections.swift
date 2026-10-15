import SwiftUI
import ZimmerKit

extension SessionPageSection {
    /// What the page's `ScrollViewReader` scrolls to.
    var anchor: String { "detail.section.\(rawValue)" }

    /// The chip's words on a phone's width, where the full labels do not fit beside each other.
    var shortLabel: String {
        switch self {
        case .overview: return "Top"
        case .hierarchy: return "Hierarchy"
        case .humanMessages: return "Humans"
        case .transcript: return "Transcript"
        }
    }

    /// The chip at the largest text sizes, where even the short words do not fit.
    var symbol: String {
        switch self {
        case .overview: return "arrow.up.to.line"
        case .hierarchy: return "point.3.connected.trianglepath.dotted"
        case .humanMessages: return "person.2"
        case .transcript: return "text.bubble"
        }
    }
}

/// The session page's sub-navigation, pinned under the navigation bar: one chip per section,
/// the one being read filled, and the full-screen transcript at its end. The chips never
/// scroll sideways — every one is in sight — so their words shorten to fit, then give way to
/// symbols.
struct SectionStrip: View {
    let sections: [SessionPageSection]
    let current: SessionPageSection
    let jump: (SessionPageSection) -> Void
    /// Nil when there is no transcript to read full screen.
    let fullScreen: (() -> Void)?

    private enum Words { case full, short, symbol }

    var body: some View {
        HStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                chips(.full)
                chips(.short)
                chips(.symbol)
            }
            .padding(.leading, 12)
            Spacer(minLength: 4)
            if let fullScreen {
                Theme.rule.frame(width: 1, height: 20)
                Button(action: fullScreen) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 44, height: 32)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Read the transcript full screen")
                .accessibilityIdentifier("detail.fullscreen")
            }
        }
        .padding(.vertical, 6)
        .background {
            Theme.ground
                .overlay(alignment: .bottom) { Theme.rule.frame(height: 1) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail.sections")
    }

    private func chips(_ words: Words) -> some View {
        HStack(spacing: 5) {
            ForEach(sections) { section in
                Button { jump(section) } label: {
                    Pill(selected: section == current, compact: true) {
                        switch words {
                        case .full: Text(section.label)
                        case .short: Text(section.shortLabel)
                        case .symbol: Image(systemName: section.symbol)
                        }
                    }
                    .lineLimit(1)
                    .fixedSize()
                }
                .buttonStyle(.plain)
                .accessibilityLabel(section.label)
                .accessibilityAddTraits(section == current ? .isSelected : [])
                .accessibilityIdentifier("detail.sections.\(section.rawValue)")
            }
        }
    }
}

/// Which messages a reader has scrolled past: one for the page and one for its full-screen
/// transcript, so each opens where the other was left. A reference rather than state: it
/// changes with every message scrolled past, and nothing on screen is drawn from it.
final class ReadingPosition {
    /// The messages whose top is above the top of what is in view.
    var above: Set<Int> = []
    /// The end of the conversation is in view: open at the newest message, and follow it.
    var atEnd = true
    /// The message the full-screen transcript opens at; nil for the newest.
    var start: Int?

    init(start: Int? = nil) {
        self.start = start
        atEnd = start == nil
    }

    static func anchor(_ message: Int) -> String { "conversation.message.\(message)" }

    /// The message to open at among those shown; nil for the newest.
    func target(in shown: [ConversationMessage]) -> Int? {
        ConversationReading.target(above: above, atEnd: atEnd, shown: shown)
    }
}

extension View {
    /// Tells `position` when this message's top crosses `edge`, the top of what is in view, in
    /// global coordinates. Only on the crossing, so scrolling between messages costs nothing.
    func tracksReading(_ message: Int, edge: CGFloat, in position: ReadingPosition) -> some View {
        // A message scrolled to sits with its top on the edge, and counts as reached.
        onGeometryChange(for: Bool.self) { $0.frame(in: .global).minY <= edge + 1 } action: { above in
            if above { position.above.insert(message) } else { position.above.remove(message) }
        }
    }

    /// Marks this view as the top of `section`: the strip's chip scrolls to it, and its top
    /// reaching the strip's `edge` (in global coordinates) lights the chip.
    func pageSection(_ section: SessionPageSection, edge: CGFloat, reached: Binding<Set<SessionPageSection>>) -> some View {
        id(section.anchor)
            .onGeometryChange(for: Bool.self) { $0.frame(in: .global).minY <= edge + 4 } action: { isReached in
                if isReached { reached.wrappedValue.insert(section) } else { reached.wrappedValue.remove(section) }
            }
    }

    /// `pageSection` for a view that is the top of a section only sometimes.
    @ViewBuilder
    func pageSection(_ section: SessionPageSection?, edge: CGFloat, reached: Binding<Set<SessionPageSection>>) -> some View {
        if let section { pageSection(section, edge: edge, reached: reached) } else { self }
    }

    /// The top of what this scroll view shows, in global coordinates: under the bars.
    func readsTopEdge(_ edge: Binding<CGFloat>) -> some View {
        onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY + $0.safeAreaInsets.top } action: { edge.wrappedValue = $0 }
    }
}

/// The transcript alone, over everything else: the conversation and the composer, without the
/// header and the cards, for reading a long one. Done goes back to the page at the message
/// reached here. Nothing about it is kept: the page opens without it every time.
struct FullScreenTranscript<Conversation: View, Composer: View>: View {
    @ObservedObject var model: SessionDetailModel
    @EnvironmentObject private var app: AppModel
    /// Where this opens, and where it leaves the reader for the page.
    let position: ReadingPosition
    /// The page's conversation section, each message reporting against the given top edge.
    @ViewBuilder let conversation: (_ edge: CGFloat, _ position: ReadingPosition) -> Conversation
    @ViewBuilder let composer: () -> Composer
    @Environment(\.dismiss) private var dismiss
    @State private var endY: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    @State private var edge: CGFloat = 0
    @State private var opened = false
    private var atEnd: Bool { endY <= viewportHeight + 80 }

    static var endAnchor: String { "fullscreen.conversation.end" }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if let error = model.error { ErrorBanner(error: error) }
                        conversation(edge, position)
                        Color.clear
                            .frame(height: 1)
                            .id(Self.endAnchor)
                            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .scrollView).minY } action: { endY = $0 }
                    }
                    .padding(.horizontal, Theme.margin)
                    .padding(.vertical, 12)
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewportHeight = $0 }
                .readsTopEdge($edge)
                .onAppear {
                    // Where the page was being read, or the newest message; after the layout
                    // that adds the messages, or the scroll can miss.
                    let target = position.start
                    Task { @MainActor in
                        if let target {
                            proxy.scrollTo(ReadingPosition.anchor(target), anchor: .top)
                        } else {
                            proxy.scrollTo(Self.endAnchor, anchor: .bottom)
                        }
                        opened = true
                    }
                }
                .onChange(of: model.conversation?.messages.last?.id) { _, _ in
                    // New messages are followed only while the end is in view, as on the page.
                    if opened, atEnd { withAnimation { proxy.scrollTo(Self.endAnchor, anchor: .bottom) } }
                }
                .onChange(of: atEnd) { _, end in
                    if opened { position.atEnd = end }
                }
            }
            // The cover takes the page off the screen, and its reading with it: this reads again
            // instead, as the page does.
            .task(id: model.pollInterval) {
                while !Task.isCancelled {
                    try? await Task.sleep(for: model.pollInterval)
                    guard !Task.isCancelled else { return }
                    guard app.path.last == model.id, app.tab == .sessions else { continue }
                    await model.poll()
                }
            }
            .refreshable { await model.load() }
            .background(Theme.ground)
            .navigationTitle(Text(verbatim: "#\(model.id) · Transcript"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Label("Done", systemImage: "arrow.down.right.and.arrow.up.left")
                            .labelStyle(.titleAndIcon)
                    }
                    .accessibilityLabel("Exit full screen")
                    .accessibilityIdentifier("transcript.fullscreen.exit")
                }
            }
            .overlay(alignment: .bottom) {
                Toast(text: $model.notice, identifier: "fullscreen.notice")
            }
            .safeAreaInset(edge: .bottom) { composer() }
        }
    }
}
