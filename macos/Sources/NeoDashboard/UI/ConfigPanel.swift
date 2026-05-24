// Preview-window configuration popover. Holds the controls that aren't
// the theme picker (which lives in the menu-bar popup): data source,
// time format, temperature unit, and theme-specific tuning like the
// matrix-rain toggle.

import SwiftUI

struct ConfigPanel: View {
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        Form {
            sourceSection
            Section("Display") {
                Picker("Time", selection: $env.timeFormat) {
                    ForEach(AppEnvironment.TimeFormat.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Temperature", selection: $env.temperatureUnit) {
                    ForEach(AppEnvironment.TemperatureUnit.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Date", selection: $env.dateFormat) {
                    ForEach(AppEnvironment.DateFormat.allCases) { Text($0.rawValue).tag($0) }
                }
            }
            if env.mode == .matrixDashboard {
                Section("Matrix") {
                    Toggle("Matrix rain", isOn: $env.showRain)
                        .onChange(of: env.showRain) { _, _ in env.loop?.reconfigure() }
                }
            }
        }
        .formStyle(.grouped)
        .padding(8)
        .frame(width: 360)
    }

    // MARK: - Source

    private var sourceSection: some View {
        Section("Source") {
            Menu {
                Button {
                    env.sourceSelection = .auto
                } label: {
                    Label("Auto (active session)", systemImage: "wand.and.stars")
                }
                Button {
                    env.sourceSelection = .claudeCode
                } label: {
                    Label("Claude Code", systemImage: "terminal")
                }
                Button {
                    env.sourceSelection = .codex
                } label: {
                    Label("Codex", systemImage: "command")
                }
                Button {
                    env.sourceSelection = .agy
                } label: {
                    Label("AGY", systemImage: "network")
                }
                Button {
                    env.sourceSelection = .demo
                } label: {
                    Label("Demo", systemImage: "theatermasks")
                }
                if !env.activeSessions.isEmpty {
                    Section("Active sessions") {
                        ForEach(env.activeSessions) { s in
                            Button {
                                env.sourceSelection = .session(s)
                            } label: {
                                sessionRow(s)
                            }
                        }
                    }
                }
            } label: {
                Label(env.sourceSelection.label,
                      systemImage: env.sourceSelection.symbol)
            }
        }
    }

    @ViewBuilder
    private func sessionRow(_ s: ActiveSession) -> some View {
        let mins = max(0, Int(Date.now.timeIntervalSince1970 - s.updatedAt) / 60)
        let agoText = s.busy ? "● busy" : (mins == 0 ? "just now" : "\(mins)m ago")
        Label("\(s.kind.label) · \(s.displayName)  ·  \(agoText)",
              systemImage: s.busy ? "circle.fill" : s.kind.symbol)
    }
}
