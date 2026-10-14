import SwiftUI
import ZimmerKit

/// The web UI's snooze menu's last row, "Custom — pick a date and time", as a sheet: any time
/// from the next whole minute on, which is the `min` the web's picker sets so a time in the
/// past cannot be chosen. It starts at the *Tomorrow* preset, 9 AM. `snooze` reports whether
/// the server took it; the sheet stays open with the time when it did not.
struct CustomSnoozeSheet: View {
    let snooze: (Date) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var until = VisibilityChange.snoozePresets().first { $0.id == "tomorrow" }?.until ?? Date().addingTimeInterval(86_400)
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker(
                        "Snooze until",
                        selection: $until,
                        in: VisibilityChange.earliestCustomSnooze()...,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .datePickerStyle(.graphical)
                    .tint(Theme.accent)
                    .accessibilityIdentifier("snooze.custom.picker")
                } footer: {
                    Text("Visual only — it does not pause, start or stop the session.")
                }
            }
            .themeGround()
            .navigationTitle("Snooze until…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Snoozing…" : "Snooze") {
                        Task {
                            saving = true
                            // A sheet left open past the minute it was opened in could hold a
                            // time that has since passed, which the server refuses.
                            let chosen = max(until, VisibilityChange.earliestCustomSnooze())
                            let saved = await snooze(chosen)
                            saving = false
                            if saved { dismiss() }
                        }
                    }
                    .disabled(saving)
                    .accessibilityIdentifier("snooze.custom.save")
                }
            }
        }
        .presentationDetents([.large])
    }
}
