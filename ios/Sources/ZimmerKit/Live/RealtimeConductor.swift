import Foundation

/// What a Live Mode voice call is doing, for the screen and the car.
public enum LiveVoiceState: String, Sendable, Equatable {
    case idle, connecting, listening, thinking, speaking, working

    public var label: String {
        switch self {
        case .idle: return "Call ended"
        case .connecting: return "Connecting…"
        case .listening: return "Listening"
        case .thinking: return "Thinking…"
        case .speaking: return "Speaking"
        case .working: return "Working on it…"
        }
    }

    /// The call's status line, on the phone and in the car: muted is said beside the state, not
    /// instead of it, so a reply under way still shows.
    public func label(muted: Bool) -> String {
        muted && self != .idle ? "\(label) · Muted" : label
    }
}

/// The Realtime protocol half of a Live Mode voice call, with no I/O: OpenAI's server events go in,
/// and what to do about them comes out. The same sequencing as the web's call dock
/// (`live_voice_controller.js`), so the phone and the browser behave alike:
///
/// - a function call is relayed to Zimmer as soon as its arguments are complete
///   (`response.function_call_arguments.done`), several side by side;
/// - each result goes back as a `function_call_output` item, followed by a `session.update` when
///   the call enabled or disabled a server or changed a Live setting (Zimmer's `session` when it
///   sent one, otherwise just the tools);
/// - a call that moved Live Mode to another conversation (`LiveToolResult.switchedTo`) sends
///   nothing more: its session is over, and `reattach` says where the call goes;
/// - a call the person asked to hang up with (`LiveToolResult.hangUp`) is answered, asks for no
///   reply after it — nor does anything else from then on — and once the response that asked is
///   done, `hangUp` says to end the call when the reply has finished sounding. Calls already
///   relayed are not taken back: Zimmer runs them whether the call is still up or not;
/// - once the response that asked for them is done and every result is in, exactly one
///   `response.create` — and never on top of a response already running (the user speaking
///   mid-tool starts one), in which case it waits for that response to finish;
/// - a response the user talked over (`cancelled`) asks for nothing more: a call first seen in
///   its `response.done` is not run, and one already relayed is answered but not followed up;
/// - a response cut short (`incomplete`, by the output cap or OpenAI's content filter) is not
///   that: nobody talked over it, so its calls run and get their follow-up like a completed
///   response's, and the model hears what came of them. Zimmer refuses arguments that were cut
///   off, which is what tells the model to try again or say so. Three in a row stops asking and
///   says so, rather than retrying unheard for ever;
/// - when the output cap cost a tool call, or a reply nobody heard a word of, the call drops the
///   cap for the rest of its life (`session.update`), so the same cap cannot do it twice. A reply
///   nobody heard is asked for again. A spoken reply the cap cut off just ends: that is the cap;
/// - each call runs once, however often its events repeat;
/// - finished transcript lines are recorded, and the user starting to speak stops whatever reply
///   audio is still sounding, `response.done` or not, and tells OpenAI how much of it was heard
///   (`conversation.item.truncate`, which a WebSocket client sends itself — over WebRTC the server
///   holds the audio and does it);
/// - with Listening gated (wake word, dynamic) turn detection starts no reply and cuts none off:
///   a finished user line comes out as `hear`, Zimmer says whether to answer it, and `heard`
///   asks for the reply — or deletes the line from the call;
/// - OpenAI's `error` events, and a response that ended `failed`, come out as `failure` so the
///   call can say what went wrong instead of sitting in Listening;
/// - Send now (`endTurn()`) ends a turn turn detection has not ended yet: the speech it heard goes
///   up as the person's line (`input_audio_buffer.commit`), and the reply is asked for under the
///   usual rule. Only while there is speech to send, once per turn, and turn detection's own end
///   of the same turn, arriving late, is not a second one.
public struct RealtimeConductor: Sendable {
    public enum Effect: Equatable, Sendable {
        /// Send this client event to OpenAI.
        case send(JSONValue)
        /// Run this function call through Zimmer, then call `relayed(callID:result:)`.
        case relay(callID: String, name: String, arguments: String)
        /// A finished transcript line, for the thread.
        case record(role: LiveTurn.Role, text: String)
        /// Gated: record this user line with Zimmer, which says whether to answer it; then call
        /// `heard(itemID:respond:)`.
        case hear(itemID: String?, text: String)
        /// A tool call moved Live Mode to this conversation: reconnect onto it.
        case reattach(conversation: Int)
        /// The person asked to hang up, and the response that asked is done: end the call once
        /// the reply still sounding has finished. Said once per call.
        case hangUp
        /// Play this reply audio: 16-bit mono PCM at 24 kHz.
        case play(Data)
        /// A new reply item's audio started arriving: count it from here.
        case replyStarted(itemID: String)
        /// The user started talking: stop any reply audio still sounding, and send
        /// `truncate(itemID:audioEndMs:)` for each reply item not heard to the end
        /// (`LiveReplyPlayout`). Only the player knows which those are: a reply can sound long
        /// after its `response.done`. `arriving` is the item OpenAI was still sending, which was
        /// not heard to the end even if all the audio that reached the phone was.
        case interrupt(arriving: String?)
        case state(LiveVoiceState)
        case failure(String)
        /// For the cues: what the state alone does not say.
        case signal(LiveCueDirector.Signal)
    }

