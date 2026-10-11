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
        VStack(spacing: 28) {
            Spacer(minLength: 32)
            VStack(spacing: 18) {
                Image("ZimmerMark")
                    .resizable()
                    .frame(width: 104, height: 104)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .strokeBorder(Theme.gold.opacity(0.7), lineWidth: 1)
                    )
                    .accessibilityHidden(true)
                VStack(spacing: 8) {
                    Text("Zimmer")
                        .font(.system(size: 40, weight: .bold))
                        .foregroundStyle(Theme.ink)
                    Text("Your agent sessions, from your phone.")
                        .font(.body)
                        .foregroundStyle(Theme.inkSoft)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Server").themeLabel()
                TextField("https://zimmer.example.com", text: $server)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .modifier(SignInField())
                    .accessibilityIdentifier("signin.server")
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("Same as the server", text: $appHost)
                            .textContentType(.URL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .modifier(SignInField())
                            .accessibilityIdentifier("signin.apphost")
                        Text("Only for a deployment that serves the app from its own hostname.")
                            .font(.caption)
                            .foregroundStyle(Theme.inkSoft)
                    }
                    .padding(.top, 6)
                } label: {
                    Text("App host").themeLabel()
                }
                .tint(Theme.inkSoft)
            }

            Button {
                Task {
                    isSigningIn = true
                    await model.signIn(web: server, api: appHost)
                    isSigningIn = false
                }
            } label: {
                HStack(spacing: 8) {
                    if isSigningIn { ProgressView().tint(.white) }
                    Text("Sign in")
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(isSigningIn || server.trimmingCharacters(in: .whitespaces).isEmpty)
            .accessibilityIdentifier("signin.button")

            if let error = model.error {
                ErrorBanner(error: error)
            }
            Spacer()
            Text("You'll sign in on Zimmer's own page, then approve this phone. Revoke it any time under Settings → API keys.")
                .font(.footnote)
                .foregroundStyle(Theme.inkSoft)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Always the mark's navy, in either appearance: the PWA's launch colour, and the one
        // screen that is all brand.
        .background(Theme.ground.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        // And the status bar's light text over it, while this screen is up.
        .preferredColorScheme(.dark)
        .onAppear {
            guard server.isEmpty, let origins = model.environment.configuration.origins else { return }
            server = origins.web.absoluteString
            appHost = origins.isSplit ? origins.api.absoluteString : ""
        }
    }
}

/// A sign-in address field: a well on the navy, a hairline round it.
private struct SignInField: ViewModifier {
    func body(content: Content) -> some View {
        content
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .background(Theme.well, in: RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous).strokeBorder(Theme.rule, lineWidth: 1))
    }
}

struct ErrorBanner: View {
    let error: ZimmerError

    var body: some View {
        let tone = error == .edgeRefused ? Theme.status(.waiting).text : Theme.danger
        Label {
            Text(error.userMessage).foregroundStyle(Theme.ink)
        } icon: {
            Image(systemName: error == .edgeRefused ? "network.slash" : "exclamationmark.triangle.fill")
                .foregroundStyle(tone)
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .themeCard(radius: Theme.smallRadius)
        .overlay(alignment: .leading) { tone.frame(width: 3).padding(.vertical, 12) }
        .accessibilityIdentifier(error == .edgeRefused ? "error.edge" : "error.banner")
    }
}
