// Shared state that the menu bar, preview window, and frame loop all
// reach into. Owned by `NeoDashboardApp` and passed via @Environment.

import Combine
import Foundation
import SwiftUI
import UserNotifications

@MainActor
final class AppEnvironment: ObservableObject {
    /// SwiftUI's `@StateObject` builds the singleton; AppDelegate reaches it
    /// through this back-reference to wire startup into AppKit's lifecycle.
    private(set) static var shared: AppEnvironment?

    /// Called from `NeoDashboardApp.init()` before SwiftUI has constructed
    /// the StateObject. We just register a one-shot resolver that the first
    /// `init()` writes to `shared`.
    static func installSharedInstance() {
        // No-op marker so the App can be sure the symbol is referenced;
        // actual wiring happens in `init()`.
    }

    /// User's source choice. `.auto` follows the newest active Claude/Codex/AGY
    /// session; `.session` pins it to a specific jsonl; `.demo` swaps in the
    /// scripted demo source. Pinned sessions are ephemeral because they may
    /// have ended by the next app launch.
    enum SourceSelection: Hashable {
        case auto
        case claudeCode
        case codex
        case agy
        case demo
        case session(ActiveSession)

        var label: String {
            switch self {
            case .auto: return "Auto"
            case .claudeCode: return "Claude Code"
            case .codex: return "Codex"
            case .agy: return "AGY"
            case .demo: return "Demo"
            case .session(let s): return "\(s.kind.label) · \(s.displayName)"
            }
        }

        var symbol: String {
            switch self {
            case .auto: return "wand.and.stars"
            case .claudeCode: return "terminal"
            case .codex: return "command"
            case .agy: return "network"
            case .demo: return "theatermasks"
            case .session(let s): return s.kind.symbol
            }
        }
    }

    /// Output rotation in clockwise degrees applied to the rendered frame
    /// before it ships to the LCD. Stored as the degree value so the raw
    /// `UserDefaults` int is human-readable.
    enum DisplayRotation: Int, CaseIterable, Identifiable {
        case deg0 = 0, deg90 = 90, deg180 = 180, deg270 = 270
        var id: Int { rawValue }
        var label: String { "\(rawValue)°" }
        /// 90°/270° swap width/height — renderers should lay out for a
        /// portrait canvas so panels stack vertically instead of being
        /// drawn landscape and then visually tipped on their side.
        var isPortrait: Bool { self == .deg90 || self == .deg270 }
    }

    /// Which on-screen layout the LCD is showing. Matrix + Cozy are full
    /// render pipelines; `wow` and `animalCrossing` are static-image
    /// placeholders until those layouts get implemented.
    enum RenderMode: String, CaseIterable, Identifiable {
        case matrixDashboard = "Matrix"
        case cozy = "Cozy"
        case wowAlliance = "WoW Alliance"
        case wowHorde = "WoW Horde"
        case animalCrossing = "Animal Crossing"
        case dragonball = "Dragon Ball"
        var id: String { rawValue }
    }

    enum TimeFormat: String, CaseIterable, Identifiable {
        case h12 = "12-hour"
        case h24 = "24-hour"
        var id: String { rawValue }
    }

    enum TemperatureUnit: String, CaseIterable, Identifiable {
        case fahrenheit = "°F"
        case celsius = "°C"
        var id: String { rawValue }
        var openMeteoParam: String {
            self == .celsius ? "celsius" : "fahrenheit"
        }
    }

    /// Numeric date layout. The weekday prefix used by the top strip is
    /// rendered separately; this controls the digits + separator only.
    enum DateFormat: String, CaseIterable, Identifiable {
        case usDot = "MM.DD.YYYY"
        case iso = "YYYY-MM-DD"
        case eu = "DD.MM.YYYY"
        case longHuman = "MMM D, YYYY"
        var id: String { rawValue }
    }