    /// Put to the model when a call has just moved to another conversation, so it speaks first and
    /// the person is not left in silence. Not on the thread: nobody said it. The same words as the
    /// web dock's (`live_voice_controller.js`).
    public static let switchedOpening = "(We have just switched to this conversation. In one short sentence, say so and where it left off, then stop.)"

    /// Every call ever started, so a repeated event never runs one twice.
    private var seen: Set<String> = []
    /// Calls started and not yet answered.
    private var inFlight: Set<String> = []
    /// Calls of a cancelled response: answered when their result comes, followed up never.
    private var dropped: Set<String> = []
    /// The reply item whose audio is arriving, until its response is done.
    private var playingItem: String?
    /// The item the user talked over while it was arriving: audio of it still on its way is
    /// not played.
    private var cutItem: String?
    /// Answered calls, until the response that asked for them is done.
    private var answered: Set<String> = []
    /// The calls of a finished response still waiting on their results.
    private var awaiting: Set<String> = []
    private var responseActive = false
    /// A `response.create` was sent and its `response.created` has not come: a second one now
    /// would be refused for the response already on its way.
    private var requested = false
    private var pendingResponse = false
    /// The person asked to hang up: nothing more is asked of the model.
    public private(set) var hangingUp = false
    private var saidHangUp = false
    /// The call asks for its own replies (Listening is wake word or dynamic).
    public private(set) var gated = false
    /// The Listening mode in force, for the call log. Follows what OpenAI applied: `always` once
    /// a session starts its own replies; a call that became gated mid-call reads `gated` here,
    /// because `session.updated` does not say which gated mode (`LiveHeard.listening` does).
    public private(set) var listening: String?
    /// The output cap is off for this call: every later `session.update` keeps it off.
    private var capLifted = false
    /// The running response has played audio.
    private var spoke = false
    /// Responses cut short with a call on them since one last completed.
    private var cutsInARow = 0
    private static let cutsBeforeGivingUp = 3

    /// Turn detection heard the person start (`speech_started`) and has not ended the turn
    /// (`speech_stopped`, `committed`): there is speech Send now can send.
    public private(set) var speechOpen = false
    /// Send now's commit is out and OpenAI has not answered it: a second tap is the same tap.
    public private(set) var endingTurn = false
    /// Send now ended the turn in progress: turn detection's own end of it is not a second end.
    private var forcedTurn = false
    private var sendNows = 0
    /// What every client event Send now sends is tagged with (`event_id`), so an `error` OpenAI
    /// answers one of them with is known for the race it is, not a failure of the call.
    public static let sendNowEventPrefix = "zimmer_send_now_"

    /// Send now would send something.
    public var canEndTurn: Bool { speechOpen && !endingTurn }

    /// What Send now came to.
    public enum EndTurn: Equatable, Sendable {
        /// The turn ended here: apply these.
        case ended([Effect])
        /// Nothing heard since the last turn ended, whoever ended it.
        case nothingToSend
        /// Send now's commit for this turn is still out.
        case alreadySending
    }

