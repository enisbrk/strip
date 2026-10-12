import QuartzCore

/// Drives the presented viewport offset towards a target with a critically damped spring.
@MainActor
final class Animator {
    /// Spring stiffness; higher = snappier. ~0.3 s to settle at 22.
    var omega: Double = 22
    private(set) var presented: CGFloat = 0
    private var from: CGFloat = 0
    private var target: CGFloat = 0
    private var startTime: CFTimeInterval = 0
    private var timer: Timer?
    private var onFrame: ((CGFloat) -> Void)?

    var isAnimating: Bool { timer != nil }

    func jump(to value: CGFloat, onFrame: (CGFloat) -> Void) {
        stop()
        presented = value
        target = value
        onFrame(value)
    }

    func animate(to value: CGFloat, onFrame: @escaping (CGFloat) -> Void) {
        self.onFrame = onFrame
        guard abs(value - presented) > 0.5 else {
            // No scrolling needed, but widths/order may have changed: render once.
            jump(to: value, onFrame: onFrame)
            return
        }
        from = presented
        target = value
        startTime = CACurrentMediaTime()
        if timer == nil {
            let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let t = CACurrentMediaTime() - startTime
        // Critically damped spring step response: 1 - (1 + ωt)·e^(−ωt)
        let progress = 1 - (1 + omega * t) * exp(-omega * t)
        let value = from + (target - from) * CGFloat(progress)
        if abs(target - value) < 0.5 {
            presented = target
            stop()
            onFrame?(target)
        } else {
            presented = value.rounded()
            onFrame?(presented)
        }
    }
}
