"""CLI entry — `python -m agent_dashboard`.

Flags:
  --mirror      Show the dashboard in a window on the desktop in addition to
                pushing to the LCD (useful when developing on the Pi itself).
  --no-lcd      Skip the LCD push — render to a window only.
  --fps N       Render+push framerate. Default 15. The Trofeo Vision is USB
                Hi-Speed; 15 fps × ~120 KB JPEG ≈ 1.8 MB/s, plenty of headroom.
  --sim-ms N    Demo state-machine tick interval. Default 380 (matches JSX).
  --quality N   JPEG quality 1-100. Default 85.
"""

from __future__ import annotations

import argparse
import sys

from .app import run


def main() -> int:
    p = argparse.ArgumentParser(prog="agent-dashboard")
    p.add_argument("--source", choices=["demo", "claude-code"], default="claude-code",
                   help="telemetry source (default: claude-code if available, else demo)")
    p.add_argument("--mirror", action="store_true", help="also show window on desktop")
    p.add_argument("--no-lcd", action="store_true", help="don't push to LCD")
    p.add_argument("--fps", type=int, default=15)
    p.add_argument("--sim-ms", type=int, default=380)
    p.add_argument("--quality", type=int, default=85)
    args = p.parse_args()
    # auto-fallback to demo if claude-code requested but projects dir is missing
    source = args.source
    if source == "claude-code":
        from pathlib import Path
        if not (Path.home() / ".claude" / "projects").is_dir():
            print("note: ~/.claude/projects not found — falling back to demo")
            source = "demo"
    return run(
        source=source,
        mirror=args.mirror,
        no_lcd=args.no_lcd,
        fps=args.fps,
        sim_ms=args.sim_ms,
        jpeg_quality=args.quality,
    )


if __name__ == "__main__":
    sys.exit(main())
