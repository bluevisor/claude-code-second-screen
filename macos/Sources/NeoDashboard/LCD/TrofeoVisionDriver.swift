// Real LCD driver — talks to the Trofeo Vision Type 2 device over HID.
//
// The macOS kernel's IOHIDFamily claims HID interfaces, so we can't use
// libusb. Instead we go through IOHIDManager: enumerate by VID/PID, open,
// run the TRCC handshake via SetReport (output) + an input-report
// callback that receives the response off the interrupt IN endpoint,
// then push JPEG frames as a stream of 512-byte output reports
// (report ID 0).
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

    var isAvailable: Bool { device != nil }

    private(set) var resolution: (Int, Int) = (1280, 480)

    private let logger = Logger(subsystem: "tech.bluevisor.NeoDashboard",
                                category: "LCD.Driver")
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?

    /// Input-report plumbing. The interrupt IN endpoint delivers reports
    /// asynchronously via the runloop the manager is scheduled on
    /// (the main runloop, set in `open()`). The handshake thread waits
    /// on `handshakeSem`; the C callback stashes the bytes into
    /// `handshakeState.received` then signals.
    private struct HandshakeState {
        var received: Data?
    }
    private let handshakeLock = OSAllocatedUnfairLock(initialState: HandshakeState())
    private let handshakeSem = DispatchSemaphore(value: 0)
    private var inputBuffer: UnsafeMutablePointer<UInt8>?
    private var inputBufferSize: Int = 0
    private var inputCallbackRegistered = false

    func open() throws {
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDVendorIDKey as String: Self.vendorID,
            kIOHIDProductIDKey as String: Self.productID,
        ]
        IOHIDManagerSetDeviceMatching(mgr, matching as CFDictionary)
        // Schedule with the main runloop so input-report callbacks land
        // on a thread we know is always pumping. The handshake itself
        // runs on a background dispatch queue and just blocks on a
        // semaphore until the callback fires.
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let openResult = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            throw NSError(domain: "TrofeoVision", code: Int(openResult),
                          userInfo: [NSLocalizedDescriptionKey: "IOHIDManagerOpen failed"])
        }
        guard let set = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>,
              let dev = set.first else {
            IOHIDManagerClose(mgr, 0)
            throw NSError(domain: "TrofeoVision", code: -1,
                          userInfo: [NSLocalizedDescriptionKey:
                            "Trofeo Vision not found (VID \(String(format: "%04x", Self.vendorID))/PID \(String(format: "%04x", Self.productID)))"])
        }
        let devOpen = IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone))
        guard devOpen == kIOReturnSuccess else {
            IOHIDManagerClose(mgr, 0)
            throw NSError(domain: "TrofeoVision", code: Int(devOpen),
                          userInfo: [NSLocalizedDescriptionKey: "IOHIDDeviceOpen failed"])
        }
        manager = mgr
        device = dev

        // Best-effort logging — product/serial strings are vendor-defined and
        // may be absent, but they help on multi-LCD machines.
        if let product = IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) as? String {
            logger.info("LCD product: \(product, privacy: .public)")
        }

        registerInputCallback(dev: dev)
        try handshake()
    }

    func close() {
        if let dev = device {
            if inputCallbackRegistered, let buf = inputBuffer {
                IOHIDDeviceRegisterInputReportCallback(dev, buf, inputBufferSize, nil, nil)
                inputCallbackRegistered = false
            }
            IOHIDDeviceClose(dev, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        if let mgr = manager {
            IOHIDManagerClose(mgr, 0)
        }
        if let buf = inputBuffer {
            buf.deinitialize(count: inputBufferSize)
            buf.deallocate()
            inputBuffer = nil
            inputBufferSize = 0
        }
        device = nil
        manager = nil
    }

    // MARK: - Handshake (template method from hid.py:HidDevice.handshake)

    private func handshake() throws {
        guard let dev = device else { throw error("device not opened") }
        _ = dev
        let initPacket = TRCCFraming.buildInitPacket()
        let maxAttempts = 3
        var lastError: Error?
        for attempt in 1...maxAttempts {
            do {
                // Drain any stray signal from a previous attempt and
                // clear the cached response before sending.
                drainSemaphore()
                handshakeLock.withLock { $0.received = nil }

                try Thread.sleep(forSeconds: 0.050)
                try setOutputReport(initPacket, reportID: 0)
                // Response arrives via the interrupt IN endpoint
                // (handled by the registered input-report callback).
                // GetReport over the control endpoint returns
                // kIOReturnUnsupported on this firmware, so we sit on
                // the semaphore until the callback signals.
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
                logger.info("LCD ready — resolution \(info.width)×\(info.height), pm=\(info.pm), sub=\(info.sub)")
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
        guard let dev = device else { return false }
        let (w, h) = resolution
        let packet = TRCCFraming.buildFramePacket(jpeg: jpeg, width: w, height: h)
        // The packet length is always a multiple of 512; chunk into
        // output reports. Enter `withUnsafeBytes` once and pass offset
        // pointers to IOHIDDeviceSetReport — the previous loop did
        // `packet.subdata(in:)` per chunk, allocating ~160 fresh Data
        // copies of the JPEG payload per frame.
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
        // Match the C# inter-frame sleep so the firmware can flush.
        try? Thread.sleep(forSeconds: 0.001)
        return true
    }

    // MARK: - HID transport

    private func setOutputReport(_ data: Data, reportID: CFIndex) throws {
        guard let dev = device else { throw error("device not opened") }
        let r = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> IOReturn in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return kIOReturnBadArgument
            }
            return IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, reportID,
                                        base, data.count)
        }
        if r != kIOReturnSuccess {
            throw error("IOHIDDeviceSetReport returned \(String(format: "0x%08x", r))")
        }
    }

    /// Register the async input-report callback. The buffer must
    /// outlive the registration — we keep it on the driver instance
    /// for the lifetime of the open() call (cleared in close()).
    private func registerInputCallback(dev: IOHIDDevice) {
        let size = TRCCFraming.responseSize
        // Read the device's max report length if available — some
        // firmwares quietly truncate to a smaller report.
        let reportSize: Int = {
            if let v = IOHIDDeviceGetProperty(dev, kIOHIDMaxInputReportSizeKey as CFString) as? Int,
               v > 0 {
                return max(v, size)
            }
            return size
        }()
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: reportSize)
        buf.initialize(repeating: 0, count: reportSize)
        inputBuffer = buf
        inputBufferSize = reportSize
        let ctx = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        IOHIDDeviceRegisterInputReportCallback(dev, buf, reportSize,
                                               Self.inputReportCallback, ctx)
        inputCallbackRegistered = true
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
