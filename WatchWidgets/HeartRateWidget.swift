import SwiftUI
import WidgetKit

struct HeartRateEntry: TimelineEntry {
    let date: Date
    let reading: ComplicationCache.Reading?
    var isRecent: Bool {
        guard let reading else { return false }
        return reading.isRecent(at: date)
    }
}

struct HeartRateProvider: TimelineProvider {
    // Placeholders intentionally contain no invented heart-rate value.
    func placeholder(in context: Context) -> HeartRateEntry {
        HeartRateEntry(date: Date(), reading: nil)
    }
    func getSnapshot(in context: Context, completion: @escaping (HeartRateEntry) -> Void) {
        completion(HeartRateEntry(date: Date(), reading: ComplicationCache.load()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<HeartRateEntry>) -> Void) {
        let now = Date()
        let reading = ComplicationCache.load()
        var entries = [HeartRateEntry(date: now, reading: reading)]
        // Pre-render staleness at its actual deadline, even if the next
        // WidgetKit reload is deferred. The original measurement time stays.
        if let reading, reading.measuredAt.addingTimeInterval(20 * 60) > now {
            entries.append(HeartRateEntry(date: reading.measuredAt.addingTimeInterval(20 * 60), reading: reading))
        }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(20 * 60))))
    }
}

struct HeartRateComplicationView: View {
    let entry: HeartRateEntry
    @Environment(\.widgetFamily) private var family
    private var value: String {
        guard entry.isRecent, let reading = entry.reading else { return "--" }
        return String(reading.bpm)
    }
    var body: some View {
        Group {
            switch family {
            case .accessoryInline:
                Label("\(value) BPM", systemImage: "heart")
            case .accessoryCorner:
                Text(value)
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .widgetLabel {
                        Label("BPM", systemImage: "heart.fill")
                    }
            case .accessoryRectangular:
                VStack(alignment: .leading) {
                    Label("\(value) BPM", systemImage: "heart.fill")
                        .font(.headline)
                    if let reading = entry.reading {
                        HStack(spacing: 3) {
                            Text("Measured")
                            Text(reading.measuredAt, style: .time)
                        }.font(.caption2)
                        if !entry.isRecent { Text("No recent reading").font(.caption2) }
                    } else {
                        Text("Open Heart Rate to pair").font(.caption2)
                    }
                }
            default:
                VStack(spacing: 0) {
                    Image(systemName: "heart.fill").font(.caption2)
                    Text(value).font(.headline).monospacedDigit()
                    Text("BPM").font(.system(size: 9))
                }
            }
        }
        .privacySensitive()
        .containerBackground(.clear, for: .widget)
        .accessibilityLabel(entry.isRecent ? "Heart rate \(value) beats per minute" : "No recent heart-rate reading")
    }
}

@main
struct HeartRateWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: ComplicationCache.kind, provider: HeartRateProvider()) { entry in
            HeartRateComplicationView(entry: entry)
        }
        .configurationDisplayName("Pulse")
        .description("Your latest Watch reading. Keep on your active face to support occasional Mac sync.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }
}
