import AppKit
import Charts
import ServiceManagement
import SwiftUI

private let heartColor = Color(red: 1.0, green: 0.22, blue: 0.37)

/// Menu-bar window: current reading, trend chart, and a collapsed
/// Connection section for pairing and delivery details.
struct MenuBarView: View {
    let store: HeartRateStore
    let credentials: MacCredentials
    let server: WatchHTTPServer
    let cloud: CloudPublisher

    enum TrendRange: String, CaseIterable, Identifiable {
        case hour = "1H", sixHours = "6H", day = "Day"
        var id: String { rawValue }
        var span: TimeInterval {
            switch self {
            case .hour: return 3600
            case .sixHours: return 6 * 3600
            case .day: return 24 * 3600
            }
        }
        /// Bucket width: each bar shows the min–max of its interval.
        /// Axis tick spacing in seconds, chosen so labels never collide.
        var tick: TimeInterval {
            switch self {
            case .hour: return 15 * 60
            case .sixHours: return 2 * 3600
            case .day: return 6 * 3600
            }
        }
        var bucket: TimeInterval {
            switch self {
            case .hour: return 120
            case .sixHours: return 600
            case .day: return 1800
            }
        }
    }

    @State private var didConfigure = false
    @State private var range: TrendRange = .hour
    @State private var showConnection = false
    @State private var showInfo = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @AppStorage("trendRange") private var savedRange = TrendRange.hour.rawValue


    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                header(status: store.status(at: context.date), now: context.date)
            }
            trendSection
            Divider()
            DisclosureGroup(isExpanded: $showConnection) {
                connectionSection.padding(.top, 8)
            } label: {
                Text("Connection").font(.subheadline.weight(.medium))
            }
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 320)
        .task {
            // The server autostarts in HRMenuBarApp.init; the window only
            // needs to pick up the (possibly changed) local address.
            range = TrendRange(rawValue: savedRange) ?? .hour
            guard !didConfigure else { return }
            didConfigure = true
            store.configure(pairingCode: credentials.pairingCode, localAddress: LocalAddress.primaryIPv4())
        }
        .onChange(of: range) { _, new in savedRange = new.rawValue }
    }

    // MARK: - Current reading

    private func header(status: HeartRateStore.Status, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Image(systemName: "heart.fill").foregroundStyle(heartColor)
                Text("Heart Rate").font(.subheadline.weight(.semibold)).foregroundStyle(heartColor)
                Spacer()
                statusPill(status)
                Button { showInfo.toggle() } label: {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("What this status means")
                .popover(isPresented: $showInfo, arrowEdge: .bottom) { infoPopover(status) }
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(store.currentBPM.map(String.init) ?? "--")
                    .font(.system(size: 52, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(status == .live ? .primary : .secondary)
                Text("BPM")
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(detailLine(status, now: now))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private func statusPill(_ status: HeartRateStore.Status) -> some View {
        HStack(spacing: 4) {
            Circle().fill(statusColor(status)).frame(width: 6, height: 6)
            Text(statusWord(status)).font(.caption2.weight(.medium))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(.quaternary, in: Capsule())
    }

    private func statusWord(_ status: HeartRateStore.Status) -> String {
        switch status {
        case .off: return "Off"
        case .failed: return "Error"
        case .needsLocalNetworkPermission: return "Permission"
        case .waiting: return "Waiting"
        case .connected: return "Connected"
        case .live: return "Live"
        case .stale: return "Paused"
        case .passiveSynced: return "Periodic"
        case .passiveQuiet: return "No recent reading"
        }
    }

    private func infoPopover(_ status: HeartRateStore.Status) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Periodic", systemImage: "clock").font(.subheadline.weight(.semibold))
            Text("With the Watch app closed, your Apple Watch sends its latest readings about every 15 minutes. The number shown can be a few minutes old; the line under it says when it was measured.")
            Label("Live", systemImage: "waveform.path.ecg").font(.subheadline.weight(.semibold))
            Text("Open Heart Rate Mac on your Watch and tap Start Monitoring for a reading every second. This uses more battery.")
            if status == .passiveQuiet {
                Text("No reading has arrived for over 20 minutes. Check that the Watch is on your wrist, on the same Wi‑Fi, and has the Heart Rate Mac complication on its face.")
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
        .padding(14)
        .frame(width: 260, alignment: .leading)
    }

    /// One honest line: how old the shown number is, never implying "now".
    private func detailLine(_ status: HeartRateStore.Status, now: Date) -> String {
        let last = store.samples.last
        let measured = last.map { HeartRateStore.ageText(max(0, now.timeIntervalSince($0.recordedAt))) }
        let clock = last.map { $0.recordedAt.formatted(date: .omitted, time: .shortened) }
        switch status {
        case .off: return "Receiver stopped"
        case .failed(let message): return "Receiver error: \(message)"
        case .needsLocalNetworkPermission: return "Allow Local Network access in System Settings"
        case .waiting: return "Waiting for your Apple Watch"
        case .connected: return "Watch connected"
        case .live: return "Live from your Apple Watch"
        case .stale: return "Live session paused · measured \(measured ?? "—")"
        case .passiveSynced: return "Measured \(measured ?? "—") · \(clock ?? "")"
        case .passiveQuiet: return "Last measured \(measured ?? "—") · \(clock ?? "")"
        }
    }

    private func statusColor(_ status: HeartRateStore.Status) -> Color {
        switch status {
        case .live: return .green
        case .connected: return .yellow
        case .stale, .passiveQuiet: return .orange
        case .passiveSynced: return .blue
        case .failed, .needsLocalNetworkPermission: return .red
        case .waiting, .off: return .gray
        }
    }

    // MARK: - Trend

    private var trendSection: some View {
        // Re-evaluated once a minute so the window slides with the clock.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let end = context.date
            let start = end.addingTimeInterval(-range.span)
            let buckets = store.trend.buckets(from: start, to: end, width: range.bucket)
            VStack(alignment: .leading, spacing: 10) {
                Picker("Range", selection: $range) {
                    ForEach(TrendRange.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                summary(buckets)
                chart(buckets, start: start, end: end)
            }
        }
    }

    private func summary(_ buckets: [TrendHistory.Bucket]) -> some View {
        let low = buckets.map(\.min).min()
        let high = buckets.map(\.max).max()
        let total: Double = buckets.map(\.average).reduce(0, +)
        let average: Int? = buckets.isEmpty ? nil : Int((total / Double(buckets.count)).rounded())
        let rangeText: String = (low != nil && high != nil) ? "\(low!)–\(high!)" : "--"
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 0) {
                Text("RANGE").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(rangeText)
                        .font(.system(.title2, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                    Text("BPM").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 0) {
                Text("AVERAGE").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Text(average.map(String.init) ?? "--")
                    .font(.system(.title2, design: .rounded).weight(.semibold))
                    .monospacedDigit()
            }
        }
    }

    private func chart(_ buckets: [TrendHistory.Bucket], start: Date, end: Date) -> some View {
        let low: Double = Double(buckets.map(\.min).min() ?? 55) - 8
        let high: Double = Double(buckets.map(\.max).max() ?? 95) + 8
        let inset: TimeInterval = range.bucket * 0.18
        return Chart(buckets) { bucket in
            // Min–max capsule per interval; a single reading becomes a dot.
            Self.mark(for: bucket, inset: inset)
        }
        .chartXScale(domain: start...end)
        .chartYScale(domain: low...high)
        .chartXAxis {
            AxisMarks(values: Self.ticks(from: start, to: end, step: range.tick)) { _ in
                AxisGridLine().foregroundStyle(.quaternary)
                if range == .hour {
                    AxisValueLabel(format: .dateTime.hour().minute())
                } else {
                    AxisValueLabel(format: .dateTime.hour())
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel()
            }
        }
        .frame(height: 130)
        .overlay {
            if buckets.isEmpty {
                Text("No readings in this period")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel("Heart rate trend")
    }

    /// Ticks on round local clock times (12 AM, 6 AM, …). A tick too close
    /// to the right edge is dropped so its label is never cut off.
    private static func ticks(from start: Date, to end: Date, step: TimeInterval) -> [Date] {
        let midnight = Calendar.current.startOfDay(for: start)
        let limit = end.addingTimeInterval(-end.timeIntervalSince(start) * 0.08)
        var result: [Date] = []
        var tick = midnight
        while tick <= limit {
            if tick >= start { result.append(tick) }
            tick = tick.addingTimeInterval(step)
        }
        return result
    }

    private static func mark(for bucket: TrendHistory.Bucket, inset: TimeInterval) -> some ChartContent {
        let x0: Date = bucket.start.addingTimeInterval(inset)
        let x1: Date = bucket.end.addingTimeInterval(-inset)
        let y0: Double = Double(bucket.min) - 0.9
        let y1: Double = Double(bucket.max) + 0.9
        let xs: PlottableValue<Date> = .value("Start", x0)
        let xe: PlottableValue<Date> = .value("End", x1)
        let ys: PlottableValue<Double> = .value("Low", y0)
        let ye: PlottableValue<Double> = .value("High", y1)
        let bar = RectangleMark(xStart: xs, xEnd: xe, yStart: ys, yEnd: ye)
        return bar.cornerRadius(4).foregroundStyle(heartColor)
    }

    // MARK: - Connection (collapsed by default)

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if CloudPairing.isEnabled {
                Label(cloudText, systemImage: cloudSymbol)
                    .font(.caption)
                    .foregroundStyle(cloudIsHealthy ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Manual pairing").font(.caption2.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 4)
            }
            if let number = store.pairingNumber {
                Text("PAIRING NUMBER").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Text(PairingNumber.grouped(number))
                    .font(.system(.title2, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .textSelection(.enabled)
                Text("On your Apple Watch, open Heart Rate Mac and enter this number. You only do this once.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Connect this Mac to Wi‑Fi to pair your Apple Watch.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let last = store.samples.last {
                Text("Last update \(last.receivedAt, format: .dateTime.hour().minute())")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            HStack {
                Button(store.serverIsRunning ? "Stop Receiver" : "Start Receiver") {
                    if store.serverIsRunning { server.stop() } else { server.start() }
                }
                Button("Forget Watch") {
                    credentials.forgetAll()
                    store.notePairingCleared()
                }
            }
            .controlSize(.small)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var cloudIsHealthy: Bool {
        switch cloud.state {
        case .failed, .signedOut: return false
        default: return true
        }
    }

    private var cloudSymbol: String { cloudIsHealthy ? "checkmark.icloud" : "exclamationmark.icloud" }

    private var cloudText: String {
        switch cloud.state {
        case .idle, .publishing: return "Setting up automatic pairing…"
        case .published: return "Your Apple Watch pairs automatically through iCloud."
        case .signedOut: return "Sign in to iCloud on this Mac for automatic pairing."
        case .failed(let message): return "Automatic pairing unavailable: \(message)"
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Toggle("Open at Login", isOn: $launchAtLogin)
                .toggleStyle(.checkbox)
                .font(.caption)
                .onChange(of: launchAtLogin) { _, enabled in
                    // User-initiated only; reflect what the system accepted.
                    if enabled { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
                    launchAtLogin = SMAppService.mainApp.status == .enabled
                }
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .controlSize(.small)
        }
    }
}