    // Persisted user preferences (UserDefaults via @AppStorage-style wrappers).
    @Published var sourceSelection: SourceSelection = .auto {
        didSet { applySourceSelection() }
    }
    /// Discovered live every telemetry tick — bound to the menubar picker.
    @Published private(set) var activeSessions: [ActiveSession] = []
    @Published var showRain: Bool { didSet { Defaults.showRain = showRain } }
    @Published var rotation: DisplayRotation {
        didSet {
            // didSet still fires when SwiftUI hands us the same value
            // back; gate everything on a real change so we never
            // re-enter reconfigure as a side effect of an unrelated UI
            // refresh (e.g. the clock toggle re-rendering the toolbar).
            guard oldValue != rotation else { return }
            Defaults.rotation = rotation.rawValue
            // Only rebuild when the canvas aspect ratio actually flips
            // (0↔180 or 90↔270 stays on the same canvas).
            if oldValue.isPortrait != rotation.isPortrait {
                loop?.reconfigure()
            }
        }
    }
    @Published var flipHorizontal: Bool { didSet { Defaults.flipHorizontal = flipHorizontal } }
    @Published var flipVertical: Bool { didSet { Defaults.flipVertical = flipVertical } }
    @Published var mode: RenderMode { didSet { Defaults.mode = mode.rawValue } }
    @Published var timeFormat: TimeFormat {
        didSet {
            Defaults.timeFormat = timeFormat.rawValue
            UserPrefs.update(timeFormat: timeFormat)
        }
    }
    @Published var temperatureUnit: TemperatureUnit {
        didSet {
            Defaults.temperatureUnit = temperatureUnit.rawValue
            UserPrefs.update(temperatureUnit: temperatureUnit)
            WeatherService.shared.refreshNow()
        }
    }
    @Published var dateFormat: DateFormat {
        didSet {
            Defaults.dateFormat = dateFormat.rawValue
            UserPrefs.update(dateFormat: dateFormat)
        }
    }
    /// When on, WeatherService asks CoreLocation for a precise fix
    /// (and falls back to IP only on denial / timeout). When off, it
    /// skips CoreLocation entirely and uses IP geolocation. Default on
    /// — most users want neighborhood accuracy once they've granted
    /// the permission.
    @Published var usePreciseLocation: Bool {
        didSet {
            guard oldValue != usePreciseLocation else { return }
            Defaults.usePreciseLocation = usePreciseLocation
            WeatherService.shared.setUsePreciseLocation(usePreciseLocation)
        }
    }
    /// Clock-mode override. `.auto` falls back to the legacy behavior —
    /// show the clock when telemetry has no content, otherwise the
    /// dashboard. `.on` / `.off` pin the LCD to one mode regardless of
    /// telemetry. The preview toolbar's clock button drives this so its
    /// visual state and the actual displayed mode stay in sync.
    enum ClockMode: String, CaseIterable, Hashable {
        case auto, on, off
    }
    @Published var clockMode: ClockMode {
        didSet { Defaults.clockMode = clockMode.rawValue }
    }

    /// Effective clock-mode for the current telemetry — what the LCD is
    /// actually showing. Resolves `.auto` against the latest telemetry,
    /// so reads stay correct as content comes and goes.
    var wantsClock: Bool {
        resolveWantsClock(for: telemetry)
    }

    /// Same resolution but against a specific telemetry snapshot — used by
    /// FrameLoop to avoid re-reading `telemetry` mid-tick.
    func resolveWantsClock(for tel: Telemetry) -> Bool {
        switch clockMode {
        case .on: return true
        case .off: return false
        case .auto: return !tel.hasContent
        }
    }
    /// PreviewWindow flips this on appear / off on disappear. FrameLoop
    /// reads it to skip the main-actor `updatePreview(image:)` hop when
    /// nothing on screen would render the new image — recovers a few
    /// fps when the preview window is closed (the LCD is the only sink).
    @Published var previewWindowVisible: Bool = false

