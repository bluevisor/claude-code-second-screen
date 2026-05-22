"""Port of useTelemetryDemo from helpers.jsx — a state-machine telemetry simulator.

Drives an Agent through a thinking → tool* → writing → idle loop, emitting log
entries and drifting token/quota counters as it goes. Output exactly matches the
AgentTelemetry shape the dashboard renders.
"""

from __future__ import annotations

import random
import time
from copy import deepcopy
from dataclasses import asdict
from datetime import datetime, timezone

from .types import (
    Agent,
    LogEntry,
    Model,
    Quota,
    QuotaWindow,
    Server,
    Telemetry,
)


AGENTS = {
    "claude-code": {
        "label": "CLAUDE CODE",
        "provider": "anthropic",
        "provider_label": "ANTHROPIC API",
        "tools": ["Read", "Edit", "Bash", "Grep", "Glob", "Write", "Task", "WebFetch", "WebSearch", "TodoWrite"],
    },
    "codex": {
        "label": "CODEX",
        "provider": "openai",
        "provider_label": "OPENAI API",
        "tools": ["shell", "apply_patch", "update_plan", "read_file", "local_shell_call"],
    },
    "hermes": {
        "label": "HERMES",
        "provider": "local",
        "provider_label": "LOCAL · vLLM",
        "tools": ["query", "edit", "run", "search", "plan", "reflect"],
    },
    "agy": {
        "label": "AGY",
        "provider": "local",
        "provider_label": "AGY ORCHESTRATOR",
        "tools": ["recall", "write", "exec", "fetch", "compose", "verify"],
    },
}


MODELS = {
    "sonnet45": {"id": "claude-sonnet-4-5-20250929", "name": "CLAUDE SONNET", "v": "4.5", "provider": "anthropic", "ctx_max": 200_000, "p50": 280, "p95": 412, "pricing_in": 3.00, "pricing_out": 15.00},
    "opus41":   {"id": "claude-opus-4-1-20250402",   "name": "CLAUDE OPUS",   "v": "4.1", "provider": "anthropic", "ctx_max": 200_000, "p50": 430, "p95": 684, "pricing_in": 15.00, "pricing_out": 75.00},
    "haiku45":  {"id": "claude-haiku-4-5-20250509",  "name": "CLAUDE HAIKU",  "v": "4.5", "provider": "anthropic", "ctx_max": 200_000, "p50": 140, "p95": 187, "pricing_in": 0.80, "pricing_out": 4.00},
    "gpt5":     {"id": "gpt-5-2025-10-21",           "name": "GPT-5",         "v": "2025.10", "provider": "openai", "ctx_max": 400_000, "p50": 340, "p95": 502, "pricing_in": 2.50, "pricing_out": 10.00},
    "gemini25": {"id": "gemini-2.5-pro-002",         "name": "GEMINI 2.5 PRO", "v": "2.5", "provider": "google", "ctx_max": 1_000_000, "p50": 520, "p95": 731, "pricing_in": 1.25, "pricing_out": 5.00},
}


TASKS_BY_AGENT = {
    "claude-code": [
        {"goal": "Refactor payment service module",        "plan": [("Read", "src/payments/charge.ts"), ("Grep", "stripe.charge"), ("Edit", "split idempotency key"), ("Bash", "pnpm test payments")]},
        {"goal": "Investigate CI flake in queue worker",   "plan": [("Read", "src/queue/worker.ts"), ("Bash", "docker logs ci-runner"), ("Grep", "ECONNRESET"), ("Edit", "retry w/ exp backoff")]},
        {"goal": "Generate release notes for v2.4.0",      "plan": [("Bash", "git log v2.3..HEAD"), ("Grep", "feat: |fix:"), ("Edit", "CHANGELOG.md"), ("Write", "release-notes-v2.4.md")]},
        {"goal": "Review PR #2841 — search ranking",       "plan": [("Read", "src/search/rank.ts"), ("Read", "src/search/__tests__/rank.test.ts"), ("Grep", "scoreThreshold"), ("Edit", "inline comments on hunks")]},
    ],
    "codex": [
        {"goal": "Migrate test runner to vitest",          "plan": [("read_file", "package.json"), ("shell", "jest --listTests"), ("apply_patch", "vite.config.ts"), ("shell", "pnpm vitest")]},
        {"goal": "Add OAuth callback handler",             "plan": [("read_file", "src/auth/index.ts"), ("update_plan", "callback route + token exchange"), ("apply_patch", "add /callback"), ("shell", "pnpm typecheck")]},
    ],
    "hermes": [
        {"goal": "Summarize Q3 customer interviews",       "plan": [("search", "interview transcripts"), ("plan", "theme clustering"), ("query", "extract objections"), ("edit", "themes.md")]},
        {"goal": "Triage inbound bug reports",             "plan": [("query", "fetch open bugs"), ("reflect", "prioritize by frequency"), ("edit", "triage notes"), ("run", "post to slack")]},
    ],
    "agy": [
        {"goal": "Compose nightly metrics digest",         "plan": [("recall", "yesterday's KPIs"), ("fetch", "analytics warehouse"), ("compose", "digest.md"), ("verify", "numbers vs source")]},
        {"goal": "Synthesize design review feedback",      "plan": [("recall", "review thread"), ("fetch", "figma comments"), ("compose", "action items"), ("write", "review-2025-05-22.md")]},
    ],
}


