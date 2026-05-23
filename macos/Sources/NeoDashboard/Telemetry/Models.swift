// Telemetry data model — the single shape the renderer consumes.
//
// Mirrors the Python `agent_dashboard.telemetry.types` module so any source
// (Claude Code, Codex, agy, demo, …) plugs in without changing the renderer.

import Foundation

enum AgentStatus: String, Sendable, Codable {
    case idle, waiting, processing, thinking, tool, writing, error
}

enum LogTag: String, Sendable, Codable {
    case info, ok, warn, err
}

struct LogEntry: Sendable, Hashable {
    let id: Int
    let ts: String        // HH:MM:SS in local wall clock
    let tag: LogTag
    let msg: String
}

enum SubAgentStatus: String, Sendable, Codable {
    case running, done, error
}

struct SubAgent: Sendable, Hashable {
    let toolUseID: String
    let subagentType: String
    let description: String
    let status: SubAgentStatus
    let startedAt: String
}

struct Agent: Sendable {
    var kind: String              // "claude-code", "codex", …
    var sessionID: String         // short id, e.g. "B3AE-5268"
    var cwd: String
    var gitBranch: String
    var gitDirty: Bool
    var startedAt: Date
    var status: AgentStatus
    var currentTask: String
    var currentTool: String?
    var detail: String
    var progress: Double          // 0–100
    var turn: Int
    var filesRead: Int
    var filesEdited: Int
    var log: [LogEntry]
    var subAgents: [SubAgent]
}

struct AgentModel: Sendable {
    var id: String                // raw model id ("claude-opus-4-7")
    var name: String              // "CLAUDE OPUS"
    var version: String           // "4.7"
    var provider: String          // "anthropic", "openai", …
    var contextUsed: Double
    var contextMax: Double
    var inputTokens: Double
    var outputTokens: Double
    var cacheReadTokens: Double
    var cacheWriteTokens: Double
    var p50ms: Double
    var p95ms: Double
    var lastRequestMs: Double
    /// Rolling window of recent assistant-turn latencies (oldest→newest, ms).
    /// Renderers sparkline this; empty when the source hasn't seen enough
    /// events yet.
    var latencyHistory: [Double] = []
}

struct QuotaWindow: Sendable {
    var label: String             // "5H", "7D"
    var used: Double
    var cap: Double
    var costUSD: Double
    var resetInSec: Int
}

struct Quota: Sendable {
    var plan: String              // "MAX 5×", "API USAGE", …
    var pricingInPerMTok: Double
    var pricingOutPerMTok: Double
    var windows: [QuotaWindow]
}

struct Telemetry: Sendable {
    var agent: Agent
    var model: AgentModel
    var quota: Quota
    var source: String            // "LIVE", "DEMO", …
    /// False when the source has nothing meaningful to render (no events
    /// yet, or the pinned session has been removed). FrameLoop swaps in
    /// the clock fallback when this is false.
    var hasContent: Bool = true
}

extension Telemetry {
    /// A placeholder telemetry used when no session has been observed yet.
    static func empty() -> Telemetry {
        let agent = Agent(
            kind: "claude-code",
            sessionID: "----",
            cwd: "~",
            gitBranch: "",
            gitDirty: false,
            startedAt: Date(),
            status: .idle,
            currentTask: "(no session yet)",
            currentTool: nil,
            detail: "waiting for session jsonl",
            progress: 0,
            turn: 0,
            filesRead: 0,
            filesEdited: 0,
            log: [
                LogEntry(id: 1, ts: hms(Date()), tag: .info,
                         msg: "watching ~/.claude/projects/")
            ],
            subAgents: []
        )
        let model = AgentModel(
            id: "-",
            name: "—",
            version: "-",
            provider: "anthropic",
            contextUsed: 0,
            contextMax: 200_000,
            inputTokens: 0,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            p50ms: 0,
            p95ms: 0,
            lastRequestMs: 0
        )
        let quota = Quota(
            plan: "MAX 20×",
            pricingInPerMTok: 15.0,
            pricingOutPerMTok: 75.0,
            windows: [
                QuotaWindow(label: "5H", used: 0, cap: 2_500_000, costUSD: 0,
                            resetInSec: 5 * 3600),
                QuotaWindow(label: "7D", used: 0, cap: 35_000_000, costUSD: 0,
                            resetInSec: 7 * 86400),
            ]
        )
        return Telemetry(agent: agent, model: model, quota: quota,
                         source: "LIVE", hasContent: false)
    }
}

private let hmsFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f
}()

func hms(_ d: Date) -> String { hmsFormatter.string(from: d) }
