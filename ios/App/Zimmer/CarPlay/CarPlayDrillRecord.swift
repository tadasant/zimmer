#if DEBUG
import Foundation

/// What the car's app did, one line each, in a file the CarPlay drill reads: each handler that ran
/// (`CarPlayImages.arrived`), and each drawing of the tiles or the voice settings. CarPlay's host can drop a tap before Zimmer hears it, and
/// no screen tells that apart from a tap Zimmer heard and did nothing about. The drill taps again
/// only when this file says nothing followed.
///
/// `CarPlayDrillUITests` names the file in the launch environment. Without it, nothing is written.
enum CarPlayDrillRecord {
    private static let path = ProcessInfo.processInfo.environment["ZIMMER_CARPLAY_DRILL_RECORD"]

    /// From any thread: one appending write per line.
    static func note(_ line: String) {
        guard let path else { return }
        let file = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard file >= 0 else { return }
        defer { close(file) }
        let bytes = Array("\(line)\n".utf8)
        _ = write(file, bytes, bytes.count)
    }
}
#endif
