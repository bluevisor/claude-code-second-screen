// Live Claude Code telemetry — tails the newest session jsonl under
// ~/.claude/projects and derives the `Telemetry` shape from the event stream.
//
// Port of `agent_dashboard/telemetry/claude_code.py`. See TELEMETRY.md in
// the Python project for the full derivation rules.

import Foundation
import os.log

/// (timestamp, in, out, cache_read, cache_create) — for rolling-window quotas.
private struct TokenSample {
    let ts: TimeInterval
    let input: Double
    let output: Double
    let cacheRead: Double
    let cacheCreate: Double
}

final class ClaudeCodeSource: TelemetrySource {
    let label = "Claude Code"

    private let projectsDir: URL
    private let logger = Logger(subsystem: "tech.bluevisor.NeoDashboard",
                                category: "ClaudeCode")
    private var plan: String

    private let sessionsDir: URL
    private var jsonl: URL?
    private var pinned: URL?            // user-pinned session, overrides auto
    private var offset: UInt64 = 0
    private var events: [Event] = []
    private var latencies: [Double] = []
    private var tokenHistory: [TokenSample] = []
    private var lastStatus: AgentStatus = .idle
    private var statusStarted: Date = .now
    private var scannedOtherSessions = false
    private var dirty = true
    private var cachedTelemetry: Telemetry?
    private var bootstrapping = false
    /// Bounds on the in-memory event ring. Long-running Claude sessions
    /// (8h+ of dense agent loops) otherwise grow `events` without limit;
    /// each tick then re-scans the whole array several times. Mirrors
    /// CodexSource's caps.
    private let maxRetainedEvents = 4_000
    private let maxRetainedTokenSamples = 2_000

    init(projectsDir: URL? = nil, sessionsDir: URL? = nil) {
        self.plan = ClaudePlan.detect()
        self.projectsDir = projectsDir
            ?? URL(fileURLWithPath: NSString("~/.claude/projects").expandingTildeInPath,
                   isDirectory: true)
        self.sessionsDir = sessionsDir
            ?? URL(fileURLWithPath: NSString("~/.claude/sessions").expandingTildeInPath,
                   isDirectory: true)
    }

