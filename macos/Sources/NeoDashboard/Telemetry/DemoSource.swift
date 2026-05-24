// Minimal demo source — useful in Previews and when no Claude Code session
// is available. Cycles through a couple of states with believable values.
//
// Not a full port of `demo.py`: it produces enough variance to exercise the
// renderer (status verb, log roll, quota fill). Full state machine can be
// ported later if needed for screenshots.

import Foundation

final class DemoSource: TelemetrySource {
    let label = "Demo"

    private var tel: Telemetry
    private var startedAt: Date = .now

    init() {
        var t = Telemetry.empty()
        t.source = "DEMO"
        t.agent.kind = "claude-code"
        t.agent.sessionID = "B3AE-5268"
        t.agent.cwd = "~/Developer/bluevisor/claude-code-second-screen"
        t.agent.gitBranch = "main"
        t.agent.status = .thinking
        t.agent.currentTask = "update readme text and screenshot, commit and push"
        t.agent.detail = "parsing tool result"
        t.agent.turn = 28
        t.agent.filesRead = 75
        t.agent.filesEdited = 86
        t.agent.log = (1...6).map { i in
            LogEntry(id: i, ts: "16:47:0\(i)", tag: i.isMultiple(of: 2) ? .ok : .info,
                     msg: i.isMultiple(of: 2)
                         ? "tool.result  total 784 drwxr-xr-x …"
                         : "tool.call  Read  ~/Developer/bluev…")
        }
        t.model.id = "claude-opus-4-7"
        t.model.name = "CLAUDE OPUS"
        t.model.version = "4.7"
        t.model.contextUsed = 387_000
        t.model.contextMax = 1_000_000
        t.model.inputTokens = 918
        t.model.outputTokens = 471_000
        t.model.cacheReadTokens = 118_630_000
        t.model.p50ms = 6917
        t.model.p95ms = 21651
        t.model.lastRequestMs = 10587
        t.quota.plan = "MAX 5×"
        t.quota.windows = [
            QuotaWindow(label: "5H", used: 121_410_000, cap: 200_000_000,
                        costUSD: 243.56, resetInSec: 4 * 3600 + 59 * 60),
            QuotaWindow(label: "7D", used: 197_370_000, cap: 500_000_000,
                        costUSD: 458.05, resetInSec: 7 * 86400),
        ]
        t.model.thinking = .effort("xhigh")
        t.hasContent = true
        tel = t
    }

    func tick() -> Telemetry {
        let elapsed = Date.now.timeIntervalSince(startedAt)
        // Cycle the status every ~6s so the verb glow + caret animate.
        let cycle = Int(elapsed / 6) % 4
        switch cycle {
        case 0: tel.agent.status = .thinking
        case 1: tel.agent.status = .tool; tel.agent.currentTool = "Read"
        case 2: tel.agent.status = .writing
        default: tel.agent.status = .idle
        }
        return tel
    }
}
