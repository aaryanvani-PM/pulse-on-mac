import AppKit
import AVFoundation
import SwiftUI

/// Saves screenshots and a short video of the popover with demo data:
///
///   Build/HRMenuBar.app/Contents/MacOS/HRMenuBar -HRDemo -HRDemoExport <folder>
///
/// The app draws its own window into images, so this needs no Screen
/// Recording permission. It quits when done.
@MainActor
enum DemoExport {
    static var folder: URL? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-HRDemoExport"), args.indices.contains(index + 1) else { return nil }
        return URL(fileURLWithPath: args[index + 1], isDirectory: true)
    }

    static func run(store: HeartRateStore, credentials: MacCredentials, server: WatchHTTPServer,
                    cloud: CloudPublisher, to folder: URL) async {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let saved = UserDefaults.standard.string(forKey: "trendRange")
        defer { UserDefaults.standard.set(saved, forKey: "trendRange") }
        // Let a few live readings arrive first.
        try? await Task.sleep(for: .seconds(4))

        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for range in MenuBarView.TrendRange.allCases {
                UserDefaults.standard.set(range.rawValue, forKey: "trendRange")
                let view = MenuBarView(store: store, credentials: credentials, server: server, cloud: cloud)
                let capture = Capture(view, appearance: appearance)
                try? await Task.sleep(for: .seconds(1.5))
                capture.png().map { try? $0.write(to: folder.appendingPathComponent("popover-\(range.rawValue.lowercased())-\(name).png")) }
                capture.close()
            }
            UserDefaults.standard.set(MenuBarView.TrendRange.hour.rawValue, forKey: "trendRange")
            let open = Capture(MenuBarView(store: store, credentials: credentials, server: server, cloud: cloud,
                                           expandConnection: true), appearance: appearance)
            try? await Task.sleep(for: .seconds(1.5))
            open.png().map { try? $0.write(to: folder.appendingPathComponent("popover-connection-\(name).png")) }
            open.close()
            // Settings with an alert switched on, from a throwaway store so
            // the user's own settings are never touched.
            let suite = "pulse-demo-settings"
            let demoPrefs = Preferences(defaults: UserDefaults(suiteName: suite)!)
            demoPrefs.highAlert = true
            demoPrefs.highLimit = 120
            demoPrefs.sustainMinutes = 5
            let settings = Capture(SettingsView(prefs: demoPrefs), appearance: appearance, active: true)
            try? await Task.sleep(for: .seconds(1.5))
            settings.png().map { try? $0.write(to: folder.appendingPathComponent("settings-\(name).png")) }
            settings.close()
            UserDefaults().removePersistentDomain(forName: suite)
        }

        // 20 s video of the 1H popover with the reading ticking.
        UserDefaults.standard.set(MenuBarView.TrendRange.hour.rawValue, forKey: "trendRange")
        let live = Capture(MenuBarView(store: store, credentials: credentials, server: server, cloud: cloud),
                           appearance: .darkAqua)
        try? await Task.sleep(for: .seconds(1.5))
        await live.record(to: folder.appendingPathComponent("popover-live-dark.mov"), seconds: 20, fps: 30)
        live.close()
        NSApp.terminate(nil)
    }

    /// An off-screen window holding the view, drawn at 2x.
    /// Borderless windows can't become key by default; controls in a
    /// non-key window draw without their accent colour.
    final class KeyWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }

    @MainActor
    final class Capture {
        let window: NSWindow
        let host: NSView

        /// `active` draws controls as in the focused window (blue switches).
        init<V: View>(_ view: V, appearance: NSAppearance.Name, active: Bool = false) {
            let root = view
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            let host = NSHostingView(rootView: root)
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            window = KeyWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.appearance = NSAppearance(named: appearance)
            window.contentView = host
            window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
            if active {
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            } else {
                window.orderFront(nil)
            }
            self.host = host
        }

        func close() { window.orderOut(nil) }

        func bitmap() -> NSBitmapImageRep? {
            host.layoutSubtreeIfNeeded()
            let size = host.bounds.size
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2),
                                             pixelsHigh: Int(size.height * 2), bitsPerSample: 8, samplesPerPixel: 4,
                                             hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                             bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
            rep.size = size
            host.cacheDisplay(in: host.bounds, to: rep)
            return rep
        }

        func png() -> Data? { bitmap()?.representation(using: .png, properties: [:]) }

        func record(to url: URL, seconds: Double, fps: Int) async {
            try? FileManager.default.removeItem(at: url)
            guard let first = bitmap(), let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return }
            // Even dimensions for the encoder.
            let width = first.pixelsWide / 2 * 2, height = first.pixelsHigh / 2 * 2
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            ])
            input.expectsMediaDataInRealTime = true
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            ])
            writer.add(input)
            writer.startWriting()
            writer.startSession(atSourceTime: .zero)
            let frames = Int(seconds * Double(fps))
            for frame in 0..<frames {
                if let rep = bitmap(), let cg = rep.cgImage, let pool = adaptor.pixelBufferPool {
                    var buffer: CVPixelBuffer?
                    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
                    if let buffer {
                        CVPixelBufferLockBaseAddress(buffer, [])
                        // Video has no transparency: put the popover on black.
                        if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                                               bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                               space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                               bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                                   | CGBitmapInfo.byteOrder32Little.rawValue) {
                            ctx.setFillColor(.black)
                            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
                            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
                        }
                        CVPixelBufferUnlockBaseAddress(buffer, [])
                        while !input.isReadyForMoreMediaData { try? await Task.sleep(for: .milliseconds(5)) }
                        adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
                    }
                }
                try? await Task.sleep(for: .milliseconds(1000 / fps))
            }
            input.markAsFinished()
            await writer.finishWriting()
        }
    }
}
