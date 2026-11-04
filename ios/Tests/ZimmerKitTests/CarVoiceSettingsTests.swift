import Foundation
import XCTest
@testable import ZimmerKit

/// The car's voice settings panel: that it shows the value the voice route wrote, writes the same
/// one back, offers nothing the call would not act on, and that Reset to defaults clears what has
/// really broken a call. `FakeZimmerAPI` holds the server's one row and its rules, so a value it
/// starts with is one a voice call left there.
@MainActor
final class CarVoiceSettingsTests: XCTestCase {
    /// The row as voice calls left it on the call that broke (session 26864's post-mortem): a
    /// reply cap of 180, a gated Listening, and a threshold Semantic turn detection never sends.
    private static let broken: [String: JSONValue] = [
        "voice_max_output_tokens": .number(180), "voice_listening": .string("dynamic"),
        "voice_vad_eagerness": .string("low"), "voice_vad_threshold": .number(0.92), "voice_vad_silence_duration_ms": .number(1_200),
    ]
    /// The same row on Silence turn detection, where the threshold does reach OpenAI.
    private static let silence = broken.merging(["voice_turn_detection": .string("server_vad")]) { first, _ in first }

    private func panel(_ live: [String: JSONValue] = [:]) async -> (CarVoiceSettingsModel, FakeZimmerAPI) {
        let api = FakeZimmerAPI(liveSettings: live)
        let model = CarVoiceSettingsModel(api: api)
        await model.load()
        return (model, api)
    }

    private func row(_ model: CarVoiceSettingsModel, _ key: String) throws -> CarVoiceSettings.Row {
        try XCTUnwrap(model.settings?.rows.first { $0.key == key }, "no row for \(key)")
    }

    private func choice(_ row: CarVoiceSettings.Row, _ title: String) throws -> CarVoiceSettings.Choice {
        try XCTUnwrap(row.choices.first { $0.title == title }, "\(row.key) offers \(row.choices.map(\.title))")
    }

    private func client(_ handlers: [ScriptedTransport.Handler]) -> (ZimmerHTTPClient, ScriptedTransport) {
        let transport = ScriptedTransport(handlers)
        return (ZimmerHTTPClient(auth: AuthSession(store: Fixtures.signedIn(), transport: transport), transport: transport), transport)
    }

    // MARK: - Reading

    func testTheCapAVoiceCallPushedTooFarIsTheFirstThingThePanelShows() async throws {
        let (model, _) = await panel(Self.broken)
        XCTAssertEqual(model.settings?.rows.first?.key, "voice_max_output_tokens")
        let cap = try row(model, "voice_max_output_tokens")
        XCTAssertEqual(cap.detail, "180")
        XCTAssertEqual(cap.choices.map(\.title), ["No cap (default)", "180", "512", "1024", "2048"], "the value in force is on the list though it is no preset")
        XCTAssertEqual(cap.choices.filter(\.isCurrent).map(\.title), ["180"])
        XCTAssertEqual(try choice(cap, "No cap (default)").value, .null, "no cap is the setting back on its default")
    }

    func testTheCapReadsAsNoCapWhenItIsNotSet() async throws {
        let (model, _) = await panel()
        let cap = try row(model, "voice_max_output_tokens")
        XCTAssertEqual(cap.detail, "No cap (default)")
        XCTAssertEqual(cap.choices.filter(\.isCurrent).map(\.title), ["No cap (default)"])
    }

    /// The server's range decides what is offered, so a raised floor needs no change here.
    func testAPresetUnderTheServersFloorIsNotOffered() {
        let field = LiveSettingField(key: "voice_max_output_tokens", path: "voice", type: .integer, label: "Voice max output tokens", min: 800, max: 4_096)
        let settings = CarVoiceSettings(LiveSettings(settings: ["voice_max_output_tokens": .null], fields: [field]))
        XCTAssertEqual(settings.rows.first?.choices.map(\.title), ["No cap (default)", "1024", "2048"])
    }

