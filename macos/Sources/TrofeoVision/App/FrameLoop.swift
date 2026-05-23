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
    private let logger = Logger(subsystem: "tech.bluevisor.TrofeoVision",
                                category: "FrameLoop")
    private let encoder = JPEGEncoder()
    private var renderer: FrameRenderer = MatrixRenderer()
    /// Used whenever telemetry reports no active session — overrides the
    /// user-selected renderer.
    private let clockRenderer = ClockRenderer()
    private var blink: Double = 0
    private var telTimer: Timer?
    private var frameTimer: Timer?
    private let workQueue = DispatchQueue(label: "tech.bluevisor.TrofeoVision.render",
                                          qos: .userInteractive)
    private var lcdOpen = false
    /// Set while a render+send is in flight on workQueue. New ticks bail when
    /// this is true so the clock can't lag behind a backed-up HID pipeline.
    private let renderInFlight = OSAllocatedUnfairLock(initialState: false)

    init(env: AppEnvironment) {
        self.env = env
    }

    func start() {
        guard let env else { return }
        renderer = FrameRendererFactory.make(env.mode, showRain: env.showRain)
        openLCDIfNeeded()
        scheduleTimers(fps: env.targetFPS)
    }

    func reconfigure() {
        guard let env else { return }
        telTimer?.invalidate()
        frameTimer?.invalidate()
        renderer = FrameRendererFactory.make(env.mode, showRain: env.showRain)
        scheduleTimers(fps: env.targetFPS)
    }

    private func scheduleTimers(fps: Int) {
        // Telemetry at 1 Hz (live sources only grow at turn boundaries).
        let tel = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
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
        let shouldRun = renderInFlight.withLock { busy -> Bool in
            if busy { return false }
            busy = true
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

        workQueue.async { [weak self] in
            guard let self else { return }
            defer { self.renderInFlight.withLock { $0 = false } }
            // Source has nothing live → render the clock fallback instead
            // of the user's selected dashboard.
            let activeRenderer: FrameRenderer = tel.hasContent ? self.renderer : self.clockRenderer
            guard let raw = activeRenderer.render(tel, blink: phase, now: now) else { return }
            // LCD gets the oriented frame; preview stays in the native
            // landscape so the user can still read it on screen.
            let lcdImg = Self.oriented(raw, rotation: rotation,
                                       flipH: flipH, flipV: flipV) ?? raw
            if pushToLCD, let jpeg = self.encoder.encode(lcdImg) {
                _ = env.driver.send(jpeg)
            }
            if let jpeg = self.encoder.encode(raw) {
                _ = env.preview.send(jpeg)
            }
            Task { @MainActor in
                env.updatePreview(image: raw)
            }
        }
    }

    /// Apply rotation + flip to the rendered canvas. Returns nil only on a
    /// CGContext allocation failure; the caller falls back to the source.
    private static func oriented(_ src: CGImage,
                                 rotation: AppEnvironment.DisplayRotation,
                                 flipH: Bool, flipV: Bool) -> CGImage? {
        if rotation == .deg0, !flipH, !flipV { return src }
        let w = CGFloat(src.width)
        let h = CGFloat(src.height)
        let swap = (rotation == .deg90 || rotation == .deg270)
        let outW = swap ? h : w
        let outH = swap ? w : h
        guard let ctx = CGContext(
            data: nil,
            width: Int(outW),
            height: Int(outH),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
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
        return ctx.makeImage()
    }

    private func openLCDIfNeeded() {
        guard let env else { return }
        guard env.pushToLCD, !lcdOpen else { return }
        env.updateLCDStatus(.connecting)
        workQueue.async { [weak self] in
            guard let self else { return }
            do {
                try env.driver.open()
                let (w, h) = env.driver.resolution
                Task { @MainActor in
                    env.updateLCDStatus(.ready(width: w, height: h))
                }
                self.lcdOpen = true
            } catch {
                Task { @MainActor in
                    env.updateLCDStatus(.error(error.localizedDescription))
                }
                self.logger.error("LCD open failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
