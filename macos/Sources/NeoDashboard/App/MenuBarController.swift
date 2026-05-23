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
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "display", accessibilityDescription: "NeoDashboard")
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageOnly
            button.toolTip = "NeoDashboard"
            button.target = self
            button.action = #selector(togglePopover(_:))
        }
        let host = NSHostingController(
            rootView: MenuBarContent()
                .environmentObject(env)
                .frame(width: 320)
        )
        host.sizingOptions = [.preferredContentSize, .intrinsicContentSize]
        let p = NSPopover()
        p.contentViewController = host
        p.behavior = .transient
        p.animates = true
        self.popover = p
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
