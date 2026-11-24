import Foundation

/// Answers the in-memory Zimmer holds back until somebody lets them go, so a screen can be seen
/// ahead of the server's answer for as long as it takes to look.
///
/// Held by a signal and never by a clock. A screen query on a loaded simulator can take seconds,
/// so a delay of any fixed length is one a UI test can overrun with the app behaving perfectly:
/// an answer six seconds away was overtaken by two queries (actions/runs/45309598346).
///
/// The signal is a pair of files in `directory`, because a UI test runs in another process:
/// `<name>.held` appears when the app asks for the answer, and it is given once `<name>.answer`
/// is there. `FixtureHold.swift` in `ZimmerUITests` is the other end.
public struct FixtureHold: Sendable {
    /// What is held: the names of writes (`FakeZimmerAPI.refusableWrites`), or `openSession`.
    public let names: Set<String>
    public let directory: URL

    /// Opening a session: its first detail read.
    public static let openSession = "open_session"

    public init(_ names: Set<String>, in directory: URL) {
        self.names = names
        self.directory = directory
    }

    /// Returns once `name` may be answered: at once, unless it is held.
    func wait(_ name: String) async throws {
        guard names.contains(name) else { return }
        let files = FileManager.default
        let answer = directory.appendingPathComponent("\(name).answer").path
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data().write(to: directory.appendingPathComponent("\(name).held"))
        while !files.fileExists(atPath: answer) {
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
