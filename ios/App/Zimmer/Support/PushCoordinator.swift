import Foundation
import UIKit
import UserNotifications
import ZimmerKit
import os

/// Push notifications, end to end on the phone: ask permission, register with APNs, hand
/// the token to Zimmer (`POST /api/v1/apns_devices`), and open the session a tapped
/// notification is about. A singleton because the app delegate receives the token and the
/// taps, and it has no SwiftUI environment to reach the model through.
@MainActor
final class PushCoordinator {
    static let shared = PushCoordinator()

    weak var model: AppModel?
    private let tokenKey = "zimmer.apnsToken"
    private let log = Logger(subsystem: "com.tadasant.zimmer", category: "push")

    /// A development build talks to APNs' sandbox, a TestFlight or App Store build to
    /// production — and a token is only valid against the environment that issued it.
    /// Staging keeps `DEBUG`, and is installed from Xcode, so it is a sandbox build too.
    static var environment: APNsEnvironment {
        #if DEBUG
        return .sandbox
        #else
        return .production
        #endif
    }

    /// Ask once (iOS remembers the answer) and register if allowed. Called after sign-in.
    func enable() async {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            guard granted else {
                log.info("notifications declined")
                return
            }
            UIApplication.shared.registerForRemoteNotifications()
        } catch {
            log.error("notification authorization failed: \(String(describing: error), privacy: .public)")
        }
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func didRegister(deviceToken: Data) {
        let token = PushToken.hex(deviceToken)
        guard let api = model?.api else { return }
        let environment = Self.environment
        let version = Self.appVersion
        Task {
            do {
                try await api.registerDevice(token: token, environment: environment, deviceName: UIDevice.current.name, appVersion: version)
                UserDefaults.standard.set(token, forKey: tokenKey)
                log.info("registered for push (\(environment.rawValue, privacy: .public))")
            } catch {
                log.error("push registration failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func didFailToRegister(_ error: Error) {
        log.error("APNs registration failed: \(String(describing: error), privacy: .public)")
    }

    /// On sign-out, before the credential goes: this phone should stop getting pushes.
    func unregister() async {
        guard let token = UserDefaults.standard.string(forKey: tokenKey), let api = model?.api else { return }
        do {
            try await api.unregisterDevice(token: token)
        } catch {
            log.error("push unregistration failed: \(String(describing: error), privacy: .public)")
        }
        UserDefaults.standard.removeObject(forKey: tokenKey)
    }

    /// A tapped notification opens its session.
    func open(_ payload: PushPayload) {
        guard let id = payload.sessionID else { return }
        model?.path = [id]
    }

    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }
}
