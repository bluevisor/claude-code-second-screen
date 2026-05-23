// Desktop mirror of what's currently being pushed to the LCD.
// The preview itself always shows the native landscape frame so it's
// readable on screen; the toolbar (pinned to the trailing edge) exposes
// the rotation / flip toggles that affect the LCD in real time.

import AppKit
import SwiftUI

struct PreviewWindow: View {
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black
                if let cg = env.lastFramePreview {
                    Image(decorative: cg, scale: 1, orientation: .up)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(1280.0 / 480.0, contentMode: .fit)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                } else {
                    ProgressView("Waiting for first frame…")
                        .controlSize(.small)
                        .tint(.green)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .navigationTitle("Trofeo Vision · Live Preview")
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Picker("Mode", selection: $env.mode) {
                    ForEach(AppEnvironment.RenderMode.allCases) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 110)
                .help("Which dashboard to show on the LCD")
                .onChange(of: env.mode) { _, _ in env.loop?.reconfigure() }
            }
            ToolbarItemGroup(placement: .primaryAction) {
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
}
