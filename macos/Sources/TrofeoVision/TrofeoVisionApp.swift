// App entry — menu-bar-only SwiftUI app.
//
// `LSUIElement` in Info.plist suppresses the Dock icon. `MenuBarExtra` with
// `.window` style gives us a popover-like control surface that follows Apple
// HIG (16×16 status icon + tappable popover). A separate Window scene hosts
// the optional live preview.

import SwiftUI

@main
struct TrofeoVisionApp: App {
    @StateObject private var env = AppEnvironment()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
                .environmentObject(env)
                .frame(width: 320)
        } label: {
            MenuBarLabel()
                .environmentObject(env)
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
        // StateObject hasn't run yet; defer start to .onAppear.
    }
}

struct MenuBarLabel: View {
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        // Color the SF Symbol by agent status (matches the rail LED).
        Image(systemName: "rectangle.connected.to.line.below")
            .symbolRenderingMode(.palette)
            .foregroundStyle(statusColor, .secondary)
            .onAppear {
                env.start()
            }
    }

    private var statusColor: Color {
        switch env.telemetry.agent.status {
        case .error: return .red
        case .idle:  return .orange
        default:     return .green
        }
    }
}
