import SwiftUI
import ZimmerKit

/// Sign in through Zimmer's own web sign-in, in the system sheet.
///
/// The sheet shows the same Google and second-factor steps the browser does, then Zimmer's
/// consent screen for "Zimmer for iOS". On a deployment whose machine calls go to a
/// separate app host behind an access proxy, the edge's own login runs first. Nothing is
/// typed into the app but the addresses, and only when the build does not already know them.
struct SignInView: View {
    @EnvironmentObject private var model: AppModel
    @State private var server = ""
    @State private var appHost = ""
    @State private var isSigningIn = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image("ZimmerMark")
                .resizable()
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text("Zimmer").font(.largeTitle.weight(.bold))
                Text("Your agent sessions, from your phone.")
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Server").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                TextField("https://zimmer.example.com", text: $server)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(12)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityIdentifier("signin.server")
                DisclosureGroup("App host") {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("Same as the server", text: $appHost)
                            .textContentType(.URL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(12)
                            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                            .accessibilityIdentifier("signin.apphost")
                        Text("Only for a deployment that serves the app from its own hostname.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 6)
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            }

            Button {
                Task {
                    isSigningIn = true
                    await model.signIn(web: server, api: appHost)
                    isSigningIn = false
                }
            } label: {
                HStack {
                    if isSigningIn { ProgressView().tint(.white) }
                    Text("Sign in").font(.headline)
                }
                .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isSigningIn || server.trimmingCharacters(in: .whitespaces).isEmpty)
            .accessibilityIdentifier("signin.button")

            if let error = model.error {
                ErrorBanner(error: error)
            }
            Spacer()
            Text("You'll sign in on Zimmer's own page, then approve this phone. Revoke it any time under Settings → API keys.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .onAppear {
            guard server.isEmpty, let origins = model.environment.configuration.origins else { return }
            server = origins.web.absoluteString
            appHost = origins.isSplit ? origins.api.absoluteString : ""
        }
    }
}

struct ErrorBanner: View {
    let error: ZimmerError

    var body: some View {
        Label(error.userMessage, systemImage: error == .edgeRefused ? "network.slash" : "exclamationmark.triangle")
            .font(.callout)
            .foregroundStyle(error == .edgeRefused ? Color.purple : Color.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityIdentifier(error == .edgeRefused ? "error.edge" : "error.banner")
    }
}
