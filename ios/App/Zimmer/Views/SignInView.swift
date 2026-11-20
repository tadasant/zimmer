import SwiftUI
import ZimmerKit

/// Sign in through Zimmer's own web sign-in, in the system sheet.
///
/// The sheet shows the same Google and second-factor steps the browser does, then Zimmer's
/// consent screen for "Zimmer for iOS". On a deployment whose machine calls go to a
/// separate app host behind an access proxy, the edge's own login runs first. Nothing is
/// typed into the app but the addresses, and only when the build does not already know them.
///
/// Three ways in: the first deployment on a fresh install; another one added from the switcher
/// (`.add`, in a sheet), Slack's "Add a workspace"; and a deployment already on the list whose
/// sign-in has ended (`.again`), which signs in to the same addresses and keeps the way to the
/// other deployments open.
struct SignInView: View {
    enum Mode: Equatable {
        case first
        case add
        case again(Deployment)
    }

    let mode: Mode
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var workspaces: Workspaces
    @Environment(\.dismiss) private var dismiss
    @State private var server = ""
    @State private var appHost = ""
    @State private var isSigningIn = false
    @State private var confirmingRemove = false

    var body: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 32)
            header

            if case let .again(deployment) = mode {
                VStack(spacing: 6) {
                    Text(deployment.host)
                        .font(.callout.monospaced())
                        .foregroundStyle(Theme.inkSoft)
                        .accessibilityIdentifier("signin.again.host")
                    Text("This phone's sign-in to \(deployment.name) has ended. Sign in again to pick up where you were.")
                        .font(.callout)
                        .foregroundStyle(Theme.inkSoft)
                        .multilineTextAlignment(.center)
                }
            } else {
                addressFields
            }

            Button {
                Task {
                    isSigningIn = true
                    if case .again = mode {
                        await model.signInAgain()
                    } else if await workspaces.add(web: server, api: appHost), mode == .add {
                        dismiss()
                    }
                    isSigningIn = false
                }
            } label: {
                HStack(spacing: 8) {
                    if isSigningIn { ProgressView().tint(.white) }
                    Text(mode == .add ? "Add and sign in" : "Sign in")
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(isSigningIn || (asksForAddress && server.trimmingCharacters(in: .whitespaces).isEmpty))
            .accessibilityIdentifier("signin.button")

            if let error = shownError {
                ErrorBanner(error: error)
            }

            if case let .again(deployment) = mode {
                otherDeployments(besides: deployment)
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
        .background(Theme.ground.ignoresSafeArea())
        .toolbar {
            if mode == .add {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSigningIn)
                        .accessibilityIdentifier("signin.cancel")
                }
            }
        }
        .onAppear {
            workspaces.addError = nil
            guard server.isEmpty else { return }
            // The first sign-in offers the build's own deployment (or the one typed last); an
            // added one starts empty unless the build's own is not on the list yet.
            guard let origins = model.environment.configuration.origins,
                  mode == .first || workspaces.list.existing(for: origins) == nil else { return }
            server = origins.web.absoluteString
            appHost = origins.isSplit ? origins.api.absoluteString : ""
        }
    }

    private var asksForAddress: Bool {
        if case .again = mode { return false }
        return true
    }

    private var shownError: ZimmerError? {
        if case .again = mode { return model.error }
        return workspaces.addError
    }

    @ViewBuilder
    private var header: some View {
        VStack(spacing: 18) {
            if case let .again(deployment) = mode {
                DeploymentAvatar(deployment: deployment, size: 104)
                    .accessibilityHidden(true)
            } else {
                Image("ZimmerMark")
                    .resizable()
                    .frame(width: mode == .add ? 72 : 104, height: mode == .add ? 72 : 104)
                    .clipShape(RoundedRectangle(cornerRadius: mode == .add ? 18 : 24, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: mode == .add ? 18 : 24, style: .continuous)
                            .strokeBorder(Theme.gold.opacity(0.7), lineWidth: 1)
                    )
                    .accessibilityHidden(true)
            }
            VStack(spacing: 8) {
                Text(title)
                    .font(.system(size: mode == .add ? 30 : 40, weight: .bold))
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("signin.title")
                Text(subtitle)
                    .font(.body)
                    .foregroundStyle(Theme.inkSoft)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var title: String {
        switch mode {
        case .first: return "Zimmer"
        case .add: return "Add a deployment"
        case let .again(deployment): return deployment.name
        }
    }

    private var subtitle: String {
        switch mode {
        case .first: return "Your agent sessions, from your phone."
        case .add: return "Another Zimmer, beside the ones you're signed in to. Each keeps its own sign-in."
        case .again: return "Signed out"
        }
    }

    private var addressFields: some View {
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
    }

    /// Signed out of one deployment, the rest are a tap away; or this one can go.
    private func otherDeployments(besides deployment: Deployment) -> some View {
        VStack(spacing: 10) {
            if workspaces.list.deployments.count > 1 {
                Button {
                    workspaces.showingSwitcher = true
                } label: {
                    Label("Switch deployment", systemImage: "rectangle.2.swap")
                }
                .accessibilityIdentifier("signin.switch")
            }
            Button(role: .destructive) {
                confirmingRemove = true
            } label: {
                Text("Remove \(deployment.name) from this phone")
            }
            .font(.callout)
            .accessibilityIdentifier("signin.remove")
        }
        .confirmationDialog("Remove \(deployment.name)?", isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { Task { await workspaces.remove(deployment.id) } }
        } message: {
            Text("Its drafts and settings on this phone go with it. Your other deployments stay signed in.")
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
