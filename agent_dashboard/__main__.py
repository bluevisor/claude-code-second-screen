"""CLI entry — `python -m agent_dashboard`.

Flags:
  --mirror      Show the dashboard in a window on the desktop in addition to
                pushing to the LCD (useful when developing on the Pi itself).
  --no-lcd      Skip the LCD push — render to a window only.
  --fps N       Render+push framerate. Default 15. The Trofeo Vision is USB
                Hi-Speed; 15 fps × ~120 KB JPEG ≈ 1.8 MB/s, plenty of headroom.
  --sim-ms N    Demo state-machine tick interval. Default 380 (matches JSX).
  --quality N   JPEG quality 1-100. Default 85.
  --stats       Log measured render/JPEG/LCD timings every 5 seconds.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from .telemetry.claude_code import PROJECTS_DIR
from .telemetry.codex import SESSIONS_DIR


def _newest_jsonl_mtime(root: Path) -> float:
    if not root.is_dir():
        return -1.0
    newest = -1.0
    for p in root.rglob("*.jsonl"):
        try:
            newest = max(newest, p.stat().st_mtime)
        except OSError:
            continue
    return newest


def _resolve_source(source: str) -> str:
    if source == "auto":
        claude_mtime = _newest_jsonl_mtime(PROJECTS_DIR)
        codex_mtime = _newest_jsonl_mtime(SESSIONS_DIR)
        if claude_mtime < 0 and codex_mtime < 0:
            print("note: no Claude Code or Codex sessions found — falling back to demo")
            return "demo"
        return "codex" if codex_mtime >= claude_mtime else "claude-code"
    if source == "claude-code" and not PROJECTS_DIR.is_dir():
        print("note: ~/.claude/projects not found — falling back to demo")
        return "demo"
    if source == "codex" and not SESSIONS_DIR.is_dir():
        print("note: ~/.codex/sessions not found — falling back to demo")
        return "demo"
    return source


def main() -> int:
    p = argparse.ArgumentParser(prog="agent-dashboard")
    p.add_argument("--source", choices=["auto", "demo", "claude-code", "codex"], default="auto",
                   help="telemetry source (default: newest Claude Code/Codex session, else demo)")
    p.add_argument("--demo-agent", choices=["claude-code", "codex", "hermes", "agy"], default="claude-code",
                   help="agent profile used with --source demo")
    p.add_argument("--demo-model", choices=["sonnet45", "opus41", "haiku45", "gpt5", "gemini25"], default="sonnet45",
                   help="model profile used with --source demo")
    p.add_argument("--mirror", action="store_true", help="also show window on desktop")
    p.add_argument("--no-lcd", action="store_true", help="don't push to LCD")
    p.add_argument("--fps", type=int, default=15)
    p.add_argument("--sim-ms", type=int, default=380)
    p.add_argument("--quality", type=int, default=85)
    p.add_argument("--no-rain", action="store_true", help="disable matrix rain for more render headroom")
    p.add_argument("--rain-fps", type=int, default=12, help="max matrix rain update rate (default 12)")
    p.add_argument("--stats", action="store_true", help="log measured render/JPEG/send timings")
    args = p.parse_args()
    source = _resolve_source(args.source)
    from .app import run

    return run(
        source=source,
        mirror=args.mirror,
        no_lcd=args.no_lcd,
        fps=args.fps,
        sim_ms=args.sim_ms,
        jpeg_quality=args.quality,
        demo_agent=args.demo_agent,
        demo_model=args.demo_model,
        show_rain=not args.no_rain,
        rain_fps=args.rain_fps,
        stats=args.stats,
    )


if __name__ == "__main__":
    sys.exit(main())
