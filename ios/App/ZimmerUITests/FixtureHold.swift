import XCTest

/// An answer the `-ZimmerFixture` in-memory Zimmer holds back until the test lets it go, for a
/// test of what the app shows before the server has answered. Pass `arguments` to the launch,
/// look at the screen, `assertStillHeld`, then `answer`.
///
/// Anything seen before `answer` was shown without the server: there was no answer to show. So
/// each wait before it can be as long as any other in the suite, and an app that waits for the
/// server fails it. Use this rather than a fixture that answers after some seconds and a test
/// that must finish looking first: queries on a loaded runner take seconds, and they lose that
/// race with the app behaving perfectly (actions/runs/45309598346).
///
/// `ZimmerKit`'s `FixtureHold` is the other end, and says what the files mean.
@MainActor
struct FixtureHold {
    /// A write by the name the fixture refuses it by, or `open_session`.
    let name: String
    private let directory: URL

    init(_ name: String) {
        self.name = name
        // Its own directory, so no earlier test's answer is already there.
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("fixture-hold-\(UUID().uuidString)")
    }

    var arguments: [String] { ["-ZimmerFixtureHold", name, "-ZimmerFixtureHoldIn", directory.path] }

    /// The app has asked for the answer and is without it. What keeps a test honest: with
    /// nothing held, what it saw may have been the answer itself.
    func assertStillHeld(timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line) {
        let held = directory.appendingPathComponent("\(name).held").path
        let deadline = Date().addingTimeInterval(timeout)
        while !FileManager.default.fileExists(atPath: held), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: held), "the fixture is holding \(name)", file: file, line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: answerPath), "\(name) is not yet answered", file: file, line: line)
    }

    /// Lets the answer go.
    func answer(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(FileManager.default.createFile(atPath: answerPath, contents: nil), "\(name) was let go", file: file, line: line)
    }

    private var answerPath: String { directory.appendingPathComponent("\(name).answer").path }
}
