import AppKit
import ApplicationServices
import StripCore

@MainActor
protocol WindowTrackerDelegate: AnyObject {
    func windowAppeared(_ window: AXWindow, initial: Bool)
    func windowDestroyed(_ id: WindowID)
    func windowChanged(_ id: WindowID, notification: String)
    func focusChanged(pid: pid_t)
    func appHiddenChanged(pid: pid_t, hidden: Bool)
    func appTerminated(pid: pid_t)
    func activeSpaceChanged()
}

/// Discovers application windows and turns AX / NSWorkspace notifications into window events.
@MainActor
final class WindowTracker: AppObserverDelegate {
    weak var delegate: WindowTrackerDelegate?

    private var observers: [pid_t: AppObserver] = [:]
    private var windows: [pid_t: [WindowID: AXWindow]] = [:]
    private var workspaceTokens: [NSObjectProtocol] = []
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    func start() {
        let nc = NSWorkspace.shared.notificationCenter
        func on(_ name: Notification.Name, _ handler: @escaping @MainActor (pid_t) -> Void) {
            workspaceTokens.append(nc.addObserver(forName: name, object: nil, queue: .main) { note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let pid = app?.processIdentifier ?? 0
                MainActor.assumeIsolated { handler(pid) }
            })
        }
        on(NSWorkspace.didLaunchApplicationNotification) { [weak self] pid in self?.observe(pid: pid) }
        on(NSWorkspace.didTerminateApplicationNotification) { [weak self] pid in self?.forget(pid: pid) }
        on(NSWorkspace.didActivateApplicationNotification) { [weak self] pid in
            guard let self else { return }
            if observers[pid] == nil { observe(pid: pid) }
            delegate?.focusChanged(pid: pid)
        }
        on(NSWorkspace.didHideApplicationNotification) { [weak self] pid in
            self?.delegate?.appHiddenChanged(pid: pid, hidden: true)
        }
        on(NSWorkspace.didUnhideApplicationNotification) { [weak self] pid in
            self?.delegate?.appHiddenChanged(pid: pid, hidden: false)
        }
        on(NSWorkspace.activeSpaceDidChangeNotification) { [weak self] _ in
            guard let self else { return }
            rescanAll(initial: false)
            delegate?.activeSpaceChanged()
        }

        rescanAll(initial: true)
    }

    func stop() {
        workspaceTokens.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceTokens.removeAll()
        observers.values.forEach { $0.invalidate() }
        observers.removeAll()
        windows.removeAll()
    }

    func window(_ id: WindowID) -> AXWindow? {
        for perApp in windows.values { if let w = perApp[id] { return w } }
        return nil
    }

    /// The focused window of the given app, registering it if we have never seen it.
    func focusedWindow(pid: pid_t) -> AXWindow? {
        guard let observer = observers[pid],
              let element = AX.element(observer.appElement, kAXFocusedWindowAttribute) else { return nil }
        if let id = lookup(element, pid: pid) { return windows[pid]?[id] }
        return register(element, pid: pid, announce: true)
    }

    // MARK: - Discovery

    private func rescanAll(initial: Bool) {
        var found: [AXWindow] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            found += observe(pid: app.processIdentifier, announce: !initial)
        }
        if initial {
            // Keep the user's current left-to-right arrangement as the initial strip order.
            let ordered = found.sorted { ($0.frame?.minX ?? 0) < ($1.frame?.minX ?? 0) }
            ordered.forEach { delegate?.windowAppeared($0, initial: true) }
        }
    }

    @discardableResult
    private func observe(pid: pid_t, announce: Bool = true, attempt: Int = 0) -> [AXWindow] {
        guard pid != ownPID, pid > 0,
              let app = NSRunningApplication(processIdentifier: pid),
              app.activationPolicy == .regular else { return [] }

        if observers[pid] == nil {
            guard let observer = AppObserver(pid: pid, delegate: self) else {
                // Apps that are still launching reject observers for a moment.
                if attempt < 10 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        self?.observe(pid: pid, announce: true, attempt: attempt + 1)
                    }
                }
                return []
            }
            observers[pid] = observer
        }

        let appElement = observers[pid]!.appElement
        return AX.elements(appElement, kAXWindowsAttribute).compactMap {
            register($0, pid: pid, announce: announce)
        }
    }

    /// Starts tracking a window element; returns it only if it was not tracked before.
    @discardableResult
    private func register(_ element: AXUIElement, pid: pid_t, announce: Bool) -> AXWindow? {
        guard let id = AX.windowID(of: element) else { return nil }
        if windows[pid]?[id] != nil { return nil }
        guard let window = AXWindow(element: element, pid: pid), window.role == kAXWindowRole else { return nil }
        windows[pid, default: [:]][id] = window
        observers[pid]?.watch(window: element)
        if announce { delegate?.windowAppeared(window, initial: false) }
        return window
    }

    private func forget(pid: pid_t) {
        observers.removeValue(forKey: pid)?.invalidate()
        windows.removeValue(forKey: pid)
        delegate?.appTerminated(pid: pid)
    }

    private func lookup(_ element: AXUIElement, pid: pid_t) -> WindowID? {
        if let id = AX.windowID(of: element), windows[pid]?[id] != nil { return id }
        // Destroyed elements often no longer resolve to an id; compare elements instead.
        return windows[pid]?.first { CFEqual($0.value.element, element) }?.key
    }

    // MARK: - AppObserverDelegate

    func appObserver(_ observer: AppObserver, received notification: String, element: AXUIElement) {
        let pid = observer.pid
        switch notification {
        case kAXWindowCreatedNotification:
            // Give the app a moment to finish configuring the window (subrole, size).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                self?.register(element, pid: pid, announce: true)
            }
        case kAXFocusedWindowChangedNotification:
            if lookup(element, pid: pid) == nil { register(element, pid: pid, announce: true) }
            delegate?.focusChanged(pid: pid)
        case kAXUIElementDestroyedNotification:
            guard let id = lookup(element, pid: pid) else { return }
            windows[pid]?.removeValue(forKey: id)
            delegate?.windowDestroyed(id)
        default:
            guard let id = lookup(element, pid: pid) else { return }
            delegate?.windowChanged(id, notification: notification)
        }
    }
}
