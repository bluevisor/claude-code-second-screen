// Matrix theme palette + font helpers.
//
// Mirrors the constants near the top of `themes/matrix.py`.

import AppKit
import CoreGraphics
import CoreText

enum MatrixTheme {
    // MARK: - Palette
    static let ink         = NSColor(srgbRed: 201/255.0, green: 255/255.0, blue: 226/255.0, alpha: 1.0)
    static let inkDim      = ink.withAlphaComponent(0.55)
    static let inkFaint    = ink.withAlphaComponent(0.30)
    static let phosphor    = NSColor(srgbRed:  41/255.0, green: 255/255.0, blue: 140/255.0, alpha: 1.0)
    static let phosphorSoft = phosphor.withAlphaComponent(0.22)
    static let magenta     = NSColor(srgbRed: 255/255.0, green:  42/255.0, blue: 109/255.0, alpha: 1.0)
    static let amber       = NSColor(srgbRed: 255/255.0, green: 182/255.0, blue:  39/255.0, alpha: 1.0)
    static let cyan        = NSColor(srgbRed:  42/255.0, green: 240/255.0, blue: 255/255.0, alpha: 1.0)
    static let panelBorder = phosphor.withAlphaComponent(0.22)
    static let bgTop       = NSColor(srgbRed:   2/255.0, green:  16/255.0, blue:  12/255.0, alpha: 1.0)
    static let bgBot       = NSColor(srgbRed:   1/255.0, green:   9/255.0, blue:  10/255.0, alpha: 1.0)

    static let canvasSize = CGSize(width: 1280, height: 480)
    /// Portrait canvas used when the LCD is rotated 90°/270°. Same pixel
    /// budget as `canvasSize`, just transposed — panels are stacked
    /// vertically rather than side-by-side.
    static let canvasSizePortrait = CGSize(width: 480, height: 1280)

    // MARK: - Fonts

    /// Multiplier applied to every `font(…)` call so the dashboard can be
    /// retuned in one place. Bumped progressively after hardware tests —
    /// 1.12 → 1.25 made the rail/panel copy comfortably readable from a
    /// normal desk distance.
    static let fontScale: CGFloat = 1.25

    /// JetBrains Mono in the requested point size and weight.
    /// Falls back to `Menlo` when the bundled font isn't registered yet.
    static func font(_ pointSize: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let size = (pointSize * fontScale).rounded()
        if let f = NSFont(name: fontName(for: weight), size: size) {
            return f
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    /// Map PySide6 weight → JetBrains Mono variant. We register all variants
    /// from the bundled .ttf files at app startup; see `FontRegistration`.
    private static func fontName(for weight: NSFont.Weight) -> String {
        switch weight {
        case .light, .ultraLight, .thin: return "JetBrainsMono-Light"
        case .regular: return "JetBrainsMono-Regular"
        case .medium: return "JetBrainsMono-Medium"
        case .semibold: return "JetBrainsMono-SemiBold"
        case .bold: return "JetBrainsMono-Bold"
        case .heavy, .black: return "JetBrainsMono-ExtraBold"
        default: return "JetBrainsMono-Regular"
        }
    }

    // MARK: - Verb maps

    static let statusVerbs: [AgentStatus: String] = [
        .idle: "Standby…",
        .waiting: "Waiting…",
        .processing: "Vibing…",
        .thinking: "Thinking…",
        .tool: "Working…",
        .writing: "Writing…",
        .error: "Error",
    ]

    static let toolVerbs: [String: String] = [
        "Read": "Reading…",
        "Bash": "Running…",
        "Edit": "Editing…",
        "Write": "Writing…",
        "Grep": "Searching…",
        "Glob": "Searching…",
        "WebFetch": "Fetching…",
        "WebSearch": "Searching…",
        "Agent": "Delegating…",
        "Task": "Delegating…",
        "TodoWrite": "Planning…",
        "NotebookEdit": "Editing…",
        "Skill": "Loading…",
        "ToolSearch": "Searching…",
    ]

    /// Subscription plans charge a flat fee, so per-window dollar tallies are noise.
    static func isSubscriptionPlan(_ plan: String) -> Bool {
        let p = plan.uppercased()
        return p.hasPrefix("MAX") || p.hasPrefix("PRO") || p.hasPrefix("FREE") || p.hasPrefix("TEAM")
    }
}

/// One-shot registration of the bundled JetBrains Mono .ttf files with the
/// process's font manager. Safe to call repeatedly. Main-actor confined —
/// the SwiftUI app only calls it from `.onAppear`.
@MainActor
enum FontRegistration {
    private static var registered = false

    static func registerOnce() {
        if registered { return }
        registered = true
        // Register every JetBrains Mono variant present in the bundle. The
        // Xcodegen build phase flattens the fonts into Contents/Resources/,
        // so the resourceURL itself is the right directory.
        let bundle = Bundle.main
        let candidates: [URL] = [
            bundle.resourceURL,
            bundle.resourceURL?.appendingPathComponent("fonts"),
        ].compactMap { $0 }

        for dir in candidates {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil) else { continue }
            for f in files where f.pathExtension.lowercased() == "ttf" {
                _ = CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil)
            }
        }
    }
}