    func tick() -> Telemetry {
        refreshActiveFile()
        tailNewLines()
        if !scannedOtherSessions, !bootstrapping {
            bootstrapping = true
            let projectsDir = self.projectsDir
            let activeJsonl = self.jsonl
            let logger = self.logger
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let samples = Self.scanTokenHistory(projectsDir: projectsDir,
                                                     exclude: activeJsonl)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.tokenHistory.append(contentsOf: samples)
                    self.tokenHistory.sort { $0.ts < $1.ts }
                    self.scannedOtherSessions = true
                    self.dirty = true
                    logger.info("bootstrapped token history: \(self.tokenHistory.count) events (added \(samples.count))")
                }
            }
        }
        if dirty {
            cachedTelemetry = buildTelemetry()
            dirty = false
        }
        return promoteByRegistryStatus(cachedTelemetry ?? .empty())
    }

    /// Claude's "Searching…" / "Thinking…" UI states sit between jsonl
    /// events — the assistant has fired off an API call but no new line
    /// has arrived. The sessions registry still flips `status: busy` for
    /// those gaps, so we use it to lift the dashboard out of "Standby…"
    /// when the jsonl-based derivation would otherwise return `.idle`.
    private func promoteByRegistryStatus(_ tel: Telemetry) -> Telemetry {
        guard tel.hasContent, tel.agent.status == .idle,
              let url = jsonl else { return tel }
        let busy = SessionDiscovery.active().contains {
            $0.jsonl == url && $0.busy
        }
        guard busy else { return tel }
        var out = tel
        out.agent.status = .processing
        out.agent.detail = "waiting on api response"
        return out
    }

    /// Pin the source to a specific session jsonl. Passing nil reverts to
    /// the busy-or-most-recent auto pick. Resets internal buffers so the
    /// next tick starts fresh on the new file.
    func setPinned(_ url: URL?) {
        if pinned == url { return }
        pinned = url
        jsonl = nil
        offset = 0
        events.removeAll(keepingCapacity: true)
        latencies.removeAll(keepingCapacity: true)
        dirty = true
    }

    // MARK: - File discovery + tailing

    private func refreshActiveFile() {
        // If the user pinned a specific session, follow it exclusively.
        // Otherwise pick the busiest interactive session from the registry,
        // falling back to the newest-mtime jsonl when registry is empty.
        let pick: URL?
        if let p = pinned, FileManager.default.fileExists(atPath: p.path) {
            pick = p
        } else {
            pick = activeSessionJSONL() ?? newestJSONL(under: projectsDir)
        }
        guard let next = pick else { return }
        if next != jsonl {
            logger.info("active session: \(next.path, privacy: .public)")
            jsonl = next
            offset = 0
            events.removeAll(keepingCapacity: true)
            latencies.removeAll(keepingCapacity: true)
            dirty = true
        }
    }

    private func activeSessionJSONL() -> URL? {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: sessionsDir,
                                                      includingPropertiesForKeys: nil,
                                                      options: [.skipsHiddenFiles]) else { return nil }
        struct Cand { let url: URL; let busy: Bool; let updatedAt: Double }
        var cands: [Cand] = []
        for url in items where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let any = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            guard (any["kind"] as? String) == "interactive",
                  let sessionId = any["sessionId"] as? String,
                  let cwd = any["cwd"] as? String else { continue }
            let updatedAt = (any["updatedAt"] as? Double)
                ?? Double((any["updatedAt"] as? Int) ?? 0)
            let busy = (any["status"] as? String) == "busy"
            let dirName = cwd.replacingOccurrences(of: "/", with: "-")
            let jsonl = projectsDir
                .appendingPathComponent(dirName, isDirectory: true)
                .appendingPathComponent("\(sessionId).jsonl")
            if fm.fileExists(atPath: jsonl.path) {
                cands.append(Cand(url: jsonl, busy: busy, updatedAt: updatedAt))
            }
        }
        guard !cands.isEmpty else { return nil }
        cands.sort {
            if $0.busy != $1.busy { return $0.busy }
            return $0.updatedAt > $1.updatedAt
        }
        return cands.first?.url
    }

    private func tailNewLines() {
        guard let url = jsonl else { return }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value else { return }
        if size < offset {
            offset = 0
            events.removeAll(keepingCapacity: true)
        }
        if size == offset { return }
        dirty = true

        guard let fh = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? fh.close() }
        do {
            try fh.seek(toOffset: offset)
        } catch {
            logger.warning("seek failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard let chunk = try? fh.readToEnd() else { return }
        offset = size

        var prevTs: TimeInterval? = events.last?.timestamp
        let s = String(data: chunk, encoding: .utf8) ?? ""
        for raw in s.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = raw.data(using: .utf8) else { continue }
            guard let any = try? JSONSerialization.jsonObject(with: data, options: []),
                  let dict = any as? [String: Any] else { continue }
            let ev = Event(raw: dict)
            events.append(ev)

            if ev.type == "assistant", let p = prevTs, ev.timestamp > 0 {
                let dtMs = max(0, (ev.timestamp - p) * 1000)
                if dtMs > 50, dtMs < 300_000 {
                    latencies.append(dtMs)
                    if latencies.count > 64 { latencies.removeFirst(latencies.count - 64) }
                }
            }
            if ev.timestamp > 0 { prevTs = ev.timestamp }
            if ev.type == "assistant", let usage = ev.usage {
                let total = usage.input + usage.output + usage.cacheRead + usage.cacheCreate
                if total > 0, ev.timestamp > 0 {
                    tokenHistory.append(TokenSample(
                        ts: ev.timestamp,
                        input: usage.input, output: usage.output,
                        cacheRead: usage.cacheRead, cacheCreate: usage.cacheCreate
                    ))
                }
            }
        }
        trimBuffers()
    }

    /// Keep the in-memory event ring bounded. Claude rewrites cwd /
    /// sessionId / gitBranch on every assistant line, so the session
    /// header isn't load-bearing — a simple tail-trim is safe for
    /// derivation. Cumulative token totals shown on the dashboard may
    /// drift after the buffer wraps; rolling-window quotas use
    /// `tokenHistory` (also bounded) which is what actually feeds 5H/7D.
    private func trimBuffers() {
        if events.count > maxRetainedEvents {
            events.removeFirst(events.count - maxRetainedEvents)
        }
        if tokenHistory.count > maxRetainedTokenSamples {
            tokenHistory.removeFirst(tokenHistory.count - maxRetainedTokenSamples)
        }
    }

    private static func scanTokenHistory(projectsDir: URL,
                                          exclude: URL?) -> [TokenSample] {
        let cutoff = Date.now.timeIntervalSince1970 - 7 * 86400
        let fm = FileManager.default
        guard let it = fm.enumerator(at: projectsDir,
                                     includingPropertiesForKeys: [.contentModificationDateKey],
                                     options: [.skipsHiddenFiles]) else { return [] }
        var samples: [TokenSample] = []
        for case let url as URL in it where url.pathExtension == "jsonl" {
            if url == exclude { continue }
            let attrs = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            guard let mtime = attrs?.contentModificationDate?.timeIntervalSince1970,
                  mtime >= cutoff else { continue }
            autoreleasepool {
                guard let data = try? Data(contentsOf: url) else { return }
                let s = String(data: data, encoding: .utf8) ?? ""
                for line in s.split(separator: "\n", omittingEmptySubsequences: true) {
                    guard let d = line.data(using: .utf8),
                          let any = try? JSONSerialization.jsonObject(with: d, options: []),
                          let dict = any as? [String: Any] else { continue }
                    let ev = Event(raw: dict)
                    if ev.type != "assistant" { continue }
                    if ev.timestamp < cutoff { continue }
                    guard let u = ev.usage else { continue }
                    let total = u.input + u.output + u.cacheRead + u.cacheCreate
                    if total <= 0 { continue }
                    samples.append(TokenSample(
                        ts: ev.timestamp,
                        input: u.input, output: u.output,
                        cacheRead: u.cacheRead, cacheCreate: u.cacheCreate
                    ))
                }
            }
        }
        return samples
    }

    // MARK: - Derivation

    private func buildTelemetry() -> Telemetry {
        if events.isEmpty { return .empty() }

        var cwd = ""
        var gitBranch = ""
        var sessionUUID = ""
        var startedAt = ""
        var lastModelID = ""

        for ev in events {
            if let v = ev.raw["cwd"] as? String { cwd = v }
            if let v = ev.raw["gitBranch"] as? String { gitBranch = v }
            if let v = ev.raw["sessionId"] as? String { sessionUUID = v }
            if startedAt.isEmpty, let v = ev.raw["timestamp"] as? String { startedAt = v }
        }
        // Skip `<synthetic>` events — Claude Code emits those for its
        // internal title-generation / summary calls, not the user's
        // chosen model. Without this filter the dashboard ends up
        // showing "Claude v?" right after one of those housekeeping
        // events runs.
        for ev in events.reversed() where ev.type == "assistant" {
            if let m = ev.message["model"] as? String,
               !m.isEmpty,
               !m.hasPrefix("<") {
                lastModelID = m
                break
            }
        }

        let (modelName, version, family, contextMax0, pin, pout) = parseModelID(lastModelID)

        // current task — most recent user-string content
        var currentTask = ""
        for ev in events.reversed() where ev.type == "user" {
            if let c = ev.message["content"] as? String, !c.trimmingCharacters(in: .whitespaces).isEmpty {
                currentTask = c.trimmingCharacters(in: .whitespaces)
                break
            }
        }
        let turn = events.reduce(0) { acc, ev in
            if ev.type == "user", let c = ev.message["content"] as? String,
               !c.trimmingCharacters(in: .whitespaces).isEmpty { return acc + 1 }
            return acc
        }

        // accumulators
        var filesRead = 0
        var filesEdited = 0
        var totalIn = 0.0, totalOut = 0.0, totalCR = 0.0, totalCC = 0.0
        var lastAssistantIdx = -1
        for (i, ev) in events.enumerated() where ev.type == "assistant" {
            lastAssistantIdx = i
            if let u = ev.usage {
                totalIn += u.input; totalOut += u.output
                totalCR += u.cacheRead; totalCC += u.cacheCreate
            }
            if let content = ev.message["content"] as? [[String: Any]] {
                for block in content where (block["type"] as? String) == "tool_use" {
                    let name = (block["name"] as? String ?? "").lowercased()
                    switch name {
                    case "read", "read_file", "recall", "query":
                        filesRead += 1
                    case "edit", "write", "apply_patch", "compose":
                        filesEdited += 1
                    default: break
                    }
                }
            }
        }
        // context used = the latest assistant's usage at emit time
        var ctxUsed = 0.0
        if lastAssistantIdx >= 0, let u = events[lastAssistantIdx].usage {
            ctxUsed = u.input + u.cacheRead + u.cacheCreate
        }
        var contextMax = Double(contextMax0)
        if ctxUsed > contextMax {
            contextMax = ctxUsed > 200_000 ? 1_000_000 : contextMax
        }

        let (status, currentTool, detail) = deriveStatus(lastAssistantIdx: lastAssistantIdx)
        if status != lastStatus {
            lastStatus = status
            statusStarted = .now
        }
        let elapsed = Date.now.timeIntervalSince(statusStarted)
        let progressTarget: Double = {
            switch status {
            case .thinking: return 15
            case .tool: return 20
            case .writing: return 12
            case .idle: return 4
            case .error: return 6
            default: return 10
            }
        }()
        let progress = min(100, elapsed / progressTarget * 100)

        let log = deriveLog()
        let subs = deriveSubAgents()

        // latencies
        let p50: Double, p95: Double, lastMs: Double
        if !latencies.isEmpty {
            let sorted = latencies.sorted()
            p50 = sorted[sorted.count / 2]
            p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
            lastMs = latencies.last ?? 0
        } else {
            p50 = 0; p95 = 0; lastMs = 0
        }

        // rolling windows
        let now = Date.now.timeIntervalSince1970
        let cutoff5h = now - 5 * 3600
        let cutoff7d = now - 7 * 86400
        var used5h = 0.0, used7d = 0.0, cost5h = 0.0, cost7d = 0.0
        for s in tokenHistory {
            let cost = (s.input * pin + s.output * pout
                        + s.cacheRead * pin * 0.10 + s.cacheCreate * pin * 1.25) / 1_000_000
            if s.ts >= cutoff7d {
                used7d += s.input + s.output + s.cacheRead + s.cacheCreate
                cost7d += cost
            }
            if s.ts >= cutoff5h {
                used5h += s.input + s.output + s.cacheRead + s.cacheCreate
                cost5h += cost
            }
        }
        let cap5h = max(2_500_000.0, ceilNice(used5h * 1.3))
        let cap7d = max(35_000_000.0, ceilNice(used7d * 1.3))

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let prettyCWD = (cwd.isEmpty ? "~" : cwd).replacingOccurrences(of: home, with: "~")

        let started = isoToDate(startedAt) ?? .now
        let agent = Agent(
            kind: "claude-code",
            sessionID: shortSessionID(sessionUUID),
            cwd: prettyCWD,
            gitBranch: (gitBranch == "HEAD") ? "" : gitBranch,
            gitDirty: gitDirty(cwd: cwd),
            startedAt: started,
            status: status,
            currentTask: String(currentTask.prefix(280)),
            currentTool: currentTool,
            detail: detail,
            progress: progress,
            turn: turn,
            filesRead: filesRead,
            filesEdited: filesEdited,
            log: log,
            subAgents: subs
        )
        // Thinking detection — Claude's `/thinking` slash command writes
        // its confirmation as a user event whose content contains
        // `<local-command-stdout>Effort level set to X</local-command-stdout>`.
        // That's the source of truth (the budget_tokens parameter on
        // the API request is not echoed back into the jsonl). Walk
        // back from the latest event so the most recent `/thinking`
        // call wins. Fall through to ON/OFF based on the presence of
        // thinking blocks when no explicit marker is found.
        let thinking: ThinkingMode = {
            if let level = parseExplicitEffort(events: events) {
                return .effort(level)
            }
            for ev in events.suffix(40).reversed() where ev.type == "assistant" {
                if let content = ev.message["content"] as? [[String: Any]],
                   content.contains(where: { ($0["type"] as? String) == "thinking" }) {
                    return .on
                }
            }
            return .off
        }()
        // Append " 1M" to the display name when the context window
        // appears to be the extended-context variant. We infer that from
        // contextMax having been bumped past 200K above (driven by token
        // usage); the API id is just `claude-sonnet-4-6` either way.
        let displayName = contextMax >= 1_000_000 ? "\(modelName) 1M" : modelName
        let model = AgentModel(
            id: lastModelID.isEmpty ? "claude" : lastModelID,
            name: displayName, version: version, provider: "anthropic",
            contextUsed: ctxUsed, contextMax: contextMax,
            inputTokens: totalIn, outputTokens: totalOut,
            cacheReadTokens: totalCR, cacheWriteTokens: totalCC,
            p50ms: p50, p95ms: p95, lastRequestMs: lastMs,
            latencyHistory: latencies,
            thinking: thinking
        )
        _ = family // reserved for plan-pricing dispatch in the future
        let quota = Quota(
            plan: plan,
            pricingInPerMTok: pin, pricingOutPerMTok: pout,
            windows: [
                QuotaWindow(label: "5H", used: used5h, cap: cap5h,
                            costUSD: cost5h,
                            resetInSec: max(0, Int(5 * 3600 - elapsed))),
                QuotaWindow(label: "7D", used: used7d, cap: cap7d,
                            costUSD: cost7d, resetInSec: 7 * 86400),
            ]
        )
        return Telemetry(agent: agent, model: model, quota: quota, source: "LIVE")
    }

    // Claude Code appends metadata events (last-prompt, permission-mode,
    // summary, system, file-history-snapshot) mid-turn. They aren't agent state.
    private static let metaTypes: Set<String> = [
        "last-prompt", "permission-mode", "summary", "system",
        "file-history-snapshot",
    ]

    private func deriveStatus(lastAssistantIdx: Int)
        -> (AgentStatus, String?, String)
    {
        if events.isEmpty { return (.idle, nil, "no events") }
        // Claude Code interleaves the conversation with hook output
        // (`attachment`), title/agent metadata (`ai-title`, `agent-name`),
        // queue ops, and snapshot bookkeeping. None of those reflect agent
        // state — only `user` and `assistant` lines do — so walk back to
        // the most recent one and ignore everything else.
        let ev = events.reversed().first {
            $0.type == "user" || $0.type == "assistant"
        }
        guard let ev else {
            return (.processing, nil, "processing prompt")
        }

        if ev.type == "user" {
            let c = ev.message["content"]
            if let s = c as? String, !s.trimmingCharacters(in: .whitespaces).isEmpty {
                return (.processing, nil, "processing prompt")
            }
            // Array content = tool_result coming back. Claude is parsing
            // it AND already drafting the next chunk — we can't separate
            // the two from the jsonl, so use the neutral "processing"
            // verb instead of misleadingly sticking on "thinking".
            if c is [Any] {
                return (.processing, nil, "tool result returned")
            }
            return (.processing, nil, "reading context")
        }
        if ev.type == "assistant" {
            let content = (ev.message["content"] as? [[String: Any]]) ?? []
            for block in content.reversed() where (block["type"] as? String) == "tool_use" {
                let name = block["name"] as? String
                let input = (block["input"] as? [String: Any]) ?? [:]
                var target = ""
                for key in ["file_path", "path", "command", "pattern"] {
                    if let v = input[key] as? String { target = v; break }
                }
                let home = FileManager.default.homeDirectoryForCurrentUser.path
                target = target.replacingOccurrences(of: home, with: "~")
                if target.count > 48 { target = String(target.prefix(48)) }
                return (.tool, name, target.isEmpty ? "running" : target)
            }
            let age = ev.timestamp > 0
                ? Date.now.timeIntervalSince1970 - ev.timestamp
                : .infinity
            // "thinking" is only meaningful when the message JUST landed.
            // After a few seconds Claude has almost certainly moved on to
            // streaming the next chunk, so don't get stuck on the label.
            if age < 3,
               let last = content.last, (last["type"] as? String) == "thinking" {
                return (.thinking, nil, "reasoning")
            }
            if age < 3 {
                return (.writing, nil, "drafting response")
            }
            return (.idle, nil, "awaiting next directive")
        }
        return (.idle, nil, "—")
    }

    private func deriveLog() -> [LogEntry] {
        var out: [LogEntry] = []
        var id = 0
        for ev in events.reversed() {
            if out.count >= 30 { break }
            let ts = hmsLocal(ev.timestamp)
            switch ev.type {
            case "user":
                let c = ev.message["content"]
                if let s = c as? String, !s.trimmingCharacters(in: .whitespaces).isEmpty {
                    id += 1
                    let head = String(s.trimmingCharacters(in: .whitespaces).prefix(42))
                    out.append(LogEntry(id: id, ts: ts, tag: .info,
                                        msg: "prompt.received  →  \(head)"))
                } else if let arr = c as? [[String: Any]] {
                    for block in arr where (block["type"] as? String) == "tool_result" {
                        let isErr = (block["is_error"] as? Bool) == true
                        var snippet = ""
                        if let res = block["content"] as? [[String: Any]] {
                            snippet = res.compactMap { b in
                                guard (b["type"] as? String) == "text",
                                      let t = b["text"] as? String else { return nil }
                                return String(t.prefix(60))
                            }.joined(separator: " ")
                        } else if let res = block["content"] as? String {
                            snippet = String(res.prefix(60))
                        }
                        id += 1
                        out.append(LogEntry(
                            id: id, ts: ts,
                            tag: isErr ? .err : .ok,
                            msg: (isErr ? "tool.error  " : "tool.result  ")
                                + snippet.trimmingCharacters(in: .whitespacesAndNewlines)
                                  .replacingOccurrences(of: "\n", with: " ")
                        ))
                        break
                    }
                }
            case "assistant":
                if let content = ev.message["content"] as? [[String: Any]] {
                    for block in content where (block["type"] as? String) == "tool_use" {
                        let name = (block["name"] as? String) ?? ""
                        let input = (block["input"] as? [String: Any]) ?? [:]
                        var target = ""
                        for key in ["file_path", "path", "command", "pattern"] {
                            if let v = input[key] as? String { target = v; break }
                        }
                        let home = FileManager.default.homeDirectoryForCurrentUser.path
                        target = target.replacingOccurrences(of: home, with: "~")
                        if target.count > 42 { target = String(target.prefix(42)) }
                        id += 1
                        let msg = "tool.call  \(name)  \(target)"
                            .trimmingCharacters(in: .whitespaces)
                        out.append(LogEntry(id: id, ts: ts, tag: .info, msg: msg))
                    }
                }
            default: break
            }
        }
        return out
    }

    private func deriveSubAgents() -> [SubAgent] {
        var results: [String: [String: Any]] = [:]
        for ev in events where ev.type == "user" {
            if let arr = ev.message["content"] as? [[String: Any]] {
                for block in arr where (block["type"] as? String) == "tool_result" {
                    if let tid = block["tool_use_id"] as? String {
                        results[tid] = block
                    }
                }
            }
        }
        var found: [SubAgent] = []
        for ev in events where ev.type == "assistant" {
            let ts = (ev.raw["timestamp"] as? String) ?? ""
            if let content = ev.message["content"] as? [[String: Any]] {
                for block in content where (block["type"] as? String) == "tool_use" {
                    let name = (block["name"] as? String) ?? ""
                    if name != "Agent", name != "Task" { continue }
                    let tid = (block["id"] as? String) ?? ""
                    let input = (block["input"] as? [String: Any]) ?? [:]
                    let res = results[tid]
                    let status: SubAgentStatus = res == nil
                        ? .running
                        : ((res?["is_error"] as? Bool) == true ? .error : .done)
                    found.append(SubAgent(
                        toolUseID: tid,
                        subagentType: (input["subagent_type"] as? String) ?? "general",
                        description: String(((input["description"] as? String) ?? "").prefix(60)),
                        status: status,
                        startedAt: ts
                    ))
                }
            }
        }
        // newest first, running pinned to the top, cap 8
        found.reverse()
        let running = found.filter { $0.status == .running }
        let finished = found.filter { $0.status != .running }
        return Array((running + finished).prefix(8))
    }
}

