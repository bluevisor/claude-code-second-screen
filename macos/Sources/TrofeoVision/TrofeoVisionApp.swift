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
        MenuBarExtra {
            MenuBarContent()
                .environmentObject(env)
                .frame(width: 320)
        } label: {
            // Plain SF Symbol — palette/.foregroundStyle on a MenuBarExtra
            // label silently renders blank on some setups. The agent-status
            // color lives inside the popover instead.
            Image(systemName: "display")
        }
        .menuBarExtraStyle(.window)

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

    init() {
        // Start the render + telemetry loop the moment AppKit comes up so
        // the LCD pipeline runs even before the user opens the popover.
        // `@StateObject` isn't initialized at App.init time, but the
        // delegate's applicationDidFinishLaunching runs after StateObject
        // wires up — we hop through `AppEnvironment.shared` there.
        AppEnvironment.installSharedInstance()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ note: Notification) {
        AppEnvironment.shared?.start()
    }
}
