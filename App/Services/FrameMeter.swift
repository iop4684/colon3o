import QuartzCore
import SwiftUI

/// Switches for finding what slows the lyrics screen down, and a frame-rate meter to read the
/// result. Temporary: they live in the player's ••• menu under "Performance Test".
enum PerformanceTest {
    static let meterKey = "perf.meter"
    static let noSweepKey = "perf.noSweep"
    static let noFadeKey = "perf.noFade"
    static let plainBackgroundKey = "perf.plainBackground"
}

/// Counts the frames the screen actually shows, with a display link, and reports once a second:
/// frames per second and the longest gap between two frames (a hitch).
@MainActor
final class FrameMeter: ObservableObject {
    @Published private(set) var fps = 0
    @Published private(set) var worstMs = 0.0

    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var windowStart: CFTimeInterval = 0
    private var frames = 0
    private var worst: CFTimeInterval = 0

    func start() {
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(step(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
        last = 0
    }

    @objc private func step(_ link: CADisplayLink) {
        let now = link.timestamp
        if last > 0 { worst = max(worst, now - last) }
        last = now
        frames += 1
        if windowStart == 0 { windowStart = now }
        if now - windowStart >= 1 {
            fps = Int((Double(frames) / (now - windowStart)).rounded())
            worstMs = (worst * 1000).rounded()
            frames = 0
            worst = 0
            windowStart = now
        }
    }
}

/// The meter's readout, drawn over the player when it's on.
struct FrameMeterBadge: View {
    @StateObject private var meter = FrameMeter()

    var body: some View {
        Text("\(meter.fps) fps · worst \(Int(meter.worstMs)) ms")
            .font(.caption.monospacedDigit().weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.black.opacity(0.6), in: Capsule())
            .foregroundStyle(meter.worstMs > 34 ? .orange : .green)
            .onAppear { meter.start() }
            .onDisappear { meter.stop() }
            .allowsHitTesting(false)
    }
}
