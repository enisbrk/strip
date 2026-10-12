import CoreGraphics

public enum CenterMode: String, Codable, CaseIterable, Sendable {
    /// Scroll only as far as needed to make the focused column fully visible.
    case never
    /// Center the focused column only when the strip is wider than the screen.
    case onOverflow
    /// Always center the focused column.
    case always
}

/// Where an app's new windows join the strip.
public enum AppPosition: String, Codable, CaseIterable, Sendable {
    /// Next to the focused column (the default for every app).
    case nextToFocus
    /// Always the first column.
    case first
    /// Always the last column.
    case last
}

/// Per-app behaviour.
public struct AppRule: Codable, Equatable, Identifiable, Sendable {
    public var bundleID: String
    public var appName: String
    /// Keep its windows out of the strip.
    public var float: Bool
    /// Width for its new windows (fraction of the screen); nil = the default width.
    public var width: CGFloat?
    public var position: AppPosition

    public var id: String { bundleID }

    public init(bundleID: String, appName: String, float: Bool = false, width: CGFloat? = nil,
                position: AppPosition = .nextToFocus) {
        self.bundleID = bundleID
        self.appName = appName
        self.float = float
        self.width = width
        self.position = position
    }
}

public struct Settings: Codable, Equatable, Sendable {
    public var outerGap: CGFloat = 8
    public var innerGap: CGFloat = 8
    public var presetWidths: [CGFloat] = [1.0 / 3.0, 0.5, 2.0 / 3.0, 1.0]
    public var defaultWidth: CGFloat = 0.5
    public var widthStep: CGFloat = 0.1
    public var centerMode: CenterMode = .never
    public var animate: Bool = true
    public var layout: LayoutPreset = .strip
    public var focusBorder: Bool = false
    public var dimInactive: Bool = false
    public var dimAmount: CGFloat = 0.25
    public var minimap: Bool = true
    /// Show the shortcut just pressed above the minimap.
    public var shortcutHUD: Bool = true
    /// Fingers for swiping the strip on the trackpad: nil = automatic, 0 = off, 3 or 4.
    public var trackpadFingers: Int?
    public var appRules: [AppRule] = [
        AppRule(bundleID: "com.apple.calculator", appName: "Calculator", float: true),
        AppRule(bundleID: "com.apple.systempreferences", appName: "System Settings", float: true),
        AppRule(bundleID: "com.apple.ActivityMonitor", appName: "Activity Monitor", float: true),
        AppRule(bundleID: "com.apple.archiveutility", appName: "Archive Utility", float: true),
        AppRule(bundleID: "com.apple.FaceTime", appName: "FaceTime", float: true),
    ]
    /// Displays (by UUID) Strip leaves alone.
    public var disabledDisplays: [String] = []
    public var focusFollowsMouse: Bool = false
    public var mouseFollowsFocus: Bool = false
    /// Interface language code (en, tr, es, fr, it); nil follows the system language.
    public var language: String?

    public func rule(for bundleID: String?) -> AppRule? {
        bundleID.flatMap { id in appRules.first { $0.bundleID == id } }
    }

    public func shouldFloat(_ bundleID: String?) -> Bool { rule(for: bundleID)?.float ?? false }

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case outerGap, innerGap, presetWidths, defaultWidth, widthStep, centerMode, animate, layout
        case focusBorder, dimInactive, dimAmount, minimap, shortcutHUD, trackpadFingers
        case appRules, disabledDisplays, focusFollowsMouse, mouseFollowsFocus, language
        /// Read only, to migrate settings saved before app rules.
        case floatingBundleIDs
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(outerGap, forKey: .outerGap)
        try c.encode(innerGap, forKey: .innerGap)
        try c.encode(presetWidths, forKey: .presetWidths)
        try c.encode(defaultWidth, forKey: .defaultWidth)
        try c.encode(widthStep, forKey: .widthStep)
        try c.encode(centerMode, forKey: .centerMode)
        try c.encode(animate, forKey: .animate)
        try c.encode(layout, forKey: .layout)
        try c.encode(focusBorder, forKey: .focusBorder)
        try c.encode(dimInactive, forKey: .dimInactive)
        try c.encode(dimAmount, forKey: .dimAmount)
        try c.encode(minimap, forKey: .minimap)
        try c.encode(shortcutHUD, forKey: .shortcutHUD)
        try c.encodeIfPresent(trackpadFingers, forKey: .trackpadFingers)
        try c.encode(appRules, forKey: .appRules)
        try c.encode(disabledDisplays, forKey: .disabledDisplays)
        try c.encode(focusFollowsMouse, forKey: .focusFollowsMouse)
        try c.encode(mouseFollowsFocus, forKey: .mouseFollowsFocus)
        try c.encodeIfPresent(language, forKey: .language)
    }

    public init(from decoder: Decoder) throws {
        // Decode leniently so adding new fields never wipes saved settings.
        let d = Settings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        outerGap = try c.decodeIfPresent(CGFloat.self, forKey: .outerGap) ?? d.outerGap
        innerGap = try c.decodeIfPresent(CGFloat.self, forKey: .innerGap) ?? d.innerGap
        presetWidths = try c.decodeIfPresent([CGFloat].self, forKey: .presetWidths) ?? d.presetWidths
        defaultWidth = try c.decodeIfPresent(CGFloat.self, forKey: .defaultWidth) ?? d.defaultWidth
        widthStep = try c.decodeIfPresent(CGFloat.self, forKey: .widthStep) ?? d.widthStep
        centerMode = try c.decodeIfPresent(CenterMode.self, forKey: .centerMode) ?? d.centerMode
        animate = try c.decodeIfPresent(Bool.self, forKey: .animate) ?? d.animate
        layout = (try? c.decodeIfPresent(LayoutPreset.self, forKey: .layout)) ?? d.layout
        focusBorder = try c.decodeIfPresent(Bool.self, forKey: .focusBorder) ?? d.focusBorder
        dimInactive = try c.decodeIfPresent(Bool.self, forKey: .dimInactive) ?? d.dimInactive
        dimAmount = try c.decodeIfPresent(CGFloat.self, forKey: .dimAmount) ?? d.dimAmount
        minimap = try c.decodeIfPresent(Bool.self, forKey: .minimap) ?? d.minimap
        shortcutHUD = try c.decodeIfPresent(Bool.self, forKey: .shortcutHUD) ?? d.shortcutHUD
        trackpadFingers = try c.decodeIfPresent(Int.self, forKey: .trackpadFingers)
        if let rules = try c.decodeIfPresent([AppRule].self, forKey: .appRules) {
            appRules = rules
        } else if let legacy = try c.decodeIfPresent([String].self, forKey: .floatingBundleIDs) {
            // Settings saved before app rules existed: a plain list of floating apps.
            appRules = legacy.map { AppRule(bundleID: $0, appName: $0, float: true) }
        }
        disabledDisplays = try c.decodeIfPresent([String].self, forKey: .disabledDisplays) ?? d.disabledDisplays
        focusFollowsMouse = try c.decodeIfPresent(Bool.self, forKey: .focusFollowsMouse) ?? d.focusFollowsMouse
        mouseFollowsFocus = try c.decodeIfPresent(Bool.self, forKey: .mouseFollowsFocus) ?? d.mouseFollowsFocus
        language = try c.decodeIfPresent(String.self, forKey: .language)
    }
}
