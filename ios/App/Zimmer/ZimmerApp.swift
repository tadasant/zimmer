import SwiftUI
import UIKit
import UserNotifications
import ZimmerKit

/// The app: SwiftUI screens over ZimmerKit. The screens hold no sign-in rules and no
/// networking; `AppEnvironment` chooses the adapters and `AppModel` holds what is shown.
@main
struct ZimmerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .task {
                    PushCoordinator.shared.model = model
                    await model.start()
                }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushCoordinator.shared.didRegister(deviceToken: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        PushCoordinator.shared.didFailToRegister(error)
    }

    /// Shown even while the app is open: a session asking for input is worth the banner.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let payload = PushPayload(userInfo: response.notification.request.content.userInfo)
        await MainActor.run { PushCoordinator.shared.open(payload) }
    }
}
