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
/// **One phone, several deployments.** APNs gives the phone one token, and the phone registers
/// it with each deployment as that deployment comes to the front (`enable`, from
/// `AppModel.start`), so every deployment signed in to here can reach it. What this keeps about
/// a registration — the token sent, how it went, a reported decline — is kept per deployment
/// (`Deployment.defaultsKey`), and removing a deployment unregisters only from it. A tapped push
/// says which deployment sent it (`deployment`, a digest of its host), and opens there, switching first if it must.
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
            registration = UserDefaults.standard.string(forKey: key(registrationKey))
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

    /// The keys this writes, by their names before deployments had prefixes: the migrated
    /// deployment's (`Deployment.migratedID`) are still these.
    static let legacyDefaultsKeys = ["zimmer.apnsToken", "zimmer.apnsRegistration", "zimmer.apnsReportedDecline"]

    private init() {}

    /// `name`, as the deployment in front stores it.
    private func key(_ name: String) -> String {
        model?.deployment?.defaultsKey(name) ?? name
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
                if !UserDefaults.standard.bool(forKey: key(reportedDeclineKey)) {
                    report(.declined, "notification permission not granted") { [declineKey = key(reportedDeclineKey)] in
                        UserDefaults.standard.set(true, forKey: declineKey)
                    }
                }
                return
            }
            UserDefaults.standard.removeObject(forKey: key(reportedDeclineKey))
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
        guard let model, let deployment = model.deployment else {
            // Held until the model exists rather than dropped: a token lost here is a phone
            // that never registers and nothing that says so.
            pendingToken = deviceToken
            return
        }
        let api = model.api
        let token = PushToken.hex(deviceToken)
        let environment = Self.environment
        let version = Self.appVersion
        let tokenKey = deployment.defaultsKey(self.tokenKey)
        let registrationKey = deployment.defaultsKey(self.registrationKey)
        Task {
            do {
                try await api.registerDevice(token: token, environment: environment, deviceName: UIDevice.current.name, appVersion: version)
                UserDefaults.standard.set(token, forKey: tokenKey)
                log.info("registered for push (\(environment.rawValue, privacy: .public))")
                record("Registered (\(environment.rawValue))", key: registrationKey)
            } catch {
                log.error("push registration failed: \(String(describing: error), privacy: .public)")
                record("Could not register with Zimmer: \(Self.describe(error))", key: registrationKey)
                report(.register, String(describing: error))
            }
        }
    }

    func didFailToRegister(_ error: Error) {
        log.error("APNs registration failed: \(String(describing: error), privacy: .public)")
        record("APNs refused a token: \(Self.describe(error))")
        report(.apns, String(describing: error))
    }

    /// On signing out of `deployment`, before its credential goes, through its own `api`: that
    /// deployment should stop sending this phone pushes. The others keep theirs.
    func unregister(from api: ZimmerAPI, deployment: Deployment) async {
        // Cleared whether or not this phone ever registered there.
        UserDefaults.standard.removeObject(forKey: deployment.defaultsKey(self.registrationKey))
        UserDefaults.standard.removeObject(forKey: deployment.defaultsKey(self.reportedDeclineKey))
        if model?.deployment?.id == deployment.id {
            registration = nil
            pendingToken = nil
        }
        let tokenKey = deployment.defaultsKey(self.tokenKey)
        guard let token = UserDefaults.standard.string(forKey: tokenKey) else { return }
        do {
            try await api.unregisterDevice(token: token)
        } catch {
            log.error("push unregistration failed: \(String(describing: error), privacy: .public)")
        }
        UserDefaults.standard.removeObject(forKey: tokenKey)
    }

    /// A tapped notification opens its session, on the deployment that sent it: in front
    /// already, or brought there first (the new model picks the push up from `pending`). A push
    /// from a deployment that is not on the list, or one that does not say where it came from
    /// while several could have sent it, only brings the app forward — a session id opened on
    /// the wrong deployment would show some other session.
    func open(_ payload: PushPayload) {
        guard let id = payload.sessionID else { return }
        LiveCall.shared.personChoseElsewhere()
        guard let model else {
            pending = payload
            return
        }
        switch Workspaces.shared.list.route(forPush: payload.deployment) {
        case .active:
            model.path = [id]
        case let .other(deployment):
            log.info("push is for another deployment; switching")
            pending = payload
            Workspaces.shared.switchTo(deployment.id)
        case .unknown:
            log.notice("push from a deployment this phone cannot place; not opening session \(id, privacy: .public)")
        }
    }

    private func record(_ outcome: String, key: String? = nil) {
        let key = key ?? self.key(registrationKey)
        // A registration answered after a switch is about the deployment behind; Settings shows
        // the one in front's.
        if key == self.key(registrationKey) { registration = outcome }
        UserDefaults.standard.set(outcome, forKey: key)
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
