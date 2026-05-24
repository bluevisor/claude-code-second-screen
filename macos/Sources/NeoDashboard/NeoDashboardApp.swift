// App entry — menu-bar-only SwiftUI app.
//
// `LSUIElement` in Info.plist suppresses the Dock icon. `MenuBarExtra` with
// `.window` style gives us a popover-like control surface that follows Apple
// HIG (16×16 status icon + tappable popover). A separate Window scene hosts
// the optional live preview.

import SwiftUI

@main
struct NeoDashboardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var env = AppEnvironment()

    var body: some Scene {
        // Live preview is shown via Window scene; the menu bar item is
        // managed by AppKit (NSStatusItem) in `MenuBarController` so it
        // stays visible even when the menu bar overflows behind a notch.
        Window("Live Preview", id: "preview") {
            PreviewWindow()
                .environmentObject(env)
                .frame(minWidth: 640, idealWidth: 1280,
                       minHeight: 240, idealHeight: 480)
        }
        .commandsRemoved()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController?
    private var didStart = false

    func applicationDidFinishLaunching(_ note: Notification) {
        startWhenEnvironmentIsReady()
    }

    private func startWhenEnvironmentIsReady(attempt: Int = 0) {
        guard !didStart else { return }
        guard let env = AppEnvironment.shared else {
            if attempt < 20 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    self?.startWhenEnvironmentIsReady(attempt: attempt + 1)
                }
            }
            return
        }
        didStart = true
        menuBar = MenuBarController(env: env)
        env.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Menu-bar app — closing the preview window must not quit us.
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        // Reopen the preview window when the app icon is clicked.
        if !flag, let url = URL(string: "neo-dashboard://preview") {
            NSWorkspace.shared.open(url)
        }
        return true
    }
}