// MARK: - Helpers

private struct Event {
    let raw: [String: Any]
    let type: String
    let timestamp: TimeInterval
    let message: [String: Any]
    let usage: Usage?

    struct Usage {
        let input, output, cacheRead, cacheCreate: Double
    }

    init(raw: [String: Any]) {
        self.raw = raw
        self.type = (raw["type"] as? String) ?? ""
        if let s = raw["timestamp"] as? String,
           let d = ClaudeCodeSource.iso8601.date(from: s) {
            self.timestamp = d.timeIntervalSince1970
        } else {
            self.timestamp = 0
        }
        let msg = (raw["message"] as? [String: Any]) ?? [:]
        self.message = msg
        if type == "assistant", let u = msg["usage"] as? [String: Any] {
            self.usage = Usage(
                input: (u["input_tokens"] as? Double) ?? Double((u["input_tokens"] as? Int) ?? 0),
                output: (u["output_tokens"] as? Double) ?? Double((u["output_tokens"] as? Int) ?? 0),
                cacheRead: (u["cache_read_input_tokens"] as? Double)
                    ?? Double((u["cache_read_input_tokens"] as? Int) ?? 0),
                cacheCreate: (u["cache_creation_input_tokens"] as? Double)
                    ?? Double((u["cache_creation_input_tokens"] as? Int) ?? 0)
            )
        } else {
            self.usage = nil
        }
    }
}

