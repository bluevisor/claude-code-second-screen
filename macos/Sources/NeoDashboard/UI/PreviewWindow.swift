// Desktop mirror of what's currently being pushed to the LCD.
// The preview itself always shows the native landscape frame so it's
// readable on screen; the toolbar (pinned to the trailing edge) exposes
// the rotation / flip toggles that affect the LCD in real time.
//
// The hosting NSWindow is locked to the LCD's 1280:480 aspect ratio so
// resizing can't produce letterbox bands around the rendered frame.

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
        .background(LCDWindowAspectLock())
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

/// Walks up to the hosting NSWindow and pins its content-resize aspect to
/// the LCD's 1280:480 so the rendered frame fills the content area exactly
/// (no black letterbox bands). Re-snaps on every `didResize` because
/// SwiftUI's autosave + toolbar-width minimums can otherwise leave the
/// content area wider than the locked aspect ratio.
private struct LCDWindowAspectLock: NSViewRepresentable {
    final class Coordinator {
        static let ratio: CGFloat = 1280.0 / 480.0
        weak var boundWindow: NSWindow?
        var observer: NSObjectProtocol?

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }

        func bind(_ view: NSView) {
            guard let window = view.window, window !== boundWindow else {
                if boundWindow != nil { snap(window: boundWindow) }
                return
            }
            boundWindow = window
            window.contentAspectRatio = NSSize(width: 1280, height: 480)
            snap(window: window)
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification,
                object: window, queue: .main
            ) { [weak self] _ in
                self?.snap(window: window)
            }
        }

        func snap(window: NSWindow?) {
            guard let window else { return }
            // `contentLayoutRect` is the SwiftUI-visible area excluding the
            // titlebar/toolbar band that sits over the content view in
            // unified style. We size against THIS to keep the rendered
            // dashboard meeting the window edges with no letterboxing.
            let safe = window.contentLayoutRect.size
            let content = window.contentRect(forFrameRect: window.frame).size
            guard safe.height > 0, content.height > 0 else { return }
            let inset = content.height - safe.height       // titlebar height
            let aspect = safe.width / safe.height
            // 2 px tolerance — setContentSize ripples back through didResize
            // and we'd otherwise oscillate by sub-pixel rounding.
            guard abs(safe.width - safe.height * Self.ratio) > 2 else { return }
            let targetSafe: NSSize
            if aspect > Self.ratio {
                targetSafe = NSSize(width: safe.height * Self.ratio,
                                    height: safe.height)
            } else {
                targetSafe = NSSize(width: safe.width,
                                    height: safe.width / Self.ratio)
            }
            window.setContentSize(NSSize(width: targetSafe.width,
                                         height: targetSafe.height + inset))
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { context.coordinator.bind(v) }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { context.coordinator.bind(nsView) }
    }
}
