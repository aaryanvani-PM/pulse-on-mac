import SwiftUI

@main
struct HRMenuBarApp: App {
    @State private var store: HeartRateStore
    @State private var credentials: MacCredentials
    @State private var server: WatchHTTPServer
    @State private var cloud: CloudPublisher

    init() {
        let credentials = MacCredentials()
        let store = HeartRateStore(historyURL: TrendHistory.defaultURL)
        IngestLog.note("receiver-launched")
        store.onDecision = { packet, decision, receivedAt in
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
        // Autostart at launch: the menu-bar window is created lazily, so the
        // server must not depend on the window being opened first.
        store.configure(pairingCode: credentials.pairingCode, localAddress: LocalAddress.primaryIPv4())
        server.start()
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
    }
}

/// The always-visible menu-bar item: the BPM sits directly in the bar with a
/// heart after it, updating every second.
///
/// Why a dedicated view: a label written inline in the App body did not
/// re-render when samples arrived (the value only ever showed up in the
/// dropdown). A standalone view observing `store.now` — a 1 Hz heartbeat
/// property — re-renders every second regardless of traffic, which also
/// drives the live→stale dimming and the passive-sync age.
private struct MenuBarLabel: View {
    let store: HeartRateStore

    var body: some View {
        let status = store.status(at: store.now)
        HStack(spacing: 4) {
            Text(displayValue(for: status))
                .monospacedDigit() // 7↔8 glyph widths differ; no layout jitter
                .foregroundStyle(textStyle(for: status))
            Image(systemName: symbolName(for: status))
                .foregroundStyle(iconStyle(for: status))
        }
        .font(.system(size: 13, weight: .medium))
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
}
