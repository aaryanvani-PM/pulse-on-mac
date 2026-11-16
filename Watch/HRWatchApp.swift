import SwiftUI
import WatchKit

@main
struct HRWatchApp: App {
    @State private var linkState: LinkStateStore
    @State private var link: LinkClient
    @State private var manager: WorkoutManager
    @State private var passive: PassiveMonitor

    init() {
        #if DEBUG
        DebugHooks.applyLaunchArguments()
        #endif
        let linkState = LinkStateStore()
        let link = LinkClient(store: linkState)
        let manager = WorkoutManager(link: link)
        let passive = PassiveMonitor(
            link: link,
            isContinuousActive: { [weak manager] in
                guard let manager else { return false }
                return manager.state == .running || manager.state == .starting
            }
        )
        _linkState = State(initialValue: linkState)
        _link = State(initialValue: link)
        _manager = State(initialValue: manager)
        _passive = State(initialValue: passive)
        passive.restoreAtLaunch()
    }

    var body: some Scene {
        WindowGroup {
            RootView(link: link)
                .environment(linkState)
                .environment(manager)
                .environment(passive)
        }
        .backgroundTask(.appRefresh(BackgroundRefresh.identifier)) {
            await passive.scheduledRefresh()
        }
        .backgroundTask(.urlSession(BackgroundUploader.identifier)) {
            await MainActor.run { PassiveTrace.event("urlsession.wake") }
            await BackgroundUploader.shared.waitForEvents()
            await passive.followUpAfterUpload()
        }
    }
}

struct RootView: View {
    let link: LinkClient
    private static var previewPaired: Bool {
        #if DEBUG
        return DebugHooks.previewPaired
        #else
        return false
        #endif
    }
    @Environment(WorkoutManager.self) private var manager
    @Environment(LinkStateStore.self) private var linkState

    var body: some View {
        Group {
            if linkState.state == .unpaired, !Self.previewPaired {
                PairView(link: link)
            } else {
                HomeView(link: link)
            }
        }
    }
}

