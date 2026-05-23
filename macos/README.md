# Trofeo Vision (macOS)

Native macOS menu-bar app that drives the Thermalright Trofeo Vision USB LCD
with live Claude Code / Codex / agy telemetry. Replaces the Python sibling
project at the repo root.

- Swift 6 / SwiftUI 5 / AppKit, no Python.
- Lives in the menu bar (`LSUIElement`); no Dock icon.
- Talks to the LCD directly via `IOHIDManager` (no kext, no Rosetta, no
  homebrew dependencies). Implements the TRCC Type 2 protocol — handshake,
  resolution probe, JPEG frame push over 512-byte HID output reports.
- Optional desktop preview window mirrors what's pushed to the LCD.
- Settings: source (Claude Code / Demo), plan label, target FPS,
  matrix rain toggle, push-to-LCD toggle.

## Build & run

Requires Xcode 26 (or any Xcode that ships Swift 6.0+) and
[XcodeGen](https://github.com/yonaskolb/XcodeGen):

```fish
brew install xcodegen
cd macos
xcodegen                       # writes TrofeoVision.xcodeproj
xcodebuild -project TrofeoVision.xcodeproj \
           -scheme TrofeoVision \
           -configuration Debug \
           -derivedDataPath build
open build/Build/Products/Debug/TrofeoVision.app
```

The app appears as a menu-bar icon. Click it for the popover; choose
**Show Preview…** to open a live mirror window or **Settings…** for
preferences.

## Project layout

```
macos/
├── project.yml                       # XcodeGen spec
├── Resources/
│   ├── Info.plist
│   ├── TrofeoVision.entitlements
│   ├── fonts/                        # JetBrains Mono variants (TTF)
│   └── icons/                        # anthropic-figure.png, openai-logo.png
└── Sources/TrofeoVision/
    ├── TrofeoVisionApp.swift         # @main + MenuBarExtra wiring
    ├── App/
    │   ├── AppEnvironment.swift      # ObservableObject — shared state
    │   └── FrameLoop.swift           # render+push loop, off-main work
    ├── UI/
    │   ├── MenuBarContent.swift      # popover UI
    │   ├── PreviewWindow.swift       # desktop mirror
    │   └── SettingsView.swift        # Cmd-, settings
    ├── Telemetry/
    │   ├── Models.swift              # Agent, Model, Quota, …
    │   ├── TelemetrySource.swift     # protocol
    │   ├── ClaudeCodeSource.swift    # tails ~/.claude/projects/**/*.jsonl
    │   └── DemoSource.swift          # for previews + screenshots
    ├── Render/
    │   ├── MatrixTheme.swift         # palette, font registration
    │   ├── MatrixRenderer.swift      # 1280×480 CoreGraphics painter
    │   ├── RainPainter.swift         # falling katakana background
    │   └── JPEGEncoder.swift         # CGImage → JPEG Data via ImageIO
    └── LCD/
        ├── LCDOutput.swift           # protocol + in-memory preview
        ├── TrofeoVisionDriver.swift  # IOHIDManager Type 2 driver
        └── TRCCFraming.swift         # pure byte plumbing for handshake/frame
```

## TRCC Type 2 protocol notes

Reverse-engineered from
[`thermalright-trcc-linux`](https://github.com/Lexonight1/thermalright-trcc-linux).
Trofeo Vision identifies as **VID `0x0416` / PID `0x5302`**, decodes JPEG
frames natively, and accepts data over a single HID output report (`reportID
= 0`, 512 bytes per chunk).

### Handshake

```
out: DA DB DC DD 00 00 00 00 00 00 00 00  01 00 00 00  00 00 00 00 | …pad → 512B
in:  DA DB DC DD ss PP …                                          (resp[12] == 0x01)
```

`PP` is the **PM byte**, `ss` is the **SUB byte**. Together they pick the
FBL → resolution table entry. Trofeo Vision returns `PM = 0x44` → FBL 192 →
(PM=68 disambiguates) **1280 × 480**.

### Frame

```
DA DB DC DD            magic
02 00                  cmd_type = PICTURE
00 00                  mode = JPEG  (LCD detects FF D8 magic in payload)
WW WW                  width  (uint16 LE)
HH HH                  height (uint16 LE)
02 00 00 00            sub-flag
LL LL LL LL            payload length (uint32 LE)
[JPEG payload …]
[zero pad to next 512B multiple]
```

The whole 512-aligned packet is chunked into back-to-back HID output
reports. Firmware reassembles via the length field. A 1ms inter-frame
sleep mirrors `DELAY_FRAME_TYPE2_S` from the C# decompilation.

## What's intentionally left for follow-ups

- **Codex / agy sources** — only Claude Code is wired up today. The
  `TelemetrySource` protocol is built for plug-in extension.
- **Pixel-level visual parity with matrix.py** — the panel layout, fonts,
  palette, and verb logic match; subtle FX (glow blur on the status verb,
  scanlines fade vignette, animated bar scan highlight) need finer polish.
- **Hot-plug + reconnect** — driver opens once at start. If the cable is
  unplugged we currently log the failure; a `IOHIDManagerRegisterDeviceMatchingCallback`
  hook would let us recover automatically.
- **Code-signing / notarization** — built ad-hoc signed for local use.
  Real distribution wants a Developer ID + entitlements review (we already
  list `com.apple.security.device.usb`).

## Dev tips

- The menu-bar icon's tint follows the agent status (green = active,
  amber = idle, red = error). Same convention as the LCD rail LED.
- The Live Preview window keeps rendering even when **Push to LCD** is off
  — useful when working without the LCD plugged in.
- `Console.app` + the subsystem filter `tech.bluevisor.TrofeoVision`
  surfaces all log lines from the driver and frame loop.
