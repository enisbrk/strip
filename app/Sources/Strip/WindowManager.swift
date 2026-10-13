import AppKit
import StripCore

/// One monitor: a strip per Space, with its own focus, scroll position and animation.
@MainActor
private final class Display {
    let id: CGDirectDisplayID
    /// Stable across restarts (display ids are not), used to save the session.
    let uuid: String
    /// AX-space (top-left origin) frames.
    var frame: CGRect
    var visibleFrame: CGRect
    /// The Space currently shown on this display.
    var spaceID: SpaceID = 0
    var strips: [SpaceID: Strip] = [:]
    /// Windows of each Space's strip when it was last laid out, to tell when one joins.
    var knownWindows: [SpaceID: Set<WindowID>] = [:]
    let animator = Animator()

    /// The strip of the Space on screen; everything that lays out windows works on this one.
    var strip: Strip {
        get { strips[spaceID] ?? Strip() }
        set { strips[spaceID] = newValue }
    }

    init(id: CGDirectDisplayID, frame: CGRect, visibleFrame: CGRect) {
        self.id = id
        self.uuid = Spaces.displayUUID(id) ?? String(id)
        self.frame = frame
        self.visibleFrame = visibleFrame
    }

    /// The Space whose strip holds `window`, on any Space of this display.
    func space(of window: WindowID) -> SpaceID? {
        strips.first { $0.value.contains(window) }?.key
    }
}

/// Owns one strip per display and keeps real windows in sync with them.
@MainActor
final class WindowManager: ObservableObject, WindowTrackerDelegate {
    private struct Managed {
        let window: AXWindow
        let bundleID: String?
        var displayID: CGDirectDisplayID
        var floating: Bool
        var minimized = false
        var fullscreen = false
        var hidden = false
        /// On a display Strip was told to leave alone.
        var excluded = false
        /// A sign-in sheet (Wi-Fi portal, modal dialog): floats above everything, never tiled.
        var keepOnTop = false

        var isTileable: Bool { !floating && !minimized && !fullscreen && !hidden && !excluded }
    }

    @Published private(set) var isEnabled = false
    /// What the user asked for (⌃⌥Q / menu). The watchdog restarts the engine while this is true.
    @Published private(set) var wantsEnabled = true
    @Published private(set) var tiledCount = 0

    private let settingsStore: SettingsStore
    private var settings: Settings { settingsStore.settings }
    private var tracker: WindowTracker?
    private var displays: [Display] = []
    private var managed: [WindowID: Managed] = [:]
    /// The display commands act on: the one holding the focused window.
    private var activeDisplayID: CGDirectDisplayID?