    /// Under Semantic, the default, `RealtimeSession` sends eagerness and nothing else, so a
    /// threshold or a pause control would be a placebo: the row is not there, and Turn detection
    /// says what would bring it back.
    func testASettingTheTurnDetectionDoesNotSendHasNoRow() async throws {
        let (semantic, _) = await panel(Self.broken)
        let keys = semantic.settings?.rows.map(\.key) ?? []
        XCTAssertFalse(keys.contains("voice_vad_threshold"), "0.92 goes nowhere under Semantic")
        XCTAssertFalse(keys.contains("voice_vad_silence_duration_ms"))
        XCTAssertEqual(try row(semantic, "voice_vad_eagerness").detail, "low")
        XCTAssertEqual(try row(semantic, "voice_turn_detection").detail, "Semantic (default). Threshold and pause need Silence")

        let (silence, _) = await panel(Self.silence)
        let silenceKeys = silence.settings?.rows.map(\.key) ?? []
        XCTAssertFalse(silenceKeys.contains("voice_vad_eagerness"), "and the other way round")
        XCTAssertEqual(try row(silence, "voice_vad_threshold").detail, "0.92")
        XCTAssertEqual(try row(silence, "voice_vad_silence_duration_ms").detail, "1200 ms")
        XCTAssertEqual(try row(silence, "voice_turn_detection").detail, "Silence")
    }

    /// Picking Silence brings the threshold up on the panel's next draw, from the answer to the
    /// write: the row the driver just made real is the row they see.
    func testChoosingSilenceBringsTheThresholdBack() async throws {
        let (model, _) = await panel(Self.broken)
        let detection = try row(model, "voice_turn_detection")
        model.open(detection)
        model.choose(try choice(detection, "Silence"))
        await model.settled()
        XCTAssertEqual(try row(model, "voice_vad_threshold").detail, "0.92")
    }

    func testTheDefaultsAreSaidAndChoicesAreFewAndWithinTheServersRange() async throws {
        let (model, _) = await panel(["voice_turn_detection": .string("server_vad")])
        XCTAssertEqual(try row(model, "voice_vad_threshold").detail, "0.5 (default)")
        XCTAssertEqual(try row(model, "voice_noise_reduction").detail, "Off (default)")
        XCTAssertEqual(try row(model, "voice_speed").detail, "1× (default)")
        XCTAssertEqual(try row(model, "voice_vad_threshold").choices.map(\.title), ["0.3", "0.5 (default)", "0.7", "0.9"])
        XCTAssertEqual(try row(model, "voice_vad_silence_duration_ms").choices.map(\.title), ["300 ms", "500 ms (default)", "800 ms", "1200 ms"])
        XCTAssertEqual(try row(model, "voice_noise_reduction").choices.map(\.title), ["Off (default)", "near field", "far field"])
        XCTAssertEqual(try row(model, "voice_vad_threshold").choices.first?.note, "Hears quiet speech")
        for row in model.settings?.rows ?? [] {
            XCTAssertLessThanOrEqual(row.choices.count, 5, "\(row.key) is too many to take in at a glance")
        }
    }

    /// The car is built as Always whatever Listening says, but a call handed to the phone is not,
    /// so the row is real and has to say where it applies.
    func testListeningIsOfferedAndSaysItIsThePhonesOnly() async throws {
        let (model, _) = await panel(Self.broken)
        let listening = try row(model, "voice_listening")
        XCTAssertEqual(listening.detail, "Dynamic. On the phone. The car always answers")
        XCTAssertEqual(listening.choices.map(\.title), ["Always (default)", "Wake word", "Dynamic"])
        XCTAssertTrue(CarVoiceSettings.resetKeys.contains("voice_listening"))
    }

    func testAServerThatDoesNotNameASettingGetsNoRowForIt() {
        let field = LiveSettingField(key: "voice_speed", path: "voice", type: .float, label: "Speaking speed", min: 0.25, max: 1.5, defaultValue: .number(1))
        let settings = CarVoiceSettings(LiveSettings(settings: ["voice_speed": .number(1)], fields: [field]))
        XCTAssertEqual(settings.rows.map(\.key), ["voice_speed"])
    }

