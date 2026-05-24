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
        // Preview shows the raw rendered canvas — portrait when the
        // user is in a 90°/270° rotation, landscape otherwise.
        let aspect: CGFloat = env.rotation.isPortrait ? 480.0 / 1280.0
                                                      : 1280.0 / 480.0
        ZStack {
            Color.black
            if let cg = env.lastFramePreview {
                // Resizable + aspectRatio is enough — the image fills the
                // available container while preserving aspect. Previously
                // this was wrapped in GeometryReader and given an explicit
                // .frame(width:height:) tied to the proxy size; that
                // combination over-constrained the layout and triggered
                // "layoutSubtreeIfNeeded on a view already being laid out"
                // when the aspect ratio flipped between portrait and
                // landscape.
                Image(decorative: cg, scale: 1, orientation: .up)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(aspect, contentMode: .fit)
            } else {
                ProgressView("Waiting for first frame…")
                    .controlSize(.small)
                    .tint(.green)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minWidth: 640, minHeight: 240)
        .navigationTitle("NeoDashboard · Live Preview")
        // Tell FrameLoop whether to bother publishing the per-frame
        // CGImage. When this window is closed, nothing is reading it.
        // The flips are dispatched to a later runloop tick so they
        // never land mid-view-update — onAppear / onDisappear can be
        // delivered while SwiftUI is still walking the scene graph
        // (e.g. when activation policy changes during a CoreLocation
        // prompt), and a synchronous @Published write there trips
        // "Publishing changes from within view updates is not allowed".
        .onAppear {
            Task { @MainActor in env.previewWindowVisible = true }
        }
        .onDisappear {
            Task { @MainActor in env.previewWindowVisible = false }
        }
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
                // Explicitly read the two underlying @Published values
                // here so SwiftUI's dependency tracker subscribes the
                // toolbar to both — relying only on the computed
                // `env.wantsClock` left the view stale after telemetry
                // updates because tracking through a non-@Published
                // computed property isn't always picked up.
                let _ = env.clockMode
                let _ = env.telemetry.hasContent
                let showingClock = env.wantsClock
                Button {
                    env.clockMode = showingClock ? .off : .on
                } label: {
                    Label("Clock",
                          systemImage: showingClock ? "clock.fill" : "clock")
                        .foregroundStyle(showingClock ? Color.accentColor : .primary)
                }
                .help("Toggle the clock face. Reflects the actual displayed mode — the auto-fallback when no session is active also shows the button as on.")
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