    /// Last frame we set per window, so unchanged windows are not touched every animation frame.
    private var lastApplied: [WindowID: CGRect] = [:]
    private var lastSetTime: [WindowID: CFTimeInterval] = [:]
    /// Windows the user moved or resized; handled once the mouse button is released.
    private var pendingUserChanges: Set<WindowID> = []
    private var mouseWatcher: Timer?
    /// The tiled window being dragged with the mouse, and the miniature screens shown meanwhile.
    private var draggedID: WindowID?
    private var lastActivationByStrip: CFTimeInterval = 0
    private let dragOverview = DragOverview()
    private let tabBars = TabBars()
    private let focusBorder = FocusBorder()
    private let dimOverlay = DimOverlay()
    private let minimap = Minimap()
    private let stripEditor = StripEditor()
    private let swipe = TrackpadSwipe()
    private var swipeDisplay: Display?
    private var swipeStartOffset: CGFloat = 0
    /// Apps that snap windows back when given a negative x, and apps confirmed not to.
    private var leftClampingPIDs: Set<pid_t> = []
    private var leftOverflowOKPIDs: Set<pid_t> = []
    private var screenToken: NSObjectProtocol?

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
        tabBars.onSelect = { [weak self] id in self?.selectTab(id) }
        stripEditor.onAction = { [weak self] action in self?.editorAction(action) }
    }

    // MARK: - Lifecycle

    func start() {
        guard !isEnabled else { return }
        isEnabled = true
        wantsEnabled = true
        appliedDisabledDisplays = settings.disabledDisplays
        Log.info("Engine started")
        displays.removeAll()
        managed.removeAll()
        lastApplied.removeAll()
        refreshDisplays()
        let tracker = WindowTracker()
        tracker.delegate = self
        self.tracker = tracker
        screenToken = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshDisplays() }
        }
        tracker.start()
        restoreSession()
        configureSwipe()
        configureMouseTracking()
        if let front = NSWorkspace.shared.frontmostApplication {
            focusChanged(pid: front.processIdentifier)
        }
        relayoutAll(animated: false)
    }

    /// Stops managing windows and brings every parked window back onto the screen.
    func stop() {
        guard isEnabled else { return }
        displays.forEach { $0.animator.stop() }
        mouseWatcher?.invalidate()
        mouseWatcher = nil
        draggedID = nil
        dragOverview.hide()
        tracker?.stop()
        tracker = nil
        swipe.stop()
        if let screenToken { NotificationCenter.default.removeObserver(screenToken) }
        screenToken = nil
        sessionSaveWork?.cancel()
        saveSession()
        isEnabled = false
        stopMouseTracking()
        Log.info("Engine stopped")
        restoreWindowsOnScreen()
        tabBars.removeAll()
        focusBorder.show(around: nil)
        dimOverlay.hide()
        minimap.hideAll()
        stripEditor.hide()
        displays.removeAll()
        managed.removeAll()
        tiledCount = 0
    }

    /// System web sheets that ask for something before going on (Wi-Fi portal sign-in, SMS code…).
    private static let webSheetBundleIDs: Set<String> = ["com.apple.CaptiveNetworkAssistant", "com.apple.NetAuthAgent"]

    func settingsChanged() {
        guard isEnabled else { return }
        if settings.disabledDisplays != appliedDisabledDisplays {
            // Which displays are managed changed: rebuild everything from scratch.
            restart()
            return
        }
        for (id, m) in managed where !m.minimized && !m.fullscreen {
            if settings.shouldFloat(m.bundleID) && !m.floating { managed[id]?.floating = true }
        }
        syncStripMembership()
        lastApplied.removeAll()
        relayoutAll(animated: false)
        updateDecorations()
        configureSwipe()
        configureMouseTracking()
    }

    // MARK: - Trackpad

    private func configureSwipe() {
        let fingers = settings.trackpadFingers ?? TrackpadSwipe.defaultFingerCount()
        guard isEnabled, fingers > 0 else {
            swipe.stop()
            return
        }
        swipe.fingers = fingers
        swipe.onBegin = { [weak self] in self?.swipeBegan() }
        swipe.onChange = { [weak self] travel in self?.swipeChanged(travel) }
        swipe.onEnd = { [weak self] travel, velocity in self?.swipeEnded(velocity: velocity) }
        swipe.start()
    }

    /// The strip under the pointer follows the fingers…
    private func swipeBegan() {
        guard let d = mouseDisplay ?? activeDisplay else { return }
        swipeDisplay = d
        d.animator.stop()
        swipeStartOffset = d.animator.presented
    }

    private func swipeChanged(_ travel: CGFloat) {
        guard let d = swipeDisplay else { return }
        let engine = engine(d)
        let maxOffset = settings.layout == .strip
            ? max(0, engine.totalWidth(d.strip) - engine.area.width)
            : CGFloat(max(engine.pageCount(d.strip, preset: settings.layout) - 1, 0)) * engine.pageStride
        let slack = engine.area.width * 0.15
        // Content moves with the fingers (natural scrolling).
        let offset = min(max(swipeStartOffset - travel * engine.area.width * 1.5, -slack), maxOffset + slack)
        d.animator.jump(to: offset.rounded()) { [weak self, weak d] value in
            if let d { self?.apply(d, offset: value) }
        }
    }

    /// …then settles on the nearest column (or screen, with a grid preset).
    private func swipeEnded(velocity: CGFloat) {
        guard let d = swipeDisplay else { return }
        swipeDisplay = nil
        let engine = engine(d)
        let current = d.animator.presented
        // A quick flick moves at least one column / screen in its direction.
        let fling = velocity < -1.2 ? 1 : velocity > 1.2 ? -1 : 0
        let layout = settings.layout
        if layout == .strip {
            guard let settled = engine.settle(d.strip, offset: current, fling: fling) else { return }
            d.strip.viewportOffset = settled.offset
            // Keep focus if the focused column is still fully on screen; else focus where we landed.
            if let f = d.strip.focusedIndex {
                let x = engine.columnOrigins(d.strip)[f], w = engine.slotWidth(of: d.strip.columns[f])
                if x < settled.offset - 1 || x + w > settled.offset + engine.area.width + 1 {
                    d.strip.focus(index: settled.index)
                }
            }
        } else {
            let pages = engine.pageCount(d.strip, preset: layout)
            let page = min(max(Int((current / engine.pageStride).rounded()) + fling, 0), max(pages - 1, 0))
            if let f = d.strip.focusedIndex, engine.page(of: f, preset: layout) != page {
                d.strip.focus(index: page * layout.slots.count)
            }
            d.strip.viewportOffset = CGFloat(page) * engine.pageStride
        }
        if let id = d.strip.focusedWindowID { activate(managed[id]?.window) }
        // A swipe navigates like a shortcut does.
        showMinimap(d)
        render(d, animated: true)
    }

    // MARK: - Session

    private static let sessionKey = "session.v1"
    private var sessionSaveWork: DispatchWorkItem?

    private func scheduleSessionSave() {
        sessionSaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveSession() }
        sessionSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    private func saveSession() {
        guard isEnabled else { return }
        var snapshot: [String: [String: Strip]] = [:]
        for d in displays {
            snapshot[d.uuid] = Dictionary(uniqueKeysWithValues: d.strips.map { (String($0.key), $0.value) })
        }
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: Self.sessionKey)
        }
    }

    /// Puts columns back the way they were (order, widths, stacks, tabs) when Strip restarts while
    /// the apps keep running: window ids stay valid as long as the windows exist.
    private func restoreSession() {
        guard let data = UserDefaults.standard.data(forKey: Self.sessionKey),
              let snapshot = try? JSONDecoder().decode([String: [String: Strip]].self, from: data) else { return }
        for d in displays {
            guard let saved = snapshot[d.uuid] else { continue }
            for space in d.strips.keys {
                if let strip = saved[String(space)] { d.strips[space]?.restore(from: strip) }
            }
        }
    }

    // MARK: - Mouse

    private var mouseMonitor: Any?
    private var focusFollowsWork: DispatchWorkItem?
    /// Focus given by focus-follows-mouse: the strip must not scroll for it.
    private var mouseFocusedID: WindowID?

    private func configureMouseTracking() {
        stopMouseTracking()
        guard isEnabled, settings.focusFollowsMouse else { return }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseMoved() }
        }
    }

    private func stopMouseTracking() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        focusFollowsWork?.cancel()
    }

    private func mouseMoved() {
        // Wait for the pointer to rest a moment so sweeping across windows doesn't flicker focus.
        focusFollowsWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.focusWindowUnderMouse() }
        focusFollowsWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private var mouseLocationAX: CGPoint {
        let p = NSEvent.mouseLocation
        return CGPoint(x: p.x, y: (NSScreen.screens.first?.frame.height ?? 0) - p.y)
    }

    private func focusWindowUnderMouse() {
        guard isEnabled, settings.focusFollowsMouse, NSEvent.pressedMouseButtons == 0, draggedID == nil,
              !stripEditor.isVisible,
              swipeDisplay == nil, !displays.contains(where: { $0.animator.isAnimating }),
              let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return }
        let point = mouseLocationAX
        let ownPID = ProcessInfo.processInfo.processIdentifier
        // The list is front to back: the first normal window under the pointer is the one you see.
        for w in info {
            guard (w[kCGWindowLayer as String] as? Int) == 0, (w[kCGWindowOwnerPID as String] as? pid_t) != ownPID,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0).contains(point),
                  let id = w[kCGWindowNumber as String] as? WindowID else { continue }
            guard let d = display(of: id), id != focusedTiledWindow(),
                  let frame = lastApplied[id], !OffscreenPlacer.isParked(frame, display: d.frame) else { return }
            mouseFocusedID = id
            d.strip.focus(id)
            activeDisplayID = d.id
            activate(managed[id]?.window)
            updateDecorations()
            return
        }
    }

    /// Mouse follows focus: after a keyboard focus change, put the pointer in the focused window.
    private func warpMouseToFocus(_ d: Display) {
        guard settings.mouseFollowsFocus, let id = d.strip.focusedWindowID else { return }
        let engine = engine(d)
        let frames = settings.layout == .strip
            ? engine.frames(for: d.strip, offset: d.strip.viewportOffset)
            : engine.presetFrames(for: d.strip, preset: settings.layout, offset: d.strip.viewportOffset)
        guard let frame = frames[id], !frame.contains(mouseLocationAX) else { return }
        CGWarpMouseCursorPosition(CGPoint(x: frame.midX, y: frame.midY))
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    // MARK: - Health

    private var appliedDisabledDisplays: [String] = []

    /// Stops and starts the engine from scratch (also used by the watchdog).
    func restart() {
        Log.warning("Engine restarting")
        if isEnabled { stop() }
        start()
    }

    /// Whether the engine is in a usable state; the watchdog restarts it when this fails.
    func isHealthy() -> Bool {
        guard isEnabled else { return true }
        guard tracker != nil, !displays.isEmpty else { return false }
        // The Accessibility API must answer for the system-wide element.
        var app: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute as CFString, &app)
        return err != .apiDisabled && err != .notImplemented
    }

    // MARK: - Displays

    /// Rebuilds the display list (monitors plugged in / out, resolution or Dock changes).
    /// Windows of a removed display move to the main display.
    private func refreshDisplays() {
        var updated: [Display] = []
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let id = CGDirectDisplayID(number.uint32Value)
            if settings.disabledDisplays.contains(Spaces.displayUUID(id) ?? "") { continue }
            let display = displays.first { $0.id == id }
                ?? Display(id: id, frame: .zero, visibleFrame: .zero)
            display.frame = AX.axRect(fromAppKit: screen.frame)
            display.visibleFrame = AX.axRect(fromAppKit: screen.visibleFrame)
            display.spaceID = Spaces.current(onDisplay: id)
            updated.append(display)
        }
        guard let main = updated.first else { return }
        for gone in displays where !updated.contains(where: { $0 === gone }) {
            // macOS moves the Spaces of an unplugged display to the main one; so do we.
            gone.animator.stop()
            for (space, strip) in gone.strips {
                for column in strip.columns {
                    main.strips[space, default: Strip()].append(column)
                    column.windows.forEach { managed[$0]?.displayID = main.id }
                }
            }
        }
        for (id, m) in managed where !updated.contains(where: { $0.id == m.displayID }) {
            managed[id]?.displayID = main.id
        }
        displays = updated
        if let active = activeDisplayID, display(withID: active) == nil { activeDisplayID = main.id }
        lastApplied.removeAll()
        relayoutAll(animated: false)
    }

    private func display(withID id: CGDirectDisplayID) -> Display? {
        displays.first { $0.id == id }
    }

    /// Every other screen, managed or not: parked and sliding windows must never show up on them.
    private func otherScreenFrames(_ d: Display) -> [CGRect] {
        NSScreen.screens.map { AX.axRect(fromAppKit: $0.frame) }.filter { $0 != d.frame }
    }

    /// Whether a frame is mostly on a display Strip was told to leave alone.
    private func isOnDisabledDisplay(_ frame: CGRect) -> Bool {
        let screens = NSScreen.screens
        guard let best = DisplayAssignment.bestDisplay(for: frame, displays: screens.map { AX.axRect(fromAppKit: $0.frame) }),
              let number = screens[best].deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return false }
        return settings.disabledDisplays.contains(Spaces.displayUUID(CGDirectDisplayID(number.uint32Value)) ?? "")
    }

    /// The display showing `windowID` in the strip of its current Space.
    private func display(of windowID: WindowID) -> Display? {
        displays.first { $0.strip.contains(windowID) }
    }

    /// Where a window is tracked, on any Space.
    private func owner(of windowID: WindowID) -> (display: Display, space: SpaceID)? {
        for d in displays { if let space = d.space(of: windowID) { return (d, space) } }
        return nil
    }

    private func refreshCurrentSpaces() {
        for d in displays { d.spaceID = Spaces.current(onDisplay: d.id) }
    }

    /// Adds a window to the strip of the Space it is on.
    private func track(_ id: WindowID, on d: Display, focus: Bool, append: Bool = false) -> SpaceID {
        let space = Spaces.space(of: id) ?? d.spaceID
        if let place = minimizedPlaces.removeValue(forKey: id), !append {
            // Back from the Dock: where it was, as it was.
            d.strips[space, default: Strip()].restore(id, at: place, focus: focus)
            return space
        }
        let rule = settings.rule(for: managed[id]?.bundleID)
        let width = rule?.width ?? settings.defaultWidth
        switch (append, rule?.position ?? .nextToFocus) {
        case (true, _): d.strips[space, default: Strip()].append(id, width: width)
        case (false, .first): d.strips[space, default: Strip()].insert(id, width: width, at: 0, focus: focus)
        case (false, .last): d.strips[space, default: Strip()].insert(id, width: width, at: .max, focus: focus)
        case (false, .nextToFocus): d.strips[space, default: Strip()].insert(id, width: width, focus: focus)
        }
        return space
    }

    /// Where minimized windows sat in their strip, to put them back there when restored.
    private var minimizedPlaces: [WindowID: Strip.Place] = [:]

    private func untrack(_ id: WindowID) {
        guard let (d, space) = owner(of: id) else { return }
        d.strips[space]?.remove(id)
    }

    /// The display whose frame shows most of `frame`.
    private func bestDisplay(for frame: CGRect) -> Display? {
        DisplayAssignment.bestDisplay(for: frame, displays: displays.map(\.frame)).map { displays[$0] }
    }

    /// Display under the mouse pointer.
    private var mouseDisplay: Display? {
        let p = NSEvent.mouseLocation
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let ax = CGPoint(x: p.x, y: primaryHeight - p.y)
        return displays.first { $0.frame.contains(ax) }
    }

    private var activeDisplay: Display? {
        activeDisplayID.flatMap { display(withID: $0) } ?? mouseDisplay ?? displays.first
    }

    private func screen(for display: Display) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.id
        }
    }

    private func engine(_ display: Display) -> LayoutEngine {
        LayoutEngine(screen: display.visibleFrame, settings: settings)
    }

    // MARK: - Commands

    /// - Parameter binding: the shortcut that triggered it, shown above the minimap.
    func perform(_ command: Command, via binding: KeyBinding? = nil) {
        execute(command)
        // Tell what was just done, on the display it happened on.
        guard isEnabled, command != .toggleEnabled, command != .editStrip, settings.shortcutHUD || settings.minimap,
              let d = activeDisplay, let screen = screen(for: d) else { return }
        minimap.show(displayID: d.id, screen: screen, strip: d.strip, preset: settings.layout, engine: engine(d),
                     icons: appIcons(d), showMap: settings.minimap,
                     caption: settings.shortcutHUD ? MinimapCaption(keys: binding?.keyCaps ?? [], title: command.title) : nil)
    }

    private func execute(_ command: Command) {
        if case .toggleEnabled = command {
            if isEnabled {
                wantsEnabled = false
                stop()
            } else {
                start()
            }
            return
        }
        guard isEnabled, let d = activeDisplay else { return }
        switch command {
        case .focusLeft: focusStrip(d) { $0.moveFocus(by: -1) }
        case .focusRight: focusStrip(d) { $0.moveFocus(by: 1) }
        case .focusFirst: focusStrip(d) { $0.focus(index: 0) }
        case .focusLast: focusStrip(d) { $0.focus(index: $0.columns.count - 1) }
        case .focusIndex(let i):
            guard i < d.strip.columns.count else { return }
            focusStrip(d) { $0.focus(index: i) }
        case .screenLeft: switchScreen(d, direction: -1)
        case .screenRight: switchScreen(d, direction: 1)
        case .focusUp: focusStrip(d) { $0.moveFocusInColumn(by: -1) }
        case .focusDown: focusStrip(d) { $0.moveFocusInColumn(by: 1) }
        case .moveUp: d.strip.moveFocusedWindowInColumn(by: -1); relayout(d, animated: true)
        case .moveDown: d.strip.moveFocusedWindowInColumn(by: 1); relayout(d, animated: true)
        case .stackLeft: d.strip.stackFocused(direction: -1); relayout(d, animated: true)
        case .stackRight: d.strip.stackFocused(direction: 1); relayout(d, animated: true)
        case .popOutLeft: d.strip.popOutFocused(direction: -1); relayout(d, animated: true)
        case .popOutRight: d.strip.popOutFocused(direction: 1); relayout(d, animated: true)
        case .toggleTabbed:
            d.strip.toggleFocusedTabbed()
            if let id = d.strip.focusedWindowID { activate(managed[id]?.window) }
            relayout(d, animated: true)
        case .taller: d.strip.adjustFocusedHeight(by: settings.widthStep); relayout(d, animated: true)
        case .shorter: d.strip.adjustFocusedHeight(by: -settings.widthStep); relayout(d, animated: true)
        case .equalizeHeights: d.strip.equalizeFocusedHeights(); relayout(d, animated: true)
        case .moveLeft: d.strip.moveFocusedColumn(by: -1); relayout(d, animated: true)
        case .moveRight: d.strip.moveFocusedColumn(by: 1); relayout(d, animated: true)
        case .cycleWidth: d.strip.cycleFocusedWidth(presets: settings.presetWidths); relayout(d, animated: true)
        case .fullWidth:
            d.strip.toggleFocusedFullWidth()
            relayout(d, animated: true)
        case .wider: d.strip.adjustFocusedWidth(by: settings.widthStep); relayout(d, animated: true)
        case .narrower: d.strip.adjustFocusedWidth(by: -settings.widthStep); relayout(d, animated: true)
        case .center:
            d.strip.viewportOffset = engine(d).centeredOffset(for: d.strip)
            render(d, animated: true)
        case .toggleCentered: d.strip.toggleFocusedCentered(); relayout(d, animated: true)
        case .toggleFloat: toggleFloatOfFocusedWindow()
        case .sendToNextDisplay: sendFocusedWindowToNextDisplay(from: d)
        case .editStrip: toggleEditor(d)
        case .toggleEnabled: break
        }
    }

    /// Pages to the next / previous screen on this display: the next group of windows in a grid
    /// preset, or one screen width of columns in strip mode. Always slides.
    private func switchScreen(_ d: Display, direction: Int) {
        let engine = engine(d)
        let layout = settings.layout
        if layout == .strip {
            guard let step = engine.screenStep(d.strip, direction: direction) else { return }
            d.strip.focus(index: step.index)
            d.strip.viewportOffset = step.offset
        } else {
            guard let index = engine.presetScreenStep(d.strip, preset: layout, direction: direction) else { return }
            d.strip.focus(index: index)
            d.strip.viewportOffset = engine.presetOffset(for: d.strip, preset: layout)
        }
        if let id = d.strip.focusedWindowID { activate(managed[id]?.window) }
        render(d, animated: true)
        warpMouseToFocus(d)
    }

    private func focusStrip(_ d: Display, _ change: (inout Strip) -> Void) {
        change(&d.strip)
        if let id = d.strip.focusedWindowID { activate(managed[id]?.window) }
        relayout(d, animated: true)
        warpMouseToFocus(d)
    }

    private func toggleFloatOfFocusedWindow() {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let window = tracker?.focusedWindow(pid: pid),
              var m = managed[window.id] else { return }
        m.floating.toggle()
        managed[window.id] = m
        let d = display(of: window.id) ?? display(withID: m.displayID) ?? activeDisplay
        if m.floating {
            d?.strip.remove(window.id)
            lastApplied.removeValue(forKey: window.id)
            if let d {
                let area = engine(d).area
                let size = CGSize(width: area.width * 0.6, height: area.height * 0.7)
                window.setFrame(CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                                       width: size.width, height: size.height))
                markSet(window.id)
            }
            activate(window)
        } else {
            d?.strip.insert(window.id, width: settings.defaultWidth, focus: true)
        }
        if let d { relayout(d, animated: true) }
    }

    private func sendFocusedWindowToNextDisplay(from d: Display) {
        guard displays.count > 1, let id = d.strip.focusedWindowID,
              let i = displays.firstIndex(where: { $0 === d }) else { return }
        let target = displays[(i + 1) % displays.count]
        move(id, from: d, to: target, at: nil)
        activate(managed[id]?.window)
        warpMouseToFocus(target)
    }

    /// Moves a column to another display's strip, after its focused column or at `index`.
    private func move(_ id: WindowID, from source: Display, to target: Display, at index: Int?) {
        let width = source.strip.columns.first { $0.windowID == id }?.width ?? settings.defaultWidth
        source.strip.remove(id)
        target.strip.insert(id, width: width, focus: true)
        if let index { target.strip.move(id, to: index) }
        managed[id]?.displayID = target.id
        activeDisplayID = target.id
        lastApplied.removeValue(forKey: id)
        relayout(source, animated: true)
        relayout(target, animated: true)
    }

    // MARK: - Layout

    private func relayoutAll(animated: Bool) {
        displays.forEach { relayout($0, animated: animated) }
    }

    /// Recomputes a display's target viewport and renders towards it.
    private func relayout(_ d: Display, animated: Bool) {
        guard isEnabled else { return }
        tiledCount = displays.reduce(0) { $0 + $1.strip.allWindows.count }
        scheduleSessionSave()
        let engine = engine(d)
        d.strip.viewportOffset = settings.layout == .strip
            ? engine.targetOffset(for: d.strip)
            : engine.presetOffset(for: d.strip, preset: settings.layout)
        // The minimap appears for shortcuts (see perform) and when a window joins this strip.
        let windows = Set(d.strip.allWindows)
        let known = d.knownWindows[d.spaceID]
        d.knownWindows[d.spaceID] = windows
        if animated, let known, !windows.subtracting(known).isEmpty { showMinimap(d) }
        render(d, animated: animated)
        if stripEditor.isVisible, stripEditor.displayID == d.id {
            stripEditor.update(strip: d.strip, tiles: overviewTiles(d))
        }
    }

    // MARK: - Strip editor

    private func toggleEditor(_ d: Display) {
        if stripEditor.isVisible {
            stripEditor.hide()
            return
        }
        guard let screen = screen(for: d) else { return }
        let area = engine(d).area
        stripEditor.show(displayID: d.id, screen: screen, aspect: area.width / max(area.height, 1),
                         widths: settings.presetWidths)
        stripEditor.update(strip: d.strip, tiles: overviewTiles(d))
    }

    private func editorAction(_ action: StripEditAction) {
        guard let d = stripEditor.displayID.flatMap(display(withID:)) else {
            stripEditor.hide()
            return
        }
        switch action {
        case .drop(let id, let target): d.strip.drop(id, on: target, share: false)
        case .width(let id, let width): d.strip.setWidth(width, for: id)
        case .toggleTabs(let id): d.strip.toggleTabbed(containing: id)
        case .toggleCentered(let id): d.strip.toggleCentered(containing: id)
        case .focus(let id):
            stripEditor.hide()
            d.strip.focus(id)
            activeDisplayID = d.id
            activate(managed[id]?.window)
        case .close:
            stripEditor.hide()
            return
        }
        relayout(d, animated: true)
    }

    /// Icon and title of every window on `d`, for the miniature overviews.
    private func overviewTiles(_ d: Display) -> [WindowID: OverviewTile] {
        var tiles: [WindowID: OverviewTile] = [:]
        for id in d.strip.allWindows {
            guard let w = managed[id]?.window else { continue }
            let app = NSRunningApplication(processIdentifier: w.pid)
            let title = w.title.isEmpty ? (app?.localizedName ?? "") : w.title
            tiles[id] = OverviewTile(icon: app?.icon, title: title)
        }
        return tiles
    }

    private func showMinimap(_ d: Display) {
        guard settings.minimap, let screen = screen(for: d) else { return }
        minimap.show(displayID: d.id, screen: screen, strip: d.strip, preset: settings.layout, engine: engine(d),
                     icons: appIcons(d))
    }

    /// The app icon of every window on `d`, for the minimap tiles.
    private func appIcons(_ d: Display) -> [WindowID: NSImage] {
        var icons: [WindowID: NSImage] = [:]
        for id in d.strip.allWindows {
            if let pid = managed[id]?.window.pid, let icon = NSRunningApplication(processIdentifier: pid)?.icon {
                icons[id] = icon
            }
        }
        return icons
    }

    private func render(_ d: Display, animated: Bool) {
        let target = d.strip.viewportOffset
        if animated && settings.animate {
            d.animator.animate(to: target) { [weak self, weak d] offset in
                if let d { self?.apply(d, offset: offset) }
            }
        } else {
            d.animator.jump(to: target) { [weak self, weak d] offset in
                if let d { self?.apply(d, offset: offset) }
            }
        }
    }

    private func apply(_ d: Display, offset: CGFloat) {
        let layout = settings.layout
        let engine = engine(d)
        let frames = layout == .strip
            ? engine.frames(for: d.strip, offset: offset)
            : engine.presetFrames(for: d.strip, preset: layout, offset: offset)
        let screen = d.frame
        let others = otherScreenFrames(d)
        var changes: [(AXWindow, CGRect, sizeChanged: Bool)] = []
        for (id, frame) in frames {
            guard let window = managed[id]?.window else { continue }
            let placed = OffscreenPlacer.place(frame, display: screen, otherDisplays: others,
                                               allowLeftOverflow: !leftClampingPIDs.contains(window.pid))
            let last = lastApplied[id]
            guard last != placed else { continue }
            // Apps may adjust a parked window's size; set the full frame again when it comes into view.
            let enteringView = last.map { OffscreenPlacer.isParked($0, display: screen) } ?? true
                && !OffscreenPlacer.isParked(placed, display: screen)
            changes.append((window, placed, last?.size != placed.size || enteringView))
            lastApplied[id] = placed
        }
        // Inactive tabs and the rest of a maximized stack are parked, sized like the visible window
        // so switching is instant.
        for column in d.strip.columns where column.showsOnlyActive {
            guard let size = frames[column.windowID]?.size else { continue }
            for id in column.windows where id != column.windowID {
                guard let window = managed[id]?.window else { continue }
                let parked = OffscreenPlacer.park(size: size, display: screen, otherDisplays: others)
                guard lastApplied[id] != parked else { continue }
                changes.append((window, parked, lastApplied[id]?.size != size))
                lastApplied[id] = parked
            }
        }
        updateTabBars(d, offset: offset)
        if let focused = focusedTiledWindow(), d.strip.contains(focused) { updateDecorations() }
        guard !changes.isEmpty else { return }
        AXUIElement.withEnhancedUIDisabled(pids: Set(changes.map(\.0.pid))) {
            for (window, frame, sizeChanged) in changes {
                if sizeChanged {
                    window.setFrame(frame)
                    // macOS clamps a size that doesn't fit where the window is at that moment (e.g. the
                    // first frame of a slide). Remember what it really got so the next frame retries.
                    if let actual = window.frame?.size,
                       abs(actual.width - frame.width) > 0.5 || abs(actual.height - frame.height) > 0.5 {
                        lastApplied[window.id] = CGRect(origin: frame.origin, size: actual)
                    }
                } else {
                    window.setPosition(frame.origin)
                }
                markSet(window.id)
                if frame.minX < screen.minX && !OffscreenPlacer.isParked(frame, display: screen) {
                    verifyLeftOverflow(window, requested: frame, display: d)
                }
            }
        }
    }

    /// Positions the tab bars of a display's tabbed columns. Titles are only re-read once the
    /// animation settles, so sliding stays cheap.
    private func updateTabBars(_ d: Display, offset: CGFloat) {
        let layout = settings.layout
        let engine = engine(d)
        let rects = layout == .strip
            ? engine.columnRects(for: d.strip, offset: offset)
            : engine.presetColumnRects(for: d.strip, preset: layout, offset: offset)
        let others = otherScreenFrames(d)
        let readContent = !d.animator.isAnimating
        var bars: [TabBars.Bar] = []
        for (column, rect) in zip(d.strip.columns, rects) where column.tabbed && !column.maximized {
            let frame = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: LayoutEngine.tabBarHeight)
            let visible = OffscreenPlacer.place(rect, display: d.frame, otherDisplays: others) == rect
                && !(leftClampingPIDs.contains(managed[column.windowID]?.window.pid ?? 0) && rect.minX < d.frame.minX)
            let tabs: [TabBars.Tab]? = readContent ? column.windows.compactMap { id in
                guard let w = managed[id]?.window else { return nil }
                let app = NSRunningApplication(processIdentifier: w.pid)
                return TabBars.Tab(id: id, title: w.title.isEmpty ? (app?.localizedName ?? "") : w.title,
                                   icon: app?.icon, isActive: id == column.windowID)
            } : nil
            bars.append(TabBars.Bar(key: TabBars.key(for: column), frame: frame, isVisible: visible, tabs: tabs))
        }
        tabBars.update(displayID: d.id, bars: bars)
    }

    // MARK: - Focus decorations

    /// The tiled window that has keyboard focus: the focused column of the active display,
    /// as long as its app is frontmost.
    private func focusedTiledWindow() -> WindowID? {
        guard let d = activeDisplay, let id = d.strip.focusedWindowID,
              managed[id]?.window.pid == NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        return id
    }

    /// Focus border and dimming follow the focused window (also during animations).
    private func updateDecorations() {
        guard isEnabled else { return }
        let focused = focusedTiledWindow()
        let frame = focused.flatMap { id -> CGRect? in
            guard let f = lastApplied[id], let d = display(of: id),
                  !OffscreenPlacer.isParked(f, display: d.frame) else { return nil }
            return f
        }
        focusBorder.show(around: settings.focusBorder ? frame : nil)
        if settings.dimInactive {
            dimOverlay.show(below: frame == nil ? nil : focused,
                            displays: displays.map { ($0.id, $0.frame) }, amount: settings.dimAmount)
        } else {
            dimOverlay.hide()
        }
        // Sign-in sheets stay above the strip (and the dimming) whatever gets focus.
        for m in managed.values where m.keepOnTop && !m.minimized && !m.hidden { m.window.raise() }
    }

    /// A tab was clicked: show that window in its column and focus it.
    private func selectTab(_ id: WindowID) {
        guard let d = display(of: id) else { return }
        d.strip.focus(id)
        activate(managed[id]?.window)
        relayout(d, animated: true)
    }

    /// The first time an app's window is pushed past the left edge, read the frame back to see
    /// whether the app accepted it. If it snapped back, park such columns from now on.
    private func verifyLeftOverflow(_ window: AXWindow, requested: CGRect, display d: Display) {
        let pid = window.pid
        guard !leftOverflowOKPIDs.contains(pid), !leftClampingPIDs.contains(pid),
              let actual = window.frame else { return }
        guard actual.minX > requested.minX + 2 else {
            leftOverflowOKPIDs.insert(pid)
            return
        }
        leftClampingPIDs.insert(pid)
        let others = otherScreenFrames(d)
        let parked = OffscreenPlacer.place(requested, display: d.frame, otherDisplays: others,
                                           allowLeftOverflow: false)
        window.setPosition(parked.origin)
        lastApplied[window.id] = parked
    }

    private func activate(_ window: AXWindow?) {
        guard let window else { return }
        lastActivationByStrip = CACurrentMediaTime()
        if let d = display(of: window.id) { activeDisplayID = d.id }
        window.focus()
    }

    private func markSet(_ id: WindowID) { lastSetTime[id] = CACurrentMediaTime() }

    /// Whether a moved/resized notification is most likely the echo of our own change.
    private func isOwnChange(_ id: WindowID) -> Bool {
        if displays.contains(where: { $0.animator.isAnimating }) { return true }
        guard let t = lastSetTime[id] else { return false }
        return CACurrentMediaTime() - t < 0.35
    }

    private func syncStripMembership(focusNew: Bool = false) {
        for (id, m) in managed {
            let tracked = owner(of: id) != nil
            if m.isTileable && !tracked && fullscreenReturn[id] == nil,
               let d = display(withID: m.displayID) ?? displays.first {
                _ = track(id, on: d, focus: focusNew)
            } else if !m.isTileable && tracked {
                untrack(id)
                if m.floating { bringOnScreen(m.window) }
                lastApplied.removeValue(forKey: id)
            }
        }
    }

    /// Moves a window that is (mostly) off screen back into its display's visible area, keeping its size.
    private func bringOnScreen(_ window: AXWindow) {
        guard let frame = window.frame,
              let d = managed[window.id].flatMap({ display(withID: $0.displayID) }) ?? displays.first else { return }
        let area = engine(d).area
        let visible = frame.intersection(area)
        guard visible.isNull || visible.width < min(frame.width, area.width) * 0.5
                || visible.height < min(frame.height, area.height) * 0.5 else { return }
        let size = CGSize(width: min(frame.width, area.width), height: min(frame.height, area.height))
        window.setFrame(CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                               width: size.width, height: size.height))
        markSet(window.id)
    }

    private func restoreWindowsOnScreen() {
        for d in displays {
            let area = engine(d).area
            let tiled = d.strips.values.flatMap(\.allWindows).compactMap { managed[$0]?.window }
            for (i, window) in tiled.enumerated() {
                let step = CGFloat(i % 10) * 30
                let width = min(window.frame?.width ?? area.width / 2, area.width - step)
                window.setFrame(CGRect(x: area.minX + step, y: area.minY + step,
                                       width: width, height: area.height - step))
            }
        }
        // Windows that left the strips earlier (hidden apps, other Spaces) may still be parked.
        for (id, m) in managed where owner(of: id) == nil && !m.minimized && !m.fullscreen {
            bringOnScreen(m.window)
        }
    }

    // MARK: - WindowTrackerDelegate

    func windowAppeared(_ window: AXWindow, initial: Bool) {
        guard managed[window.id] == nil, let fallback = activeDisplay ?? displays.first else { return }
        let bundleID = NSRunningApplication(processIdentifier: window.pid)?.bundleIdentifier
        let webSheet = bundleID.map(Self.webSheetBundleIDs.contains) == true || window.isModal
        let floating = webSheet || !window.isStandardWindow || !window.isResizable || settings.shouldFloat(bundleID)
        // A window belongs to the display it opened on.
        let frame = window.frame
        let d = frame.flatMap(bestDisplay) ?? fallback
        var m = Managed(window: window, bundleID: bundleID, displayID: d.id, floating: floating)
        m.excluded = frame.map(isOnDisabledDisplay) ?? false
        m.minimized = window.isMinimized
        m.fullscreen = window.isFullscreen
        m.hidden = NSRunningApplication(processIdentifier: window.pid)?.isHidden ?? false
        m.keepOnTop = webSheet
        managed[window.id] = m
        if webSheet { window.raise() }
        guard m.isTileable else { return }

        if initial {
            _ = track(window.id, on: d, focus: false, append: true)
        } else {
            // Only windows of the frontmost app take focus; background apps never steal it.
            let isFront = NSWorkspace.shared.frontmostApplication?.processIdentifier == window.pid
            let space = track(window.id, on: d, focus: isFront)
            if isFront { activeDisplayID = d.id }
            if space == d.spaceID { relayout(d, animated: true) }
        }
    }

    func windowDestroyed(_ id: WindowID) {
        let d = display(of: id)
        fullscreenReturn.removeValue(forKey: id)
        minimizedPlaces.removeValue(forKey: id)
        managed.removeValue(forKey: id)
        lastApplied.removeValue(forKey: id)
        lastSetTime.removeValue(forKey: id)
        pendingUserChanges.remove(id)
        let wasOwned = owner(of: id) != nil
        untrack(id)
        guard wasOwned, let d else { return }
        if let focused = d.strip.focusedWindowID, d.id == activeDisplayID,
           NSWorkspace.shared.frontmostApplication?.processIdentifier == managed[focused]?.window.pid {
            activate(managed[focused]?.window)
        }
        relayout(d, animated: true)
    }

    func windowChanged(_ id: WindowID, notification: String) {
        guard var m = managed[id] else { return }
        switch notification {
        case kAXWindowMiniaturizedNotification:
            m.minimized = true
            if let (d, space) = owner(of: id), let place = d.strips[space]?.place(of: id) { minimizedPlaces[id] = place }
        case kAXWindowDeminiaturizedNotification:
            m.minimized = false
        default:
            if m.excluded {
                // Dragged from a display Strip leaves alone onto a managed one: start tiling it.
                guard NSEvent.pressedMouseButtons == 0, let frame = m.window.frame, !isOnDisabledDisplay(frame),
                      let d = bestDisplay(for: frame) else { return }
                m.excluded = false
                m.displayID = d.id
                managed[id] = m
                syncStripMembership(focusNew: true)
                relayout(d, animated: true)
                return
            }
            let fullscreen = m.window.isFullscreen
            if fullscreen != m.fullscreen {
                m.fullscreen = fullscreen
                managed[id] = m
                fullscreen ? enteredFullscreen(id) : leftFullscreen(id)
                return
            } else if m.isTileable && !isOwnChange(id) {
                if NSEvent.pressedMouseButtons == 0 {
                    appMovedWindowByItself(m.window)
                } else {
                    pendingUserChanges.insert(id)
                    if draggedID == nil { draggedID = id }
                    watchMouseRelease()
                }
                return
            } else {
                return
            }
        }
        managed[id] = m
        syncStripMembership(focusNew: !m.minimized && !m.fullscreen)
        if let d = display(withID: m.displayID) { relayout(d, animated: true) }
    }

    func focusChanged(pid: pid_t) {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let window = tracker?.focusedWindow(pid: pid),
              var m = managed[window.id] else {
            updateDecorations()
            return
        }
        refreshCurrentSpaces()
        if owner(of: window.id) == nil, fullscreenReturn[window.id] != nil, !window.isFullscreen {
            // Leaving full screen can report focus before the resize: take the same way back.
            managed[window.id]?.fullscreen = false
            leftFullscreen(window.id)
            return
        }
        if owner(of: window.id) == nil && !m.floating {
            // A focused window is by definition visible: refresh stale state so it rejoins a strip.
            m.hidden = false
            m.minimized = window.isMinimized
            m.fullscreen = window.isFullscreen
            if let frame = window.frame, !OffscreenPlacer.isParked(frame, display: display(withID: m.displayID)?.frame ?? .zero),
               let d = bestDisplay(for: frame) {
                m.displayID = d.id
            }
            managed[window.id] = m
            guard m.isTileable, let d = display(withID: m.displayID) ?? displays.first else { return }
            _ = track(window.id, on: d, focus: true)
        }
        // Not on a Space that is on screen yet (a Space switch is under way): the switch relayouts.
        guard let d = display(of: window.id) else { return }
        if d.strip.focusedWindowID != window.id {
            Log.info("Focus → \(window.id) (\(NSRunningApplication(processIdentifier: pid)?.localizedName ?? "?"))")
        }
        if mouseFocusedID == window.id {
            // Focus follows mouse: the window is already on screen; scrolling would move it away
            // from under the pointer.
            mouseFocusedID = nil
            d.strip.focus(window.id)
            activeDisplayID = d.id
            updateDecorations()
            return
        }
        d.strip.focus(window.id)
        activeDisplayID = d.id
        // Relayout even if it was already focused: its column may be scrolled out of view.
        relayout(d, animated: true)
        updateDecorations()
    }

    func appHiddenChanged(pid: pid_t, hidden: Bool) {
        // macOS hides the app you leave when Option is held during an app switch, and every
        // Strip shortcut uses Option. A hide right after Strip switched apps is that side effect.
        if hidden, CACurrentMediaTime() - lastActivationByStrip < 1.0,
           let app = NSRunningApplication(processIdentifier: pid) {
            app.unhide()
            return
        }
        for (id, m) in managed where m.window.pid == pid { managed[id]?.hidden = hidden }
        syncStripMembership()
        relayoutAll(animated: true)
    }

    func appTerminated(pid: pid_t) {
        leftClampingPIDs.remove(pid)
        leftOverflowOKPIDs.remove(pid)
        for (id, m) in managed where m.window.pid == pid { windowDestroyed(id) }
    }

    func activeSpaceChanged() {
        updateSpaceMembership()
        // The window list can still show the old Space during the switch animation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            self?.updateSpaceMembership()
        }
    }

    /// Each Space keeps its own strip. After a switch, lay out the Space now on screen, and move
    /// windows the user dragged to another Space (Mission Control) into that Space's strip.
    private func updateSpaceMembership() {
        guard isEnabled else { return }
        refreshCurrentSpaces()
        for d in displays {
            for (space, strip) in d.strips {
                for id in strip.allWindows {
                    guard let actual = Spaces.space(of: id), actual != space else { continue }
                    let width = strip.columns.first { $0.contains(id) }?.width ?? settings.defaultWidth
                    d.strips[space]?.remove(id)
                    d.strips[actual, default: Strip()].insert(id, width: width, focus: false)
                }
            }
            // Strips of Spaces that went away (full-screen Spaces) are dropped once empty.
            d.strips = d.strips.filter { !$0.value.columns.isEmpty || $0.key == d.spaceID }
        }
        lastApplied.removeAll()
        relayoutAll(animated: false)
    }

    // MARK: - Native full screen

    /// Where a window was in its strip before it went full screen (it gets its own Space meanwhile).
    private var fullscreenReturn: [WindowID: (displayID: CGDirectDisplayID, space: SpaceID, index: Int, width: CGFloat)] = [:]

    private func enteredFullscreen(_ id: WindowID) {
        guard let (d, space) = owner(of: id), let strip = d.strips[space], let index = strip.index(of: id) else { return }
        fullscreenReturn[id] = (d.id, space, index, strip.columns[index].width)
        Log.info("Window \(id) entered full screen")
        untrack(id)
        lastApplied.removeValue(forKey: id)
        if space == d.spaceID { relayout(d, animated: true) }
    }

    /// Back from full screen: the window returns to the column it left, focused, and the strip
    /// scrolls to it once macOS has finished its exit animation.
    private func leftFullscreen(_ id: WindowID) {
        guard let m = managed[id], m.isTileable, owner(of: id) == nil else { return }
        let saved = fullscreenReturn.removeValue(forKey: id)
        guard let d = saved.flatMap({ display(withID: $0.displayID) }) ?? display(withID: m.displayID) ?? displays.first
        else { return }
        let space = saved?.space ?? d.spaceID
        let width = saved?.width ?? settings.rule(for: m.bundleID)?.width ?? settings.defaultWidth
        if let index = saved?.index {
            d.strips[space, default: Strip()].insert(id, width: width, at: index, focus: true)
        } else {
            d.strips[space, default: Strip()].insert(id, width: width, focus: true)
        }
        managed[id]?.displayID = d.id
        activeDisplayID = d.id
        lastApplied.removeValue(forKey: id)
        Log.info("Window \(id) left full screen")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self, self.isEnabled else { return }
            self.refreshCurrentSpaces()
            self.lastApplied.removeValue(forKey: id)
            if let d = self.display(of: id) {
                d.strip.focus(id)
                self.relayout(d, animated: true)
                self.updateDecorations()
            }
        }
    }

    // MARK: - Manual move / resize

    /// Handles a window that moved without the mouse: an app pulling its window back to x = 0
    /// (Sublime Text, Sequel Ace…), or macOS moving it to another display (Window ▸ Move to…).
    private func appMovedWindowByItself(_ window: AXWindow) {
        guard let source = display(of: window.id) else { return }
        if let actual = window.frame {
            if let target = bestDisplay(for: actual), target !== source,
               !OffscreenPlacer.isParked(actual, display: target.frame) {
                move(window.id, from: source, to: target, at: nil)
                return
            }
            if let expected = lastApplied[window.id], expected.minX < source.frame.minX,
               actual.minX > expected.minX + 2 {
                leftClampingPIDs.insert(window.pid)
                leftOverflowOKPIDs.remove(window.pid)
            }
        }
        lastApplied.removeValue(forKey: window.id)
        relayout(source, animated: false)
    }

    /// Waits for the mouse button to be released, then turns the user's drag into a strip change.
    private func watchMouseRelease() {
        guard mouseWatcher == nil else { return }
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard NSEvent.pressedMouseButtons == 0 else {
                    self.updateDrag()
                    return
                }
                self.mouseWatcher?.invalidate()
                self.mouseWatcher = nil
                self.finishDrag()
                self.applyUserChanges()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        mouseWatcher = t
    }

    /// Shows the overview of the dragged window's display once it has really been dragged
    /// (not resized), then tracks the hover.
    private func updateDrag() {
        guard let id = draggedID else { return }
        if dragOverview.isVisible {
            dragOverview.updateHover(mouse: NSEvent.mouseLocation)
            return
        }
        guard let d = display(of: id), let window = managed[id]?.window, let frame = window.frame,
              let expected = lastApplied[id],
              abs(frame.width - expected.width) < 4, abs(frame.height - expected.height) < 4,
              hypot(frame.minX - expected.minX, frame.minY - expected.minY) > 30,
              let screen = screen(for: d) else { return }

        let maxSize = CGSize(width: screen.visibleFrame.width * 0.8, height: screen.visibleFrame.height * 0.8)
        let strip = d.strip, engine = engine(d)
        let overview = Overview.make(strip: strip, preset: settings.layout, engine: engine, maxSize: maxSize)
        // Strip mode previews the drop: the strip as it would be, windows moving aside live.
        let preview: ((StripDrop?) -> Overview)? = settings.layout != .strip ? nil : { drop in
            var s = strip
            if let drop { s.drop(id, on: drop, share: true) }
            return Overview.make(strip: s, preset: .strip, engine: engine, maxSize: maxSize)
        }
        dragOverview.show(overview: overview, tiles: overviewTiles(d), dragged: id, on: screen, preview: preview)
        dragOverview.updateHover(mouse: NSEvent.mouseLocation)
    }

    /// Mouse released: if it was over a miniature slot or column, move the window there.
    private func finishDrag() {
        defer { draggedID = nil }
        guard let id = draggedID, dragOverview.isVisible else { return }
        let target = dragOverview.hoveredTarget
        let drop = dragOverview.stripDrop
        guard let d = display(of: id), drop != nil || target != nil else {
            dragOverview.hide()
            return
        }
        // The overview already shows the result: leave it a moment while the windows get there.
        dragOverview.hide(after: 0.35)
        pendingUserChanges.remove(id)
        if settings.layout == .strip {
            if let drop { d.strip.drop(id, on: drop, share: true) }
        } else if let target {
            if target.windowID != nil {
                d.strip.swap(id, withIndex: target.index)
            } else {
                d.strip.move(id, to: d.strip.columns.count - 1)
            }
        }
        d.strip.focus(id)
        lastApplied.removeValue(forKey: id)
        activate(managed[id]?.window)
        relayout(d, animated: true)
    }

    private func applyUserChanges() {
        let layout = settings.layout
        var touched: [Display] = []
        for id in pendingUserChanges {
            guard let source = display(of: id), let window = managed[id]?.window,
                  let frame = window.frame, let expected = lastApplied[id] else { continue }
            lastApplied.removeValue(forKey: id)
            touched.append(source)
            let center = CGPoint(x: frame.midX, y: frame.midY)

            // Dropped on another monitor: the window joins that display's strip where it was dropped.
            if let target = bestDisplay(for: frame), target !== source,
               !OffscreenPlacer.isParked(frame, display: target.frame) {
                let e = engine(target)
                let index = layout == .strip
                    ? e.columnIndex(atScreenX: center.x, strip: target.strip, offset: target.strip.viewportOffset)
                    : e.presetIndex(at: center, strip: target.strip, preset: layout)
                move(id, from: source, to: target, at: index)
                activate(window)
                continue
            }

            let engine = engine(source)
            if layout != .strip {
                // Grid preset: dropping a window on another slot swaps the two.
                if let target = engine.presetIndex(at: center, strip: source.strip, preset: layout) {
                    source.strip.swap(id, withIndex: target)
                }
            } else if abs(frame.width - expected.width) > 4 || abs(frame.height - expected.height) > 4 {
                // Resized by hand: keep the new width, and the new height inside a stack.
                if abs(frame.width - expected.width) > 4 {
                    source.strip.setWidth((frame.width + engine.innerGap) / (engine.area.width + engine.innerGap), for: id)
                }
                if abs(frame.height - expected.height) > 4,
                   let column = source.strip.columns.first(where: { $0.contains(id) }), column.isStack, !column.tabbed {
                    let available = engine.area.height - engine.innerGap * CGFloat(column.windows.count - 1)
                    source.strip.setHeightFraction(frame.height / available, for: id)
                }
            } else if abs(frame.minX - expected.minX) > 4,
                      let target = engine.columnIndex(atScreenX: center.x, strip: source.strip,
                                                      offset: source.strip.viewportOffset) {
                // Dragged: drop it onto the column under its center.
                source.strip.move(id, to: target)
            }
        }
        pendingUserChanges.removeAll()
        for d in displays where touched.contains(where: { $0 === d }) { relayout(d, animated: true) }
    }
}