STATUS_VERBS = {
    "idle": "STANDBY",
    "thinking": "THINKING",
    "tool": "EXECUTING",
    "writing": "WRITING",
    "error": "ERROR",
}


def now_hms(d: datetime | None = None) -> str:
    d = d or datetime.now()
    return d.strftime("%H:%M:%S")


def seed_telemetry(agent_kind: str, model_key: str) -> Telemetry:
    a = AGENTS.get(agent_kind, AGENTS["claude-code"])
    m = MODELS.get(model_key, MODELS["sonnet45"])
    task = TASKS_BY_AGENT[agent_kind][0]

    tokens_limit_min = 400_000 if m["provider"] == "anthropic" else 800_000
    requests_limit_min = 4_000 if m["provider"] == "anthropic" else 5_000
    cap_5h = 2_500_000 if m["provider"] == "anthropic" else 8_000_000
    cap_7d = 35_000_000 if m["provider"] == "anthropic" else 100_000_000

    started = datetime.now(timezone.utc).timestamp() - 18 * 60 - 12
    started_iso = datetime.fromtimestamp(started, tz=timezone.utc).isoformat()

    log = [
        LogEntry(id=3, ts=now_hms(), tag="info", msg=f"prompt.received  →  {task['goal'][:38]}…"),
        LogEntry(id=2, ts=now_hms(), tag="ok",   msg=f"agent::ready  {a['label'].lower()}  v1.7.4"),
        LogEntry(id=1, ts=now_hms(), tag="info", msg="uplink established  rtt=24ms"),
    ]

    return Telemetry(
        source="DEMO",
        agent=Agent(
            kind=agent_kind,
            session_id="4F-2A91",
            pid=4214,
            cwd="~/seen/web",
            git_branch="main",
            git_dirty=True,
            started_at=started_iso,
            status="thinking",
            current_task=task["goal"],
            current_tool=None,
            detail="parsing request context",
            progress=0,
            turn=12,
            files_read=47,
            files_edited=8,
            log=log,
            _task_idx=0,
            _step=0,
        ),
        model=Model(
            id=m["id"], name=m["name"], version=m["v"], provider=m["provider"],
            context_used=42_180, context_max=m["ctx_max"],
            input_tokens=184_000, output_tokens=38_400,
            cache_read_tokens=1_240_000, cache_write_tokens=96_000,
            p50_ms=m["p50"], p95_ms=m["p95"], last_request_ms=m["p50"],
        ),
        quota=Quota(
            plan="MAX 20×" if m["provider"] == "anthropic" else "API USAGE",
            pricing_in_per_mtok=m["pricing_in"],
            pricing_out_per_mtok=m["pricing_out"],
            windows=[
                QuotaWindow(label="5H", used=1_240_000,  cap=cap_5h, cost_usd=3.72,  reset_in_sec=3 * 3600 + 12 * 60),
                QuotaWindow(label="7D", used=14_280_000, cap=cap_7d, cost_usd=42.84, reset_in_sec=4 * 86400 + 18 * 3600),
            ],
        ),
        server=Server(
            provider_label=a["provider_label"],
            status="operational",
            tokens_remaining_min=round(tokens_limit_min * 0.78),
            tokens_limit_min=tokens_limit_min,
            requests_remaining_min=requests_limit_min - 42,
            requests_limit_min=requests_limit_min,
            reset_in_sec=38,
            retries_hour=0,
            errors_hour=0,
            queued_requests=1,
        ),
    )


