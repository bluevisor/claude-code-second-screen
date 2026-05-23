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
import os.log

@MainActor
final class FrameLoop {
    private weak var env: AppEnvironment?
    private let logger = Logger(subsystem: "tech.bluevisor.TrofeoVision",
                                category: "FrameLoop")
    private let encoder = JPEGEncoder()
    private var renderer = MatrixRenderer()
    private var blink: Double = 0
    private var telTimer: Timer?
    private var frameTimer: Timer?
    private let workQueue = DispatchQueue(label: "tech.bluevisor.TrofeoVision.render",
                                          qos: .userInteractive)
    private var lcdOpen = false

    init(env: AppEnvironment) {
        self.env = env
    }

    func start() {
        guard let env else { return }
        renderer = MatrixRenderer(showRain: env.showRain)
        openLCDIfNeeded()
        scheduleTimers(fps: env.targetFPS)
    }

    func reconfigure() {
        guard let env else { return }
        telTimer?.invalidate()
        frameTimer?.invalidate()
        renderer = MatrixRenderer(showRain: env.showRain)
        scheduleTimers(fps: env.targetFPS)
    }

    private func scheduleTimers(fps: Int) {
        // Telemetry at 1 Hz (live sources only grow at turn boundaries).
        telTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                let tel = self.env?.source.tick() ?? .empty()
                self.env?.updateTelemetry(tel)
            }
        }
        telTimer?.fire()
        // Frames at target FPS.
        let interval = 1.0 / max(1, Double(fps))
        frameTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.renderTick() }
        }
    }

    private func renderTick() {
        guard let env else { return }
        let tel = env.telemetry
        let pushToLCD = env.pushToLCD
        let now = Date.now
        blink += 1.0 / max(1, Double(env.targetFPS))
        let phase = blink

        workQueue.async { [weak self] in
            guard let self else { return }
            guard let img = self.renderer.render(tel, blink: phase, now: now) else { return }
            var jpeg: Data?
            if pushToLCD || env.preview.snapshot() == nil {
                jpeg = self.encoder.encode(img)
            }
            if let jpeg, pushToLCD {
                _ = env.driver.send(jpeg)
            }
            if let jpeg { _ = env.preview.send(jpeg) }
            Task { @MainActor in
                env.updatePreview(image: img)
            }
        }
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
