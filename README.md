# claude-code-second-screen

Live agent telemetry on a USB second screen. Built for the
[**Thermalright Trofeo Vision LCD**](https://www.thermalright.com/product/trofeo-vision-lcd-black/)
(1280×480, USB-C, VID `0x0416` / PID `0x5302`), running on a Raspberry Pi.

![Matrix theme — live Claude Code session](docs/screenshot-matrix-live.jpg)

Renders the current Claude Code or Codex session's status — what tool is running,
which model, context window fill, rolling 5-hour / 7-day token totals, log of
recent tool calls — directly onto a USB-attached LCD so you can glance at
your agent without alt-tabbing.

The dashboard ships in two modes:

| Mode | Data source | Use it for |
|---|---|---|
| `--source auto` *(default)* | Newest Claude Code or Codex jsonl | Your active local agent session |
| `--source claude-code` | `~/.claude/projects/**/*.jsonl` | Your actual Claude Code session |
| `--source codex` | `~/.codex/sessions/**/*.jsonl` | Your actual Codex session |
| `--source demo` | Built-in state-machine simulator | Showroom / no Claude installed |

## Hardware

- **LCD**: Thermalright Trofeo Vision (or any other [TRCC-supported](https://github.com/Lexonight1/thermalright-trcc-linux) LCD — protocol is auto-detected). 1280×480 is the design target; other resolutions will letterbox or scale.
- **Host**: Linux or macOS box with USB and Python 3.11+. Tested on a Raspberry Pi 5 / arm64 and on macOS.

The LCD handshake and frame-push are handled by the excellent
[`thermalright-trcc-linux`](https://github.com/Lexonight1/thermalright-trcc-linux)
project — see *Credits* below. On Linux it speaks to the LCD via libusb;
on macOS the kernel's `IOHIDFamily` claims HID interfaces and won't release
them, so we go through `hidapi` (IOHIDManager) instead.

## Quick start (Linux)

```bash
# 1. Get TRCC's HID driver + udev rules
sudo apt install pipx libusb-1.0-0 sg3-utils
pipx install trcc-linux
trcc setup -y                # installs udev rules (one sudo prompt)
# unplug/replug the LCD's USB-C cable so the rules take effect

# 2. Get this project (JetBrains Mono TTFs are bundled under OFL 1.1)
git clone https://github.com/bluevisor/claude-code-second-screen.git
cd claude-code-second-screen
python3 -m venv .venv
.venv/bin/pip install -e .

# 3. Run
QT_QPA_PLATFORM=offscreen .venv/bin/python -m agent_dashboard
```

## Quick start (macOS)

```bash
# 1. System libs
brew install hidapi python@3.11

# 2. Get this project
git clone https://github.com/bluevisor/claude-code-second-screen.git
cd claude-code-second-screen
python3.11 -m venv .venv
.venv/bin/pip install -e .

# 3. Run (no udev / no sudo needed — hidapi uses IOHIDManager)
.venv/bin/python -m agent_dashboard
```

The first frame should appear on the LCD within ~2 seconds.

## CLI flags

```
--source {auto,claude-code,codex,demo}  telemetry source (default: newest live session)
--demo-agent {claude-code,codex,...}    demo agent profile
--demo-model {sonnet45,gpt5,...}        demo model profile
--mirror                                also show a window on the desktop
--no-lcd                                don't push to LCD
--fps N                                 render+push framerate (default 15)
--sim-ms N                              demo state-machine tick interval (default 380)
--quality N                             JPEG quality 1-100 (default 85)
--no-rain                               disable matrix rain for more render headroom
--rain-fps N                            max matrix rain update rate (default 12)
--stats                                 log render/JPEG/send timings every 5s
```

## Themes

The handoff bundle described four themes (`matrix`, `fantasy`, `cozy`, `studio`)
but only **matrix** is implemented today.

### Matrix · terminal CRT

The default look. Three-panel grid:

- **Left** — Agent: status verb (`Thinking…` / `Reading…` / `Working…` …), wrapped prompt, tool detail, scrolling log
- **Middle** — Model: name, version, P50/P95 latency, in/out tokens, cache stats, context bar
- **Right** — Quota: 5H / 7D rolling token + cost windows, recent sub-agent invocations

Top rail: agent label, cwd / git-branch / session-id chips, weekday + date.
Footer: last-request / P95 / cache-hit stats, big wall-clock, timezone.

Visual effects: falling katakana glyph rain in the gutters, radial-masked
hairline grid, animated scan-highlight on the activity bar, CRT
interlacing + subtle vignette, blinking cap-aligned caret next to the
status verb.

## Architecture

```
agent_dashboard/
├── __main__.py          # CLI
├── app.py               # QApplication + render loop (renders → JPEG → LCD)
├── fonts.py             # Loads bundled JetBrains Mono into Qt's font DB
├── lcd/
│   └── output.py        # Wraps TRCC's HidDeviceType2 + PyUsbTransport
├── telemetry/
│   ├── types.py         # AgentTelemetry dataclasses
│   ├── demo.py          # State-machine simulator (port of useTelemetryDemo)
│   ├── claude_code.py   # Tails ~/.claude/projects/**/*.jsonl
│   └── codex.py         # Tails ~/.codex/sessions/**/*.jsonl
└── themes/
    ├── matrix.py        # Matrix theme widget (QPainter)
    └── matrix_fx.py     # Rain painter, masked grid, glow-text helper
```

The render loop is a `QTimer` ticking at `--fps`: it calls `widget.render(QImage)`
to capture an offscreen 1280×480 image, encodes JPEG, and hands it to
`HidDeviceType2.send_frame()` which the LCD JPEG-detects via the `FF D8`
magic bytes. The app reuses the offscreen frame and JPEG encoder between
ticks, caches static background/scanline layers, caches model badge scaling,
and throttles the glyph rain with `--rain-fps` so the expensive animation work
does not have to run for every pushed frame. Use `--stats` to see measured
render, JPEG encode, and USB send time.

For Claude Code mode, `ClaudeCodeSource`:

1. On startup, scans every `*.jsonl` under `~/.claude/projects/` mtime'd
   within the last 7 days, accumulating per-event token totals into a deque.
2. On each tick (1 Hz), it `seek()`s past the previously-read offset of the
   active session file and parses only the new lines.
3. Derives `agent.status` from the most recent *meaningful* event (skipping
   `last-prompt` / `permission-mode` / `system` / `file-history-snapshot`
   metadata that Claude Code appends mid-turn): open `tool_use` → `tool`
   with a tool-specific verb (`Reading…`, `Editing…`, `Running…`, etc.);
   trailing `thinking` → `thinking`; recent assistant `text` → `writing`;
   user-string prompt awaiting reply → `processing`; else `idle`.
4. Sums every assistant message's `usage` into cumulative + rolling windows.

For Codex mode, `CodexSource`:

1. Tails the newest rollout under `~/.codex/sessions/**/*.jsonl`.
2. Reads `session_meta` / `turn_context` for cwd, model, and session id.
3. Derives status from unmatched `response_item/function_call` records,
   `function_call_output`, reasoning events, and user/agent messages.
4. Uses `event_msg/token_count` for cumulative, current-context, and rolling
   5-hour / 7-day token totals.

## Limitations

- **Matrix is the only theme.** Fantasy / Cozy / Studio (from the handoff
  bundle) aren't ported.
- **No live rate-limit data.** Claude Code's jsonl doesn't carry the API
  rate-limit response headers, so the dashboard relies on rolling token
  totals it computes itself. (A future MITM proxy could surface real
  `requests_remaining_min` / `tokens_remaining_min`.)
- **Quota caps are auto-scaled** from observed usage rather than your
  actual plan limits. Adjust `cap_5h` / `cap_7d` in
  `telemetry/claude_code.py` if you want hard targets.
- **5H cost is hidden on subscription plans.** When `quota.plan` starts
  with `MAX` / `PRO` / `FREE` / `TEAM` the footer skips the dollar tally
  since flat-fee billing makes the per-request total noise.
- **Sub-agent panel populates only for Claude Code Agent/Task calls.**
  Codex sessions don't surface an equivalent event today.
- **Latency is a proxy** computed from inter-event timestamps in the
  jsonl, which includes human idle time. Don't read p95 as wall-clock API
  latency.
- **Single active session.** The dashboard always shows the
  most-recently-modified jsonl for the selected source. In `--source auto`,
  the focus switches to whichever of Claude Code or Codex has the newest
  session file.

## Credits

- **[thermalright-trcc-linux](https://github.com/Lexonight1/thermalright-trcc-linux)**
  by Lexonight1 — the reverse-engineered HID protocol that makes this LCD
  controllable from Linux at all. Massive thanks; without it this project
  doesn't exist.
- **[claude.ai/design](https://claude.ai/design)** — the dashboard's visual
  design started as a Claude Design handoff bundle, recreated in native Qt.
- **[JetBrains Mono](https://www.jetbrains.com/lp/mono/)** — bundled under
  the SIL Open Font License 1.1.

## License

[MIT](LICENSE).