extension ClaudeCodeSource {
    // ISO8601DateFormatter is documented thread-safe for parsing (Foundation
    // archives state per-call). Reads only, configured once at init.
    fileprivate nonisolated(unsafe) static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

// (Removed `inferThinkingEffort` heuristic — it was guessing the
// /effort setting from observed thinking-text length, which is not
// reliable in either direction. See comment in `buildTelemetry`.)

/// Scans recent user events for the `/thinking` slash command's stdout
/// marker (`<local-command-stdout>Effort level set to X</local-command-stdout>`)
/// and returns the last-set effort string (e.g. "auto", "high"). Returns
/// nil when no marker is present in the visible event window.
private func parseExplicitEffort(events: [Event]) -> String? {
    // Walk most-recent-first. The `/thinking` command can be re-issued
    // mid-session, so the latest invocation is what's currently active.
    for ev in events.reversed() where ev.type == "user" {
        let text = effortMarkerText(ev.message)
        guard !text.isEmpty,
              let range = text.range(of: "Effort level set to ") else { continue }
        let tail = text[range.upperBound...]
        // The level token ends at whitespace or the closing tag.
        let level = tail.prefix { ch in
            !ch.isWhitespace && ch != "<"
        }
        let trimmed = level.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return trimmed.lowercased() }
    }
    return nil
}

