// Shared state that the menu bar, preview window, and frame loop all
// reach into. Owned by `NeoDashboardApp` and passed via @Environment.

import Combine
import Foundation
import SwiftUI

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
    @Published var rotation: DisplayRotation { didSet { Defaults.rotation = rotation.rawValue } }
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
    /// Manual override — when true the LCD shows the clock regardless of
    /// whether the active source has telemetry. The clock fallback still
    /// auto-engages when telemetry is absent, this just lets the user pin
    /// it on (e.g. for an ambient desk look while keeping a busy session).
    @Published var forceClock: Bool { didSet { Defaults.forceClock = forceClock } }
    /// PreviewWindow flips this on appear / off on disappear. FrameLoop
    /// reads it to skip the main-actor `updatePreview(image:)` hop when
    /// nothing on screen would render the new image — recovers a few
    /// fps when the preview window is closed (the LCD is the only sink).
    @Published var previewWindowVisible: Bool = false

    /// LCD push is always on while the app runs — the device is the whole
    /// point of the program. Exposed as a constant so call sites that used
    /// to read the toggle don't have to branch.
    let pushToLCD = true

    /// Hard target — sustained ≈25 fps over USB-HID is the practical ceiling
    /// per measurements; we set 30 and let the frame coalescer cap.
    let targetFPS = 30

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
        self.forceClock = Defaults.forceClock
        UserPrefs.update(timeFormat: self.timeFormat)
        UserPrefs.update(temperatureUnit: self.temperatureUnit)
        UserPrefs.update(dateFormat: self.dateFormat)
        AppEnvironment.shared = self
    }

    // MARK: - Lifecycle

    func start() {
        FontRegistration.registerOnce()
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
        lcdStatus = s
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
    static var forceClock: Bool {
        get { d.object(forKey: "forceClock") as? Bool ?? false }
        set { d.set(newValue, forKey: "forceClock") }
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
}
