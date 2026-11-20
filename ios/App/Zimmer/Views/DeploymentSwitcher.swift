import SwiftUI
import UIKit
import ZimmerKit

/// A deployment's avatar: its initials on a colour of its own, a rounded square as Slack draws
/// a workspace's. The colour comes from the deployment's id (`Deployment.paletteIndex`), so it is
/// the same on every launch, and two deployments side by side rarely share one.
struct DeploymentAvatar: View {
    let deployment: Deployment
    var size: CGFloat = 32

    /// Deep enough for white initials in both appearances.
    static let palette: [UInt32] = [0x4F46E5, 0x0F766E, 0xBE123C, 0xB45309, 0x7C3AED, 0x0369A1, 0x047857, 0x334155]

    var body: some View {
        let fill = Color(uiColor: UIColor(hex: Self.palette[deployment.paletteIndex(count: Self.palette.count)]))
        Text(deployment.initials)
            .font(.system(size: size * (deployment.initials.count > 1 ? 0.38 : 0.46), weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(fill, in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
    }
}

/// The board's top-left corner: the deployment in front, as its avatar, one tap from the
/// switcher — where Slack keeps the workspace you are in.
struct DeploymentSwitcherButton: View {
    @EnvironmentObject private var workspaces: Workspaces

    var body: some View {
        if let active = workspaces.active {
            Button {
                workspaces.showingSwitcher = true
            } label: {
                DeploymentAvatar(deployment: active, size: 28)
            }
            .accessibilityLabel("Deployment: \(active.name)")
            .accessibilityHint("Switch to another deployment, or add one")
            .accessibilityIdentifier("deployments.open")
        }
    }
}

/// The switcher: every deployment this phone is signed in to, the one in front marked, a tap
/// to switch, and Add a deployment at the foot. Edit reorders and removes; a row's menu
/// renames it or signs out of it. A sheet at half height, as Slack's is, and dragged up for a
/// long list.
struct DeploymentSwitcher: View {
    @EnvironmentObject private var workspaces: Workspaces
    @Environment(\.dismiss) private var dismiss
    @State private var adding = false
    @State private var renaming: Deployment?
    @State private var newName = ""
    @State private var removing: Deployment?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(workspaces.list.deployments) { deployment in
                        row(deployment)
                    }
                    .onMove { offsets, destination in workspaces.move(fromOffsets: offsets, toOffset: destination) }
                    .onDelete { offsets in
                        removing = offsets.first.map { workspaces.list.deployments[$0] }
                    }
                } footer: {
                    Text("Each deployment keeps its own sign-in, drafts and notifications. Switching never signs you out of the others.")
                }
                .themeRows()

                Section {
                    Button {
                        adding = true
                    } label: {
                        Label("Add a deployment", systemImage: "plus")
                    }
                    .accessibilityIdentifier("deployments.add")
                }
                .themeRows()
            }
            .themeGround()
            .navigationTitle("Deployments")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    EditButton().accessibilityIdentifier("deployments.edit")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("deployments.done")
                }
            }
            .sheet(isPresented: $adding) {
                NavigationStack { SignInView(mode: .add) }
                    .environmentObject(workspaces.model)
                    .environmentObject(workspaces)
            }
            .alert("Rename deployment", isPresented: isRenaming, presenting: renaming) { deployment in
                TextField(deployment.host, text: $newName)
                    .accessibilityIdentifier("deployments.rename.field")
                Button("Save") { workspaces.rename(deployment.id, to: newName) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Only on this phone. Leave it empty for the address.")
            }
            .confirmationDialog(
                "Sign out of \(removing?.name ?? "this deployment")?", isPresented: isRemoving,
                titleVisibility: .visible, presenting: removing
            ) { deployment in
                Button("Sign out and remove", role: .destructive) {
                    Task { await workspaces.remove(deployment.id) }
                }
            } message: { _ in
                Text("This phone's connection to it is revoked and its drafts and settings here are forgotten. Your other deployments stay signed in.")
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func row(_ deployment: Deployment) -> some View {
        let isActive = deployment.id == workspaces.list.activeID
        return Button {
            if isActive { dismiss() } else { workspaces.switchTo(deployment.id) }
        } label: {
            HStack(spacing: 12) {
                DeploymentAvatar(deployment: deployment, size: 40)
                    .overlay(
                        RoundedRectangle(cornerRadius: 40 * 0.24 + 3, style: .continuous)
                            .strokeBorder(isActive ? Theme.ink : .clear, lineWidth: 2)
                            .padding(-3)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(deployment.name)
                        .font(Theme.headline(emphasized: isActive))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    Text(deployment.host)
                        .font(.caption)
                        .foregroundStyle(Theme.inkSoft)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if isActive {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .accessibilityHidden(true)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("deployments.row.\(deployment.id)")
        .accessibilityValue(isActive ? "Current" : "")
        .contextMenu {
            Button {
                newName = deployment.name
                renaming = deployment
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button(role: .destructive) {
                removing = deployment
            } label: {
                Label("Sign out and remove", systemImage: "rectangle.portrait.and.arrow.right")
            }
        }
    }

    private var isRenaming: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    private var isRemoving: Binding<Bool> {
        Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
    }
}
