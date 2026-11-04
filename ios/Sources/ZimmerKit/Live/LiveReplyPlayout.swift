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
/// speaker.
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
        let samples: Int
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

    /// The person started talking at `now`: forget the queue, and return every item with audio
    /// still to play, oldest first. Empty means the reply has finished sounding, so there is
    /// nothing to stop and nothing to truncate. `latency` is the route's output latency: audio
    /// the player has passed but the speaker has not sounded yet is not heard.
    public mutating func stop(at now: TimeInterval, latency: TimeInterval = 0) -> [Cut] {
        defer { self = LiveReplyPlayout() }
        let playhead = now - latency
        var items: [(id: String, audio: Int, heard: Int)] = []
        for chunk in chunks {
            let played = Int((playhead - chunk.startsAt) * RealtimeAudio.sampleRate)
            let heard = min(max(0, played), chunk.samples)
            if let index = items.firstIndex(where: { $0.id == chunk.itemID }) {
                items[index].audio += chunk.samples
                items[index].heard += heard
            } else {
                items.append((chunk.itemID, chunk.samples, heard))
            }
        }
        return items.filter { $0.heard < $0.audio }.map {
            Cut(itemID: $0.id, audioMs: Self.ms($0.audio), heardMs: Self.ms($0.heard))
        }
    }

    private static func ms(_ samples: Int) -> Int {
        samples * 1_000 / Int(RealtimeAudio.sampleRate)
    }
}