    public init(listening: String? = nil) {
        self.listening = listening
        gated = Self.gates(listening)
    }

    /// Whether a call with this Listening mode asks for its own replies.
    public static func gates(_ listening: String?) -> Bool {
        listening == "wake_word" || listening == "dynamic"
    }

    /// The session OpenAI says the call has (`session.created`, `session.updated`): its turn
    /// detection says from here on whether the call is gated (`create_response: false`). What
    /// OpenAI applied, not what was sent, so a refused `session.update` changes nothing.
    mutating func note(session: JSONValue) {
        guard case let .bool(creates)? = session["audio"]?["input"]?["turn_detection"]?["create_response"] else { return }
        if creates {
            listening = "always"
        } else if !gated {
            listening = "gated"
        }
        gated = !creates
    }

    /// Zimmer's answer for a line `hear` sent: ask for the reply once nothing else is running, or
    /// take the line out of the call.
    public mutating func heard(itemID: String?, respond: Bool) -> [Effect] {
        if respond {
            pendingResponse = true
            return [.signal(.heardPerson)] + sendPendingResponse()
        }
        // Not answered: back to listening, or the call would read as working on it for ever.
        let listening: [Effect] = responseActive || playingItem != nil ? [] : [.state(.listening)]
        guard let itemID else { return listening }
        return [.send(.object(["type": .string("conversation.item.delete"), "item_id": .string(itemID)]))] + listening
    }

    /// A line the person did not speak, put to the model as if typed: what the car sends when
    /// the driver taps a session's row, so the call opens on that session rather
    /// than on silence. A user message item, then a reply asked for under the usual rule —
    /// once nothing else is running.
    public mutating func open(with text: String) -> [Effect] {
        pendingResponse = true
        let item: JSONValue = .object([
            "type": .string("message"), "role": .string("user"),
            "content": .array([.object(["type": .string("input_text"), "text": .string(text)])]),
        ])
        return [.send(.object(["type": .string("conversation.item.create"), "item": item]))] + sendPendingResponse()
    }

