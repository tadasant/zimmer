import SwiftUI
import UIKit
import ZimmerKit

/// The web UI's CLIs page: whether each command-line tool is installed and signed in, as the
/// worker last checked, with the page's install and sign-in hints and a Copy on each; Refresh
/// queues a fresh check and Clear Cache the worker's npm and pip cache clear. The SSH hint names
/// the signed-in server, as the page does when it has no Tailscale address to print.
struct CliToolsView: View {
    @EnvironmentObject private var app: AppModel
    @State private var report: CliStatusReport?
    @State private var error: ZimmerError?
    /// The last action's answer, in the server's words, under the status line.
    @State private var notice: String?
    @State private var refreshing = false
    @State private var confirmingClear = false
    /// What was last copied, named beside its button for a moment.
    @State private var copied: String?

    var body: some View {
        List {
            if let error { ErrorBanner(error: error).listRowInsets(EdgeInsets()).listRowBackground(Color.clear) }
            if let report {
                headline(report)
                sshHint
                ForEach(report.tools) { tool in toolSection(tool) }
            }
        }
        .themeGround()
        .overlay { if report == nil && error == nil { LoadingState() } }
        .task { await load() }
        .refreshable { await load() }
        .navigationTitle("CLI Tools")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        Task { await refresh() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .accessibilityIdentifier("clis.refresh")
                    Button(role: .destructive) {
                        confirmingClear = true
                    } label: {
                        Label("Clear Cache", systemImage: "trash")
                    }
                    .accessibilityIdentifier("clis.clearCache")
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("CLI actions")
                .accessibilityIdentifier("clis.actions")
            }
        }
        .confirmationDialog(
            "Clear the worker's npm and pip caches and reinstall the MCP packages?",
            isPresented: $confirmingClear,
            titleVisibility: .visible
        ) {
            Button("Clear Cache", role: .destructive) { Task { await clearCache() } }
                .accessibilityIdentifier("clis.clearCache.confirm")
        } message: {
            Text("For MCP servers that fail to start on a corrupted cache (ENOTEMPTY, missing files). It runs in the worker container, where the servers are spawned.")
        }
    }

    // MARK: - Sections

    /// The page's banner, and under it when the check ran and what the last action answered.
    private func headline(_ report: CliStatusReport) -> some View {
        let ready = report.allAuthenticated == true
        return Section {
            VStack(alignment: .leading, spacing: 4) {
                Label {
                    Text(report.headline).font(.subheadline.weight(.semibold)).foregroundStyle(ready ? Theme.success : Theme.warning)
                } icon: {
                    Image(systemName: ready ? "checkmark.circle.fill" : "exclamationmark.triangle.fill").foregroundStyle(ready ? Theme.success : Theme.warning)
                }
                .accessibilityIdentifier("clis.headline")
                Text(statusLine(report)).font(.caption).foregroundStyle(Theme.inkMute).accessibilityIdentifier("clis.status")
                if let notice {
                    Text(notice).font(.caption).foregroundStyle(Theme.accent).accessibilityIdentifier("clis.notice")
                }
            }
            .padding(.vertical, 2)
        }
        .listRowBackground(ready ? Theme.success.opacity(0.08) : Theme.warning.opacity(0.08))
    }

    private func statusLine(_ report: CliStatusReport) -> String {
        if refreshing { return "Refresh queued — checking…" }
        guard let at = report.generatedAt else { return "Not checked yet; the worker checks every two minutes." }
        let age = Format.age(at)
        return age == "now" ? "Checked just now" : "Checked \(age) ago"
    }

    /// The server the tools are on, as the page's first step: `ssh root@…`.
    private var sshHint: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("First, SSH into the server:").font(.caption).foregroundStyle(Theme.inkSoft)
                codeBlock(sshCommand, key: "ssh")
                Text("All commands below should be run on the server after connecting.").font(.caption2).foregroundStyle(Theme.inkMute)
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("clis.ssh")
        } header: {
            Text("Connect to Server").themeLabel()
        }
        .themeRows()
    }

    private var sshCommand: String {
        "ssh root@\(app.signedInOrigins?.web.host ?? "zimmer")"
    }

    private func toolSection(_ tool: CliStatusReport.Tool) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Text(tool.name).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                    Text(verbatim: "(\(tool.key))").font(Theme.mono).foregroundStyle(Theme.inkMute)
                    if let version = tool.version { capsule("v\(version)", tone: Theme.inkMute) }
                }
                HStack(spacing: 6) {
                    capsule(tool.installedLabel, tone: tool.installed == true ? Theme.success : tool.installed == false ? Theme.danger : Theme.inkMute)
                    capsule(tool.authenticatedLabel, tone: tool.authenticated == true ? Theme.success : tool.authenticated == false ? Theme.warning : Theme.inkMute)
                }
                if let details = tool.details, !details.isEmpty {
                    Text(details).font(.caption).foregroundStyle(Theme.inkSoft)
                }
                if tool.installed == false, let install = tool.installInstructions, !install.isEmpty {
                    step("1", "Installation", tone: Theme.inkMute)
                    codeBlock(install, key: "install.\(tool.key)")
                }
                if tool.installed == true, tool.authenticated == false {
                    step("!", "Authentication Required", tone: Theme.warning)
                    if tool.usesEnvVar, let name = tool.envVarName, let hint = tool.envVarHint {
                        Text("\(name) environment variable is not set. Set \(name) as a GitHub Actions secret and redeploy (or set it in your shell for a manual bin/kamal deploy):")
                            .font(.caption).foregroundStyle(Theme.warning)
                        codeBlock(hint, key: "env.\(tool.key)")
                    } else if let auth = tool.authInstructions, !auth.isEmpty {
                        codeBlock(auth, key: "auth.\(tool.key)")
                    }
                }
                if tool.isReady {
                    Label {
                        Text("Ready to use" + (tool.usesEnvVar && tool.envVarName != nil ? " (via \(tool.envVarName ?? ""))" : ""))
                            .font(.caption.weight(.medium)).foregroundStyle(Theme.success)
                    } icon: {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
                    }
                }
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("clis.tool.\(tool.key)")
        }
        .themeRows()
    }

    // MARK: - Pieces

    private func step(_ mark: String, _ title: String, tone: Color) -> some View {
        HStack(spacing: 6) {
            Text(mark)
                .font(.caption2.weight(.bold))
                .frame(width: 18, height: 18)
                .foregroundStyle(tone)
                .background(tone.opacity(0.14), in: Circle())
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(Theme.inkSoft)
        }
    }

    /// The page's dark code block with its Copy in the corner.
    private func codeBlock(_ text: String, key: String) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(text)
                .font(Theme.mono)
                .foregroundStyle(Theme.ink)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Theme.well, in: RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous))
            Button {
                UIPasteboard.general.string = text
                copied = key
                Haptics.success()
            } label: {
                Label(copied == key ? "Copied" : "Copy", systemImage: copied == key ? "checkmark" : "doc.on.doc")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .tint(Theme.accent)
            .accessibilityIdentifier("clis.copy.\(key)")
        }
    }

    private func capsule(_ text: String, tone: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .foregroundStyle(tone)
            .background(tone.opacity(0.14), in: Capsule())
    }

    // MARK: - Loading and actions

    private func load() async {
        do {
            report = try await app.api.cliStatus()
            error = nil
            app.cliIssues = report?.unauthenticatedCount ?? 0
        } catch {
            self.error = error as? ZimmerError ?? .transport(error)
            app.noteError(self.error!)
        }
    }

    /// Queue a fresh check, show it queued, then read the status again once the worker has
    /// had a moment: the answer to the refresh is the status as cached when it was asked.
    private func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        do {
            report = try await app.api.refreshCliStatus()
            notice = "CLI status refresh queued. Results update shortly."
            error = nil
            try? await Task.sleep(for: .seconds(2))
            refreshing = false
            await load()
        } catch {
            refreshing = false
            self.error = error as? ZimmerError ?? .transport(error)
            Haptics.failure()
        }
    }

    private func clearCache() async {
        do {
            notice = try await app.api.clearCliCache()
            error = nil
            Haptics.success()
        } catch {
            self.error = error as? ZimmerError ?? .transport(error)
            Haptics.failure()
        }
    }
}
