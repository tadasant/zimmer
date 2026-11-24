import Foundation

/// One thing that came back from work the person started earlier: what a call tells its model.
/// `POST /api/v1/live_conversations/:id/background_results`.
public struct LiveBackgroundResult: Decodable, Sendable, Equatable {
    public let id: Int
    public let text: String

    public init(id: Int, text: String) {
        self.id = id
        self.text = text
    }
}

struct LiveBackgroundResultsResponse: Decodable {
    let results: [LiveBackgroundResult]
}

/// A call's side of work coming back by itself — the same rules as the web dock's
/// `lib/live_background_results.js`. Zimmer says on the poll a call already makes how many results
/// are waiting (`LiveOverview.backgroundResults`); this says when to claim them, and hands each one
/// over once, while the call is idle, as context the model does not speak. So the model knows
/// before the person's next turn, and nothing interrupts.
///
/// A claim is this call's id and a number. One whose answer was lost is made again unchanged,
/// whatever the count says, and gets the same results; `seen` drops any handed over already. Until
/// Zimmer has heard a result was handed over it is said on every look (`unreported`), and a call
/// that ends first leaves it for the next one.
public struct LiveBackgroundResults: Sendable {
    /// This call, as Zimmer knows it.
    public let call: String
    private var number = 1
    private var asking = false
    private var seen: Set<Int> = []
    /// A claim was made and its answer never came.
    private var claiming = false
    private var undelivered: [LiveBackgroundResult] = []
    /// Handed over, and Zimmer not yet told.
    public private(set) var unreported: [Int] = []

    public init(call: String = UUID().uuidString) {
        self.call = call
    }

    /// What every request is made under.
    public var currentClaim: String { "\(call):\(number)" }

    /// The claim to make now, if one is worth making. `answered` or `failed` must follow.
    public mutating func claim(waiting: Int, idle: Bool) -> String? {
        guard !asking, idle, undelivered.isEmpty, waiting > 0 || claiming else { return nil }
        asking = true
        claiming = true
        return currentClaim
    }

    public mutating func answered(_ results: [LiveBackgroundResult]) {
        asking = false
        claiming = false
        number += 1
        for result in results where seen.insert(result.id).inserted { undelivered.append(result) }
    }

    /// The same claim is made again on the next poll.
    public mutating func failed() {
        asking = false
    }

    /// The next text to hand over, while the call is idle; `delivered` once it has gone.
    public func next(idle: Bool) -> String? {
        idle ? undelivered.first?.text : nil
    }

    public mutating func delivered() {
        if !undelivered.isEmpty { unreported.append(undelivered.removeFirst().id) }
    }

    /// Zimmer has heard these were handed over.
    public mutating func reported(_ ids: [Int]) {
        unreported.removeAll { ids.contains($0) }
    }
}