class DemoSimulator:
    """Owns the telemetry state and advances it on `tick()` calls.

    Call tick() ~every 380ms (matches the JSX) and pass the result to the
    renderer. Tick frequency controls how fast the state machine moves; render
    frequency is independent.
    """

    def __init__(self, agent_kind: str = "claude-code", model_key: str = "sonnet45"):
        self.agent_kind = agent_kind
        self.model_key = model_key
        self._log_id = 100
        self.tel = seed_telemetry(agent_kind, model_key)
        self._tasks = TASKS_BY_AGENT[agent_kind]
        self._task = self._tasks[0]

    def reseed(self, agent_kind: str, model_key: str) -> None:
        self.agent_kind = agent_kind
        self.model_key = model_key
        self.tel = seed_telemetry(agent_kind, model_key)
        self._tasks = TASKS_BY_AGENT[agent_kind]
        self._task = self._tasks[0]

    def _push_log(self, tag: str, msg: str) -> None:
        self._log_id += 1
        self.tel.agent.log = [LogEntry(id=self._log_id, ts=now_hms(), tag=tag, msg=msg)] + self.tel.agent.log[:29]

    def tick(self) -> Telemetry:
        a = self.tel.agent
        m = self.tel.model
        s = self.tel.server
        q = self.tel.quota
        model_def = MODELS[self.model_key]
        prev_in = m.input_tokens
        prev_out = m.output_tokens

        # model / server drift
        jitter = 1 + (random.random() - 0.5) * 0.08
        m.last_request_ms = max(60, round(model_def["p50"] * jitter + random.random() * 60))
        m.p50_ms = round(0.92 * m.p50_ms + 0.08 * m.last_request_ms)
        m.p95_ms = max(m.p95_ms, round(m.last_request_ms * 1.35))
        m.p95_ms = round(0.97 * m.p95_ms + 0.03 * m.last_request_ms * 1.35)

        s.reset_in_sec -= 1
        if s.reset_in_sec <= 0:
            s.tokens_remaining_min = s.tokens_limit_min
            s.requests_remaining_min = s.requests_limit_min
            s.reset_in_sec = 60
        elif a.status in ("tool", "writing"):
            s.tokens_remaining_min = max(0, s.tokens_remaining_min - (800 + random.random() * 2200))
            if random.random() < 0.18:
                s.requests_remaining_min = max(0, s.requests_remaining_min - 1)
        if s.tokens_remaining_min / max(s.tokens_limit_min, 1) < 0.15 and random.random() < 0.05:
            s.retries_hour += 1
            self._push_log("warn", "rate.limit  backing off 180ms")
        s.status = "degraded" if s.retries_hour > 6 else "operational"

        # agent state machine
        if a.status == "thinking":
            a.progress = min(100, a.progress + 14 + random.random() * 10)
            stages = ["analyzing request", "building dependency graph", "ranking candidate paths", "preparing first tool"]
            a.detail = stages[min(3, int(a.progress // 26))]
            if a.progress >= 100:
                a.status = "tool"
                a.progress = 0
                a._step = 0
                tool, target = self._task["plan"][0]
                a.current_tool = tool
                a.detail = f"{tool}( {target} )"
                self._push_log("info", f"tool.call  {tool}  {target}")
        elif a.status == "tool":
            a.progress = min(100, a.progress + 10 + random.random() * 16)
            if a.progress >= 100:
                tool, target = self._task["plan"][a._step]
                if tool in ("Read", "read_file", "recall", "query"):
                    ok = f"read {int(random.random() * 1200) + 80} lines  {target}"
                elif tool in ("Grep", "search"):
                    ok = f"matched {int(random.random() * 40)} / {int(random.random() * 8000) + 200} files"
                elif tool in ("Edit", "apply_patch", "edit"):
                    ok = f"patched {int(random.random() * 120) + 4} lines"
                elif tool in ("Bash", "shell", "run", "exec"):
                    ok = f"exit 0  ({random.random() * 8 + 0.4:.1f}s)"
                elif tool in ("Write", "write", "compose"):
                    ok = f"wrote {target}"
                else:
                    ok = "ok"
                self._push_log("ok", f"{tool}  ✓  {ok}")
                if tool in ("Read", "read_file", "recall"):
                    a.files_read += 1
                if tool in ("Edit", "apply_patch", "edit", "Write", "write", "compose"):
                    a.files_edited += 1
                a._step += 1
                if a._step < len(self._task["plan"]):
                    nt, ntarget = self._task["plan"][a._step]
                    a.current_tool = nt
                    a.detail = f"{nt}( {ntarget} )"
                    a.progress = 0
                    self._push_log("info", f"tool.call  {nt}  {ntarget}")
                else:
                    a.status = "writing"
                    a.current_tool = None
                    a.progress = 0
                    a.detail = "drafting response"
                    self._push_log("info", "synth.response  streaming…")
        elif a.status == "writing":
            a.progress = min(100, a.progress + 7 + random.random() * 5)
            stages = ["composing summary", "streaming tokens", "verifying citations", "finalizing"]
            a.detail = stages[min(3, int(a.progress // 26))]
            stream = 80 + random.random() * 180
            m.output_tokens += stream
            m.context_used += stream
            if a.progress >= 100:
                a.status = "idle"
                a.detail = "task completed · awaiting next directive"
                self._push_log("ok", f"turn.complete  {self._task['goal']}")
                a.turn += 1
        elif a.status == "idle":
            a.progress = min(100, a.progress + 28)
            if a.progress >= 100:
                pool = self._tasks
                nt = self._task
                while nt is self._task and len(pool) > 1:
                    nt = random.choice(pool)
                self._task = nt
                a._step = 0
                a.status = "thinking"
                a.progress = 0
                a.current_task = nt["goal"]
                a.current_tool = None
                a.detail = "parsing request context"
                self._push_log("info", f"prompt.received  →  {nt['goal'][:38]}…")
                m.input_tokens += 1200 + random.random() * 2400
                m.cache_read_tokens += 8000 + random.random() * 22000

        # quota drift
        new_out = max(0, m.output_tokens - prev_out)
        new_in = max(0, m.input_tokens - prev_in)
        new_tok = new_out + new_in
        cost = (new_in * q.pricing_in_per_mtok + new_out * q.pricing_out_per_mtok) / 1_000_000
        for w in q.windows:
            if new_tok > 0:
                w.used += new_tok
            if cost > 0:
                w.cost_usd += cost
            w.reset_in_sec = max(0, w.reset_in_sec - 1)

        return self.tel
