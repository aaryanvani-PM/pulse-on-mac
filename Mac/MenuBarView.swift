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
    /// Demo export only: open the Connection section on first appearance.
    var expandConnection = false

    enum TrendRange: String, CaseIterable, Identifiable {
        case hour = "1H", sixHours = "6H", day = "Day", week = "7D", month = "30D"
        var id: String { rawValue }
        var spoken: String {
            switch self {
            case .hour: return "Last hour"
            case .sixHours: return "Last 6 hours"
            case .day: return "Last day"
            case .week: return "Last 7 days"
            case .month: return "Last 30 days"
            }
        }
        /// 7D and 30D show one bar per calendar day.
        var days: Int? {
            switch self {
            case .week: return 7
            case .month: return 30
            default: return nil
            }
        }
        var span: TimeInterval {
            switch self {
            case .hour: return 3600
            case .sixHours: return 6 * 3600
            case .day: return 24 * 3600
            case .week: return 7 * 86400
            case .month: return 30 * 86400
            }
        }
        /// Bucket width: each bar shows the min–max of its interval.
        /// Axis tick spacing in seconds, chosen so labels never collide.
        var tick: TimeInterval {
            switch self {
            case .hour: return 15 * 60
            case .sixHours: return 2 * 3600
            case .day: return 6 * 3600
            case .week: return 86400
            case .month: return 7 * 86400
            }
        }
        var bucket: TimeInterval {
            switch self {
            case .hour: return 120
            case .sixHours: return 600
            case .day: return 1800
            case .week, .month: return 86400
            }
        }
    }

    @State private var didConfigure = false
    @State private var range: TrendRange = .hour
    @State private var showConnection = false
    @State private var showInfo = false
    @State private var showHealthInfo = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @AppStorage("trendRange") private var savedRange = TrendRange.hour.rawValue
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion


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
                // Re-checked every 30 s so "quiet" and ages stay current.
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    connectionLabel(health(at: context.date))
                }
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
            if expandConnection { showConnection = true }
            guard !didConfigure, !DemoMode.isOn else { return }
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
                .accessibilityLabel("About this status")
                .popover(isPresented: $showInfo, arrowEdge: .bottom) { infoPopover(status) }
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(store.currentBPM.map(String.init) ?? "--")
                    .font(.system(size: 52, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(reduceMotion ? .identity : .numericText())
                    .foregroundStyle(status == .live ? .primary : .secondary)
                Text("BPM")
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(store.currentBPM.map { "\($0) beats per minute" } ?? "No reading")
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Status: \(statusWord(status))")
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
            Text("Open Pulse on your Watch and tap Go Live for a new reading every few seconds. This uses more battery.")
            if status == .passiveQuiet {
                Text("No reading has arrived for over 20 minutes. Check that the Watch is on your wrist, on the same Wi‑Fi, and has the Pulse complication on its face.")
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
            let (start, end, buckets) = window(at: context.date)
            VStack(alignment: .leading, spacing: 10) {
                Picker("Range", selection: $range) {
                    ForEach(TrendRange.allCases) { Text($0.rawValue).tag($0).accessibilityLabel($0.spoken) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                summary(buckets)
                chart(buckets, start: start, end: end)
            }
        }
    }

    /// The chart's time window and its bars. Hour ranges slide with the
    /// clock; 7D and 30D run from midnight, one bar per day.
    private func window(at now: Date) -> (Date, Date, [TrendHistory.Bucket]) {
        if let days = range.days {
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: now)
            let start = calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today
            let end = calendar.date(byAdding: .day, value: 1, to: today) ?? now
            return (start, end, store.trend.dayBuckets(days: days, endingAt: now))
        }
        let start = now.addingTimeInterval(-range.span)
        return (start, now, store.trend.buckets(from: start, to: now, width: range.bucket))
    }

    /// Range and average side by side, both left-aligned with units, so the
    /// numbers read as a pair instead of sitting at opposite edges.
    private func summary(_ buckets: [TrendHistory.Bucket]) -> some View {
        let low = buckets.map(\.min).min()
        let high = buckets.map(\.max).max()
        let count = buckets.map(\.count).reduce(0, +)
        let weighted = buckets.map { $0.average * Double($0.count) }.reduce(0, +)
        let average: Int? = count == 0 ? nil : Int((weighted / Double(count)).rounded())
        let rangeText: String = (low != nil && high != nil) ? "\(low!)–\(high!)" : "--"
        return HStack(alignment: .top, spacing: 26) {
            stat("RANGE", rangeText)
            stat("AVERAGE", average.map(String.init) ?? "--")
            Spacer(minLength: 0)
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(.title2, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                Text("BPM").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func chart(_ buckets: [TrendHistory.Bucket], start: Date, end: Date) -> some View {
        let low: Double = Double(buckets.map(\.min).min() ?? 55) - 8
        let high: Double = Double(buckets.map(\.max).max() ?? 95) + 8
        let inset: TimeInterval = range.bucket * (range.days == nil ? 0.18 : 0.22)
        return Chart(buckets) { bucket in
            // Min–max capsule per interval; a single reading becomes a dot.
            Self.mark(for: bucket, inset: inset)
        }
        .chartXScale(domain: start...end)
        .chartYScale(domain: low...high)
        .chartXAxis {
            if range == .week {
                // Grid lines between days, letters under the middle of each day.
                AxisMarks(values: Self.dayTicks(from: start, to: end, everyDays: 1)) { _ in
                    AxisGridLine().foregroundStyle(.quaternary)
                }
                AxisMarks(values: Self.dayTicks(from: start, to: end, everyDays: 1).map { $0.addingTimeInterval(12 * 3600) }) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.narrow))
                }
            } else {
                AxisMarks(values: range.days == nil ? Self.ticks(from: start, to: end, step: range.tick)
                                                    : Self.dayTicks(from: start, to: end, everyDays: 7)) { _ in
                    AxisGridLine().foregroundStyle(.quaternary)
                    switch range {
                    case .hour: AxisValueLabel(format: .dateTime.hour().minute())
                    case .month: AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    default: AxisValueLabel(format: .dateTime.hour())
                    }
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Heart rate chart, \(range.spoken.lowercased())")
        .accessibilityValue(Self.spokenSummary(buckets))
    }

    /// The chart in one sentence for VoiceOver.
    private static func spokenSummary(_ buckets: [TrendHistory.Bucket]) -> String {
        guard let low = buckets.map(\.min).min(), let high = buckets.map(\.max).max() else { return "No readings" }
        let count = max(1, buckets.map(\.count).reduce(0, +))
        let average = Int((buckets.map { $0.average * Double($0.count) }.reduce(0, +) / Double(count)).rounded())
        return "From \(low) to \(high) beats per minute, average \(average)"
    }

    /// Day starts for 7D (every day) and 30D (every 7 days).
    private static func dayTicks(from start: Date, to end: Date, everyDays: Int) -> [Date] {
        let calendar = Calendar.current
        var result: [Date] = []
        var day = start
        while day < end {
            result.append(day)
            day = calendar.date(byAdding: .day, value: everyDays, to: day) ?? end
        }
        // Keep the last label clear of the right edge on 30D.
        if everyDays > 1, let last = result.last, end.timeIntervalSince(last) < 3 * 86400 { result.removeLast() }
        return result
    }

    /// Ticks on round local clock times (12 AM, 6 AM, …). A tick too close
    /// to the right edge is dropped so its label is never cut off.
    private static func ticks(from start: Date, to end: Date, step: TimeInterval) -> [Date] {
        let midnight = Calendar.current.startOfDay(for: start)
        // Wide enough for "11:45 PM" at the right edge without clipping.
        let limit = end.addingTimeInterval(-end.timeIntervalSince(start) * 0.15)
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

    private func health(at now: Date) -> ConnectionHealth {
        ConnectionHealth.evaluate(serverState: store.serverState,
                                  receiverResponding: ConnectionMonitor.shared.receiverResponding,
                                  hasPairedWatch: credentials.hasPairedWatch,
                                  lastContact: store.lastContactAt, lastRejected: store.lastRejectedAt,
                                  contactAddress: store.contactAddress, currentAddress: store.localAddress, now: now)
    }

    private func connectionLabel(_ health: ConnectionHealth) -> some View {
        HStack(spacing: 6) {
            Text("Connection").font(.subheadline.weight(.medium))
            Spacer()
            Circle().fill(healthColor(health.level)).frame(width: 7, height: 7)
            Text(health.word).font(.caption).foregroundStyle(.secondary)
            Button { showHealthInfo.toggle() } label: {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Connection details")
            .accessibilityLabel("Connection details")
            .popover(isPresented: $showHealthInfo, arrowEdge: .bottom) { healthPopover(health) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Connection: \(health.word)")
    }

    private func healthPopover(_ health: ConnectionHealth) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(health.word).font(.subheadline.weight(.semibold))
            } icon: {
                Circle().fill(healthColor(health.level)).frame(width: 8, height: 8)
            }
            Text(health.detail)
            if let fix = health.fix {
                Text(fix).foregroundStyle(health.level == .problem ? Color.red : Color.secondary)
            }
            if let checked = ConnectionMonitor.shared.lastChecked {
                Text("This Mac checks its receiver every minute. Last check \(checked, format: .dateTime.hour().minute()).")
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
        .padding(14)
        .frame(width: 270, alignment: .leading)
    }

    private func healthColor(_ level: ConnectionHealth.Level) -> Color {
        switch level {
        case .good: return .green
        case .warning: return .yellow
        case .problem: return .red
        }
    }

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
                Text("On your Apple Watch, open Pulse and enter this number. You only do this once.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Connect this Mac to Wi‑Fi to pair your Apple Watch.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let contact = store.lastContactAt {
                Text("Watch last checked in \(HeartRateStore.spokenAge(store.now.timeIntervalSince(contact)))")
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
            Button {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings")
            .accessibilityLabel("Settings")
            Button("Quit") { NSApp.terminate(nil) }
                .controlSize(.small)
        }
    }
}
