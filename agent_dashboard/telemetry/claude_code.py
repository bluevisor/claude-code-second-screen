"""Live Claude Code telemetry source.

Tails the newest session jsonl under ~/.claude/projects/, derives the
AgentTelemetry shape from the event stream. Produces the same Telemetry
object the matrix theme renders — drop-in replacement for DemoSimulator.

Per TELEMETRY.md, fields are derived as follows (with pragmatic fallbacks
when a value isn't in the jsonl):

  agent.status        last event timestamp + open tool_use detection
  agent.currentTask   most recent string-content user message
  agent.currentTool   tool_use in last assistant w/o matching tool_result
  agent.log[]         derived from recent user/assistant events
  agent.turn          count of user-string messages
  agent.filesRead     count of Read/read_file tool_use blocks
  agent.filesEdited   count of Edit/Write tool_use blocks
  model.id            last assistant message.model
  model.contextUsed   last assistant usage.input + cache_read + cache_create
  model.<tok totals>  cumulative across all assistant.usage
  model.p*Ms          rolling latencies between consecutive events
  quota.windows       rolling sums over the last 5h / 7d
  server.*            mostly placeholders — jsonl doesn't carry rate headers
"""

from __future__ import annotations

import json
import logging
import os
import re
import subprocess
import time
from collections import deque
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .demo import now_hms
from .types import (
    Agent,
    LogEntry,
    Model,
    Quota,
    QuotaWindow,
    Server,
    SubAgent,
    Telemetry,
)

log = logging.getLogger(__name__)

PROJECTS_DIR = Path.home() / ".claude" / "projects"


# ─── model metadata ───────────────────────────────────────────────────────

# (ctx_max, pricing_in_per_mtok, pricing_out_per_mtok)
_MODEL_PRICING: dict[str, tuple[int, float, float]] = {
    "opus":   (200_000, 15.00, 75.00),
    "sonnet": (200_000,  3.00, 15.00),
    "haiku":  (200_000,  0.80,  4.00),
}


def _parse_model_id(model_id: str) -> tuple[str, str, str, int, float, float]:
    """claude-opus-4-7 → ('CLAUDE OPUS', '4.7', 'opus', 200000, 15.0, 75.0)."""
    m = re.match(r"claude-(opus|sonnet|haiku)-(\d+)(?:-(\d+))?", model_id or "")
    if not m:
        return ("CLAUDE", "?", "opus", 200_000, 15.00, 75.00)
    family, maj, min_ = m.groups()
    version = f"{maj}.{min_}" if min_ else maj
    ctx, pin, pout = _MODEL_PRICING.get(family, _MODEL_PRICING["opus"])
    return (f"CLAUDE {family.upper()}", version, family, ctx, pin, pout)


# ─── jsonl helpers ────────────────────────────────────────────────────────


def _find_newest_session() -> Path | None:
    """Pick the most recently modified jsonl under PROJECTS_DIR."""
    if not PROJECTS_DIR.is_dir():
        return None
    newest = None
    newest_mtime = -1.0
    for p in PROJECTS_DIR.rglob("*.jsonl"):
        try:
            mt = p.stat().st_mtime
        except OSError:
            continue
        if mt > newest_mtime:
            newest_mtime = mt
            newest = p
    return newest


def _git_dirty(cwd: str) -> bool:
    try:
        out = subprocess.run(
            ["git", "-C", os.path.expanduser(cwd), "status", "--porcelain"],
            capture_output=True, text=True, timeout=1.5,
        )
        return out.returncode == 0 and bool(out.stdout.strip())
    except (OSError, subprocess.TimeoutExpired):
        return False


def _short_session_id(uuid_str: str) -> str:
    s = uuid_str.replace("-", "").upper()
    return f"{s[:4]}-{s[-4:]}"


def _iso_to_ts(s: str) -> float:
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
    except Exception:
        return 0.0


# ─── source ────────────────────────────────────────────────────────────────


