import SwiftUI
import ZimmerKit

/// The web UI's snooze menu's last row, "Custom — pick a date and time", as a sheet: any time
/// from the next whole minute on, which is the `min` the web's picker sets so a time in the
/// past cannot be chosen. It starts at the *Tomorrow* preset, 9 AM. Snooze closes the sheet
/// at once; the screen behind shows the snooze, and a refusal over it with the row as it was.
struct CustomSnoozeSheet: View {
    let snooze: (Date) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var until = VisibilityChange.snoozePresets().first { $0.id == "tomorrow" }?.until ?? Date().addingTimeInterval(86_400)

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
                    Button("Snooze") {
                        // A sheet left open past the minute it was opened in could hold a
                        // time that has since passed, which the server refuses.
                        snooze(max(until, VisibilityChange.earliestCustomSnooze()))
                        dismiss()
                    }
                    .accessibilityIdentifier("snooze.custom.save")
                }
            }
        }
        .presentationDetents([.large])
    }
}
