// Pluggable render surface. The frame loop picks a `FrameRenderer` based on
// `AppEnvironment.mode` so future layouts (clock face, system stats, photo
// slideshow, …) can swap in without touching the loop or HID driver.

import CoreGraphics
import Foundation

/// `Sendable` so FrameLoop can capture concrete renderers into its
/// `workQueue.async` closure under Swift 6 strict concurrency. All
/// concrete renderers below conform via `@unchecked Sendable` — they
/// own mutable state (caches, rain columns) but the discipline is
/// single-writer: only the work queue calls `render` / `renderClock`.
protocol FrameRenderer: AnyObject, Sendable {
    /// Render one canvas-sized frame. `blink` is a monotonically-increasing
    /// phase the implementation can use for caret/scan animations.
    /// `blackAlpha` (0…1) is filled over the final composite inside the
    /// renderer's own context — used by FrameLoop's fade machine so we
    /// don't allocate a second CGContext just to add the overlay.
    func render(_ telemetry: Telemetry, blink: Double, now: Date,
                blackAlpha: Double) -> CGImage?

    /// Render an idle/clock-mode frame in the renderer's own visual style.
    /// Default returns `nil` — FrameLoop falls back to the generic
    /// `ClockRenderer` (matrix-themed). Implementations that want their
    /// theme to carry through the clock fallback should override.
    func renderClock(blink: Double, now: Date, blackAlpha: Double) -> CGImage?

    /// Last CRT post-processing duration in ms. Renderers without CRT return 0.
    var lastCRTMs: Double { get }
}

extension FrameRenderer {
    func renderClock(blink: Double, now: Date, blackAlpha: Double) -> CGImage? { nil }
    var lastCRTMs: Double { 0 }
}

extension MatrixRenderer: FrameRenderer {}

enum FrameRendererFactory {
    static func make(_ mode: AppEnvironment.RenderMode,
                     showRain: Bool,
                     portrait: Bool) -> FrameRenderer {
        switch mode {
        case .matrixDashboard:
            // Matrix has a real portrait layout. Other themes haven't been
            // ported yet — they keep the landscape canvas and get rotated
            // by `oriented()` for now.
            let size = portrait ? MatrixTheme.canvasSizePortrait
                                 : MatrixTheme.canvasSize
            return MatrixRenderer(size: size, showRain: showRain)
        case .cozy:
            return AnimalCrossingRenderer()
        case .wowAlliance:
            return ImageRenderer(resourceName: "wow-alliance-placeholder")
        case .wowHorde:
            return ImageRenderer(resourceName: "wow-horde-placeholder")
        case .animalCrossing:
            return ImageRenderer(resourceName: "animal-crossing-placeholder")
        case .dragonball:
            return ImageRenderer(resourceName: "dragonball-placeholder")
        }
    }
}