class ClaudeCodeSource:
    """Live source — tails the newest session jsonl and produces Telemetry.

    Usage matches DemoSimulator:
        src = ClaudeCodeSource()
        tel = src.tick()  # call periodically; returns latest Telemetry
    """

    def __init__(self) -> None:
        self._jsonl: Path | None = None
        self._offset = 0
        self._events: list[dict[str, Any]] = []
        self._latencies_ms: deque[float] = deque(maxlen=64)
        # per-event tokens for rolling-window quota
        self._token_history: deque[tuple[float, float, float, float, float]] = deque()
        # ↑ (timestamp, in, out, cache_read, cache_create)
        self._log_id = 0
        self._last_status: str = "idle"
        self._status_started: float = time.time()
        self._scanned_other_sessions = False

    # ── public API ───────────────────────────────────────────────────────

    def tick(self) -> Telemetry:
        self._refresh_active_file()
        self._tail_new_lines()
        if not self._scanned_other_sessions:
            self._bootstrap_token_history_from_other_sessions()
            self._scanned_other_sessions = True
        return self._build_telemetry()

    # ── jsonl tracking ───────────────────────────────────────────────────

    def _refresh_active_file(self) -> None:
        newest = _find_newest_session()
        if newest is None:
            return
        if newest != self._jsonl:
            log.info("active session: %s", newest)
            self._jsonl = newest
            self._offset = 0
            self._events.clear()
            self._latencies_ms.clear()

    def _tail_new_lines(self) -> None:
        if self._jsonl is None or not self._jsonl.exists():
            return
        try:
            size = self._jsonl.stat().st_size
        except OSError:
            return
        if size < self._offset:
            # file truncated/rotated
            self._offset = 0
            self._events.clear()
        if size == self._offset:
            return
        try:
            with self._jsonl.open("rb") as f:
                f.seek(self._offset)
                chunk = f.read()
            self._offset = self._jsonl.stat().st_size
        except OSError as e:
            log.warning("tail failed: %s", e)
            return

        prev_ts: float | None = None
        if self._events:
            prev_ts = _iso_to_ts(self._events[-1].get("timestamp", ""))

        for raw in chunk.splitlines():
            if not raw.strip():
                continue
            try:
                ev = json.loads(raw)
            except json.JSONDecodeError:
                continue
            self._events.append(ev)
            ts = _iso_to_ts(ev.get("timestamp", ""))
            # track latency between consecutive timestamped events as a proxy
            if ev.get("type") == "assistant" and prev_ts is not None and ts > 0:
                dt_ms = max(0.0, (ts - prev_ts) * 1000.0)
                if 50 < dt_ms < 300_000:
                    self._latencies_ms.append(dt_ms)
            if ts > 0:
                prev_ts = ts
            # token history for rolling windows
            if ev.get("type") == "assistant":
                u = (ev.get("message") or {}).get("usage") or {}
                in_t = float(u.get("input_tokens", 0) or 0)
                out_t = float(u.get("output_tokens", 0) or 0)
                cr_t = float(u.get("cache_read_input_tokens", 0) or 0)
                cc_t = float(u.get("cache_creation_input_tokens", 0) or 0)
                if ts > 0 and (in_t + out_t + cr_t + cc_t) > 0:
                    self._token_history.append((ts, in_t, out_t, cr_t, cc_t))

    def _bootstrap_token_history_from_other_sessions(self) -> None:
        """One-time scan of all jsonl files for tokens in the 7-day window."""
        if not PROJECTS_DIR.is_dir():
            return
        cutoff = time.time() - 7 * 86400
        added = 0
        for p in PROJECTS_DIR.rglob("*.jsonl"):
            if p == self._jsonl:
                continue
            try:
                if p.stat().st_mtime < cutoff:
                    continue
            except OSError:
                continue
            try:
                with p.open() as f:
                    for line in f:
                        try:
                            ev = json.loads(line)
                        except json.JSONDecodeError:
                            continue
                        if ev.get("type") != "assistant":
                            continue
                        ts = _iso_to_ts(ev.get("timestamp", ""))
                        if ts < cutoff:
                            continue
                        u = (ev.get("message") or {}).get("usage") or {}
                        in_t = float(u.get("input_tokens", 0) or 0)
                        out_t = float(u.get("output_tokens", 0) or 0)
                        cr_t = float(u.get("cache_read_input_tokens", 0) or 0)
                        cc_t = float(u.get("cache_creation_input_tokens", 0) or 0)
                        if (in_t + out_t + cr_t + cc_t) > 0:
                            self._token_history.append((ts, in_t, out_t, cr_t, cc_t))
                            added += 1
            except OSError:
                continue
        # keep history sorted by timestamp
        if added:
            ordered = sorted(self._token_history, key=lambda r: r[0])
            self._token_history.clear()
            self._token_history.extend(ordered)
        log.info("bootstrapped token history: %d events in last 7d", len(self._token_history))

    # ── derivation ───────────────────────────────────────────────────────

    def _build_telemetry(self) -> Telemetry:
        evs = self._events
        if not evs:
            return _empty_telemetry()

        # find last meaningful values
        cwd = ""
        git_branch = ""
        session_uuid = ""
        started_at = ""
        last_model_id = ""
        for ev in evs:
            if "cwd" in ev:
                cwd = ev["cwd"]
            if "gitBranch" in ev:
                git_branch = ev["gitBranch"]
            if "sessionId" in ev:
                session_uuid = ev["sessionId"]
            if not started_at and "timestamp" in ev:
                started_at = ev["timestamp"]
        # last assistant model id
        for ev in reversed(evs):
            if ev.get("type") == "assistant":
                last_model_id = (ev.get("message") or {}).get("model") or last_model_id
                if last_model_id:
                    break

        name, version, family, ctx_max, pin, pout = _parse_model_id(last_model_id)

        # current task — most recent user-string message
        current_task = ""
        for ev in reversed(evs):
            if ev.get("type") != "user":
                continue
            c = (ev.get("message") or {}).get("content")
            if isinstance(c, str) and c.strip():
                current_task = c.strip()
                break
            if isinstance(c, list):
                # may be tool_result; skip
                pass
        # turn = count of user-string messages
        turn = 0
        for ev in evs:
            if ev.get("type") == "user":
                c = (ev.get("message") or {}).get("content")
                if isinstance(c, str) and c.strip():
                    turn += 1

        # file counts + cumulative token totals + open tool detection
        files_read = 0
        files_edited = 0
        total_in = total_out = total_cr = total_cc = 0.0
        last_assistant_idx = -1
        for i, ev in enumerate(evs):
            if ev.get("type") != "assistant":
                continue
            last_assistant_idx = i
            msg = ev.get("message") or {}
            u = msg.get("usage") or {}
            total_in += float(u.get("input_tokens", 0) or 0)
            total_out += float(u.get("output_tokens", 0) or 0)
            total_cr += float(u.get("cache_read_input_tokens", 0) or 0)
            total_cc += float(u.get("cache_creation_input_tokens", 0) or 0)
            for block in msg.get("content") or []:
                if block.get("type") == "tool_use":
                    name_ = (block.get("name") or "").lower()
                    if name_ in ("read", "read_file", "recall", "query"):
                        files_read += 1
                    elif name_ in ("edit", "write", "apply_patch", "compose"):
                        files_edited += 1

        # latest assistant context = its usage at the moment it was emitted
        ctx_used = 0.0
        if last_assistant_idx >= 0:
            u = ((evs[last_assistant_idx].get("message") or {}).get("usage") or {})
            ctx_used = (
                float(u.get("input_tokens", 0) or 0)
                + float(u.get("cache_read_input_tokens", 0) or 0)
                + float(u.get("cache_creation_input_tokens", 0) or 0)
            )
        # promote context_max when observed usage exceeds the default — handles
        # 1M-context variants whose model ID doesn't carry the `[1m]` suffix.
        if ctx_used > ctx_max:
            ctx_max = 1_000_000 if ctx_used > 200_000 else ctx_max

        # last assistant message → status, tool, detail
        status, current_tool, detail = self._derive_status(evs, last_assistant_idx)
        # progress = abstract ramp since status entered
        if status != self._last_status:
            self._last_status = status
            self._status_started = time.time()
        elapsed = time.time() - self._status_started
        # ramp targets per state
        target = {"thinking": 15, "tool": 20, "writing": 12, "idle": 4, "error": 6}.get(status, 10)
        progress = min(100.0, elapsed / target * 100.0)

        # log entries derived from recent events
        log_entries = self._derive_log(evs)
        sub_agents = self._derive_sub_agents(evs)

        # latencies
        if self._latencies_ms:
            sorted_l = sorted(self._latencies_ms)
            p50 = sorted_l[len(sorted_l) // 2]
            p95 = sorted_l[min(len(sorted_l) - 1, int(len(sorted_l) * 0.95))]
            last_ms = self._latencies_ms[-1]
        else:
            p50 = p95 = last_ms = 0.0

        # rolling 5H / 7D windows
        now_ts = time.time()
        cutoff_5h = now_ts - 5 * 3600
        cutoff_7d = now_ts - 7 * 86400
        used_5h = used_7d = 0.0
        cost_5h = cost_7d = 0.0
        for ts, in_t, out_t, cr_t, cc_t in self._token_history:
            cost = (in_t * pin + out_t * pout + cr_t * pin * 0.10 + cc_t * pin * 1.25) / 1_000_000
            if ts >= cutoff_7d:
                used_7d += in_t + out_t + cr_t + cc_t
                cost_7d += cost
            if ts >= cutoff_5h:
                used_5h += in_t + out_t + cr_t + cc_t
                cost_5h += cost

        # build dataclasses
        agent = Agent(
            kind="claude-code",
            session_id=_short_session_id(session_uuid),
            pid=0,
            cwd=(cwd or "~").replace(str(Path.home()), "~"),
            git_branch="" if git_branch in ("HEAD", "") else git_branch,
            git_dirty=_git_dirty(cwd) if cwd else False,
            started_at=started_at or datetime.now(timezone.utc).isoformat(),
            status=status,  # type: ignore[arg-type]
            current_task=current_task[:280],
            current_tool=current_tool,
            detail=detail,
            progress=progress,
            turn=turn,
            files_read=files_read,
            files_edited=files_edited,
            log=log_entries,
            sub_agents=sub_agents,
        )
        model = Model(
            id=last_model_id or "claude",
            name=name, version=version, provider="anthropic",
            context_used=ctx_used, context_max=ctx_max,
            input_tokens=total_in, output_tokens=total_out,
            cache_read_tokens=total_cr, cache_write_tokens=total_cc,
            p50_ms=p50, p95_ms=p95, last_request_ms=last_ms,
        )
        # cap heuristic: round observed peak up to a nice number — keeps the bar
        # readable for Max-plan users whose actual budgets are much higher than
        # the stock JSX defaults.
        cap_5h = max(2_500_000, _ceil_nice(used_5h * 1.3))
        cap_7d = max(35_000_000, _ceil_nice(used_7d * 1.3))
        quota = Quota(
            plan="MAX 20×",
            pricing_in_per_mtok=pin,
            pricing_out_per_mtok=pout,
            windows=[
                QuotaWindow(label="5H", used=used_5h, cap=cap_5h, cost_usd=cost_5h, reset_in_sec=int(max(0, 5 * 3600 - elapsed))),
                QuotaWindow(label="7D", used=used_7d, cap=cap_7d, cost_usd=cost_7d, reset_in_sec=7 * 86400),
            ],
        )
        server = Server(
            provider_label="ANTHROPIC API",
            status="operational",
            tokens_remaining_min=0, tokens_limit_min=0,
            requests_remaining_min=0, requests_limit_min=0,
            reset_in_sec=0, retries_hour=0, errors_hour=0, queued_requests=0,
        )
        return Telemetry(agent=agent, model=model, quota=quota, server=server, source="LIVE")

    # ── per-event derivations ────────────────────────────────────────────

    # Claude Code appends `last-prompt` and `permission-mode` events to the
    # jsonl as a turn progresses — they're session metadata, not agent state.
    # Treating them as "the last event" makes our status fall through to idle
    # while the assistant is actively working.
    _META_TYPES: frozenset[str] = frozenset({
        "last-prompt", "permission-mode", "summary", "system",
    })

    def _derive_status(self, evs: list[dict[str, Any]], last_assistant_idx: int) -> tuple[str, str | None, str]:
        """Return (status, current_tool, detail)."""
        if not evs:
            return ("idle", None, "no events")

        # Find the most recent non-meta event.
        last: dict[str, Any] | None = None
        for ev in reversed(evs):
            if ev.get("type") not in self._META_TYPES:
                last = ev
                break
        if last is None:
            return ("processing", None, "processing prompt")
        last_t = last.get("type")

        # User-event handling — covers both the new-prompt gap (string
        # content, no assistant reply yet → "Processing…") and the
        # tool-result return (list content → "Thinking…", parsing result).
        if last_t == "user":
            c = (last.get("message") or {}).get("content")
            if isinstance(c, str) and c.strip():
                return ("processing", None, "processing prompt")
            if isinstance(c, list):
                return ("thinking", None, "parsing tool result")
            return ("thinking", None, "parsing request context")

        # if last event is an assistant with a tool_use block, and no later
        # user.tool_result for that tool_use_id yet, status=tool.
        if last_t == "assistant":
            msg = last.get("message") or {}
            open_tool: str | None = None
            for block in (msg.get("content") or [])[::-1]:
                if block.get("type") == "tool_use":
                    open_tool = block.get("name")
                    break
            if open_tool:
                # find the input target for nicer detail text
                target = ""
                for block in (msg.get("content") or [])[::-1]:
                    if block.get("type") == "tool_use" and block.get("name") == open_tool:
                        inp = block.get("input") or {}
                        target = (inp.get("file_path") or inp.get("path")
                                  or inp.get("command") or inp.get("pattern") or "")
                        if isinstance(target, str):
                            target = target.replace(str(Path.home()), "~")[:48]
                        break
                return ("tool", open_tool, target or "running")
            # last block was text or thinking
            kinds = [b.get("type") for b in (msg.get("content") or [])]
            if kinds and kinds[-1] == "thinking":
                return ("thinking", None, "reasoning")
            # else assistant just emitted text — if recent, still writing; else idle
            ts = _iso_to_ts(last.get("timestamp", ""))
            if ts > 0 and (time.time() - ts) < 3:
                return ("writing", None, "drafting response")
            return ("idle", None, "awaiting next directive")

        return ("idle", None, "—")

    def _derive_log(self, evs: list[dict[str, Any]]) -> list[LogEntry]:
        """Build log[] (newest first, ≤30) from recent events."""
        out: list[LogEntry] = []
        idn = 0
        # walk newest → oldest, emit log lines, stop at 30
        for ev in reversed(evs):
            if len(out) >= 30:
                break
            t = ev.get("type")
            ts_iso = ev.get("timestamp", "")
            try:
                ts = (
                    datetime.fromisoformat(ts_iso.replace("Z", "+00:00"))
                    .astimezone()  # UTC → local wall-clock so logs match the user's clock
                    .strftime("%H:%M:%S")
                )
            except Exception:
                ts = "--:--:--"
            if t == "user":
                c = (ev.get("message") or {}).get("content")
                if isinstance(c, str) and c.strip():
                    idn += 1
                    out.append(LogEntry(id=idn, ts=ts, tag="info", msg=f"prompt.received  →  {c.strip()[:42]}"))
                elif isinstance(c, list):
                    for block in c:
                        if block.get("type") == "tool_result":
                            is_err = block.get("is_error")
                            res = block.get("content")
                            if isinstance(res, list):
                                snippet = " ".join((b.get("text") or "")[:60] for b in res if isinstance(b, dict) and b.get("type") == "text")
                            else:
                                snippet = str(res or "")[:60]
                            idn += 1
                            out.append(LogEntry(
                                id=idn, ts=ts,
                                tag="err" if is_err else "ok",
                                msg=("tool.error  " if is_err else "tool.result  ") + snippet.strip().replace("\n", " "),
                            ))
                            break
            elif t == "assistant":
                msg = ev.get("message") or {}
                tool_blocks = [b for b in (msg.get("content") or []) if b.get("type") == "tool_use"]
                if tool_blocks:
                    for b in tool_blocks:
                        nm = b.get("name") or ""
                        inp = b.get("input") or {}
                        target = (inp.get("file_path") or inp.get("path") or inp.get("command") or inp.get("pattern") or "")
                        if isinstance(target, str) and target:
                            target = target.replace(str(Path.home()), "~")[:42]
                        idn += 1
                        out.append(LogEntry(id=idn, ts=ts, tag="info", msg=f"tool.call  {nm}  {target}".strip()))
        # we walked newest→oldest; that's already the desired order (log[0] = newest)
        return out

    def _derive_sub_agents(self, evs: list[dict[str, Any]]) -> list[SubAgent]:
        """Extract Claude Code Agent tool invocations and their live status.

        An ``Agent`` tool_use spawns a sub-agent; the matching ``tool_result``
        (by ``tool_use_id``) signals completion. We pair them and return the
        most-recent entries newest-first, capped at 8.
        """
        # First pass: collect tool_result blocks keyed by tool_use_id.
        results: dict[str, dict[str, Any]] = {}
        for ev in evs:
            if ev.get("type") != "user":
                continue
            content = (ev.get("message") or {}).get("content")
            if not isinstance(content, list):
                continue
            for block in content:
                if block.get("type") == "tool_result":
                    tid = block.get("tool_use_id")
                    if tid:
                        results[tid] = block

        # Second pass: pull Agent tool_use blocks, pair with results.
        found: list[SubAgent] = []
        for ev in evs:
            if ev.get("type") != "assistant":
                continue
            msg = ev.get("message") or {}
            ts = ev.get("timestamp", "")
            for block in msg.get("content") or []:
                if block.get("type") != "tool_use":
                    continue
                if (block.get("name") or "") not in ("Agent", "Task"):
                    continue
                tid = block.get("id") or ""
                inp = block.get("input") or {}
                res = results.get(tid)
                if res is None:
                    status = "running"
                elif res.get("is_error"):
                    status = "error"
                else:
                    status = "done"
                found.append(SubAgent(
                    tool_use_id=tid,
                    subagent_type=str(inp.get("subagent_type") or "general"),
                    description=str(inp.get("description") or "")[:60],
                    status=status,  # type: ignore[arg-type]
                    started_at=ts,
                ))

        # Newest first, cap at 8. Sort running first so live work stays visible.
        found.reverse()
        running = [s for s in found if s.status == "running"]
        finished = [s for s in found if s.status != "running"]
        return (running + finished)[:8]


def _ceil_nice(n: float) -> int:
    """Round n up to a nice 1/2/5 × 10^k value (for chart axis caps)."""
    if n <= 0:
        return 1
    import math
    k = math.floor(math.log10(n))
    base = 10 ** k
    for mult in (1, 2, 5, 10):
        v = mult * base
        if v >= n:
            return int(v)
    return int(10 * base)


def _empty_telemetry() -> Telemetry:
    """Returned when there are no events yet — keeps the dashboard sane."""
    now_iso = datetime.now(timezone.utc).isoformat()
    return Telemetry(
        agent=Agent(
            kind="claude-code", session_id="----", pid=0, cwd="~",
            git_branch="", git_dirty=False, started_at=now_iso,
            status="idle", current_task="(no session yet)",
            current_tool=None, detail="waiting for session jsonl",
            progress=0, turn=0, files_read=0, files_edited=0,
            log=[LogEntry(id=1, ts=now_hms(), tag="info", msg="watching ~/.claude/projects/")],
        ),
        model=Model(
            id="-", name="—", version="-", provider="anthropic",
            context_used=0, context_max=200_000,
            input_tokens=0, output_tokens=0, cache_read_tokens=0, cache_write_tokens=0,
            p50_ms=0, p95_ms=0, last_request_ms=0,
        ),
        quota=Quota(
            plan="MAX 20×", pricing_in_per_mtok=3.0, pricing_out_per_mtok=15.0,
            windows=[
                QuotaWindow(label="5H", used=0, cap=2_500_000, cost_usd=0.0, reset_in_sec=5 * 3600),
                QuotaWindow(label="7D", used=0, cap=35_000_000, cost_usd=0.0, reset_in_sec=7 * 86400),
            ],
        ),
        server=Server(
            provider_label="ANTHROPIC API", status="operational",
            tokens_remaining_min=0, tokens_limit_min=0,
            requests_remaining_min=0, requests_limit_min=0,
            reset_in_sec=0, retries_hour=0, errors_hour=0, queued_requests=0,
        ),
        source="LIVE",
    )
