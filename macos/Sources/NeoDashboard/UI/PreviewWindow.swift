// Desktop mirror of what's currently being pushed to the LCD.
// The preview itself always shows the native landscape frame so it's
// readable on screen; the toolbar (pinned to the trailing edge) exposes
// the rotation / flip toggles that affect the LCD in real time.
//
// The content preserves the LCD's 1280:480 aspect ratio inside whatever
// window size AppKit gives us. We intentionally do not mutate the NSWindow
// during resize; AppKit can assert if SwiftUI/AppKit fight over frame size.

import AppKit
import SwiftUI

struct PreviewWindow: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var showingConfig = false

    var body: some View {
        GeometryReader { proxy in
            let size = sanitized(proxy.size)
            ZStack {
                Color.black
                if let cg = env.lastFramePreview {
                    Image(decorative: cg, scale: 1, orientation: .up)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(1280.0 / 480.0, contentMode: .fit)
                        .frame(width: size.width, height: size.height)
                } else {
                    ProgressView("Waiting for first frame…")
                        .controlSize(.small)
                        .tint(.green)
                }
            }
            .frame(width: size.width, height: size.height)
        }
        .frame(minWidth: 640, minHeight: 240)
        .navigationTitle("NeoDashboard · Live Preview")
        // Tell FrameLoop whether to bother publishing the per-frame
        // CGImage. When this window is closed, nothing is reading it.
        .onAppear { env.previewWindowVisible = true }
        .onDisappear { env.previewWindowVisible = false }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Menu {
                    ForEach(AppEnvironment.RenderMode.allCases) { m in
                        Button {
                            env.mode = m
                            env.loop?.reconfigure()
                        } label: {
                            Label(m.rawValue, systemImage: themeSymbol(m))
                        }
                    }
                } label: {
                    Label(env.mode.rawValue, systemImage: themeSymbol(env.mode))
                }
                .help("Theme")
                Button {
                    showingConfig.toggle()
                } label: {
                    Label("Config", systemImage: "slider.horizontal.3")
                }
                .help("Source, time/temperature format, theme tuning")
                .popover(isPresented: $showingConfig,
                         arrowEdge: .bottom) {
                    ConfigPanel().environmentObject(env)
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    env.forceClock.toggle()
                } label: {
                    Label("Clock",
                          systemImage: env.forceClock ? "clock.fill" : "clock")
                        .foregroundStyle(env.forceClock ? Color.accentColor : .primary)
                }
                .help("Force the clock fallback regardless of active session")
                Picker("Rotation", selection: $env.rotation) {
                    ForEach(AppEnvironment.DisplayRotation.allCases) { r in
                        Text(r.label).tag(r)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
                .help("Rotation applied to the LCD output")
                Toggle(isOn: $env.flipHorizontal) {
                    Label("Flip H", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                }
                .toggleStyle(.button)
                .help("Mirror the LCD frame horizontally")
                Toggle(isOn: $env.flipVertical) {
                    Label("Flip V", systemImage: "arrow.up.and.down.righttriangle.up.righttriangle.down")
                }
                .toggleStyle(.button)
                .help("Mirror the LCD frame vertically")
            }
        }
    }

    private func sanitized(_ size: CGSize) -> CGSize {
        CGSize(width: max(1, size.width.isFinite ? size.width : 1),
               height: max(1, size.height.isFinite ? size.height : 1))
    }

    private func themeSymbol(_ mode: AppEnvironment.RenderMode) -> String {
        switch mode {
        case .matrixDashboard: return "terminal"
        case .cozy: return "leaf"
        case .wowAlliance: return "shield.lefthalf.filled"
        case .wowHorde: return "flame"
        case .animalCrossing: return "tree"
        case .dragonball: return "circle.hexagongrid"
        }
    }
}
