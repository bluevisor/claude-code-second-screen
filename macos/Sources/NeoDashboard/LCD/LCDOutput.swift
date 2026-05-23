// LCD output abstraction.
//
// One implementation drives the real Trofeo Vision via IOHIDManager;
// another writes to an in-memory frame slot used by the SwiftUI preview
// window. Both expose the same surface so the render loop never has to care.

import Foundation

protocol LCDOutput: AnyObject, Sendable {
    /// Whether the device is reachable. Implementations may probe lazily.
    var isAvailable: Bool { get }

    /// Reported resolution (width, height). Trofeo Vision is fixed at 1280×480.
    var resolution: (Int, Int) { get }

    /// Open the device and run the handshake. Throws on hardware failure.
    func open() throws

    /// Push one JPEG frame. Returns true on success. Does not throw on
    /// transient errors so the loop keeps running; check logs.
    @discardableResult
    func send(_ jpeg: Data) -> Bool

    /// Release the device.
    func close()
}

/// Records the latest JPEG without doing any I/O. Used by the SwiftUI
/// preview window to mirror what we'd send to the LCD.
final class InMemoryLCDOutput: LCDOutput, @unchecked Sendable {
    var isAvailable: Bool { true }
    let resolution = (1280, 480)

    private let lock = NSLock()
    private var latest: Data?

    func open() throws {}
    func close() {}

    @discardableResult
    func send(_ jpeg: Data) -> Bool {
        lock.lock()
        latest = jpeg
        lock.unlock()
        return true
    }

    func snapshot() -> Data? {
        lock.lock(); defer { lock.unlock() }
        return latest
    }
}
