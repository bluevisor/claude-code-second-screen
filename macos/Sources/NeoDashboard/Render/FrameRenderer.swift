// Pluggable render surface. The frame loop picks a `FrameRenderer` based on
// `AppEnvironment.mode` so future layouts (clock face, system stats, photo
// slideshow, …) can swap in without touching the loop or HID driver.

import CoreGraphics
import Foundation

protocol FrameRenderer: AnyObject {
    /// Render one canvas-sized frame. `blink` is a monotonically-increasing
    /// phase the implementation can use for caret/scan animations.
    func render(_ telemetry: Telemetry, blink: Double, now: Date) -> CGImage?

    /// Render an idle/clock-mode frame in the renderer's own visual style.
    /// Default returns `nil` — FrameLoop falls back to the generic
    /// `ClockRenderer` (matrix-themed). Implementations that want their
    /// theme to carry through the clock fallback should override.
    func renderClock(blink: Double, now: Date) -> CGImage?
}

extension FrameRenderer {
    func renderClock(blink: Double, now: Date) -> CGImage? { nil }
}

extension MatrixRenderer: FrameRenderer {}

enum FrameRendererFactory {
    static func make(_ mode: AppEnvironment.RenderMode, showRain: Bool) -> FrameRenderer {
        switch mode {
        case .matrixDashboard:
            return MatrixRenderer(showRain: showRain)
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
