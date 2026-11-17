import SwiftUI
import UserNotifications

@main
struct HRMenuBarApp: App {
    @State private var store: HeartRateStore
    @State private var credentials: MacCredentials
    @State private var server: WatchHTTPServer
    @State private var cloud: CloudPublisher

    init() {
        let credentials = MacCredentials()
        if DemoMode.isOn {
            // Mock data only: no receiver, no saved history, no logging.
            let store = HeartRateStore(historyURL: nil)
            DemoMode.start(store)
            _credentials = State(initialValue: credentials)
            _store = State(initialValue: store)
            let server = WatchHTTPServer(credentials: credentials, onEvent: { _ in },
                                         onPair: { _ in }, onState: { _ in })
            let cloud = CloudPublisher()
            _server = State(initialValue: server)
            _cloud = State(initialValue: cloud)
            if let folder = DemoExport.folder {
                Task { @MainActor in
                    await DemoExport.run(store: store, credentials: credentials, server: server, cloud: cloud, to: folder)
                }
            }
            return
        }
        let store = HeartRateStore(historyURL: TrendHistory.defaultURL)
        IngestLog.note("receiver-launched")
        let alerts = HeartAlerts(prefs: .shared)
        UNUserNotificationCenter.current().delegate = NotificationPresenter.shared
        store.onDecision = { [weak store] packet, decision, receivedAt in
            if decision == "accepted", let store { alerts.evaluate(points: store.trend.points) }
            // Passive traffic only: a continuous session sends ~1 packet/s.
            guard packet.mode == .passive else { return }
            IngestLog.record(packet, decision: decision, receivedAt: receivedAt)
        }
        let server = WatchHTTPServer(
            credentials: credentials,
            onEvent: { store.ingest($0) },
            onPair: { store.notePairing($0) },
            onState: { store.setServerState($0) }
        )
        server.onRejected = { store.noteRejected() }
        // Autostart at launch: the menu-bar window is created lazily, so the
        // server must not depend on the window being opened first.
        store.configure(pairingCode: credentials.pairingCode, localAddress: LocalAddress.primaryIPv4())
        server.start()
        ConnectionMonitor.shared.start(isListening: { [weak store] in store?.serverState == .listening })
        // The Mac's DHCP address can change while the app runs; keep the
        // displayed pairing address current every 5 seconds.
        let cloud = CloudPublisher()
        Task { [weak store] in
            while let store {
                let address = LocalAddress.primaryIPv4()
                store.refreshLocalAddress(address)
                store.refreshPairingCode(credentials.pairingCode)
                // Publishes at launch and again whenever the address or key
                // changes; a no-op otherwise.
                cloud.update(address: address, hostname: LocalAddress.localHostname(), token: credentials.cloudToken)
                try? await Task.sleep(for: .seconds(5))
            }
        }
        _credentials = State(initialValue: credentials)
        _store = State(initialValue: store)
        _server = State(initialValue: server)
        _cloud = State(initialValue: cloud)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(store: store, credentials: credentials, server: server, cloud: cloud)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(prefs: .shared)
        }
    }
}

/// The always-visible menu-bar item: the BPM sits directly in the bar with a
/// heart after it, updating every second, styled by the user's settings.
///
/// Why a dedicated view: a label written inline in the App body did not
/// re-render when samples arrived (the value only ever showed up in the
/// dropdown). A standalone view observing `store.now` — a 1 Hz heartbeat
/// property — re-renders every second regardless of traffic, which also
/// drives the live→stale dimming and the passive-sync age.
private struct MenuBarLabel: View {
    let store: HeartRateStore
    private var prefs: Preferences { .shared }

    var body: some View {
        let status = store.status(at: store.now)
        let recent = Self.isRecent(status)
        let showNumber = prefs.menuBarStyle != .heartOnly && !(prefs.heartOnlyWhenNotRecent && !recent)
        let showHeart = prefs.menuBarStyle != .numberOnly || !showNumber
        HStack(spacing: 4) {
            if showNumber {
                Text(displayValue(for: status))
                    .monospacedDigit() // 7↔8 glyph widths differ; no layout jitter
                    .foregroundStyle(textStyle(for: status))
            }
            if showHeart {
                Image(systemName: symbolName(for: status))
                    .foregroundStyle(iconStyle(for: status))
            }
        }
        .font(.system(size: 13, weight: .medium))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenDescription(status))
    }

    private static func isRecent(_ status: HeartRateStore.Status) -> Bool {
        switch status {
        case .live, .connected, .passiveSynced: return true
        default: return false
        }
    }

    private var zone: Preferences.Zone {
        guard let bpm = store.currentBPM else { return .normal }
        return prefs.zone(for: bpm)
    }

    private func displayValue(for status: HeartRateStore.Status) -> String {
        switch status {
        case .live, .connected, .stale, .passiveSynced, .passiveQuiet:
            return store.currentBPM.map(String.init) ?? "--"
        case .waiting, .off, .failed, .needsLocalNetworkPermission:
            return "--"
        }
    }

    private func symbolName(for status: HeartRateStore.Status) -> String {
        switch status {
        case .live, .connected:
            return "heart.fill"
        default:
            return "heart"
        }
    }

    private func textStyle(for status: HeartRateStore.Status) -> AnyShapeStyle {
        if prefs.colorOutsideLimits, Self.isRecent(status) {
            switch zone {
            case .high: return AnyShapeStyle(Color.orange)
            case .low: return AnyShapeStyle(Color.cyan)
            case .normal: break
            }
        }
        switch status {
        case .live, .connected: return AnyShapeStyle(.primary)
        case .stale, .passiveSynced: return AnyShapeStyle(.secondary)
        default: return AnyShapeStyle(.tertiary)
        }
    }

    private func iconStyle(for status: HeartRateStore.Status) -> AnyShapeStyle {
        switch status {
        case .live, .connected: return AnyShapeStyle(Color.red)
        case .passiveSynced: return AnyShapeStyle(Color.blue)
        case .stale: return AnyShapeStyle(.secondary)
        default: return AnyShapeStyle(.tertiary)
        }
    }

    /// What VoiceOver reads for the menu-bar item.
    private func spokenDescription(_ status: HeartRateStore.Status) -> String {
        guard let bpm = store.currentBPM, displayValue(for: status) != "--" else {
            return "Heart rate, no reading"
        }
        var parts = ["Heart rate \(bpm) beats per minute"]
        switch status {
        case .live, .connected: parts.append("live")
        case .passiveSynced, .stale, .passiveQuiet:
            if let last = store.samples.last {
                parts.append("measured \(HeartRateStore.spokenAge(store.now.timeIntervalSince(last.recordedAt)))")
            }
        default: break
        }
        switch zone {
        case .high: parts.append("above your \(prefs.highLimit) limit")
        case .low: parts.append("below your \(prefs.lowLimit) limit")
        case .normal: break
        }
        return parts.joined(separator: ", ")
    }
}