    /// LCD push is always on while the app runs — the device is the whole
    /// point of the program. Exposed as a constant so call sites that used
    /// to read the toggle don't have to branch.
    let pushToLCD = true

    /// At 15fps the frame interval is ~66ms, which leaves enough slack
    /// for steady-state render + JPEG + HID while the coalescer drops
    /// occasional slow HID spikes instead of building a stale backlog.
    let targetFPS = 15

    // Live state surfaced to the UI.
    @Published private(set) var telemetry: Telemetry = .empty()
    @Published private(set) var lcdStatus: LCDStatus = .disconnected
    @Published private(set) var lastFramePreview: CGImage?

    enum LCDStatus: Equatable {
        case disconnected
        case connecting
        case ready(width: Int, height: Int)
        case error(String)
    }

    // Workers.
    private(set) var source: TelemetrySource
    private let claudeSource: ClaudeCodeSource
    private let codexSource: CodexSource
    private let agySource: CodexSource
    private let autoSource: AutoTelemetrySource
    private let demoSource: DemoSource
    let preview = InMemoryLCDOutput()
    let driver = TrofeoVisionDriver()
    var loop: FrameLoop?

    init() {
        let claude = ClaudeCodeSource()
        let codex = CodexSource(kind: .codex)
        let agy = CodexSource(kind: .agy)
        let auto = AutoTelemetrySource(claudeSource: claude,
                                       codexSource: codex,
                                       agySource: agy)
        let demo = DemoSource()
        self.claudeSource = claude
        self.codexSource = codex
        self.agySource = agy
        self.autoSource = auto
        self.demoSource = demo
        self.source = auto
        self.showRain = Defaults.showRain
        self.rotation = DisplayRotation(rawValue: Defaults.rotation) ?? .deg0
        self.flipHorizontal = Defaults.flipHorizontal
        self.flipVertical = Defaults.flipVertical
        self.mode = RenderMode(rawValue: Defaults.mode) ?? .matrixDashboard
        self.timeFormat = TimeFormat(rawValue: Defaults.timeFormat) ?? .h12
        self.temperatureUnit = TemperatureUnit(rawValue: Defaults.temperatureUnit) ?? .fahrenheit
        self.dateFormat = DateFormat(rawValue: Defaults.dateFormat) ?? .usDot
        self.usePreciseLocation = Defaults.usePreciseLocation
        let resolvedClockMode = ClockMode(rawValue: Defaults.clockMode) ?? .auto
        self.clockMode = resolvedClockMode
        // didSet doesn't fire on the in-init assignment, so write the
        // migrated value back explicitly. This lets users (and `defaults
        // read`) observe the new key without first toggling the button.
        Defaults.clockMode = resolvedClockMode.rawValue
        UserPrefs.update(timeFormat: self.timeFormat)
        UserPrefs.update(temperatureUnit: self.temperatureUnit)
        UserPrefs.update(dateFormat: self.dateFormat)
        AppEnvironment.shared = self
    }

    // MARK: - Lifecycle

    func start() {
        FontRegistration.registerOnce()
        // Apply persisted location preference before the first refresh,
        // so a user who turned precise location off won't see the
        // CoreLocation prompt re-surface on launch.
        WeatherService.shared.setUsePreciseLocation(usePreciseLocation)
        WeatherService.shared.start()
        let loop = FrameLoop(env: self)
        self.loop = loop
        loop.start()
    }

    // MARK: - Mutators

    func updateTelemetry(_ tel: Telemetry) {
        telemetry = tel
        // Refresh the discovery list once per telemetry tick (1 Hz). The
        // menubar picker re-reads this. If the pinned session disappears,
        // fall back to auto so we don't render a stale label forever.
        let live = SessionDiscovery.active()
        if live != activeSessions { activeSessions = live }
        if case .session(let pinned) = sourceSelection,
           !live.contains(where: { $0.id == pinned.id }) {
            sourceSelection = .auto
        }
    }

