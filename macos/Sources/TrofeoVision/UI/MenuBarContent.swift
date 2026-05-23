// Popover content for the menu bar extra. Apple HIG-style layout:
// header, status group, controls group, footer (settings / quit).

import SwiftUI

struct MenuBarContent: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.vertical, 6)
            agentSummary
            Divider().padding(.vertical, 6)
            controls
            Divider().padding(.vertical, 6)
            footer
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var header: some View {
        HStack(spacing: 8) {
            statusDot
            VStack(alignment: .leading, spacing: 1) {
                Text("Trofeo Vision")
                    .font(.headline)
                Text(lcdSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var agentSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(env.telemetry.agent.kind.uppercased().replacingOccurrences(of: "-", with: " "))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(statusLabel)
                    .font(.caption)
                    .foregroundStyle(statusColor)
            }
            Text(env.telemetry.agent.currentTask.isEmpty
                 ? "—" : env.telemetry.agent.currentTask)
                .font(.body)
                .lineLimit(2)
                .truncationMode(.tail)
            HStack(spacing: 12) {
                Label(env.telemetry.model.name, systemImage: "cpu")
                    .labelStyle(.titleAndIcon)
                Spacer()
                Text("v\(env.telemetry.model.version)")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Push to LCD", isOn: $env.pushToLCD)
            Toggle("Matrix rain", isOn: $env.showRain)
            Picker("Source", selection: $env.sourceKind) {
                ForEach(AppEnvironment.SourceKind.allCases) { kind in
                    Text(kind.rawValue).tag(kind)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: env.sourceKind) { _, new in env.setSource(new) }
        }
        .font(.callout)
    }

    private var footer: some View {
        HStack {
            Button("Show Preview…") {
                openWindow(id: "preview")
            }
            Spacer()
            Button("Settings…") { openSettings() }
            Button("Quit") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .controlSize(.small)
    }

    // MARK: - Derived

    private var statusDot: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 10, height: 10)
            .overlay(Circle().stroke(.white.opacity(0.1), lineWidth: 1))
    }

    private var statusColor: Color {
        switch env.telemetry.agent.status {
        case .error: return .red
        case .idle:  return .orange
        default:     return .green
        }
    }

    private var statusLabel: String {
        switch env.telemetry.agent.status {
        case .error: return "ERROR"
        case .idle: return "IDLE"
        case .waiting: return "WAITING"
        case .processing: return "PROCESSING"
        case .thinking: return "THINKING"
        case .tool: return env.telemetry.agent.currentTool ?? "TOOL"
        case .writing: return "WRITING"
        }
    }

    private var lcdSummary: String {
        switch env.lcdStatus {
        case .disconnected: return "LCD: disconnected"
        case .connecting:   return "LCD: connecting…"
        case .ready(let w, let h): return "LCD: \(w)×\(h)"
        case .error(let msg): return "LCD: \(msg)"
        }
    }
}
