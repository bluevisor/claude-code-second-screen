"""AgentTelemetry dataclasses — mirror the contract in TELEMETRY.md."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Literal


@dataclass
class LogEntry:
    id: int
    ts: str
    tag: Literal["ok", "warn", "err", "info"]
    msg: str


@dataclass
class SubAgent:
    """A Claude Code `Agent` tool invocation tracked by id and live status."""

    tool_use_id: str
    subagent_type: str  # e.g. "Explore", "general-purpose"
    description: str
    status: Literal["running", "done", "error"]
    started_at: str


@dataclass
class QuotaWindow:
    label: str
    used: float
    cap: float
    cost_usd: float
    reset_in_sec: int


@dataclass
class Agent:
    kind: str
    session_id: str
    pid: int
    cwd: str
    git_branch: str
    git_dirty: bool
    started_at: str
    status: Literal["idle", "thinking", "tool", "writing", "error", "processing", "waiting"]
    current_task: str
    current_tool: str | None
    detail: str
    progress: float
    turn: int
    files_read: int
    files_edited: int
    log: list[LogEntry] = field(default_factory=list)
    sub_agents: list[SubAgent] = field(default_factory=list)

    # internal demo state — not part of the contract
    _task_idx: int = 0
    _step: int = 0


@dataclass
class Model:
    id: str
    name: str
    version: str
    provider: str
    context_used: float
    context_max: float
    input_tokens: float
    output_tokens: float
    cache_read_tokens: float
    cache_write_tokens: float
    p50_ms: float
    p95_ms: float
    last_request_ms: float


@dataclass
class Quota:
    plan: str
    pricing_in_per_mtok: float
    pricing_out_per_mtok: float
    windows: list[QuotaWindow] = field(default_factory=list)


@dataclass
class Server:
    provider_label: str
    status: Literal["operational", "degraded", "outage"]
    tokens_remaining_min: float
    tokens_limit_min: float
    requests_remaining_min: float
    requests_limit_min: float
    reset_in_sec: int
    retries_hour: int
    errors_hour: int
    queued_requests: int


@dataclass
class Telemetry:
    agent: Agent
    model: Model
    quota: Quota
    server: Server
    source: Literal["LIVE", "STALE", "DEMO"] = "DEMO"
