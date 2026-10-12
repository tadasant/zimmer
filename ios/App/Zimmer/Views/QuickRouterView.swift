import SwiftUI
import ZimmerKit

/// Start work from a sentence. Zimmer's Quick Router reads the request, picks the agent
/// root and starts the session — the same flow as the web UI's bubble and the browser
/// extension, recorded as `ios_app`.
///
/// Three ways in, as the web UI has: the field pinned to the foot of the board
/// (`QuickRouterBar`, the web's "What do you want to do?" box), a button in the corner of
/// every other screen (`QuickRouterButton`, the web's bubble), and this sheet, which the
/// button opens.
struct QuickRouterView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var prompt = ""
    @State private var isStarting = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("Say what you want done. Zimmer picks where it runs.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.inkSoft)
                TextField("What do you want to do?", text: $prompt, axis: .vertical)
                    .lineLimit(4...10)
                    .foregroundStyle(Theme.ink)
                    .padding(14)
                    .themeCard(radius: Theme.smallRadius)
                    .focused($focused)
                    .accessibilityIdentifier("quickrouter.field")
                if let error = app.error { ErrorBanner(error: error) }
                Spacer()
            }
            .padding()
            .background(Theme.ground)
            .navigationTitle("Quick Router")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isStarting ? "Starting…" : "Start") {
                        Task {
                            isStarting = true
                            _ = await app.startQuickRouter(prompt)
                            isStarting = false
                        }
                    }
                    .disabled(isStarting || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("quickrouter.start")
                }
            }
            .onAppear { focused = true }
        }
    }
}

/// The web UI's prompt box on the board, pinned to the foot of the Sessions screen: the
/// first thing a thumb reaches, and the most prominent thing on the main screen. Type a
/// sentence, send it, and the session it starts opens.
struct QuickRouterBar: View {
    @EnvironmentObject private var app: AppModel
    @State private var prompt = ""
    @State private var isStarting = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.top, 2)
                    .accessibilityHidden(true)
                TextField("What do you want to do?", text: $prompt, axis: .vertical)
                    .lineLimit(1...5)
                    .foregroundStyle(Theme.ink)
                    .focused($focused)
                    .accessibilityIdentifier("quickrouter.bar.field")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(focused ? Theme.accent.opacity(0.7) : Theme.rule, lineWidth: 1)
            )
            .animation(.easeOut(duration: 0.15), value: focused)
            Button {
                Task { await start() }
            } label: {
                Image(systemName: isStarting ? "hourglass" : "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(canSend ? Color.white : Theme.inkMute)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(canSend ? Theme.accentFill : Theme.well))
                    .overlay(Circle().strokeBorder(Theme.gold.opacity(canSend ? 0.9 : 0), lineWidth: 1.5))
                    .contentTransition(.symbolEffect(.replace))
                    .animation(.snappy(duration: 0.2), value: canSend)
            }
            .disabled(!canSend)
            .accessibilityLabel("Start")
            .accessibilityIdentifier("quickrouter.bar.start")
        }
        .padding(.horizontal, Theme.margin)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background {
            Theme.ground
                .overlay(alignment: .top) { Theme.rule.frame(height: 1) }
                .ignoresSafeArea(edges: .bottom)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("quickrouter.bar")
    }

    private var canSend: Bool {
        !isStarting && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func start() async {
        isStarting = true
        defer { isStarting = false }
        if await app.startQuickRouter(prompt) {
            prompt = ""
            focused = false
        }
    }
}

/// The web UI's bubble: the Quick Router in the bottom-right corner of every screen that is
/// not the board (the board has the bar). Indigo, with the mark's gold ring. The one shadow
/// in the app, because a button floating over content needs the lift; Motet's play button
/// is the precedent.
struct QuickRouterButton: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        Button {
            app.showingQuickRouter = true
        } label: {
            Image(systemName: "sparkles")
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 54, height: 54)
                .background(Circle().fill(Theme.accentFill))
                .overlay(Circle().strokeBorder(Theme.gold.opacity(0.9), lineWidth: 1.5))
                .shadow(color: Theme.navy.opacity(0.28), radius: 10, y: 5)
        }
        .accessibilityLabel("Quick Router")
        .accessibilityIdentifier("quickrouter.fab")
    }
}

extension View {
    /// The Quick Router button in the corner, above whatever the screen keeps at its foot
    /// (a composer, a tab bar) — apply it before a `safeAreaInset` so it sits above the inset.
    func quickRouterCorner() -> some View {
        overlay(alignment: .bottomTrailing) {
            QuickRouterButton()
                .padding(.trailing, Theme.margin)
                .padding(.bottom, 14)
        }
    }
}
