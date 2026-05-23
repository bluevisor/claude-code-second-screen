// Settings scene — exposed via the standard Cmd-, menu so it follows the
// Apple HIG. Two tabs: General and Display, mirroring what the CLI flags
// on the Python project covered.

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
            displayTab
                .tabItem { Label("Display", systemImage: "rectangle.on.rectangle") }
        }
        .padding(20)
    }

    private var generalTab: some View {
        Form {
            Picker("Source", selection: $env.sourceKind) {
                ForEach(AppEnvironment.SourceKind.allCases) { Text($0.rawValue).tag($0) }
            }
            .onChange(of: env.sourceKind) { _, new in env.setSource(new) }
            TextField("Plan label", text: $env.plan, prompt: Text("MAX 5×"))
            Toggle("Push frames to LCD", isOn: $env.pushToLCD)
        }
    }

    private var displayTab: some View {
        Form {
            Toggle("Matrix rain background", isOn: $env.showRain)
                .onChange(of: env.showRain) { _, _ in env.loop?.reconfigure() }
            Stepper("Target FPS: \(env.targetFPS)",
                    value: $env.targetFPS, in: 5...30)
                .onChange(of: env.targetFPS) { _, _ in env.loop?.reconfigure() }
        }
    }
}
