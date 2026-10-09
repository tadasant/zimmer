import SwiftUI
import ZimmerKit

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Signed in to") {
                    Text(model.signedInOrigins?.web.host ?? "—")
                        .accessibilityIdentifier("settings.server")
                    if let origins = model.signedInOrigins, origins.isSplit {
                        LabeledContent("App host", value: origins.api.host ?? "—")
                    }
                }
                if model.hasEdge {
                    Section {
                        LabeledContent("Expires") {
                            if let expiry = model.edgeExpiry { Text(expiry, style: .relative) } else { Text("Not signed in") }
                        }
                        Button("Sign in to the edge again") { Task { await model.signInToEdge() } }
                            .accessibilityIdentifier("settings.edge.signin")
                    } header: {
                        Text("Edge sign-in")
                    } footer: {
                        Text("The app host sits behind an access proxy with its own sign-in. It renews itself a day before it expires.")
                    }
                }
                Section("This build") {
                    LabeledContent("Version", value: Self.version)
                    Text(model.buildTarget.summary)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("build.target")
                }
                Section {
                    Button("Sign out", role: .destructive) {
                        Task {
                            await model.signOut()
                            dismiss()
                        }
                    }
                    .accessibilityIdentifier("settings.signout")
                } footer: {
                    Text("Signing out revokes this phone's connection on the server.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
