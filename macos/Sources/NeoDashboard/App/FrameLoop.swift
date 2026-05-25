// Render loop — ticks telemetry at 1 Hz and frames at the target FPS.
//
// Two Combine timers replace the Python QTimer setup. Heavy work (render +
// JPEG encode + LCD send) runs on a background queue so the UI thread stays
// responsive. The loop owns the renderer + LCD output and pushes updates
// back to `AppEnvironment` on the main actor.

import AppKit
import Combine
import CoreGraphics
import Foundation
import os
import os.log

@MainActor
final class FrameLoop {
    private weak var env: AppEnvironment?
    private let logger = Logger(subsystem: "tech.bluevisor.NeoDashboard",
                                category: "FrameLoop")
    private let encoder = JPEGEncoder()
    private var renderer: FrameRenderer = MatrixRenderer()
    /// Used whenever telemetry reports no active session — overrides the
    /// user-selected renderer. Rebuilt alongside `renderer` when the
    /// canvas orientation changes (see `reconfigure`).
    private var clockRenderer: ClockRenderer = ClockRenderer()
    private var blink: Double = 0
    private var telTimer: Timer?
    private var frameTimer: Timer?
    private let workQueue = DispatchQueue(label: "tech.bluevisor.NeoDashboard.render",
                                          qos: .userInteractive)
    /// Cross-thread state for the worker queue. `inFlight` coalesces frame
    /// ticks so the wall clock can't lag behind a backed-up HID pipeline.
    /// LCD connection state is owned by the driver now (`startMonitoring`)
    /// so we no longer track it here.
    private struct WorkerState { var inFlight = false }
    private let workerState = OSAllocatedUnfairLock(initialState: WorkerState())
    /// Reusable CGContext for the orientation pass, keyed by output
    /// dimensions. Lives on `workQueue` (serial) so access doesn't need
    /// extra locking. Allocated lazily on first non-zero rotation.
    private let orientationCtx = OrientationContextPool()

    /// Transition state between dashboard ↔ clock fallback. A swap fades
    /// the *current* renderer out to black, switches, then fades the new
    /// renderer back in. Computed each tick from absolute timestamps so
    /// the coalescer dropping frames doesn't stall the animation.
    private enum FadeState {
        case idle
        case fadingOut(start: Date)
        case fadingIn(start: Date)
    }
    private var fadeState: FadeState = .idle
    private var currentIsClock: Bool = false
    private static let fadeDuration: TimeInterval = 0.35

    init(env: AppEnvironment) {
        self.env = env
    }

    func start() {
        guard let env else { return }
        rebuildRenderers(env: env)
        startLCDMonitoringIfNeeded()
        scheduleTimers(fps: env.targetFPS)
    }

    func reconfigure() {
        guard let env else { return }
        telTimer?.invalidate()
        frameTimer?.invalidate()
        rebuildRenderers(env: env)
        // Snap the fade machine to a clean state matching the current
        // intent. Without this, an in-flight rotation-crossing fade
        // could leave `currentIsClock` out of sync with what the user
        // toggled, which looked like the clock toggle "not working".
        fadeState = .idle
        currentIsClock = env.wantsClock
        scheduleTimers(fps: env.targetFPS)
    }

    private func rebuildRenderers(env: AppEnvironment) {
        let portrait = env.rotation.isPortrait
        renderer = FrameRendererFactory.make(env.mode,
                                             showRain: env.showRain,
                                             portrait: portrait)
        let clockSize = portrait ? MatrixTheme.canvasSizePortrait
                                  : MatrixTheme.canvasSize
        clockRenderer = ClockRenderer(size: clockSize)
    }

