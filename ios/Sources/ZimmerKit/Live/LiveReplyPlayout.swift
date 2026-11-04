import Foundation

/// Where a Live voice call's reply is on the phone's speaker. OpenAI sends a reply faster than it
/// plays, so `response.done` can come seconds before the last of its audio does, and a second
/// reply can arrive while the first is still sounding. What the person has heard is a question
/// about this queue, not about the response.
///
/// Each chunk starts when it is scheduled or when the one before it ends, whichever is later, so a
/// gap in the network is a gap here too. Pure: the time comes in with each call (`at`, seconds on
/// any monotonic clock), so it is tested on Linux. It is a model of the player rather than a
/// reading of it, so an engine that stalls with audio queued leaves it running ahead of the
/// speaker, and it can only ever decide what to truncate, never whether to stop the player.
public struct LiveReplyPlayout: Sendable {
    /// A reply item the person did not hear to the end.
    public struct Cut: Sendable, Equatable {
        public let itemID: String
        /// All of the item's audio that reached the phone.
        public let audioMs: Int
        /// How much of that the person heard. Rounded down: OpenAI refuses a truncate past the
        /// end of the audio.
        public let heardMs: Int

        public init(itemID: String, audioMs: Int, heardMs: Int) {
            self.itemID = itemID
            self.audioMs = audioMs
            self.heardMs = heardMs
        }
    }

    private struct Chunk: Sendable {
        let itemID: String
        let startsAt: TimeInterval
        var samples: Int

        func played(by playhead: TimeInterval) -> Int {
            min(max(0, Int((playhead - startsAt) * RealtimeAudio.sampleRate)), samples)
        }
    }

    private var chunks: [Chunk] = []
    private var item: String?
    private var endsAt: TimeInterval = 0

    public init() {}

    /// Audio scheduled from here on belongs to reply `itemID`.
    public mutating func started(itemID: String, at now: TimeInterval) {
        if now >= endsAt { chunks.removeAll() }
        item = itemID
    }

    /// `samples` of the reply were scheduled on the player.
    public mutating func scheduled(samples: Int, at now: TimeInterval) {
        guard let item, samples > 0 else { return }
        let startsAt = max(now, endsAt)
        chunks.append(Chunk(itemID: item, startsAt: startsAt, samples: samples))
        endsAt = startsAt + Double(samples) / RealtimeAudio.sampleRate
    }

    /// The player lost what it had queued (an engine restart): only what played by `now` was
    /// ever audible, and the next chunk starts at once. The reply under way carries on.
    public mutating func queueDropped(at now: TimeInterval) {
        for index in chunks.indices { chunks[index].samples = chunks[index].played(by: now) }
        endsAt = now
    }

    /// How much queued audio is still to play at `now`: what a cue due now has to wait out.
    public func remaining(at now: TimeInterval) -> TimeInterval {
        max(0, endsAt - now)
    }

    /// The person started talking at `now`: forget the queue, and return every item they did not
    /// hear to the end, oldest first: those with audio still to play, and `arriving`, the item
    /// OpenAI was still sending. Empty means there is nothing to truncate. `latency` is the
    /// route's output latency: audio the player has passed but the speaker has not sounded yet
    /// is not heard.
    public mutating func stop(at now: TimeInterval, latency: TimeInterval = 0, arriving: String? = nil) -> [Cut] {
        defer { self = LiveReplyPlayout() }
        let playhead = now - latency
        var items: [(id: String, audio: Int, heard: Int)] = []
        for chunk in chunks {
            let heard = chunk.played(by: playhead)
            if let index = items.firstIndex(where: { $0.id == chunk.itemID }) {
                items[index].audio += chunk.samples
                items[index].heard += heard
            } else {
                items.append((chunk.itemID, chunk.samples, heard))
            }
        }
        return items.filter { $0.heard < $0.audio || $0.id == arriving }.map {
            Cut(itemID: $0.id, audioMs: Self.ms($0.audio), heardMs: Self.ms($0.heard))
        }
    }

    private static func ms(_ samples: Int) -> Int {
        samples * 1_000 / Int(RealtimeAudio.sampleRate)
    }
}
