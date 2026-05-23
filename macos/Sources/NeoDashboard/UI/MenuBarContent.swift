// Menu bar popover — the only chrome the app exposes besides the live
// preview window. Apple HIG layout: header / live status / quick controls
// / footer actions. Settings scene is intentionally not used.

import AppKit
import SwiftUI

struct MenuBarContent: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.vertical, 8)
            statusBlock
            Divider().padding(.vertical, 8)
            controls
            Divider().padding(.vertical, 8)
            footer
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 320)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
                .overlay(Circle().stroke(.white.opacity(0.15), lineWidth: 1))
            VStack(alignment: .leading, spacing: 1) {
                Text("NeoDashboard")
                    .font(.headline)
                Text(lcdSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(env.telemetry.quota.plan)
                .font(.caption2.weight(.heavy))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.green.opacity(0.18), in: Capsule())
                .foregroundStyle(.green)
        }
    }

    // MARK: - Live status block

    private var statusBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(env.telemetry.agent.kind.uppercased().replacingOccurrences(of: "-", with: " "))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(statusLabel)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(statusColor)
            }
            Text(env.telemetry.agent.currentTask.isEmpty
                 ? "—"
                 : env.telemetry.agent.currentTask)
                .font(.callout)
                .lineLimit(3)
                .truncationMode(.tail)
                .foregroundStyle(.primary)
            HStack(spacing: 10) {
                Label(env.telemetry.model.name, systemImage: "cpu")
                    .labelStyle(.titleAndIcon)
                Text("v\(env.telemetry.model.version)")
                    .foregroundStyle(.secondary)
                Spacer()
                Text("T\(env.telemetry.agent.turn) · \(env.telemetry.agent.filesRead)R/\(env.telemetry.agent.filesEdited)W")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
        }
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            sourceRow
            if env.mode == .matrixDashboard {
                Toggle("Matrix rain", isOn: $env.showRain)
                    .toggleStyle(.switch)
                    .font(.callout)
                    .onChange(of: env.showRain) { _, _ in env.loop?.reconfigure() }
            }
        }
    }

    private var sourceRow: some View {
        HStack(spacing: 8) {
            Text("Source")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
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
                                sessionLabel(s)
                            }
                        }
                    }
                }
            } label: {
                Label(env.sourceSelection.label,
                      systemImage: env.sourceSelection.symbol)
                    .font(.callout)
            }
            .menuStyle(.borderlessButton)
        }
    }

    @ViewBuilder
    private func sessionLabel(_ s: ActiveSession) -> some View {
        let mins = max(0, Int(Date.now.timeIntervalSince1970 - s.updatedAt) / 60)
        let agoText = s.busy ? "● busy" : (mins == 0 ? "just now" : "\(mins)m ago")
        Label("\(s.kind.label) · \(s.displayName)  ·  \(agoText)",
              systemImage: s.busy ? "circle.fill" : s.kind.symbol)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button {
                openWindow(id: "preview")
                NSApp.activate(ignoringOtherApps: true)
                for w in NSApp.windows where w.title.contains("Live Preview") {
                    w.makeKeyAndOrderFront(nil)
                }
            } label: {
                Label("Show Preview", systemImage: "rectangle.on.rectangle")
            }
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .controlSize(.small)
    }

    // MARK: - Derived

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