    private func scheduleTimers(fps: Int) {
        // Telemetry at 4 Hz. Sources tail by file size and early-exit when
        // nothing has changed, so the extra polling is essentially free —
        // and it lets fast tools (Read, Glob, …) actually appear on the
        // dashboard before the user's tool-result event closes the window.
        let tel = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                let tel = self.env?.source.tick() ?? .empty()
                self.env?.updateTelemetry(tel)
            }
        }
        RunLoop.main.add(tel, forMode: .common)
        tel.fire()
        telTimer = tel
        // Frames at target FPS. Use .common so menu/event tracking can't
        // stall the wall clock displayed on the LCD.
        let interval = 1.0 / max(1, Double(fps))
        let frame = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.renderTick() }
        }
        RunLoop.main.add(frame, forMode: .common)
        frameTimer = frame
    }

    private func renderTick() {
        guard let env else { return }
        // Coalesce: if HID is still pushing the previous frame, skip this
        // tick entirely. The next tick will pick up fresh telemetry + now.
        let shouldRun = workerState.withLock { s -> Bool in
            if s.inFlight { return false }
            s.inFlight = true
            return true
        }
        guard shouldRun else { return }

        let tel = env.telemetry
        let pushToLCD = env.pushToLCD
        let rotation = env.rotation
        let flipH = env.flipHorizontal
        let flipV = env.flipVertical
        let now = Date.now
        blink += 1.0 / max(1, Double(env.targetFPS))
        let phase = blink

        // Drive the fade state machine on the main actor before handing the
        // result off to the work queue. The active renderer + black overlay
        // alpha are decided here so the worker doesn't touch shared state.
        let wantsClock = env.resolveWantsClock(for: tel)
        let (clockMode, blackAlpha) = stepFade(wantsClock: wantsClock, now: now)
        // Capture everything the worker needs into Sendable locals before
        // dispatching, so the closure doesn't reach into main-actor state.
        let activeRenderer = self.renderer
        let clockRenderer = self.clockRenderer
        let encoder = self.encoder
        let driver = env.driver
        let workerState = self.workerState
        let previewVisible = env.previewWindowVisible
        let orientationCtx = self.orientationCtx

        workQueue.async { [weak env] in
            defer { workerState.withLock { $0.inFlight = false } }
            let base: CGImage?
            if clockMode {
                // Prefer the active renderer's themed clock; fall back to
                // the generic phosphor one if it doesn't override.
                base = activeRenderer.renderClock(blink: phase, now: now,
                                                  blackAlpha: blackAlpha)
                    ?? clockRenderer.render(tel, blink: phase, now: now,
                                            blackAlpha: blackAlpha)
            } else {
                base = activeRenderer.render(tel, blink: phase, now: now,
                                             blackAlpha: blackAlpha)
            }
            guard let raw = base else { return }
            // LCD gets the oriented frame; preview always shows the raw
            // landscape so the user can read it on screen. When nothing
            // re-orients the frame (the common case), `lcdImg === raw` and
            // we only need to JPEG-encode once.
            let lcdImg = Self.oriented(raw, pool: orientationCtx,
                                       rotation: rotation,
                                       flipH: flipH, flipV: flipV) ?? raw
            if pushToLCD, let jpeg = encoder.encode(lcdImg) {
                _ = driver.send(jpeg)
            }
            // Preview CGImage update is throttled by whether the window
            // is on-screen — when it's closed, nothing reads
            // `lastFramePreview` so we skip the main-actor hop entirely.
            if previewVisible {
                Task { @MainActor in
                    env?.updatePreview(image: raw)
                }
            }
        }
    }

    /// Drives the dashboard↔clock fade machine. Returns whether the next
    /// frame should be drawn in clock mode (vs the regular dashboard) and
    /// the black-overlay alpha to apply (0 = full image, 1 = pure black).
    ///
    /// Transitions are cancellable: if the target flips mid-fade we either
    /// snap back to idle (during fadingOut, since we haven't committed to
    /// the new mode yet) or reverse into a fadingOut from the current
    /// alpha (during fadingIn, where the new mode is already on screen).
    /// Without this, double-clicking the clock toggle inside the 0.7s
    /// fade window looked like the toggle was ignored.
    private func stepFade(wantsClock: Bool, now: Date) -> (Bool, Double) {
        switch fadeState {
        case .idle:
            if wantsClock != currentIsClock {
                fadeState = .fadingOut(start: now)
            }
            return (currentIsClock, 0)
        case .fadingOut(let start):
            if wantsClock == currentIsClock {
                fadeState = .idle
                return (currentIsClock, 0)
            }
            let progress = min(1, now.timeIntervalSince(start) / Self.fadeDuration)
            if progress >= 1 {
                currentIsClock = wantsClock
                fadeState = .fadingIn(start: now)
                return (currentIsClock, 1)
            }
            return (currentIsClock, progress)
        case .fadingIn(let start):
            let progress = min(1, now.timeIntervalSince(start) / Self.fadeDuration)
            if wantsClock != currentIsClock {
                // Reverse: continue from the current alpha back to fully
                // black, then the next tick will start a fresh fadingOut
                // toward the freshly-requested target.
                let alpha = max(0, 1 - progress)
                let backdated = now.addingTimeInterval(-(1 - alpha) * Self.fadeDuration)
                fadeState = .fadingOut(start: backdated)
                return (currentIsClock, alpha)
            }
            if progress >= 1 {
                fadeState = .idle
                return (currentIsClock, 0)
            }
            return (currentIsClock, 1 - progress)
        }
    }

    /// Apply rotation + flip to the rendered canvas. Returns nil only on a
    /// CGContext allocation failure; the caller falls back to the source.
    ///
    /// The LCD hardware is fixed at 1280×480 — every frame we transmit
    /// must match that grid, regardless of which rotation the user picked
    /// or whether the source was rendered landscape (1280×480) or portrait
    /// (480×1280). At rotation 90/270 a portrait source rotates straight
    /// into the LCD's landscape frame; at 0/180 a landscape source passes
    /// through (after optional 180° flip).
    ///
    /// The output context is reused across frames via `orientationCtx` —
    /// allocating a fresh 2.4 MB bitmap context per frame was the previous
    /// behavior. Per-frame `saveGState/restoreGState` resets the CTM so
    /// transforms don't accumulate, and the source draw fully overwrites
    /// the previous frame's pixels (no clear needed).
    nonisolated private static func oriented(_ src: CGImage,
                                              pool: OrientationContextPool,
                                              rotation: AppEnvironment.DisplayRotation,
                                              flipH: Bool, flipV: Bool) -> CGImage? {
        if rotation == .deg0, !flipH, !flipV { return src }
        let w = CGFloat(src.width)
        let h = CGFloat(src.height)
        let swap = (rotation == .deg90 || rotation == .deg270)
        let outW = swap ? h : w
        let outH = swap ? w : h
        guard let ctx = pool.context(width: Int(outW), height: Int(outH)) else {
            return nil
        }
        ctx.saveGState()
        // CGContext is y-up. Compose: translate to output center, rotate
        // (positive = CCW in y-up, so clockwise display rotation negates it),
        // flip in the rotated frame, then translate back to source origin.
        ctx.translateBy(x: outW / 2, y: outH / 2)
        switch rotation {
        case .deg0: break
        case .deg90: ctx.rotate(by: -.pi / 2)
        case .deg180: ctx.rotate(by: .pi)
        case .deg270: ctx.rotate(by: .pi / 2)
        }
        if flipH { ctx.scaleBy(x: -1, y: 1) }
        if flipV { ctx.scaleBy(x: 1, y: -1) }
        ctx.translateBy(x: -w / 2, y: -h / 2)
        ctx.interpolationQuality = .high
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: w, height: h))
        let img = ctx.makeImage()
        ctx.restoreGState()
        return img
    }

    /// Holds a single CGContext for the orientation pass, swapping it
    /// only when the output dimensions change (i.e. when the user flips
    /// between landscape and portrait rotations). The bitmap is reused
    /// across frames — the per-frame `ctx.draw(src, in: …)` fully
    /// overwrites the previous frame's pixels, so no explicit clear is
    /// needed. Access is serialized by FrameLoop's `workQueue`; the
    /// `@unchecked Sendable` is honest about that.
    final class OrientationContextPool: @unchecked Sendable {
        private var ctx: CGContext?
        private var width: Int = 0
        private var height: Int = 0

        func context(width: Int, height: Int) -> CGContext? {
            if let ctx, width == self.width, height == self.height {
                return ctx
            }
            let new = CGContext(
                data: nil,
                width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
            )
            ctx = new
            self.width = width
            self.height = height
            return new
        }
    }

    /// Wire the driver's hot-plug-aware monitoring. The driver keeps an
    /// IOHIDManager alive for the app lifetime; its match/removal
    /// callbacks fire on the main runloop and the handshake runs on
    /// our work queue. State changes are routed back to
    /// `env.updateLCDStatus` so the menu bar reflects reality whether
    /// the LCD is plugged in at launch or hot-plugged later.
    ///
    /// `onState` is called on the main thread by the driver. We hop
    /// through `Task { @MainActor in … }` to satisfy the @MainActor
    /// isolation of `updateLCDStatus` without assuming the call thread.
    private func startLCDMonitoringIfNeeded() {
        guard let env, env.pushToLCD else { return }
        let driver = env.driver
        driver.startMonitoring(workQueue: workQueue) { [weak env] state in
            let mapped: AppEnvironment.LCDStatus
            switch state {
            case .disconnected:           mapped = .disconnected
            case .connecting:             mapped = .connecting
            case .ready(let w, let h):    mapped = .ready(width: w, height: h)
            case .error(let msg):         mapped = .error(msg)
            }
            Task { @MainActor in env?.updateLCDStatus(mapped) }
        }
    }
}
