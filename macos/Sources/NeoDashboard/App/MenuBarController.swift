// AppKit-driven menu bar item. Owns an NSStatusItem and an NSPopover
// hosting the SwiftUI MenuBarContent. Used in preference to SwiftUI's
// `MenuBarExtra` because the latter is silently truncated when the
// menu bar overflows behind a MacBook notch.

import AppKit
import SwiftUI

@MainActor
final class MenuBarController: NSObject {
    private let env: AppEnvironment
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!

    init(env: AppEnvironment) {
        self.env = env
        super.init()
        configure()
    }

    private func configure() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            if let image = statusImage() {
                button.image = image
                button.title = ""
                button.imagePosition = .imageOnly
            } else {
                button.image = nil
                button.title = "ND"
                button.font = .monospacedSystemFont(ofSize: 11, weight: .bold)
                button.imagePosition = .noImage
            }
            button.toolTip = "NeoDashboard"
            button.target = self
            button.action = #selector(togglePopover(_:))
        }
        let host = NSHostingController(
            rootView: MenuBarContent()
                .environmentObject(env)
                .frame(width: 180)
        )
        host.sizingOptions = [.preferredContentSize, .intrinsicContentSize]
        let p = NSPopover()
        p.contentViewController = host
        p.behavior = .transient
        p.animates = true
        self.popover = p
    }

    private func statusImage() -> NSImage? {
        guard let image = NSImage(systemSymbolName: "rectangle",
                                   accessibilityDescription: "NeoDashboard") else { return nil }
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
