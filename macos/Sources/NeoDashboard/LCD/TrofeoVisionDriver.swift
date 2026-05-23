// Real LCD driver — talks to the Trofeo Vision Type 2 device over HID.
//
// The macOS kernel's IOHIDFamily claims HID interfaces, so we can't use
// libusb. Instead we go through IOHIDManager: enumerate by VID/PID, open,
// run the TRCC handshake via SetReport (output) + GetReport (input), then
// push JPEG frames as a stream of 512-byte output reports (report ID 0).
//
// Wire timing copied from the C# decompilation (DELAY_PRE_INIT_S = 50 ms,
// DELAY_POST_INIT_S = 200 ms, DELAY_FRAME_TYPE2_S = 1 ms).

import Foundation
import IOKit
import IOKit.hid
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

    func open() throws {
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDVendorIDKey as String: Self.vendorID,
            kIOHIDProductIDKey as String: Self.productID,
        ]
        IOHIDManagerSetDeviceMatching(mgr, matching as CFDictionary)
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
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

        try handshake()
    }

    func close() {
        if let dev = device {
            IOHIDDeviceClose(dev, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        if let mgr = manager {
            IOHIDManagerClose(mgr, 0)
        }
        device = nil
        manager = nil
    }

    // MARK: - Handshake (template method from hid.py:HidDevice.handshake)

    private func handshake() throws {
        guard let dev = device else { throw error("device not opened") }
        let initPacket = TRCCFraming.buildInitPacket()
        let maxAttempts = 3
        var lastError: Error?
        for attempt in 1...maxAttempts {
            do {
                try Thread.sleep(forSeconds: 0.050)
                try setOutputReport(dev, initPacket, reportID: 0)
                try Thread.sleep(forSeconds: 0.200)
                let resp = try getInputReport(dev, reportID: 0, length: TRCCFraming.responseSize)
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

    // MARK: - Frame send

    @discardableResult
    func send(_ jpeg: Data) -> Bool {
        guard let dev = device else { return false }
        let (w, h) = resolution
        let packet = TRCCFraming.buildFramePacket(jpeg: jpeg, width: w, height: h)
        // The packet length is always a multiple of 512; chunk into output reports.
        var offset = 0
        while offset < packet.count {
            let end = min(offset + Self.chunkSize, packet.count)
            let chunk = packet.subdata(in: offset..<end)
            do {
                try setOutputReport(dev, chunk, reportID: 0)
            } catch {
                logger.error("send failed at offset \(offset)/\(packet.count): \(error.localizedDescription, privacy: .public)")
                return false
            }
            offset = end
        }
        // Match the C# inter-frame sleep so the firmware can flush.
        try? Thread.sleep(forSeconds: 0.001)
        return true
    }

    // MARK: - HID transport

    private func setOutputReport(_ dev: IOHIDDevice, _ data: Data, reportID: CFIndex) throws {
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

    private func getInputReport(_ dev: IOHIDDevice, reportID: CFIndex, length: Int) throws -> Data {
        var buf = [UInt8](repeating: 0, count: length)
        var actual = CFIndex(length)
        let r = buf.withUnsafeMutableBufferPointer { ptr -> IOReturn in
            IOHIDDeviceGetReport(dev, kIOHIDReportTypeInput, reportID,
                                 ptr.baseAddress!, &actual)
        }
        if r != kIOReturnSuccess {
            throw error("IOHIDDeviceGetReport returned \(String(format: "0x%08x", r))")
        }
        return Data(buf.prefix(Int(actual)))
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
