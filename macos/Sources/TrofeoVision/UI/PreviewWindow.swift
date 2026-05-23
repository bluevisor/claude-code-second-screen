// Desktop mirror of what's currently being pushed to the LCD.
// Aspect-fits the 1280×480 frame and clamps to the window size.

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
    }
}
