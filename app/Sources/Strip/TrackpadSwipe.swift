import AppKit

/// Follows horizontal multi-finger swipes on the trackpad through a listen-only event tap on
/// gesture events, reporting how far the fingers moved (as a fraction of the trackpad width).
@MainActor
final class TrackpadSwipe {
    var fingers = 3
    var onBegin: (() -> Void)?
    /// Total horizontal finger travel since the swipe began, in trackpad widths (right = positive).
    var onChange: ((CGFloat) -> Void)?
    /// Called with the final travel and the recent velocity (trackpad widths per second).
    var onEnd: ((CGFloat, CGFloat) -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var startX: CGFloat?
    private var lastX: CGFloat = 0
    private var lastTime: TimeInterval = 0
    private var velocity: CGFloat = 0
    /// Ignore the first jitter so a tap or a vertical swipe never moves the strip.
    private var engaged = false

    func start() {
        guard tap == nil else { return }
        let gestureType: UInt64 = 29 // NSEvent.EventType.gesture / kCGEventGesture
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: CGEventMask(1) << gestureType,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let address = UInt(bitPattern: refcon)
                nonisolated(unsafe) let event = event
                MainActor.assumeIsolated {
                    let swipe = Unmanaged<TrackpadSwipe>.fromOpaque(UnsafeRawPointer(bitPattern: address)!).takeUnretainedValue()
                    swipe.handle(type: type, event: event)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else {
            NSLog("Strip: could not create the trackpad event tap")
            return
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.source = source
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        finish()
    }

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard let nsEvent = NSEvent(cgEvent: event) else { return }
        let touching = nsEvent.allTouches().filter { $0.phase != .ended && $0.phase != .cancelled }
        guard touching.count == fingers else {
            finish()
            return
        }
        let x = touching.map(\.normalizedPosition.x).reduce(0, +) / CGFloat(touching.count)
        let y = touching.map(\.normalizedPosition.y).reduce(0, +) / CGFloat(touching.count)
        let now = event.timestamp == 0 ? ProcessInfo.processInfo.systemUptime : TimeInterval(event.timestamp) / 1e9
        guard let start = startX else {
            startX = x
            startY = y
            lastX = x
            lastTime = now
            return
        }
        if !engaged {
            // Wait until the fingers clearly move sideways.
            let dx = abs(x - start), dy = abs(y - (startY ?? y))
            guard dx > 0.03, dx > dy else { return }
            engaged = true
            onBegin?()
        }
        let dt = now - lastTime
        if dt > 0 { velocity = velocity * 0.6 + (x - lastX) / CGFloat(dt) * 0.4 }
        lastX = x
        lastTime = now
        onChange?(x - start)
    }

    private var startY: CGFloat?

    private func finish() {
        if engaged, let start = startX { onEnd?(lastX - start, velocity) }
        startX = nil
        startY = nil
        engaged = false
        velocity = 0
    }

    /// The finger count macOS does not already use for swiping between Spaces / full-screen apps.
    static func defaultFingerCount() -> Int {
        let keys = ["TrackpadThreeFingerHorizSwipeGesture"]
        for domain in ["com.apple.AppleMultitouchTrackpad", "com.apple.driver.AppleBluetoothMultitouch.trackpad"] {
            for key in keys {
                if let value = CFPreferencesCopyAppValue(key as CFString, domain as CFString) as? Int, value != 0 {
                    return 4 // three-finger horizontal swipes belong to macOS
                }
            }
        }
        return 3
    }
}
