import UIKit

/// The taps a phone gives back: a success when an action lands, an error when the server
/// refuses it. The web UI's toast, felt rather than read.
@MainActor
enum Haptics {
    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func failure() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }
}

/// What the search box searches: titles and metadata, or transcripts too — the web UI's
/// "Search transcript contents" checkbox, as a search scope.
enum SearchScope: String, Hashable, CaseIterable {
    case titles
    case transcripts

    var label: String {
        switch self {
        case .titles: return "Titles"
        case .transcripts: return "Transcripts"
        }
    }
}
