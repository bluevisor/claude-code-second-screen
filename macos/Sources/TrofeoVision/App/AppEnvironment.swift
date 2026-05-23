// Shared state that the menu bar, preview window, and frame loop all
// reach into. Owned by `TrofeoVisionApp` and passed via @Environment.

import Combine
import Foundation
import SwiftUI

@MainActor
final class AppEnvironment: ObservableObject {
    enum SourceKind: String, CaseIterable, Identifiable {
        case claudeCode = "Claude Code"
        case demo = "Demo"
        var id: String { rawValue }
    }

    // Persisted user preferences (UserDefaults via @AppStorage-style wrappers).
    @Published var plan: String { didSet { Defaults.plan = plan; applyPlan() } }
    @Published var sourceKind: SourceKind { didSet { Defaults.source = sourceKind.rawValue } }
    @Published var pushToLCD: Bool { didSet { Defaults.pushToLCD = pushToLCD } }
    @Published var showRain: Bool { didSet { Defaults.showRain = showRain } }
    @Published var targetFPS: Int { didSet { Defaults.targetFPS = targetFPS } }

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
    private let claudeSource = ClaudeCodeSource()
    private let demoSource = DemoSource()
    let preview = InMemoryLCDOutput()
    let driver = TrofeoVisionDriver()
    var loop: FrameLoop?

    init() {
        let initialSource = SourceKind(rawValue: Defaults.source) ?? .claudeCode
        self.sourceKind = initialSource
        self.plan = Defaults.plan
        self.pushToLCD = Defaults.pushToLCD
        self.showRain = Defaults.showRain
        self.targetFPS = Defaults.targetFPS
        claudeSource.setPlan(Defaults.plan)
        self.source = initialSource == .demo ? demoSource : claudeSource
    }

    // MARK: - Lifecycle

    func start() {
        FontRegistration.registerOnce()
        let loop = FrameLoop(env: self)
        self.loop = loop
        loop.start()
    }

    // MARK: - Mutators

    func setSource(_ kind: SourceKind) {
        sourceKind = kind
        source = (kind == .demo) ? demoSource : claudeSource
    }

    func updateTelemetry(_ tel: Telemetry) {
        telemetry = tel
    }

    func updatePreview(image: CGImage) {
        lastFramePreview = image
    }

    func updateLCDStatus(_ s: LCDStatus) {
        lcdStatus = s
    }

    private func applyPlan() {
        claudeSource.setPlan(plan)
    }
}

// MARK: - UserDefaults bridge

private enum Defaults {
    // UserDefaults is documented thread-safe (atomic reads/writes per key).
    private nonisolated(unsafe) static let d = UserDefaults.standard

    static var plan: String {
        get { d.string(forKey: "plan") ?? "MAX 20×" }
        set { d.set(newValue, forKey: "plan") }
    }
    static var source: String {
        get { d.string(forKey: "source") ?? "Claude Code" }
        set { d.set(newValue, forKey: "source") }
    }
    static var pushToLCD: Bool {
        get { d.object(forKey: "pushToLCD") as? Bool ?? true }
        set { d.set(newValue, forKey: "pushToLCD") }
    }
    static var showRain: Bool {
        get { d.object(forKey: "showRain") as? Bool ?? true }
        set { d.set(newValue, forKey: "showRain") }
    }
    static var targetFPS: Int {
        get { (d.object(forKey: "targetFPS") as? Int) ?? 15 }
        set { d.set(newValue, forKey: "targetFPS") }
    }
}
