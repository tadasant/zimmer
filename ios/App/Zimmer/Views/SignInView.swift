import AuthenticationServices
import SwiftUI
import ZimmerKit

/// Sign in through Zimmer's own web sign-in, in the system sheet.
///
/// The sheet shows the same Google and second-factor steps the browser does, then Zimmer's
/// consent screen for "Zimmer for iOS". Nothing is typed into the app but the server's
/// address, and only when the build does not already know it.
struct SignInView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @State private var server = ""
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
            }

            Button {
                Task {
                    isSigningIn = true
                    await model.signIn(server: server, using: webAuthenticationSession)
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
            if server.isEmpty { server = model.environment.configuration.serverURL?.absoluteString ?? "" }
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