/// Main screen: the reading, one primary action, and a short settings area
/// below the fold. Diagnostics live in the trace file, not on screen.
struct HomeView: View {
    let link: LinkClient
    @Environment(WorkoutManager.self) private var manager
    @Environment(LinkStateStore.self) private var linkState
    @Environment(PassiveMonitor.self) private var passive
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("passiveSyncEnabled") private var passiveSyncEnabled = true
    @State private var confirmUnpair = false

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                reading
                startButton
                if let problem {
                    Text(problem)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                settings.padding(.top, 10)
            }
            .padding(.horizontal, 6)
        }
        // Runs whenever the app is paired and in the foreground: re-arms
        // passive sync (idempotent), so pairing alone is enough to enable it.
        .task {
            await passive.syncState(enabled: passiveSyncEnabled)
            // A fresh launch starts directly in .active, so the scenePhase
            // onChange below never fires on first open — run the foreground
            // catch-up here as well.
            await passive.syncNow()
        }
        .onChange(of: passiveSyncEnabled) { _, enabled in
            Task { await passive.syncState(enabled: enabled) }
        }
        // Re-arm and catch up whenever the app comes back on screen.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                await passive.syncState(enabled: passiveSyncEnabled)
                await passive.syncNow()
            }
        }
        .confirmationDialog("Unpair this Mac?", isPresented: $confirmUnpair, titleVisibility: .visible) {
            Button("Unpair", role: .destructive) {
                // Unpairing must stop an active session: otherwise it keeps
                // running against a deleted credential.
                manager.stop()
                Task {
                    await link.unpair()
                    await passive.unpair()
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Reading

    private var isLive: Bool { manager.state == .running }

    private var shownBPM: Int? {
        if isLive { return manager.bpm }
        return passiveSyncEnabled ? passive.lastReading?.bpm : nil
    }

    private var reading: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Circle().fill(badgeColor).frame(width: 6, height: 6)
                Text(badgeText).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(shownBPM.map(String.init) ?? "--")
                    .font(.system(size: 54, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(isLive ? .primary : .secondary)
                Text("BPM")
                    .font(.system(.footnote, design: .rounded).weight(.semibold))
                    .foregroundStyle(.red)
            }
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    /// One line saying how current the number is.
    private var caption: String {
        if isLive { return "Live" }
        if manager.state == .starting { return "Starting…" }
        if passiveSyncEnabled, let reading = passive.lastReading {
            let time = Date(timeIntervalSince1970: reading.ts).formatted(date: .omitted, time: .shortened)
            return "Measured \(time)"
        }
        return "No reading yet"
    }

    /// Only shown when something needs the user's attention.
    private var problem: String? {
        if case .failed(let message) = manager.state { return message }
        if case .unreachable(let hint) = linkState.state { return hint }
        if passiveSyncEnabled, let status = passive.lastStatusText,
           status.localizedCaseInsensitiveContains("failed") { return status }
        return nil
    }

    private var badgeColor: Color {
        switch linkState.state {
        case .connected: return .green
        case .unreachable: return .orange
        default: return .gray
        }
    }

    private var badgeText: String {
        switch linkState.state {
        case .connected: return "Connected to Mac"
        case .unreachable: return "Mac not reachable"
        case .idle: return "Paired with Mac"
        case .unpaired: return "Not paired"
        }
    }

    // MARK: - Actions

    private var isSessionActive: Bool {
        manager.state == .running || manager.state == .starting
    }

    private var startButton: some View {
        Button {
            manager.toggle()
        } label: {
            Label(isSessionActive ? "Stop" : "Go Live",
                  systemImage: isSessionActive ? "stop.fill" : "waveform.path.ecg")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(isSessionActive ? .red : .green)
    }

    // MARK: - Settings (below the fold)

    private var settings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Background Sync", isOn: $passiveSyncEnabled)
            Text("Sends readings to your Mac about every 15 minutes while this app is closed. Keep the Heart Rate Mac complication on your watch face.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if passiveSyncEnabled {
                Button {
                    Task { await passive.syncNow() }
                } label: {
                    Label("Sync Now", systemImage: "arrow.triangle.2.circlepath").frame(maxWidth: .infinity)
                }
                if let syncAt = passive.lastSyncAt {
                    Text("Last sent \(syncAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            Button("Unpair Mac", role: .destructive) { confirmUnpair = true }
                .frame(maxWidth: .infinity)
        }
    }
}

/// Pairing screen: one number from the Mac's Connection section, typed on a
/// digits-only keypad. The number carries the Mac's address and code, and a
/// check digit so a typo is caught before any network attempt.
struct PairView: View {
    let link: LinkClient
    @State private var digits = ""
    @State private var message: String?
    @State private var pairing = false
    @State private var searchingCloud = CloudPairing.isEnabled

    private var expectedLength: Int? { PairingNumber.expectedLength(digits) }
    private var isComplete: Bool { expectedLength == digits.count }
    private var decoded: (address: String, code: String)? { PairingNumber.decode(digits) }

    /// Sized so the number, hint and all four keypad rows fit on one screen,
    /// from the 40 mm case up to Ultra.
    private var keyHeight: CGFloat {
        max(27, (WKInterfaceDevice.current().screenBounds.height - 100) / 4 - 3)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 3) {
                if searchingCloud {
                    HStack(spacing: 6) {
                        ProgressView().frame(width: 16, height: 16)
                        Text("Looking for your Mac in iCloud…").font(.caption2)
                    }
                }
                Text(digits.isEmpty ? "Pairing number" : PairingNumber.grouped(digits))
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(digits.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(maxWidth: .infinity, minHeight: 20)
                    .accessibilityLabel("Pairing number \(digits)")
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(hintIsError ? Color.red : Color.secondary)
                    .lineLimit(message == nil ? 1 : 3)
                    .minimumScaleFactor(0.7)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 13)
                keypad
            }
            .padding(.horizontal, 4)
        }
        .task { searchCloud() }
    }

    private var hint: String {
        if let message { return message }
        if digits.isEmpty { return "On your Mac, under Connection" }
        if expectedLength == nil { return "Check the first digit" }
        if isComplete, decoded == nil { return "Doesn't match. Check each digit" }
        if decoded != nil { return "Tap the green button to pair" }
        return " "
    }

    private var hintIsError: Bool {
        message != nil || (!digits.isEmpty && (expectedLength == nil || (isComplete && decoded == nil)))
    }

    private var keypad: some View {
        let keys = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "⌫", "0", "pair"]
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 3), spacing: 3) {
            ForEach(keys, id: \.self) { key in
                if key == "pair" {
                    Button {
                        pair()
                    } label: {
                        Group {
                            if pairing { ProgressView() } else { Image(systemName: "checkmark") }
                        }
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: keyHeight)
                        .background(decoded == nil ? AnyShapeStyle(.quaternary) : AnyShapeStyle(Color.green),
                                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(decoded == nil || pairing)
                    .accessibilityLabel("Pair")
                } else {
                    Button {
                        press(key)
                    } label: {
                        Group {
                            if key == "⌫" { Image(systemName: "delete.left") } else { Text(key) }
                        }
                        .font(.system(.title3, design: .rounded).weight(.medium))
                        .frame(maxWidth: .infinity, minHeight: keyHeight)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(key == "⌫" ? "Delete" : key)
                }
            }
        }
    }

    private func press(_ key: String) {
        message = nil
        if key == "⌫" {
            if !digits.isEmpty { digits.removeLast() }
        } else if digits.count < (expectedLength ?? 16) {
            digits.append(key)
        }
    }

    private func searchCloud() {
        guard CloudPairing.isEnabled else { return }
        searchingCloud = true
        Task {
            // On success LinkClient marks the store paired and RootView
            // replaces this screen.
            _ = await link.pairFromCloud()
            searchingCloud = false
        }
    }

    private func pair() {
        guard let decoded else { return }
        pairing = true
        message = nil
        Task {
            do {
                try await link.pair(host: decoded.address, code: decoded.code)
                // LinkClient marks the store paired; RootView switches screens.
            } catch {
                message = error.localizedDescription
            }
            pairing = false
        }
    }
}
