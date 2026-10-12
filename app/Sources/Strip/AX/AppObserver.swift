import AppKit
import ApplicationServices

@MainActor
protocol AppObserverDelegate: AnyObject {
    func appObserver(_ observer: AppObserver, received notification: String, element: AXUIElement)
}

/// Wraps an AXObserver for one application process.
@MainActor
final class AppObserver {
    static let windowNotifications = [
        kAXUIElementDestroyedNotification,
        kAXWindowMovedNotification,
        kAXWindowResizedNotification,
        kAXWindowMiniaturizedNotification,
        kAXWindowDeminiaturizedNotification,
    ]

    let pid: pid_t
    let appElement: AXUIElement
    weak var delegate: AppObserverDelegate?
    private let observer: AXObserver

    init?(pid: pid_t, delegate: AppObserverDelegate) {
        var created: AXObserver?
        guard AXObserverCreate(pid, appObserverCallback, &created) == .success, let created else { return nil }
        self.pid = pid
        self.observer = created
        self.appElement = AXUIElementCreateApplication(pid)
        self.delegate = delegate

        // Fails for apps that are still launching; the caller retries.
        guard add(kAXWindowCreatedNotification, to: appElement) else { return nil }
        add(kAXFocusedWindowChangedNotification, to: appElement)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    func watch(window: AXUIElement) {
        for n in Self.windowNotifications { add(n, to: window) }
    }

    func invalidate() {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    @discardableResult
    private func add(_ notification: String, to element: AXUIElement) -> Bool {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let err = AXObserverAddNotification(observer, element, notification as CFString, refcon)
        return err == .success || err == .notificationAlreadyRegistered
    }

    fileprivate func deliver(_ notification: String, _ element: AXUIElement) {
        delegate?.appObserver(self, received: notification, element: element)
    }
}

private func appObserverCallback(
    _: AXObserver, element: AXUIElement, notification: CFString, refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let name = notification as String
    let address = UInt(bitPattern: refcon)
    // The run loop source lives on the main run loop, so we are on the main thread here.
    nonisolated(unsafe) let element = element
    MainActor.assumeIsolated {
        let observer = Unmanaged<AppObserver>.fromOpaque(UnsafeRawPointer(bitPattern: address)!).takeUnretainedValue()
        observer.deliver(name, element)
    }
}