    func testAFailedReadLeavesAProblemToRetry() async throws {
        let (api, _) = client([])
        let model = CarVoiceSettingsModel(api: api)
        await model.load()
        XCTAssertNil(model.settings)
        XCTAssertNotNil(model.problem)
    }

    // MARK: - Writing

    func testAChoiceWritesTheRowAndTheNextReadSeesIt() async throws {
        let (model, api) = await panel(Self.silence)
        var written: [String] = []
        model.onWritten = { written.append($0) }
        let threshold = try row(model, "voice_vad_threshold")
        model.open(threshold)
        XCTAssertEqual(model.openRow?.key, "voice_vad_threshold")
        model.choose(try choice(threshold, "0.3"))
        await model.settled()

        XCTAssertEqual(model.page, .settings, "a choice is one tap, back to the list")
        XCTAssertEqual(try row(model, "voice_vad_threshold").detail, "0.3")
        XCTAssertEqual(written, ["voice_vad_threshold"])
        let read = try await api.liveSettings()
        XCTAssertEqual(read.value("voice_vad_threshold"), .number(0.3), "the row every other reader reads")
        XCTAssertEqual(read.history.first?.actor, "the iOS app", "and it is in the history as every write is")
    }

    /// A choice of the default clears the override rather than pinning it, so the setting moves
    /// with the shipped default and Reset has nothing left to do for it.
    func testChoosingTheDefaultPutsTheSettingBackOnIt() async throws {
        let (model, api) = await panel(Self.silence)
        let threshold = try row(model, "voice_vad_threshold")
        model.open(threshold)
        model.choose(try choice(threshold, "0.5 (default)"))
        await model.settled()
        let read = try await api.liveSettings()
        XCTAssertFalse(read.isOverridden("voice_vad_threshold"))
        XCTAssertEqual(read.value("voice_vad_threshold"), .number(0.5))
    }

    func testChoosingWhatIsInUseWritesNothing() async throws {
        let (model, api) = await panel(Self.silence)
        let threshold = try row(model, "voice_vad_threshold")
        model.open(threshold)
        model.choose(try choice(threshold, "0.95"))
        await model.settled()
        XCTAssertEqual(model.page, .settings)
        let read = try await api.liveSettings()
        XCTAssertEqual(read.history, [], "nothing changed, so nothing is recorded")
    }

    func testARefusedWriteIsSaidAndTheRowIsLeftAsItWas() async throws {
        let (model, api) = await panel(Self.silence)
        let threshold = try row(model, "voice_turn_detection")
        model.open(threshold)
        model.choose(CarVoiceSettings.Choice(title: "Nonsense", note: nil, value: .string("nonsense"), isCurrent: false))
        await model.settled()
        XCTAssertTrue(model.problem?.hasPrefix("Not saved:") == true, model.problem ?? "no problem")
        XCTAssertEqual(model.openRow?.key, "voice_turn_detection", "the choices stay up to try again")
        XCTAssertFalse(model.saving)
        let read = try await api.liveSettings()
        XCTAssertEqual(read.value("voice_turn_detection"), .string("server_vad"))
    }

    /// The call comes back when the panel closes, and is minted from the row: it has to wait for
    /// the write, or a driver who taps and closes at once comes back on the old value.
    func testSettledWaitsForTheWriteAndATapDuringOneIsIgnored() async throws {
        let (model, api) = await panel(Self.silence)
        let threshold = try row(model, "voice_vad_threshold")
        model.open(threshold)
        model.choose(try choice(threshold, "0.3"))
        XCTAssertTrue(model.saving)
        model.reset()
        await model.settled()
        let read = try await api.liveSettings()
        XCTAssertEqual(read.value("voice_vad_threshold"), .number(0.3), "the reset was a second write while the first was out")
    }

    // MARK: - Reset to defaults

