// App entry — menu-bar-only SwiftUI app.
//
// `LSUIElement` in Info.plist suppresses the Dock icon. `MenuBarExtra` with
// `.window` style gives us a popover-like control surface that follows Apple
// HIG (16×16 status icon + tappable popover). A separate Window scene hosts
// the optional live preview.

import SwiftUI

@main
struct TrofeoVisionApp: App {
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

        Settings {
            SettingsView()
                .environmentObject(env)
                .frame(width: 420)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ note: Notification) {
        guard let env = AppEnvironment.shared else { return }
        menuBar = MenuBarController(env: env)
        env.start()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        // Reopen the preview window when the app icon is clicked.
        if !flag, let url = URL(string: "trofeo-vision://preview") {
            NSWorkspace.shared.open(url)
        }
        return true
    }
}
