import Foundation
import UIKit
import UserNotifications
import ZimmerKit
import os

/// Push notifications, end to end on the phone: ask permission, register with APNs, hand
/// the token to Zimmer (`POST /api/v1/apns_devices`), and open the session a tapped
/// notification is about. A singleton because the app delegate receives the token and the
/// taps, and it has no SwiftUI environment to reach the model through.
///
/// Every step that can stop the phone short of a registration — the permission declined,
/// APNs refusing a token, Zimmer refusing the token — is reported to Zimmer
/// (`POST /api/v1/apns_devices/failure`, logged at WARN) and shown in Settings, because the
/// phone's own log is out of everyone's reach.
@MainActor
final class PushCoordinator: ObservableObject {
    static let shared = PushCoordinator()

    weak var model: AppModel? {
        didSet {
            guard model != nil else { return }
            // A notification tapped to launch the app can arrive before the model exists.
            if let pending { self.pending = nil; open(pending) }
            if let pendingToken { self.pendingToken = nil; didRegister(deviceToken: pendingToken) }
        }
    }
    private var pending: PushPayload?
    private var pendingToken: Data?
    private let tokenKey = "zimmer.apnsToken"
    private let registrationKey = "zimmer.apnsRegistration"
    private let reportedDeclineKey = "zimmer.apnsReportedDecline"
    private let log = Logger(subsystem: "com.tadasant.zimmer", category: "push")

    /// How this phone's last registration went, for Settings: registered, or where it stopped.
    @Published private(set) var registration: String?

    private init() {
        registration = UserDefaults.standard.string(forKey: registrationKey)
    }

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

    /// Ask once (iOS remembers the answer) and register if allowed. Called after sign-in,
    /// on every launch signed in, and from Settings.
    func enable() async {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            guard granted else {
                log.warning("notifications declined")
                record("Off: notifications are not allowed for Zimmer in iOS Settings")
                // Once per decline, not on every launch: it is the person's choice, and the
                // server only needs to know why this phone has no registration.
                if !UserDefaults.standard.bool(forKey: reportedDeclineKey) {
                    report(.declined, "notification permission not granted") { [key = reportedDeclineKey] in
                        UserDefaults.standard.set(true, forKey: key)
                    }
                }
                return
            }
            UserDefaults.standard.removeObject(forKey: reportedDeclineKey)
            UIApplication.shared.registerForRemoteNotifications()
        } catch {
            log.error("notification authorization failed: \(String(describing: error), privacy: .public)")
            record("Failed to ask for permission: \(Self.describe(error))")
            report(.declined, "authorization request failed: \(String(describing: error))")
        }
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func didRegister(deviceToken: Data) {
        guard let api = model?.api else {
            // Held until the model exists rather than dropped: a token lost here is a phone
            // that never registers and nothing that says so.
            pendingToken = deviceToken
            return
        }
        let token = PushToken.hex(deviceToken)
        let environment = Self.environment
        let version = Self.appVersion
        Task {
            do {
                try await api.registerDevice(token: token, environment: environment, deviceName: UIDevice.current.name, appVersion: version)
                UserDefaults.standard.set(token, forKey: tokenKey)
                log.info("registered for push (\(environment.rawValue, privacy: .public))")
                record("Registered (\(environment.rawValue))")
            } catch {
                log.error("push registration failed: \(String(describing: error), privacy: .public)")
                record("Could not register with Zimmer: \(Self.describe(error))")
                report(.register, String(describing: error))
            }
        }
    }

    func didFailToRegister(_ error: Error) {
        log.error("APNs registration failed: \(String(describing: error), privacy: .public)")
        record("APNs refused a token: \(Self.describe(error))")
        report(.apns, String(describing: error))
    }

    /// On sign-out, before the credential goes: this phone should stop getting pushes.
    func unregister() async {
        // Cleared whether or not this phone ever registered: the next sign-in may be to
        // another deployment, which has heard none of this.
        UserDefaults.standard.removeObject(forKey: registrationKey)
        UserDefaults.standard.removeObject(forKey: reportedDeclineKey)
        registration = nil
        pendingToken = nil
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
        guard let model else {
            pending = payload
            return
        }
        model.path = [id]
    }

    private func record(_ outcome: String) {
        registration = outcome
        UserDefaults.standard.set(outcome, forKey: registrationKey)
    }

    /// Best-effort: a report that cannot reach Zimmer either is already in the phone's log.
    /// `delivered` runs only once Zimmer has taken it.
    private func report(_ stage: PushFailureStage, _ detail: String, delivered: (@MainActor @Sendable () -> Void)? = nil) {
        guard let api = model?.api else { return }
        let environment = Self.environment
        let version = Self.appVersion
        Task {
            do {
                try await api.reportPushFailure(stage: stage, error: detail, environment: environment,
                                                deviceName: UIDevice.current.name, appVersion: version)
                delivered?()
            } catch {
                self.log.error("push failure report failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// What Settings shows: ZimmerKit's own wording for its errors, iOS's for the rest.
    private static func describe(_ error: Error) -> String {
        (error as? ZimmerError)?.userMessage ?? error.localizedDescription
    }

    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }
}
