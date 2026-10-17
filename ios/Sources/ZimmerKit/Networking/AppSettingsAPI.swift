import Foundation

/// The Settings page's row: the global session defaults, the experimental toggles and MCP
/// Apps (`Api::V1::AppSettingsController`, open to the app's token). The session defaults and
/// the toggles are anyone's to change; the MCP Apps pair takes a sign-in acting as you, and
/// a relay-only grant gets a 403 with the rule in its message.
public protocol AppSettingsAPI: Sendable {
    func appSettings() async throws -> AppSettings
    /// Change any subset of the row; answers with the whole row after the save.
    func updateAppSettings(_ change: AppSettingsChange) async throws -> AppSettings
}

// `ZimmerHTTPClient: ZimmerAPI`, which refines `AppSettingsAPI`.
extension ZimmerHTTPClient {
    public func appSettings() async throws -> AppSettings {
        let response: AppSettingsEnvelope = try await get("/api/v1/app_settings")
        return response.app_settings
    }

    public func updateAppSettings(_ change: AppSettingsChange) async throws -> AppSettings {
        let response: AppSettingsEnvelope = try await patch("/api/v1/app_settings", json: change.body)
        return response.app_settings
    }
}

struct AppSettingsEnvelope: Decodable {
    let app_settings: AppSettings
}