    /// One server event.
    public mutating func handle(_ event: JSONValue) -> [Effect] {
        switch event["type"]?.string {
        case "input_audio_buffer.speech_started":
            speechOpen = true
            forcedTurn = false
            endingTurn = false
            // Gated, speech does not cut the reply off: it may not be meant for the call at all.
            if gated { return playingItem == nil ? [.signal(.personTalking), .state(.listening)] : [] }
            defer { playingItem = nil }
            if let playingItem { cutItem = playingItem }
            return [.interrupt(arriving: playingItem), .signal(.personTalking), .state(.listening)]
        case "input_audio_buffer.speech_stopped":
            // The person stopped talking: the call is working on an answer from here — the
            // thinking cue starts and the screen says so — until the reply starts, or (gated)
            // the line turns out not to be one to answer. Not while a reply arrives (gated
            // speech does not cut it off). Gated, the person counts as heard once Zimmer says
            // the line gets an answer (`heard`). Send now already said all of that.
            speechOpen = false
            if forcedTurn {
                forcedTurn = false
                return []
            }
            guard playingItem == nil else { return [.signal(.personStopped)] }
            return [.signal(.personStopped), .state(.thinking)] + (gated ? [] : [.signal(.heardPerson)])
        case "input_audio_buffer.committed", "input_audio_buffer.cleared":
            speechOpen = false
            guard endingTurn else { return [] }
            endingTurn = false
            // The turn Send now ended is the person's line now: ask for its reply, under the
            // usual rule. Only now, so a commit OpenAI refused never gets a reply to nothing.
            // Gated, Zimmer decides that (`hear`).
            guard event["type"]?.string == "input_audio_buffer.committed", !gated else { return [] }
            pendingResponse = true
            return sendPendingResponse(eventID: "\(Self.sendNowEventPrefix)\(sendNows)_response")
        case "response.created":
            responseActive = true
            requested = false
            spoke = false
            return [.state(.thinking)]
        case "session.created", "session.updated":
            note(session: event["session"] ?? .null)
            return []
        case "response.output_audio.delta":
            guard let delta = event["delta"]?.string, let audio = Data(base64Encoded: delta) else { return [] }
            if let item = event["item_id"]?.string, item == cutItem { return [] }
            spoke = true
            var effects: [Effect] = []
            if let item = event["item_id"]?.string, item != playingItem {
                playingItem = item
                effects.append(.replyStarted(itemID: item))
            }
            return effects + [.play(audio), .state(.speaking)]
        case "response.function_call_arguments.done":
            guard let callID = event["call_id"]?.string, let name = event["name"]?.string else { return [] }
            return start(callID: callID, name: name, arguments: event["arguments"]?.string ?? "{}")
        case "response.done":
            responseActive = false
            playingItem = nil
            if hangingUp {
                // Its calls are still relayed, never followed up: the call is ending.
                return finish(event["response"]).filter { $0 != .state(.listening) } + hangUpIfDone()
            }
            let status = event["response"]?["status"]?.string
            if status == "failed" {
                let message = event["response"]?["status_details"]?["error"]?["message"]?.string
                return finish(event["response"]).filter { $0 != .state(.listening) } + [.failure(message ?? "OpenAI could not answer that."), .state(.listening), .signal(.actionFailed)]
            }
            return finish(event["response"]) + (status == "incomplete" ? [.signal(.actionFailed)] : [])
        case "conversation.item.input_audio_transcription.completed":
            guard gated else { return record(.user, event["transcript"]?.string) }
            guard let text = event["transcript"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                return heard(itemID: event["item_id"]?.string, respond: false)
            }
            return [.hear(itemID: event["item_id"]?.string, text: text)]
        case "conversation.item.input_audio_transcription.failed":
            // Gated, a line nobody could read is not one to answer.
            return gated ? heard(itemID: event["item_id"]?.string, respond: false) : []
        case "response.output_audio_transcript.done":
            return record(.assistant, event["transcript"]?.string)
        case "error":
            // A refused `response.create` never gets its `response.created`.
            requested = false
            if let refused = event["error"]?["event_id"]?.string, refused.hasPrefix(Self.sendNowEventPrefix) {
                // Send now lost a race with turn detection, which is not a failure: turn
                // detection committed the turn first (an empty buffer), and its own path answers
                // it; or a reply is already running. Any other refusal is reported like any error.
                let code = event["error"]?["code"]?.string
                if refused.hasSuffix("_commit") {
                    endingTurn = false
                    if code == "input_audio_buffer_commit_empty" { return [] }
                } else if code == "conversation_already_has_active_response" {
                    return []
                }
            }
            // With nothing running or about to, no answer is coming: back to listening, or the
            // call would read as working on it (and tick) for ever.
            let idle = !responseActive && inFlight.isEmpty && !pendingResponse && playingItem == nil
            return [.failure(event["error"]?["message"]?.string ?? "OpenAI reported an error.")] + (idle ? [.signal(.noAnswerComing), .state(.listening)] : [])
        default:
            return []
        }
    }

    /// Send now: end the turn turn detection is still in, whatever mode it is in. The speech
    /// heard so far goes up as the person's line (`input_audio_buffer.commit`), the call moves on
    /// to working on an answer, as at `speech_stopped`, and once OpenAI says `committed` the reply
    /// is asked for: at once, or after the response the person talked over (which turn detection
    /// is cancelling) is done. Gated, Zimmer still says whether
    /// the line gets one (`hear`), as for any other. Once per turn: a second tap, or a tap after
    /// turn detection ended the turn itself, sends nothing.
    public mutating func endTurn() -> EndTurn {
        if endingTurn { return .alreadySending }
        guard speechOpen else { return .nothingToSend }
        speechOpen = false
        endingTurn = true
        forcedTurn = true
        sendNows += 1
        let tag = "\(Self.sendNowEventPrefix)\(sendNows)"
        var effects: [Effect] = [.send(.object(["type": .string("input_audio_buffer.commit"), "event_id": .string("\(tag)_commit")]))]
        guard playingItem == nil else { return .ended(effects + [.signal(.personStopped)]) }
        effects += [.signal(.personStopped), .state(.thinking)]
        return .ended(effects + (gated ? [] : [.signal(.heardPerson)]))
    }

