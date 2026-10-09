import SwiftUI
import UIKit

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
                .task { await model.start() }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        true
    }
}
