import AppKit
import ServiceManagement
import SwiftUI

struct MenuBarContent: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.openWindow) private var openWindow
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.vertical, 8)
            buttons
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 180)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Circle()
                .fill(lcdColor)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text("NeoDashboard")
                    .font(.headline)
                Text(lcdSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var buttons: some View {
        VStack(alignment: .leading, spacing: 2) {
            MenuRow(title: "Preview", icon: "rectangle.on.rectangle") {
                showPreview()
            }
            Toggle(isOn: $launchAtLogin) {
                Label("Launch at Login", systemImage: "arrow.right.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .padding(.vertical, 2)
            .padding(.horizontal, 8)
            .onChange(of: launchAtLogin) { _, on in
                do {
                    if on { try SMAppService.mainApp.register() }
                    else { try SMAppService.mainApp.unregister() }
                } catch {
                    launchAtLogin = SMAppService.mainApp.status == .enabled
                }
            }
            Divider().padding(.vertical, 4)
            MenuRow(title: "Quit", icon: "power") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }

    private func showPreview() {
        openWindow(id: "preview")
        NSApp.activate(ignoringOtherApps: true)
        for w in NSApp.windows where w.title.contains("Live Preview") {
            w.makeKeyAndOrderFront(nil)
        }
    }

    private var lcdColor: Color {
        switch env.lcdStatus {
        case .ready: return .green
        case .connecting: return .orange
        case .error: return .red
        case .disconnected: return .gray
        }
    }

    private var lcdSummary: String {
        switch env.lcdStatus {
        case .disconnected: return "LCD disconnected"
        case .connecting:   return "LCD connecting…"
        case .ready(let w, let h): return "LCD \(w)×\(h) connected"
        case .error(let msg): return "LCD error: \(msg)"
        }
    }
}

private struct MenuRow: View {
    let title: String
    let icon: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(hovering ? Color.accentColor.opacity(0.2) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