    func updatePreview(image: CGImage) {
        lastFramePreview = image
    }

    func updateLCDStatus(_ s: LCDStatus) {
        let prev = lcdStatus
        lcdStatus = s
        if case .ready = prev, case .disconnected = s {
            postLCDNotification(title: "LCD Disconnected",
                                body: "The display was unplugged.")
        } else if case .ready(let w, let h) = s, !(prev == s) {
            postLCDNotification(title: "LCD Connected",
                                body: "\(w)×\(h) display ready.")
        }
    }

    private func postLCDNotification(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { _, _ in }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let req = UNNotificationRequest(identifier: "lcd-status",
                                         content: content, trigger: nil)
        center.add(req)
    }

    private func applySourceSelection() {
        switch sourceSelection {
        case .auto:
            source = autoSource
        case .claudeCode:
            claudeSource.setPinned(nil)
            source = claudeSource
        case .codex:
            codexSource.setPinned(nil)
            source = codexSource
        case .agy:
            agySource.setPinned(nil)
            source = agySource
        case .demo:
            source = demoSource
        case .session(let s):
            switch s.kind {
            case .claude:
                claudeSource.setPinned(s.jsonl)
                source = claudeSource
            case .codex:
                codexSource.setPinned(s.jsonl)
                source = codexSource
            case .agy:
                agySource.setPinned(s.jsonl)
                source = agySource
            }
        }
    }
}

// MARK: - UserDefaults bridge

private enum Defaults {
    // UserDefaults is documented thread-safe (atomic reads/writes per key).
    private nonisolated(unsafe) static let d = UserDefaults.standard

    static var showRain: Bool {
        get { d.object(forKey: "showRain") as? Bool ?? true }
        set { d.set(newValue, forKey: "showRain") }
    }
    static var rotation: Int {
        get { (d.object(forKey: "rotation") as? Int) ?? 0 }
        set { d.set(newValue, forKey: "rotation") }
    }
    static var flipHorizontal: Bool {
        get { d.object(forKey: "flipHorizontal") as? Bool ?? false }
        set { d.set(newValue, forKey: "flipHorizontal") }
    }
    static var clockMode: String {
        // Migrate the old boolean `forceClock` key on first read so users
        // who pinned the clock on under the old model don't lose that
        // state when the app upgrades.
        get {
            if let raw = d.string(forKey: "clockMode") { return raw }
            if let legacy = d.object(forKey: "forceClock") as? Bool {
                return legacy ? AppEnvironment.ClockMode.on.rawValue
                              : AppEnvironment.ClockMode.auto.rawValue
            }
            return AppEnvironment.ClockMode.auto.rawValue
        }
        set { d.set(newValue, forKey: "clockMode") }
    }
    static var flipVertical: Bool {
        get { d.object(forKey: "flipVertical") as? Bool ?? false }
        set { d.set(newValue, forKey: "flipVertical") }
    }
    static var mode: String {
        get { d.string(forKey: "mode") ?? "Matrix Dashboard" }
        set { d.set(newValue, forKey: "mode") }
    }
    static var timeFormat: String {
        get { d.string(forKey: "timeFormat") ?? "12-hour" }
        set { d.set(newValue, forKey: "timeFormat") }
    }
    static var temperatureUnit: String {
        get { d.string(forKey: "temperatureUnit") ?? "°F" }
        set { d.set(newValue, forKey: "temperatureUnit") }
    }
    static var dateFormat: String {
        get { d.string(forKey: "dateFormat") ?? "MM.DD.YYYY" }
        set { d.set(newValue, forKey: "dateFormat") }
    }
    static var usePreciseLocation: Bool {
        get { d.object(forKey: "usePreciseLocation") as? Bool ?? true }
        set { d.set(newValue, forKey: "usePreciseLocation") }
    }
}
