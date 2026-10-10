import SwiftUI
import ZimmerKit

/// Sign-in gates everything; after it, the session list.
struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if let badge = AppConfiguration.buildEnvironment.badge {
                BuildBadge(text: badge, summary: model.buildTarget.summary)
            }
            switch model.isSignedIn {
            case .none:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .some(false):
                SignInView()
            case .some(true):
                NavigationStack(path: $model.path) {
                    SessionListView()
                        .navigationDestination(for: Int.self) { id in
                            SessionDetailView(id: id, api: model.api)
                        }
                }
            }
        }
    }
}

/// A strip that says which deployment a non-production build is for, so a staging screen
/// is never mistaken for the real one.
struct BuildBadge: View {
    let text: String
    let summary: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 3)
            .background(Color.orange)
            .accessibilityIdentifier("build.badge")
            .accessibilityValue(summary)
    }
}
