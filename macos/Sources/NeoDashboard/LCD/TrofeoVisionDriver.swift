// Real LCD driver — talks to the Trofeo Vision Type 2 device over HID.
//
// The macOS kernel's IOHIDFamily claims HID interfaces, so we can't use
// libusb. Instead we go through IOHIDManager. The manager is kept alive
// for the entire app lifetime: matching + removal callbacks signal plug
// events so the LCD is picked up whether it's connected at startup or
// hot-plugged afterwards (the previous one-shot `open()` model meant a
// late-plugged LCD was never detected). Once a matching device arrives,
// the work queue runs the TRCC handshake (SetReport output + input
// report off the interrupt IN endpoint) and we start pushing frames.
//
// Wire timing copied from the C# decompilation (DELAY_PRE_INIT_S = 50 ms,
// DELAY_POST_INIT_S = 200 ms, DELAY_FRAME_TYPE2_S = 1 ms).

import Foundation
import IOKit
import IOKit.hid
import os
import os.log

final class TrofeoVisionDriver: LCDOutput, @unchecked Sendable {
    static let vendorID: Int = 0x0416
    static let productID: Int = 0x5302

    /// HID output reports must fit the device's 512-byte report descriptor.
    static let chunkSize = 512

    /// External-facing connection state. Reflects what the menu bar /
    /// LCD status display should show. Driven by the manager callbacks
    /// and the handshake result on the work queue.
    enum State: Equatable {
        case disconnected
        case connecting
        case ready(width: Int, height: Int)
        case error(String)
    }