/// Flatten the various shapes Claude Code uses for user-message content
/// into a single searchable string. The `/thinking` marker can land in a
/// plain-string body or inside an array of `tool_result`-style blocks.
private func effortMarkerText(_ message: [String: Any]) -> String {
    if let s = message["content"] as? String { return s }
    guard let arr = message["content"] as? [[String: Any]] else { return "" }
    var combined = ""
    for block in arr {
        if let s = block["text"] as? String { combined += s + "\n" }
        if let s = block["content"] as? String { combined += s + "\n" }
    }
    return combined
}

private func newestJSONL(under root: URL) -> URL? {
    guard let it = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsHiddenFiles]) else { return nil }
    var best: URL?
    var bestMtime: TimeInterval = -1
    for case let url as URL in it where url.pathExtension == "jsonl" {
        if let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSince1970, m > bestMtime
        {
            best = url
            bestMtime = m
        }
    }
    return best
}

private func gitDirty(cwd: String) -> Bool {
    guard !cwd.isEmpty else { return false }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = ["git", "-C", (cwd as NSString).expandingTildeInPath,
                   "status", "--porcelain"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = Pipe()
    do { try p.run() } catch { return false }
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { return false }
    let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
    return !data.isEmpty
}

private func shortSessionID(_ uuid: String) -> String {
    let s = uuid.replacingOccurrences(of: "-", with: "").uppercased()
    if s.count < 8 { return "----" }
    let head = s.prefix(4)
    let tail = s.suffix(4)
    return "\(head)-\(tail)"
}

private func parseModelID(_ id: String) -> (String, String, String, Int, Double, Double) {
    let opusPricing  = (200_000, 15.0, 75.0)
    let sonnetPricing = (200_000,  3.0, 15.0)
    let haikuPricing  = (200_000,  0.8,  4.0)
    if id.isEmpty {
        return ("CLAUDE", "?", "opus", opusPricing.0, opusPricing.1, opusPricing.2)
    }
    // claude-(opus|sonnet|haiku)-(\d+)(?:-(\d+))?
    let parts = id.split(separator: "-")
    guard parts.count >= 3, parts[0] == "claude" else {
        return ("CLAUDE", "?", "opus", opusPricing.0, opusPricing.1, opusPricing.2)
    }
    let family = String(parts[1])
    let major = String(parts[2])
    var minor: String? = nil
    if parts.count >= 4, Int(parts[3]) != nil { minor = String(parts[3]) }
    let version = minor.map { "\(major).\($0)" } ?? major
    let (ctx, pin, pout): (Int, Double, Double)
    switch family {
    case "sonnet": (ctx, pin, pout) = sonnetPricing
    case "haiku":  (ctx, pin, pout) = haikuPricing
    default:       (ctx, pin, pout) = opusPricing
    }
    return ("CLAUDE \(family.uppercased())", version, family, ctx, pin, pout)
}

private func ceilNice(_ n: Double) -> Double {
    guard n > 0 else { return 1 }
    let k = floor(log10(n))
    let base = pow(10, k)
    for mult in [1.0, 2.0, 5.0, 10.0] {
        let v = mult * base
        if v >= n { return v }
    }
    return 10 * base
}

private let hmsLocalFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
}()
private func hmsLocal(_ ts: TimeInterval) -> String {
    guard ts > 0 else { return "--:--:--" }
    return hmsLocalFormatter.string(from: Date(timeIntervalSince1970: ts))
}

private func isoToDate(_ s: String) -> Date? {
    ClaudeCodeSource.iso8601.date(from: s)
}
