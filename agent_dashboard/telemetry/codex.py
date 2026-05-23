"""Live Codex telemetry source.

Tails the newest rollout jsonl under ~/.codex/sessions/ and derives the same
Telemetry object used by the matrix theme. Codex rollouts differ from Claude
Code sessions: conversation state is emitted as top-level ``event_msg`` and
``response_item`` records, with token usage in ``event_msg/token_count``.
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
    Telemetry,
)

log = logging.getLogger(__name__)

SESSIONS_DIR = Path.home() / ".codex" / "sessions"


# (ctx_max, pricing_in_per_mtok, pricing_out_per_mtok)
_MODEL_PRICING: dict[str, tuple[int, float, float]] = {
    "gpt-5.5": (400_000, 2.50, 10.00),
    "gpt-5": (400_000, 2.50, 10.00),
    "gpt-4.1": (1_000_000, 2.00, 8.00),
    "o4-mini": (200_000, 1.10, 4.40),
}

_READ_COMMAND_PREFIXES = (
    "cat ",
    "find ",
    "git diff",
    "git show",
    "git status",
    "head ",
    "jq ",
    "ls",
    "nl ",
    "pwd",
    "rg ",
    "sed ",
    "tail ",
    "wc ",
)
_WRITE_COMMAND_PREFIXES = (
    "git commit",
    "git mv",
    "git push",
    "mv ",
    "npm run format",
    "pnpm format",
    "python -m compileall",
    "ruff ",
)


def _find_newest_session() -> Path | None:
    """Pick the most recently modified Codex rollout jsonl."""
    if not SESSIONS_DIR.is_dir():
        return None
    newest = None
    newest_mtime = -1.0
    for p in SESSIONS_DIR.rglob("*.jsonl"):
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
            capture_output=True,
            text=True,
            timeout=1.5,
        )
        return out.returncode == 0 and bool(out.stdout.strip())
    except (OSError, subprocess.TimeoutExpired):
        return False


def _short_session_id(uuid_str: str) -> str:
    s = uuid_str.replace("-", "").upper()
    if not s:
        return "----"
    return f"{s[:4]}-{s[-4:]}"


def _iso_to_ts(s: str) -> float:
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
    except Exception:
        return 0.0


def _local_hms(ts_iso: str) -> str:
    try:
        return (
            datetime.fromisoformat(ts_iso.replace("Z", "+00:00"))
            .astimezone()
            .strftime("%H:%M:%S")
        )
    except Exception:
        return "--:--:--"


def _parse_model_id(model_id: str, observed_ctx_max: float = 0) -> tuple[str, str, str, int, float, float]:
    raw = model_id or "gpt-5"
    key = raw.lower()
    matched_key = "gpt-5"
    for candidate in sorted(_MODEL_PRICING, key=len, reverse=True):
        if key.startswith(candidate):
            matched_key = candidate
            break
    ctx, pin, pout = _MODEL_PRICING[matched_key]
    if observed_ctx_max > 0:
        ctx = int(observed_ctx_max)

    version_match = re.search(r"(\d+(?:\.\d+)?)", raw)
    version = version_match.group(1) if version_match else "?"
    if key.startswith("o"):
        name = raw.split("-")[0].upper() + (" " + raw.split("-", 1)[1].upper() if "-" in raw else "")
    elif key.startswith("gpt"):
        parts = raw.split("-")
        name = "-".join(parts[:2]).upper() if len(parts) >= 2 else raw.upper()
    else:
        name = raw.upper()
    return (name, version, matched_key, ctx, pin, pout)


def _ceil_nice(n: float) -> int:
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


def _content_text(content: Any) -> str:
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return ""
    parts: list[str] = []
    for block in content:
        if not isinstance(block, dict):
            continue
        text = block.get("text") or block.get("output_text")
        if isinstance(text, str):
            parts.append(text)
    return " ".join(parts).strip()


def _decode_arguments(raw: Any) -> dict[str, Any]:
    if isinstance(raw, dict):
        return raw
    if isinstance(raw, str) and raw.strip():
        try:
            decoded = json.loads(raw)
        except json.JSONDecodeError:
            return {}
        return decoded if isinstance(decoded, dict) else {}
    return {}


def _tool_target(name: str, args: dict[str, Any]) -> str:
    for key in ("cmd", "command", "file_path", "path", "pattern", "query", "workdir"):
        val = args.get(key)
        if isinstance(val, str) and val.strip():
            return val.replace(str(Path.home()), "~")[:64]
    if name == "apply_patch":
        return "patch"
    return ""


def _is_read_call(name: str, args: dict[str, Any]) -> bool:
    if name in {"read_mcp_resource", "view_image"}:
        return True
    if name != "exec_command":
        return False
    cmd = str(args.get("cmd") or "").lstrip()
    return cmd.startswith(_READ_COMMAND_PREFIXES)


def _is_write_call(name: str, args: dict[str, Any]) -> bool:
    if name in {"apply_patch", "write_stdin"}:
        return True
    if name != "exec_command":
        return False
    cmd = str(args.get("cmd") or "").lstrip()
    return cmd.startswith(_WRITE_COMMAND_PREFIXES)


class CodexSource:
    """Live source that tails the newest Codex rollout jsonl."""

    def __init__(self, plan: str = "API USAGE") -> None:
        self._jsonl: Path | None = None
        self._offset = 0
        self._events: list[dict[str, Any]] = []
        self._latencies_ms: deque[float] = deque(maxlen=64)
        self._token_history: deque[tuple[float, float, float, float, float]] = deque()
        self._last_status = "idle"
        self._status_started = time.time()
        self._scanned_other_sessions = False
        self._plan = plan

    def tick(self) -> Telemetry:
        self._refresh_active_file()
        self._tail_new_lines()
        if not self._scanned_other_sessions:
            self._bootstrap_token_history_from_other_sessions()
            self._scanned_other_sessions = True
        return self._build_telemetry()

    def _refresh_active_file(self) -> None:
        newest = _find_newest_session()
        if newest is None:
            return
        if newest != self._jsonl:
            log.info("active codex rollout: %s", newest)
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
            log.warning("codex tail failed: %s", e)
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
            if ev.get("type") == "response_item" and prev_ts is not None and ts > 0:
                payload_type = (ev.get("payload") or {}).get("type")
                if payload_type in {"message", "function_call"}:
                    dt_ms = max(0.0, (ts - prev_ts) * 1000.0)
                    if 50 < dt_ms < 300_000:
                        self._latencies_ms.append(dt_ms)
            if ts > 0:
                prev_ts = ts
            token_row = self._token_row(ev)
            if token_row is not None:
                self._token_history.append(token_row)

    def _bootstrap_token_history_from_other_sessions(self) -> None:
        if not SESSIONS_DIR.is_dir():
            return
        cutoff = time.time() - 7 * 86400
        added = 0
        for p in SESSIONS_DIR.rglob("*.jsonl"):
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
                        token_row = self._token_row(ev)
                        if token_row is None or token_row[0] < cutoff:
                            continue
                        self._token_history.append(token_row)
                        added += 1
            except OSError:
                continue
        if added:
            ordered = sorted(self._token_history, key=lambda r: r[0])
            self._token_history.clear()
            self._token_history.extend(ordered)
        log.info("bootstrapped codex token history: %d events in last 7d", len(self._token_history))

    def _token_row(self, ev: dict[str, Any]) -> tuple[float, float, float, float, float] | None:
        if ev.get("type") != "event_msg":
            return None
        payload = ev.get("payload") or {}
        if payload.get("type") != "token_count":
            return None
        usage = ((payload.get("info") or {}).get("last_token_usage") or {})
        ts = _iso_to_ts(ev.get("timestamp", ""))
        in_t = float(usage.get("input_tokens", 0) or 0)
        out_t = float(usage.get("output_tokens", 0) or 0) + float(usage.get("reasoning_output_tokens", 0) or 0)
        cr_t = float(usage.get("cached_input_tokens", 0) or 0)
        if ts > 0 and (in_t + out_t + cr_t) > 0:
            return (ts, in_t, out_t, cr_t, 0.0)
        return None

    def _build_telemetry(self) -> Telemetry:
        evs = self._events
        if not evs:
            return _empty_telemetry()

        cwd = ""
        git_branch = ""
        session_uuid = ""
        started_at = ""
        model_id = ""
        observed_ctx_max = 0.0
        total_in = total_out = total_cr = total_cc = 0.0
        last_context_used = 0.0

        for ev in evs:
            payload = ev.get("payload") or {}
            if ev.get("type") == "session_meta":
                cwd = payload.get("cwd") or cwd
                session_uuid = payload.get("id") or session_uuid
                started_at = payload.get("timestamp") or ev.get("timestamp", "") or started_at
            elif ev.get("type") == "turn_context":
                cwd = payload.get("cwd") or cwd
                model_id = payload.get("model") or model_id
            elif ev.get("type") == "event_msg" and payload.get("type") == "token_count":
                info = payload.get("info") or {}
                total = info.get("total_token_usage") or {}
                total_in = float(total.get("input_tokens", 0) or 0)
                total_out = (
                    float(total.get("output_tokens", 0) or 0)
                    + float(total.get("reasoning_output_tokens", 0) or 0)
                )
                total_cr = float(total.get("cached_input_tokens", 0) or 0)
                observed_ctx_max = float(info.get("model_context_window", 0) or observed_ctx_max)
                last = info.get("last_token_usage") or {}
                last_context_used = float(last.get("total_tokens", 0) or 0)

        if not model_id:
            model_id = "gpt-5"
        name, version, family, ctx_max, pin, pout = _parse_model_id(model_id, observed_ctx_max)
        ctx_used = last_context_used or (total_in + total_cr)

        current_task = self._current_task(evs)
        turn = sum(
            1
            for ev in evs
            if ev.get("type") == "event_msg"
            and (ev.get("payload") or {}).get("type") == "user_message"
        )
        files_read, files_edited = self._file_counts(evs)
        status, current_tool, detail = self._derive_status(evs)
        if status != self._last_status:
            self._last_status = status
            self._status_started = time.time()
        elapsed = time.time() - self._status_started
        target = {"thinking": 15, "tool": 20, "writing": 12, "idle": 4, "error": 6, "processing": 8}.get(status, 10)
        progress = min(100.0, elapsed / target * 100.0)

        if self._latencies_ms:
            sorted_l = sorted(self._latencies_ms)
            p50 = sorted_l[len(sorted_l) // 2]
            p95 = sorted_l[min(len(sorted_l) - 1, int(len(sorted_l) * 0.95))]
            last_ms = self._latencies_ms[-1]
        else:
            p50 = p95 = last_ms = 0.0

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

        cap_5h = max(8_000_000, _ceil_nice(used_5h * 1.3))
        cap_7d = max(100_000_000, _ceil_nice(used_7d * 1.3))
        agent = Agent(
            kind="codex",
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
            log=self._derive_log(evs),
        )
        model = Model(
            id=model_id,
            name=name,
            version=version,
            provider="openai",
            context_used=ctx_used,
            context_max=ctx_max,
            input_tokens=total_in,
            output_tokens=total_out,
            cache_read_tokens=total_cr,
            cache_write_tokens=total_cc,
            p50_ms=p50,
            p95_ms=p95,
            last_request_ms=last_ms,
        )
        quota = Quota(
            plan=self._plan,
            pricing_in_per_mtok=pin,
            pricing_out_per_mtok=pout,
            windows=[
                QuotaWindow(label="5H", used=used_5h, cap=cap_5h, cost_usd=cost_5h, reset_in_sec=int(max(0, 5 * 3600 - elapsed))),
                QuotaWindow(label="7D", used=used_7d, cap=cap_7d, cost_usd=cost_7d, reset_in_sec=7 * 86400),
            ],
        )
        server = Server(
            provider_label="OPENAI API",
            status="operational",
            tokens_remaining_min=0,
            tokens_limit_min=0,
            requests_remaining_min=0,
            requests_limit_min=0,
            reset_in_sec=0,
            retries_hour=0,
            errors_hour=0,
            queued_requests=1 if status == "tool" else 0,
        )
        return Telemetry(agent=agent, model=model, quota=quota, server=server, source="LIVE")

    def _current_task(self, evs: list[dict[str, Any]]) -> str:
        for ev in reversed(evs):
            if ev.get("type") == "event_msg":
                payload = ev.get("payload") or {}
                if payload.get("type") == "user_message":
                    msg = payload.get("message")
                    if isinstance(msg, str) and msg.strip():
                        return msg.strip()
            elif ev.get("type") == "response_item":
                payload = ev.get("payload") or {}
                if payload.get("type") == "message" and payload.get("role") == "user":
                    text = _content_text(payload.get("content"))
                    if text and not text.startswith("<environment_context>"):
                        return text
        return "(no prompt yet)"

    def _file_counts(self, evs: list[dict[str, Any]]) -> tuple[int, int]:
        files_read = 0
        files_edited = 0
        for ev in evs:
            if ev.get("type") != "response_item":
                continue
            payload = ev.get("payload") or {}
            if payload.get("type") != "function_call":
                continue
            name = str(payload.get("name") or "")
            args = _decode_arguments(payload.get("arguments"))
            if _is_read_call(name, args):
                files_read += 1
            if _is_write_call(name, args):
                files_edited += 1
        return files_read, files_edited

    def _derive_status(self, evs: list[dict[str, Any]]) -> tuple[str, str | None, str]:
        calls: dict[str, dict[str, Any]] = {}
        completed: set[str] = set()
        for ev in evs:
            if ev.get("type") != "response_item":
                continue
            payload = ev.get("payload") or {}
            if payload.get("type") == "function_call":
                cid = str(payload.get("call_id") or "")
                if cid:
                    calls[cid] = payload
            elif payload.get("type") == "function_call_output":
                cid = str(payload.get("call_id") or "")
                if cid:
                    completed.add(cid)
        for cid, payload in reversed(list(calls.items())):
            if cid not in completed:
                name = str(payload.get("name") or "tool")
                args = _decode_arguments(payload.get("arguments"))
                return ("tool", name, _tool_target(name, args) or "running")

        for ev in reversed(evs):
            t = ev.get("type")
            payload = ev.get("payload") or {}
            if t == "event_msg":
                pt = payload.get("type")
                if pt == "user_message":
                    return ("processing", None, "processing prompt")
                if pt == "agent_message":
                    ts = _iso_to_ts(ev.get("timestamp", ""))
                    return ("writing" if ts > 0 and time.time() - ts < 5 else "idle", None, "updating user")
                if pt in {"token_count", "task_started"}:
                    continue
            if t != "response_item":
                continue
            pt = payload.get("type")
            if pt == "function_call_output":
                return ("thinking", None, "parsing tool result")
            if pt == "reasoning":
                return ("thinking", None, "reasoning")
            if pt == "message":
                role = payload.get("role")
                if role == "assistant":
                    ts = _iso_to_ts(ev.get("timestamp", ""))
                    return ("writing" if ts > 0 and time.time() - ts < 5 else "idle", None, "awaiting next directive")
                if role == "user":
                    return ("processing", None, "processing prompt")
        return ("idle", None, "awaiting next directive")

    def _derive_log(self, evs: list[dict[str, Any]]) -> list[LogEntry]:
        call_names: dict[str, str] = {}
        for ev in evs:
            if ev.get("type") != "response_item":
                continue
            payload = ev.get("payload") or {}
            if payload.get("type") == "function_call":
                cid = payload.get("call_id")
                if cid:
                    call_names[str(cid)] = str(payload.get("name") or "tool")

        out: list[LogEntry] = []
        idn = 0
        for ev in reversed(evs):
            if len(out) >= 30:
                break
            ts = _local_hms(ev.get("timestamp", ""))
            payload = ev.get("payload") or {}
            if ev.get("type") == "event_msg":
                pt = payload.get("type")
                if pt == "user_message":
                    msg = str(payload.get("message") or "").strip().replace("\n", " ")
                    idn += 1
                    out.append(LogEntry(id=idn, ts=ts, tag="info", msg=f"prompt.received  ->  {msg[:42]}"))
                elif pt == "agent_message":
                    msg = str(payload.get("message") or "").strip().replace("\n", " ")
                    idn += 1
                    out.append(LogEntry(id=idn, ts=ts, tag="info", msg=f"agent.update  {msg[:54]}"))
                continue
            if ev.get("type") != "response_item":
                continue
            pt = payload.get("type")
            if pt == "function_call":
                name = str(payload.get("name") or "tool")
                args = _decode_arguments(payload.get("arguments"))
                target = _tool_target(name, args)
                idn += 1
                out.append(LogEntry(id=idn, ts=ts, tag="info", msg=f"tool.call  {name}  {target}".strip()))
            elif pt == "function_call_output":
                cid = str(payload.get("call_id") or "")
                name = call_names.get(cid, "tool")
                text = str(payload.get("output") or "")
                tag = "err" if "Process exited with code 0" not in text and "code 0" not in text else "ok"
                idn += 1
                out.append(LogEntry(id=idn, ts=ts, tag=tag, msg=f"tool.result  {name}"))
        return out


def _empty_telemetry() -> Telemetry:
    now_iso = datetime.now(timezone.utc).isoformat()
    return Telemetry(
        agent=Agent(
            kind="codex",
            session_id="----",
            pid=0,
            cwd="~",
            git_branch="",
            git_dirty=False,
            started_at=now_iso,
            status="idle",
            current_task="(no session yet)",
            current_tool=None,
            detail="waiting for codex rollout jsonl",
            progress=0,
            turn=0,
            files_read=0,
            files_edited=0,
            log=[LogEntry(id=1, ts=now_hms(), tag="info", msg="watching ~/.codex/sessions/")],
        ),
        model=Model(
            id="-",
            name="GPT",
            version="-",
            provider="openai",
            context_used=0,
            context_max=400_000,
            input_tokens=0,
            output_tokens=0,
            cache_read_tokens=0,
            cache_write_tokens=0,
            p50_ms=0,
            p95_ms=0,
            last_request_ms=0,
        ),
        quota=Quota(
            plan="API USAGE",
            pricing_in_per_mtok=2.50,
            pricing_out_per_mtok=10.00,
            windows=[
                QuotaWindow(label="5H", used=0, cap=8_000_000, cost_usd=0.0, reset_in_sec=5 * 3600),
                QuotaWindow(label="7D", used=0, cap=100_000_000, cost_usd=0.0, reset_in_sec=7 * 86400),
            ],
        ),
        server=Server(
            provider_label="OPENAI API",
            status="operational",
            tokens_remaining_min=0,
            tokens_limit_min=0,
            requests_remaining_min=0,
            requests_limit_min=0,
            reset_in_sec=0,
            retries_hour=0,
            errors_hour=0,
            queued_requests=0,
        ),
        source="LIVE",
    )