    var isAvailable: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return device != nil
    }
    private(set) var resolution: (Int, Int) = (1280, 480)

    private let logger = Logger(subsystem: "tech.bluevisor.NeoDashboard",
                                category: "LCD.Driver")

    /// Cross-thread mutable state. Touched by the IOHID matching/removal
    /// callbacks on the main runloop and by `attach`/`send`/`detach` on
    /// the work queue.
    ///
    /// Members are non-Sendable CFTypes / unsafe pointers / closures, so
    /// instead of `OSAllocatedUnfairLock<State>` (whose `withLock` body
    /// is `@Sendable` in Swift 6 strict mode and rejects every capture)
    /// we hold them as `nonisolated(unsafe)` ivars synchronized by a
    /// plain `NSLock`. Same guarantee, just hand-rolled.
    private let stateLock = NSLock()
    private nonisolated(unsafe) var manager: IOHIDManager?
    private nonisolated(unsafe) var device: IOHIDDevice?
    /// True between device-arrival and either handshake-success or
    /// handshake-failure. Guards against re-entrant attach attempts if
    /// the matching callback fires twice during a flaky enumerate.
    private nonisolated(unsafe) var attaching: Bool = false
    private nonisolated(unsafe) var inputBuffer: UnsafeMutablePointer<UInt8>?
    private nonisolated(unsafe) var inputBufferSize: Int = 0
    private nonisolated(unsafe) var inputCallbackDevice: IOHIDDevice?
    private nonisolated(unsafe) var attachQueue: DispatchQueue?
    private nonisolated(unsafe) var stateCallback: ((State) -> Void)?
    private nonisolated(unsafe) var lastNotifiedState: State = .disconnected

    /// Handshake response plumbing. The IN-endpoint callback fires on
    /// the main runloop, the work-queue attach blocks on the semaphore.
    private struct HandshakeState { var received: Data? }
    private let handshakeLock = OSAllocatedUnfairLock(initialState: HandshakeState())
    private let handshakeSem = DispatchSemaphore(value: 0)

    // MARK: - Public lifecycle

    /// Start watching for the LCD. Idempotent. Wires
    /// `IOHIDManagerRegisterDeviceMatchingCallback` so plug events route
    /// to the work-queue attach path — covers both the
    /// already-connected-at-launch case and post-launch hot-plug.
    /// State changes are delivered to `onState` on the main thread.
    func startMonitoring(workQueue: DispatchQueue,
                         onState: @escaping @Sendable (State) -> Void) {
        stateLock.lock()
        if manager != nil {
            stateLock.unlock()
            return
        }
        attachQueue = workQueue
        stateCallback = onState
        stateLock.unlock()

        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDVendorIDKey as String: Self.vendorID,
            kIOHIDProductIDKey as String: Self.productID,
        ]
        IOHIDManagerSetDeviceMatching(mgr, matching as CFDictionary)

        let ctx = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerRegisterDeviceMatchingCallback(mgr, Self.deviceMatchedCallback, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(mgr, Self.deviceRemovedCallback, ctx)

        // Schedule on the main runloop so the matching/removal/input
        // callbacks all land on a thread we know is always pumping.
        // The blocking handshake itself runs on the work queue; the
        // input callback signals across via `handshakeSem`.
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(),
                                         CFRunLoopMode.defaultMode.rawValue)
        let openResult = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            let msg = "IOHIDManagerOpen failed: \(String(format: "0x%08x", openResult))"
            logger.error("\(msg, privacy: .public)")
            notify(.error(msg))
            return
        }
        stateLock.lock()
        manager = mgr
        stateLock.unlock()
        notify(.disconnected)
        // IOHIDManagerOpen drives the matching callback for any devices
        // that already match — that's how we pick up a launch-with-LCD
        // case without explicitly enumerating here.
    }

    // MARK: - LCDOutput protocol (legacy no-ops; lifecycle is driven by
    //         the IOHIDManager callbacks now).

    func open() throws {
        // Kept for protocol compatibility. The real lifecycle is in
        // `startMonitoring`. If someone wires a future call site to
        // `driver.open()`, log it so the bug is loud.
        logger.warning("open() is a no-op — call startMonitoring(workQueue:onState:) instead")
    }

    func close() {
        // Tear everything down — used when shutting the app cleanly.
        // Most paths just leave the manager alive for the process
        // lifetime, since macOS reclaims it at exit anyway.
        stateLock.lock()
        let mgr = manager
        let dev = device
        device = nil
        manager = nil
        stateLock.unlock()
        if let dev {
            detach(device: dev, clearStateInsideLock: false)
        }
        if let mgr {
            IOHIDManagerUnscheduleFromRunLoop(mgr, CFRunLoopGetMain(),
                                              CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerClose(mgr, 0)
        }
        notify(.disconnected)
    }

    // MARK: - Match / removal callbacks (fire on main)

    private static let deviceMatchedCallback: IOHIDDeviceCallback = { context, _, _, device in
        guard let context else { return }
        let me = Unmanaged<TrofeoVisionDriver>.fromOpaque(context).takeUnretainedValue()
        me.handleDeviceArrival(device)
    }

    private static let deviceRemovedCallback: IOHIDDeviceCallback = { context, _, _, device in
        guard let context else { return }
        let me = Unmanaged<TrofeoVisionDriver>.fromOpaque(context).takeUnretainedValue()
        me.handleDeviceRemoval(device)
    }

    private func handleDeviceArrival(_ device: IOHIDDevice) {
        stateLock.lock()
        if self.device != nil || attaching {
            stateLock.unlock()
            return
        }
        attaching = true
        let queue = attachQueue
        stateLock.unlock()
        guard let queue else { return }
        logger.info("device arrived — dispatching attach to work queue")
        notify(.connecting)
        let box = SendableBox(device)
        queue.async { [weak self] in
            self?.attach(device: box.value)
        }
    }

    private func handleDeviceRemoval(_ device: IOHIDDevice) {
        // Only react to the device we're actually using. If another
        // matching device is unplugged while we're attached to a
        // different instance, leave us alone.
        stateLock.lock()
        let weCare = (self.device === device)
        stateLock.unlock()
        guard weCare else { return }
        logger.info("device removed — tearing down")
        detach(device: device, clearStateInsideLock: true)
        notify(.disconnected)
    }

    // MARK: - Attach / detach (work queue)

    private func attach(device: IOHIDDevice) {
        // No matter what happens, drop `attaching` so the next arrival
        // callback isn't ignored. Tracked separately from `device` so a
        // failed attach doesn't claim the device slot.
        defer {
            stateLock.lock()
            attaching = false
            stateLock.unlock()
        }

        let devOpen = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard devOpen == kIOReturnSuccess else {
            let msg = "IOHIDDeviceOpen failed: \(String(format: "0x%08x", devOpen))"
            logger.error("\(msg, privacy: .public)")
            notify(.error(msg))
            return
        }
        if let product = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String {
            logger.info("LCD product: \(product, privacy: .public)")
        }

        registerInputCallback(dev: device)

        do {
            try handshake(device: device)
            stateLock.lock()
            self.device = device
            stateLock.unlock()
            let (w, h) = resolution
            logger.info("LCD ready — \(w, privacy: .public)×\(h, privacy: .public)")
            notify(.ready(width: w, height: h))
        } catch {
            logger.warning("handshake failed: \(error.localizedDescription, privacy: .public)")
            unregisterInputCallbackIfBound()
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
            notify(.error(error.localizedDescription))
        }
    }

    private func detach(device: IOHIDDevice, clearStateInsideLock: Bool) {
        unregisterInputCallbackIfBound()
        // IOHIDDeviceClose on a removed device returns an error
        // (kIOReturnNotOpen) which is harmless — we still want the call
        // to release any cached references on our side.
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        if clearStateInsideLock {
            stateLock.lock()
            self.device = nil
            stateLock.unlock()
        }
    }

    // MARK: - Handshake (template method from hid.py:HidDevice.handshake)

    private func handshake(device: IOHIDDevice) throws {
        let initPacket = TRCCFraming.buildInitPacket()
        let maxAttempts = 3
        var lastError: Error?
        for attempt in 1...maxAttempts {
            do {
                drainSemaphore()
                handshakeLock.withLock { $0.received = nil }

                try Thread.sleep(forSeconds: 0.050)
                try setOutputReport(device: device, data: initPacket, reportID: 0)
                let waited = handshakeSem.wait(timeout: .now() + 1.0)
                if waited == .timedOut {
                    logger.warning("handshake \(attempt)/\(maxAttempts): no input report within 1s")
                    lastError = error("timeout waiting for input report")
                    try? Thread.sleep(forSeconds: 0.5)
                    continue
                }
                guard let resp = handshakeLock.withLock({ $0.received }) else {
                    lastError = error("input callback fired without data")
                    continue
                }
                guard TRCCFraming.validateResponse(resp) else {
                    let hex = resp.prefix(16).map { String(format: "%02x", $0) }.joined()
                    logger.warning("handshake \(attempt)/\(maxAttempts): invalid response (first 16: \(hex, privacy: .public))")
                    lastError = error("invalid handshake response")
                    try Thread.sleep(forSeconds: 0.5)
                    continue
                }
                let info = TRCCFraming.parseDeviceInfo(resp)
                resolution = (info.width, info.height)
                return
            } catch {
                logger.warning("handshake attempt \(attempt) failed: \(error.localizedDescription, privacy: .public)")
                lastError = error
                if attempt < maxAttempts { try? Thread.sleep(forSeconds: 0.5) }
            }
        }
        throw lastError ?? error("handshake failed after \(maxAttempts) attempts")
    }

    private func drainSemaphore() {
        while handshakeSem.wait(timeout: .now()) == .success {}
    }

    // MARK: - Frame send

    @discardableResult
    func send(_ jpeg: Data) -> Bool {
        // Snapshot the device under the lock so a concurrent removal
        // can't pull the rug out mid-transfer. Holding the CFTypeRef
        // local keeps the device alive for the duration of this call.
        stateLock.lock()
        let dev = device
        stateLock.unlock()
        guard let dev else { return false }
        let (w, h) = resolution
        let packet = TRCCFraming.buildFramePacket(jpeg: jpeg, width: w, height: h)
        let ok = packet.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return false
            }
            var offset = 0
            while offset < packet.count {
                let len = min(Self.chunkSize, packet.count - offset)
                let r = IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0,
                                             base.advanced(by: offset), len)
                if r != kIOReturnSuccess {
                    logger.error("send failed at offset \(offset)/\(packet.count): IOHIDDeviceSetReport returned \(String(format: "0x%08x", r), privacy: .public)")
                    return false
                }
                offset += len
            }
            return true
        }
        guard ok else { return false }
        try? Thread.sleep(forSeconds: 0.001)
        return true
    }

    // MARK: - HID transport

    private func setOutputReport(device: IOHIDDevice,
                                 data: Data,
                                 reportID: CFIndex) throws {
        let r = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> IOReturn in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return kIOReturnBadArgument
            }
            return IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, reportID,
                                        base, data.count)
        }
        if r != kIOReturnSuccess {
            throw error("IOHIDDeviceSetReport returned \(String(format: "0x%08x", r))")
        }
    }

    /// Register the async input-report callback for `dev`. The buffer
    /// must outlive the registration — we hold it inside the
    /// lock-protected state and free it in `unregisterInputCallbackIfBound`.
    /// Always replaces any previous registration.
    private func registerInputCallback(dev: IOHIDDevice) {
        unregisterInputCallbackIfBound()
        let baseSize = TRCCFraming.responseSize
        let reportSize: Int = {
            if let v = IOHIDDeviceGetProperty(dev, kIOHIDMaxInputReportSizeKey as CFString) as? Int,
               v > 0 {
                return max(v, baseSize)
            }
            return baseSize
        }()
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: reportSize)
        buf.initialize(repeating: 0, count: reportSize)
        stateLock.lock()
        inputBuffer = buf
        inputBufferSize = reportSize
        inputCallbackDevice = dev
        stateLock.unlock()
        let ctx = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        IOHIDDeviceRegisterInputReportCallback(dev, buf, reportSize,
                                               Self.inputReportCallback, ctx)
    }

    /// Detach and free the input-report buffer for whatever device is
    /// currently bound. Order matters: unregister the callback before
    /// freeing the buffer so IOHID can't fire into freed memory.
    private func unregisterInputCallbackIfBound() {
        stateLock.lock()
        let dev = inputCallbackDevice
        let buf = inputBuffer
        let size = inputBufferSize
        inputCallbackDevice = nil
        inputBuffer = nil
        inputBufferSize = 0
        stateLock.unlock()
        if let dev, let buf {
            // Unregister by passing a nil callback. The buffer must
            // still be valid at this call — that's why we free below.
            IOHIDDeviceRegisterInputReportCallback(dev, buf, size, nil, nil)
        }
        if let buf {
            buf.deinitialize(count: size)
            buf.deallocate()
        }
    }

    private static let inputReportCallback: IOHIDReportCallback = { context, _, _, _, _, report, length in
        guard let context else { return }
        let me = Unmanaged<TrofeoVisionDriver>.fromOpaque(context).takeUnretainedValue()
        let data = Data(bytes: report, count: length)
        me.handshakeLock.withLock { state in
            state.received = data
        }
        me.handshakeSem.signal()
    }

    // MARK: - State notify

    /// Coalesce + dispatch state changes. Always emits on the main
    /// thread so the callback can safely poke `@MainActor`-isolated
    /// state without further hops.
    private func notify(_ newState: State) {
        stateLock.lock()
        guard lastNotifiedState != newState else {
            stateLock.unlock()
            return
        }
        lastNotifiedState = newState
        let cb = stateCallback
        stateLock.unlock()
        guard let cb else { return }
        let boxed = SendableBox(cb)
        if Thread.isMainThread {
            boxed.value(newState)
        } else {
            DispatchQueue.main.async { boxed.value(newState) }
        }
    }

    private func error(_ msg: String) -> NSError {
        NSError(domain: "TrofeoVision", code: -1,
                userInfo: [NSLocalizedDescriptionKey: msg])
    }
}

private extension Thread {
    static func sleep(forSeconds s: TimeInterval) throws {
        Foundation.Thread.sleep(forTimeInterval: s)
    }
}

/// Trivial transport wrapper that lets us ferry non-Sendable values
/// (closures, IOHIDDevice, etc.) across `DispatchQueue.async` boundaries.
/// Safe in this driver because the values either originated on the
/// destination context or are immutable references managed by the lock.
private struct SendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
