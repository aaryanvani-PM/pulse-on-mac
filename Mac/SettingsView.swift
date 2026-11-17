import SwiftUI

/// Settings window: what the menu bar shows, and optional alerts.
struct SettingsView: View {
    @Bindable var prefs: Preferences
    @State private var notificationsDenied = false

    var body: some View {
        Form {
            Section("Menu Bar") {
                Picker("Show", selection: $prefs.menuBarStyle) {
                    ForEach(Preferences.MenuBarStyle.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Color the number when it's past your limits", isOn: $prefs.colorOutsideLimits)
                Toggle("Show only the heart when there's no recent reading", isOn: $prefs.heartOnlyWhenNotRecent)
            }

            Section {
                Toggle("High heart rate", isOn: $prefs.highAlert)
                Picker("Above", selection: $prefs.highLimit) {
                    ForEach(Preferences.highChoices, id: \.self) { Text("\($0) BPM").tag($0) }
                }
                Toggle("Low heart rate", isOn: $prefs.lowAlert)
                Picker("Below", selection: $prefs.lowLimit) {
                    ForEach(Preferences.lowChoices, id: \.self) { Text("\($0) BPM").tag($0) }
                }
                Picker("For at least", selection: $prefs.sustainMinutes) {
                    ForEach(Preferences.sustainChoices, id: \.self) { Text("\($0) minutes").tag($0) }
                }
                if notificationsDenied {
                    Label("Notifications are off for Pulse on Mac. Turn them on in System Settings > Notifications.",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            } header: {
                Text("Alerts")
            } footer: {
                Text("You're notified once when readings stay past a limit for this long. With the Watch app closed, readings arrive about every 15 minutes, so an alert can take up to two readings. The limits also set when the menu bar number changes color. Pulse on Mac isn't a medical device; your Apple Watch has its own heart rate notifications in Settings > Heart.")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: prefs.highAlert) { _, on in if on { askPermission() } }
        .onChange(of: prefs.lowAlert) { _, on in if on { askPermission() } }
        .task {
            guard prefs.highAlert || prefs.lowAlert else { return }
            notificationsDenied = await HeartAlerts.permissionDenied()
        }
    }

    private func askPermission() {
        Task {
            let granted = await HeartAlerts.requestPermission()
            notificationsDenied = !granted
        }
    }
}
