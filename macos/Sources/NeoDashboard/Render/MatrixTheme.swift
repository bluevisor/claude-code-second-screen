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
    /// Falls back to system mono when the bundled font isn't registered yet.
    ///
    /// Cached by `(size, weightRaw)` so the per-frame draw loop doesn't
    /// pay an `NSFont(name:size:)` round-trip on every text call — the
    /// matrix dashboard hits this ~30+ times per frame across ~12 unique
    /// font variants.
    static func font(_ pointSize: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let size = (pointSize * fontScale).rounded()
        // NSCache is documented thread-safe per the cocoa headers; safe
        // for the work-queue draw path. Key by "size,weightRaw" as
        // NSString since NSCache wants NSObject keys.
        let key = "\(size)|\(weight.rawValue)" as NSString
        if let cached = fontCache.object(forKey: key) { return cached }
        let font = NSFont(name: fontName(for: weight), size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        fontCache.setObject(font, forKey: key)
        return font
    }

    /// Returns cached typographic metrics for `font`. NSFont's own
    /// `ascender` / `capHeight` accessors bridge into Core Text on every
    /// call — caching saves dozens of round-trips per frame across the
    /// many `capTopOrigin` / baseline computations.
    static func metrics(of font: NSFont) -> FontMetrics {
        if let cached = metricsCache.object(forKey: font) { return cached }
        let m = FontMetrics(
            ascender: font.ascender,
            descender: font.descender,
            capHeight: font.capHeight > 0 ? font.capHeight : font.pointSize * 0.7,
            pointSize: font.pointSize
        )
        metricsCache.setObject(m, forKey: font)
        return m
    }

    /// Reference type so it can live in an NSCache.
    final class FontMetrics {
        let ascender: CGFloat
        let descender: CGFloat
        let capHeight: CGFloat
        let pointSize: CGFloat
        init(ascender: CGFloat, descender: CGFloat,
             capHeight: CGFloat, pointSize: CGFloat) {
            self.ascender = ascender
            self.descender = descender
            self.capHeight = capHeight
            self.pointSize = pointSize
        }
    }

    private nonisolated(unsafe) static let fontCache: NSCache<NSString, NSFont> = {
        let c = NSCache<NSString, NSFont>()
        c.countLimit = 64
        return c
    }()
    private nonisolated(unsafe) static let metricsCache: NSCache<NSFont, FontMetrics> = {
        let c = NSCache<NSFont, FontMetrics>()
        c.countLimit = 64
        return c
    }()

    /// Returns a cached attribute dictionary for `(font, color)`. The
    /// renderer hits this on every text draw — the previous code
    /// allocated a fresh `[NSAttributedString.Key: Any]` each call.
    /// Keys use the address of the font and the components of the
    /// color so identity comparisons stay cheap. The pool tops out at
    /// a small handful of distinct combinations across the dashboard.
    static func attributes(font: NSFont, color: NSColor) -> [NSAttributedString.Key: Any] {
        let key = "\(ObjectIdentifier(font).hashValue)|\(color.cgColor.numberOfComponents)|\(color.cgColor.components ?? [0])" as NSString
        if let cached = attrCache.object(forKey: key) {
            // NSDictionary holds Any values; cast to Swift dict.
            // The conversion is cheap because the underlying storage
            // is shared (CFDictionary).
            return cached as? [NSAttributedString.Key: Any]
                ?? [.font: font, .foregroundColor: color]
        }
        let dict: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
        ]
        attrCache.setObject(dict as NSDictionary, forKey: key)
        return dict
    }

    private nonisolated(unsafe) static let attrCache: NSCache<NSString, NSDictionary> = {
        let c = NSCache<NSString, NSDictionary>()
        c.countLimit = 64
        return c
    }()

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

    // MARK: - Date helpers

    /// Weekday strings cached per (format, day-of-year) so we don't pay
    /// `DateFormatter` allocation + parse on every draw. The matrix
    /// dashboard's rail + footer + clock fallback each pull "EEEE" or
    /// "EEE" once per frame; without the cache that's 3-4 fresh
    /// DateFormatters per frame.
    static func weekday(_ date: Date, short: Bool = false) -> String {
        // Key by (year, day, format) — `.day` of `.year` is the natural
        // "this calendar day" identifier on macOS 14, where `.dayOfYear`
        // isn't available yet.
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month, .day], from: date)
        let key = "\(comps.year ?? 0)|\(comps.month ?? 0)|\(comps.day ?? 0)|\(short ? "EEE" : "EEEE")" as NSString
        if let cached = weekdayCache.object(forKey: key) as String? { return cached }
        let formatter = short ? shortWeekdayFormatter : longWeekdayFormatter
        let str = formatter.string(from: date).uppercased()
        weekdayCache.setObject(str as NSString, forKey: key)
        return str
    }

    private static let longWeekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE"
        return f
    }()
    private static let shortWeekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE"
        return f
    }()
    private nonisolated(unsafe) static let weekdayCache: NSCache<NSString, NSString> = {
        let c = NSCache<NSString, NSString>()
        c.countLimit = 16
        return c
    }()

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
