import AVFoundation
import Foundation
import ZimmerKit

/// The app's one call log (`LiveTelemetry`, in ZimmerKit): every Live voice call, from the phone
/// or the car, reports through it, and it sends to the deployment the app is signed in to
/// (`POST /api/v1/live/telemetry`), which puts each event on the shipped log stream.
///
/// How much it keeps is Zimmer's Live setting `voice_telemetry` (Settings → Live settings → Call
/// telemetry), which each call's client secret and each batch's answer carry. Until the app has
/// heard one, it reports everything (`debug`). `LiveCall` sends what is waiting when a call ends
/// and when the app goes to the background.
extension LiveTelemetry {
    static let shared: LiveTelemetry = {
        let info = Bundle.main.infoDictionary
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let telemetry = LiveTelemetry(client: LiveTelemetryClient(
            surface: ClientSource.Surface.ios.rawValue,
            appVersion: info?["CFBundleShortVersionString"] as? String,
            appBuild: info?["CFBundleVersion"] as? String,
            os: "iOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            device: machine()
        ))
        telemetry.setSink { batch in
            let api = await MainActor.run { AppEnvironment.shared.connection.api }
            return try await api.reportLiveTelemetry(batch)
        }
        return telemetry
    }()

    /// The phone's model identifier (`iPhone17,1`), not its name, which is personal.
    private static func machine() -> String {
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}

/// The events only the app can describe: the audio session, its route and interruptions, the
/// engine, and the car's screen.
extension LiveEvent {
    static func micPermission(granted: Bool, ms: TimeInterval) -> LiveEvent {
        LiveEvent(granted ? .info : .error, "audio.mic_permission") { ["granted": .bool(granted), "duration_ms": .ms(ms)] }
    }

    static func audioSessionConfigured(_ session: AVAudioSession) -> LiveEvent {
        // Read now, on the main thread, not later inside the fields closure.
        let category = session.category.rawValue
        let mode = session.mode.rawValue
        let options = session.categoryOptions.rawValue
        let rate = session.sampleRate
        let buffer = session.ioBufferDuration
        let route = describe(session.currentRoute)
        return LiveEvent(.info, "audio.session_configured") {
            ["category": .string(category), "mode": .string(mode), "options": .int(Int(options)),
             "sample_rate": .number(rate), "io_buffer_ms": .ms(buffer)].merging(route) { $1 }
        }
    }

    static func audioEngineStarted(inputRate: Double, inputChannels: Int, voiceProcessing: Bool, restart: Bool) -> LiveEvent {
        LiveEvent(.info, restart ? "audio.engine_restarted" : "audio.engine_started") {
            ["input_rate": .number(inputRate), "input_channels": .int(inputChannels), "voice_processing": .bool(voiceProcessing)]
        }
    }

    static func audioEngineFailed(_ message: String, restart: Bool) -> LiveEvent {
        LiveEvent(.error, restart ? "audio.engine_restart_failed" : "audio.engine_failed") { ["message": .string(message)] }
    }

    static func audioConfigurationChanged(running: Bool) -> LiveEvent {
        LiveEvent(.info, "audio.engine_configuration_changed") { ["engine_running": .bool(running)] }
    }

    static func audioRouteChanged(reason: AVAudioSession.RouteChangeReason, route: AVAudioSessionRouteDescription) -> LiveEvent {
        let described = describe(route)
        let reason = routeChangeReason(reason)
        return LiveEvent(.info, "audio.route_changed") { described.merging(["reason": .string(reason)]) { $1 } }
    }

    static func audioInterruption(began: Bool, shouldResume: Bool?, reason: UInt?) -> LiveEvent {
        LiveEvent(.warn, began ? "audio.interruption_began" : "audio.interruption_ended") {
            ["should_resume": shouldResume.map(JSONValue.bool) ?? .null, "reason": .int(reason.map { Int($0) })]
        }
    }

    static func mediaServicesReset() -> LiveEvent {
        LiveEvent(.error, "audio.media_services_reset")
    }

    static func carPlay(_ what: String, level: LiveTelemetryLevel = .info, _ fields: [String: JSONValue] = [:]) -> LiveEvent {
        LiveEvent(level, "carplay.\(what)") { fields }
    }

    private static func describe(_ route: AVAudioSessionRouteDescription) -> [String: JSONValue] {
        [
            "inputs": .string(route.inputs.map { $0.portType.rawValue }.joined(separator: ",")),
            "outputs": .string(route.outputs.map { $0.portType.rawValue }.joined(separator: ",")),
        ]
    }

    private static func routeChangeReason(_ reason: AVAudioSession.RouteChangeReason) -> String {
        switch reason {
        case .newDeviceAvailable: return "new_device_available"
        case .oldDeviceUnavailable: return "old_device_unavailable"
        case .categoryChange: return "category_change"
        case .override: return "override"
        case .wakeFromSleep: return "wake_from_sleep"
        case .noSuitableRouteForCategory: return "no_suitable_route"
        case .routeConfigurationChange: return "route_configuration_change"
        case .unknown: return "unknown"
        @unknown default: return "other_\(reason.rawValue)"
        }
    }
}