    /// The break-glass: whatever the voice route left, Reset puts it back, hidden rows included.
    func testResetClearsTheCapAndListeningAndLeavesTheModelAndVoiceAlone() async throws {
        let (model, api) = await panel(Self.broken.merging([
            "voice_vad_prefix_padding_ms": .number(0), "voice_noise_reduction": .string("far_field"), "voice_speed": .number(1.4),
            "voice_name": .string("cedar"), "text_model": .string("gpt-6-sol"),
        ]) { first, _ in first })
        XCTAssertEqual(model.settings?.canReset, true)
        model.reset()
        await model.settled()

        let read = try await api.liveSettings()
        XCTAssertEqual(read.value("voice_max_output_tokens"), .null, "no cap")
        XCTAssertEqual(read.value("voice_listening"), .string("always"))
        XCTAssertEqual(read.value("voice_vad_eagerness"), .string("auto"))
        XCTAssertEqual(read.value("voice_vad_threshold"), .number(0.5), "hidden under Semantic and cleared all the same")
        XCTAssertEqual(read.value("voice_vad_silence_duration_ms"), .number(500))
        XCTAssertEqual(read.value("voice_vad_prefix_padding_ms"), .number(300))
        XCTAssertEqual(read.value("voice_noise_reduction"), .null)
        XCTAssertEqual(read.value("voice_speed"), .number(1.0))
        XCTAssertEqual(read.overrides.sorted(), ["text_model", "voice_name"], "somebody's choice of model and voice is not a knob pushed too far")
        XCTAssertEqual(model.settings?.canReset, false, "and nothing is left to reset")
        XCTAssertEqual(try row(model, "voice_max_output_tokens").detail, "No cap (default)")
    }

    /// A value Reset would clear is a reason to offer it even when no row shows it.
    func testAHiddenOverrideAloneStillOffersReset() async {
        let (model, _) = await panel(["voice_vad_threshold": .number(0.92)])
        XCTAssertEqual(model.settings?.canReset, true)
    }

    func testResetCoversEveryRow() async {
        let (model, _) = await panel()
        let (silence, _) = await panel(Self.silence)
        XCTAssertEqual(model.settings?.rows.count, 6, "Semantic: cap, turn detection, eagerness, listening, noise, speed")
        XCTAssertEqual(silence.settings?.rows.count, 7, "Silence: threshold and pause for eagerness")
        for row in (model.settings?.rows ?? []) + (silence.settings?.rows ?? []) {
            XCTAssertTrue(CarVoiceSettings.resetKeys.contains(row.key), "\(row.key) can be moved here and not put back here")
        }
    }

    func testResetOnTheDefaultsWritesNothing() async throws {
        let (model, api) = await panel()
        model.reset()
        await model.settled()
        let read = try await api.liveSettings()
        XCTAssertEqual(read.history, [])
    }

    /// What goes over the wire: a real null, which is what `SettingsUpdate` takes as "back on the
    /// default", not the text "null".
    func testResetSendsNullsToTheSameEndpointAsEveryOtherWrite() async throws {
        let (api, transport) = client([
            { _ in Fixtures.json(200, Self.serverSettings(threshold: 0.95, overrides: ["voice_vad_threshold"])) },
            { _ in Fixtures.json(200, Self.serverSettings(threshold: 0.5, overrides: [])) },
        ])
        let model = CarVoiceSettingsModel(api: api)
        await model.load()
        model.reset()
        await model.settled()
        XCTAssertEqual(transport.sent.map { "\($0.method) \($0.url.path)" }, ["GET /api/v1/live/settings", "PATCH /api/v1/live/settings"])
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: transport.sent[1].body ?? Data()) as? [String: Any])
        XCTAssertEqual(Array(body.keys), ["voice_vad_threshold"])
        XCTAssertTrue(body["voice_vad_threshold"] is NSNull)
    }

    private static func serverSettings(threshold: Double, overrides: [String]) -> [String: Any] {
        [
            "settings": ["voice_vad_threshold": threshold],
            "overrides": overrides,
            "fields": [["key": "voice_vad_threshold", "path": "voice", "type": "float", "label": "Threshold (silence)", "help": "",
                        "min": 0.1, "max": 0.95, "default": 0.5, "mid_call": true] as [String: Any]],
            "history": [],
        ]
    }
}
