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
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Picker("Mode", selection: $env.mode) {
                    ForEach(AppEnvironment.RenderMode.allCases) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 150)
                .help("Which dashboard to show on the LCD")
                .onChange(of: env.mode) { _, _ in env.loop?.reconfigure() }
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
}