    /// Zimmer answered a relayed call (`result`), or could not be reached (`failure`).
    public mutating func relayed(callID: String, result: LiveToolResult?, failure: String? = nil) -> [Effect] {
        guard inFlight.remove(callID) != nil else { return [] }
        if let target = result?.switchedTo { return [.reattach(conversation: target.id)] }
        if result?.hangUp == true {
            hangingUp = true
            dropped.remove(callID)
            awaiting.remove(callID)
            answered.remove(callID)
            let output: Effect = .send(.object([
                "type": .string("conversation.item.create"),
                "item": .object(["type": .string("function_call_output"), "call_id": .string(callID), "output": .string(result?.output ?? "")]),
            ]))
            return [output, .signal(.toolsRunning(inFlight.count))] + hangUpIfDone()
        }
        var effects: [Effect] = []
        if let session = result?.session {
            effects.append(.send(sessionUpdate(keeping: session)))
        } else if let result, result.toolsChanged, let tools = result.tools {
            effects.append(.send(Self.sessionUpdate(.object(["type": .string("realtime"), "tools": tools]))))
        }
        let output = result?.output ?? "Zimmer could not run that: \(failure ?? "no answer")."
        effects.insert(.send(.object([
            "type": .string("conversation.item.create"),
            "item": .object(["type": .string("function_call_output"), "call_id": .string(callID), "output": .string(output)]),
        ])), at: 0)
        if dropped.remove(callID) != nil {
            // Its response was talked over; nothing waits on it.
        } else if awaiting.remove(callID) != nil {
            if awaiting.isEmpty { pendingResponse = true }
        } else {
            answered.insert(callID)
        }
        let failed = failure != nil || result?.error == true
        return effects + sendPendingResponse() + [.signal(.toolsRunning(inFlight.count))] + (failed ? [.signal(.actionFailed)] : [])
    }

    /// The `session.update` client event carrying `session` — what Zimmer answered for a tool
    /// call that changed a Live setting, or `POST /live_conversations/:id/session_update` after
    /// the settings changed somewhere else.
    public static func sessionUpdate(_ session: JSONValue) -> JSONValue {
        .object(["type": .string("session.update"), "session": session])
    }

    /// `sessionUpdate(_:)` for a `session` Zimmer built, which names the stored output cap: a call
    /// that lifted the cap keeps it lifted.
    public func sessionUpdate(keeping session: JSONValue) -> JSONValue {
        guard capLifted, case var .object(fields) = session else { return Self.sessionUpdate(session) }
        fields["max_output_tokens"] = .string("inf")
        return Self.sessionUpdate(.object(fields))
    }

    /// Tell OpenAI the user heard only the first `audioEndMs` of reply `itemID`.
    public static func truncate(itemID: String, audioEndMs: Int) -> JSONValue {
        .object([
            "type": .string("conversation.item.truncate"), "item_id": .string(itemID),
            "content_index": .number(0), "audio_end_ms": .number(Double(max(0, audioEndMs))),
        ])
    }

    /// The microphone's audio, as the event that carries it. Muted, the same length of silence:
    /// over a WebSocket the server's turn detection hears only what is sent, so a microphone that
    /// went quiet by sending nothing would leave the turn open forever, stuck in Listening. Silence
    /// lets it end, the way a disabled WebRTC track does in the browser.
    public static func appendAudio(_ pcm16: Data, muted: Bool = false) -> JSONValue {
        let audio = muted ? Data(count: pcm16.count) : pcm16
        return .object(["type": .string("input_audio_buffer.append"), "audio": .string(audio.base64EncodedString())])
    }

    // MARK: - Internals

    private mutating func start(callID: String, name: String, arguments: String) -> [Effect] {
        guard seen.insert(callID).inserted else { return [] }
        inFlight.insert(callID)
        return [.relay(callID: callID, name: name, arguments: arguments), .signal(.toolsRunning(inFlight.count)), .state(.working)]
    }

    private mutating func finish(_ response: JSONValue?) -> [Effect] {
        let status = response?["status"]?.string
        let calls = (response?["output"]?.array ?? []).filter { $0["type"]?.string == "function_call" }
        let cut = status == "incomplete"
        if status == "completed" { cutsInARow = 0 } else if cut, !calls.isEmpty { cutsInARow += 1 }

        var effects: [Effect] = []
        let lifting = cut && !capLifted && response?["status_details"]?["reason"]?.string == "max_output_tokens"
            && (!calls.isEmpty || !spoke)
        if lifting {
            capLifted = true
            effects.append(.send(sessionUpdate(keeping: .object(["type": .string("realtime")]))))
        }
        effects += sendPendingResponse()
        guard status == nil || status == "completed" || status == "incomplete" else {
            // Talked over, or failed: a call it asked for is not started, and one already
            // relayed is answered without a follow-up.
            for call in calls {
                guard let callID = call["call_id"]?.string else { continue }
                if inFlight.contains(callID) { dropped.insert(callID) }
                answered.remove(callID)
            }
            // Nothing asked for after it: no answer is coming.
            return requested ? effects : effects + [.state(.listening)]
        }
        guard !calls.isEmpty else {
            guard lifting else { return effects + [.state(.listening)] }
            // The cap ran out before a word was said: nothing was heard, so ask again without it.
            pendingResponse = true
            return effects + sendPendingResponse()
        }

        for call in calls {
            guard let callID = call["call_id"]?.string else { continue }
            if !seen.contains(callID), let name = call["name"]?.string {
                var arguments = call["arguments"]?.string ?? ""
                // Zimmer reads blank arguments as none at all, which is a call the model did not
                // finish making. `{` is what it refuses.
                if arguments.isEmpty { arguments = cut ? "{" : "{}" }
                effects += start(callID: callID, name: name, arguments: arguments)
            }
            if answered.remove(callID) == nil { awaiting.insert(callID) }
        }
        if awaiting.isEmpty {
            pendingResponse = true
            effects += sendPendingResponse()
        }
        return effects
    }

    private mutating func hangUpIfDone() -> [Effect] {
        guard hangingUp, !responseActive, !saidHangUp else { return [] }
        saidHangUp = true
        return [.hangUp]
    }

    private mutating func sendPendingResponse(eventID: String? = nil) -> [Effect] {
        guard pendingResponse, !responseActive, !requested, !hangingUp else { return [] }
        pendingResponse = false
        if cutsInARow >= Self.cutsBeforeGivingUp {
            cutsInARow = 0
            return [.failure("OpenAI kept cutting that reply short."), .state(.listening)]
        }
        requested = true
        guard let eventID else { return [.send(.object(["type": .string("response.create")]))] }
        return [.send(.object(["type": .string("response.create"), "event_id": .string(eventID)]))]
    }

    private func record(_ role: LiveTurn.Role, _ text: String?) -> [Effect] {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return [] }
        return [.record(role: role, text: text)]
    }
}

/// The audio conversions a voice call needs: the microphone's float samples at whatever
/// rate the hardware runs to the 16-bit mono 24 kHz PCM OpenAI takes, and back for playback.
public enum RealtimeAudio {
    public static let sampleRate: Double = 24_000

    /// Linear resampling to 24 kHz, then clamped 16-bit little-endian PCM.
    public static func pcm16(from samples: [Float], sampleRate inputRate: Double) -> Data {
        guard !samples.isEmpty, inputRate > 0 else { return Data() }
        let ratio = inputRate / sampleRate
        let count = max(1, Int((Double(samples.count) / ratio).rounded(.down)))
        var data = Data(capacity: count * 2)
        for index in 0..<count {
            let position = Double(index) * ratio
            let lower = min(Int(position), samples.count - 1)
            let upper = min(lower + 1, samples.count - 1)
            let fraction = Float(position - Double(lower))
            let sample = samples[lower] + (samples[upper] - samples[lower]) * fraction
            let clamped = max(-1, min(1, sample))
            let value = Int16(clamped * Float(Int16.max))
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// 16-bit little-endian PCM to floats in -1…1.
    public static func floats(fromPCM16 data: Data) -> [Float] {
        stride(from: 0, to: data.count - 1, by: 2).map { offset in
            let value = Int16(littleEndian: Int16(bitPattern: UInt16(data[data.startIndex + offset]) | UInt16(data[data.startIndex + offset + 1]) << 8))
            return Float(value) / Float(Int16.max)
        }
    }
}
