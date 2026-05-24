// Live Codex/AGY telemetry - tails Codex-format rollout jsonl files and
// derives the shared Telemetry shape consumed by the renderers.

import Foundation
import os.log

private struct CodexTokenSample {
    let ts: TimeInterval
    let input: Double
    let output: Double
    let cacheRead: Double
    let cacheCreate: Double
}

private struct CodexRateLimitWindow {
    let usedPercent: Double
    let windowMinutes: Double
    let resetsAt: TimeInterval
}

private struct CodexRateLimitSnapshot {
    let planLabel: String?
    let primary: CodexRateLimitWindow?
    let secondary: CodexRateLimitWindow?
}

enum CodexAgentKind: String {
    case codex
    case agy

    var label: String {
        switch self {
        case .codex: return "Codex"
        case .agy: return "AGY"
        }
    }

    var plan: String {
        switch self {
        case .codex: return "API USAGE"
        case .agy: return "AGY"
        }
    }

    var provider: String {
        switch self {
        case .codex: return "openai"
        case .agy: return "local"
        }
    }

    var configURL: URL {
        let path: String
        switch self {
        case .codex: path = "~/.codex/config.toml"
        case .agy: path = "~/.agy/config.toml"
        }
        return URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
    }
}

final class CodexSource: TelemetrySource {
    let label: String

    private let kind: CodexAgentKind
    private let sessionsDirs: [URL]
    private let logger: Logger
    private let plan: String

    private var jsonl: URL?
    private var pinned: URL?
    private var offset: UInt64 = 0
    private var events: [CodexEvent] = []
    private var latencies: [Double] = []
    private var tokenHistory: [CodexTokenSample] = []
    private var lastStatus: AgentStatus = .idle
    private var statusStarted: Date = .now
    private var lastDiscoveryAt: TimeInterval = 0
    private var lastGitDirtyCwd = ""
    private var lastGitDirtyAt: TimeInterval = 0
    private var lastGitDirty = false
    private var cachedReasoningConfig = CodexReasoningConfig()
    private var lastReasoningConfigReadAt: TimeInterval = -Double.infinity
    private let discoveryInterval: TimeInterval = 5
    private let gitDirtyInterval: TimeInterval = 30
    private let reasoningConfigInterval: TimeInterval = 5
    private let maxRetainedEvents = 4_000
    private let maxRetainedTokenSamples = 2_000

    init(kind: CodexAgentKind = .codex, sessionsDirs: [URL]? = nil) {
        self.kind = kind
        self.label = kind.label
        self.plan = kind.plan
        self.sessionsDirs = sessionsDirs ?? Self.defaultSessionsDirs(for: kind)
        self.logger = Logger(subsystem: "tech.bluevisor.NeoDashboard",
                             category: kind.label)
    }

    func tick() -> Telemetry {
        refreshActiveFile()
        tailNewLines()
        return buildTelemetry()
    }

    func setPinned(_ url: URL?) {
        if pinned == url { return }
        pinned = url
        jsonl = nil
        offset = 0
        events.removeAll(keepingCapacity: true)
        latencies.removeAll(keepingCapacity: true)
        lastDiscoveryAt = 0
    }

    // MARK: - File discovery + tailing

    private func refreshActiveFile() {
        let pick: URL?
        if let p = pinned, FileManager.default.fileExists(atPath: p.path) {
            pick = p
        } else {
            let now = Date.now.timeIntervalSince1970
            if now - lastDiscoveryAt < discoveryInterval { return }
            lastDiscoveryAt = now
            pick = newestJSONL()
        }
        guard let next = pick else { return }
        if next != jsonl {
            logger.info("active rollout: \(next.path, privacy: .public)")
            jsonl = next
            offset = 0
            events.removeAll(keepingCapacity: true)
            latencies.removeAll(keepingCapacity: true)
            tokenHistory.removeAll(keepingCapacity: true)
        }
    }

    private func newestJSONL() -> URL? {
        let fm = FileManager.default
        var best: URL?
        var bestMtime: TimeInterval = -1

        for root in sessionsDirs {
            let options: FileManager.DirectoryEnumerationOptions = kind == .agy ? [] : [.skipsHiddenFiles]
            guard let it = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: options
            ) else { continue }
            for case let url as URL in it where url.pathExtension == "jsonl" {
                guard let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate?.timeIntervalSince1970,
                    mtime > bestMtime else { continue }
                best = url
                bestMtime = mtime
            }
        }
        return best
    }

    private func tailNewLines() {
        guard let url = jsonl else { return }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value else { return }
        if size < offset {
            offset = 0
            events.removeAll(keepingCapacity: true)
        }

        if events.isEmpty && url.path.contains("transcript") {
            let sessionID = SessionDiscovery.rolloutID(from: url)
            let cwd = FileManager.default.currentDirectoryPath
            let isoString = CodexSource.iso8601Fractional.string(from: Date.now)
            let metaDict: [String: Any] = [
                "type": "session_meta",
                "payload": [
                    "id": sessionID,
                    "cwd": cwd,
                    "timestamp": isoString
                ]
            ]
            events.append(CodexEvent(raw: metaDict))
        }

        if size == offset { return }

        guard let fh = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? fh.close() }

        var prevTs: TimeInterval? = events.last?.timestamp
        func consume(_ chunk: Data) {
            let s = String(data: chunk, encoding: .utf8) ?? ""
            for raw in s.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let data = raw.data(using: .utf8),
                      let any = try? JSONSerialization.jsonObject(with: data),
                      let dict = any as? [String: Any] else { continue }
                let ev = CodexEvent(raw: dict)
                events.append(ev)

                if ev.type == "response_item",
                   let payloadType = ev.payload["type"] as? String,
                   ["message", "function_call"].contains(payloadType),
                   let p = prevTs,
                   ev.timestamp > 0 {
                    let dtMs = max(0, (ev.timestamp - p) * 1000)
                    if dtMs > 50, dtMs < 300_000 {
                        latencies.append(dtMs)
                        if latencies.count > 64 { latencies.removeFirst(latencies.count - 64) }
                    }
                }
                if ev.timestamp > 0 { prevTs = ev.timestamp }
                if let row = tokenRow(ev) {
                    tokenHistory.append(row)
                }
            }
        }

        do {
            let maxInitialBytes: UInt64 = 768 * 1024
            let headBytes: UInt64 = 128 * 1024
            if offset == 0, size > maxInitialBytes {
                try fh.seek(toOffset: 0)
                consume(try fh.read(upToCount: Int(headBytes)) ?? Data())
                try fh.seek(toOffset: size - maxInitialBytes)
                consume(try fh.readToEnd() ?? Data())
                offset = currentFileSize(url) ?? size
            } else {
                try fh.seek(toOffset: offset)
                consume(try fh.readToEnd() ?? Data())
                offset = currentFileSize(url) ?? size
            }
            trimBuffers()
        } catch {
            logger.warning("tail failed: \(error.localizedDescription, privacy: .public)")
            return
        }
    }

    private func trimBuffers() {
        if events.count > maxRetainedEvents {
            let tail = Array(events.suffix(maxRetainedEvents))
            if let meta = events.first(where: { $0.type == "session_meta" }),
               !tail.contains(where: { $0.type == "session_meta" }) {
                events = [meta] + tail
            } else {
                events = tail
            }
        }
        if tokenHistory.count > maxRetainedTokenSamples {
            tokenHistory.removeFirst(tokenHistory.count - maxRetainedTokenSamples)
        }
    }

    private func currentFileSize(_ url: URL) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?
            .uint64Value
    }

    private func tokenRow(_ ev: CodexEvent) -> CodexTokenSample? {
        guard ev.type == "event_msg",
              (ev.payload["type"] as? String) == "token_count" else { return nil }
        let info = ev.payload["info"] as? [String: Any] ?? [:]
        let usage = info["last_token_usage"] as? [String: Any] ?? [:]
        let input = doubleValue(usage["input_tokens"])
        let output = doubleValue(usage["output_tokens"])
            + doubleValue(usage["reasoning_output_tokens"])
        let cacheRead = doubleValue(usage["cached_input_tokens"])
        guard ev.timestamp > 0, input + output + cacheRead > 0 else { return nil }
        return CodexTokenSample(ts: ev.timestamp, input: input, output: output,
                                cacheRead: cacheRead, cacheCreate: 0)
    }

    // MARK: - Derivation

    private func buildTelemetry() -> Telemetry {
        if events.isEmpty { return emptyTelemetry() }

        var cwd = ""
        var sessionUUID = ""
        var startedAt = ""
        var modelID = ""
        var observedContextMax = 0.0
        var totalIn = 0.0
        var totalOut = 0.0
        var totalCacheRead = 0.0
        var totalCacheCreate = 0.0
        var lastContextUsed = 0.0

        for ev in events {
            if ev.type == "session_meta" {
                cwd = (ev.payload["cwd"] as? String) ?? cwd
                sessionUUID = (ev.payload["id"] as? String) ?? sessionUUID
                startedAt = (ev.payload["timestamp"] as? String)
                    ?? (ev.raw["timestamp"] as? String)
                    ?? startedAt
            } else if ev.type == "turn_context" {
                cwd = (ev.payload["cwd"] as? String) ?? cwd
                modelID = (ev.payload["model"] as? String) ?? modelID
            } else if ev.type == "event_msg" {
                if (ev.payload["type"] as? String) == "token_count" {
                    let info = ev.payload["info"] as? [String: Any] ?? [:]
                    let total = info["total_token_usage"] as? [String: Any] ?? [:]
                    totalIn = doubleValue(total["input_tokens"])
                    totalOut = doubleValue(total["output_tokens"])
                        + doubleValue(total["reasoning_output_tokens"])
                    totalCacheRead = doubleValue(total["cached_input_tokens"])
                    totalCacheCreate = 0
                    observedContextMax = doubleValue(info["model_context_window"])
                    let last = info["last_token_usage"] as? [String: Any] ?? [:]
                    lastContextUsed = doubleValue(last["total_tokens"])
                } else if (ev.payload["type"] as? String) == "user_message",
                          let msg = ev.payload["message"] as? String {
                    // Antigravity stamps a `<USER_SETTINGS_CHANGE>The user
                    // changed setting `Model Selection` from None to <NAME>.
                    // <next sentence>` block into the first user message of
                    // each transcript. Extract <NAME> by looking for the
                    // sentence boundary (". " — period + space), not the
                    // first `.`, because model names like "Gemini 3.5 Flash
                    // (Medium)" contain decimals that would otherwise
                    // truncate the name to "Gemini 3".
                    if let range = msg.range(of: "Model Selection` from "),
                       let toRange = msg[range.upperBound...].range(of: " to ") {
                        let tail = msg[toRange.upperBound...]
                        let endRange = tail.range(of: ". ")
                            ?? tail.range(of: ".\n")
                            ?? tail.range(of: ".")
                        if let endRange {
                            let modelPart = String(tail[tail.startIndex..<endRange.lowerBound])
                            modelID = modelPart
                        }
                    }
                }
            }
        }

        if modelID.isEmpty { modelID = kind == .codex ? "gpt-5" : "gemini" }
        let modelSpec = parseCodexModelID(modelID, observedContextMax: observedContextMax)
        let contextUsed = lastContextUsed > 0 ? lastContextUsed : totalIn + totalCacheRead

        let currentTask = currentTask(events)
        let turn = events.reduce(0) { count, ev in
            count + ((ev.type == "event_msg"
                      && (ev.payload["type"] as? String) == "user_message") ? 1 : 0)
        }
        let (filesRead, filesEdited) = fileCounts(events)
        let (status, currentTool, detail) = deriveStatus(events)
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

        let p50: Double
        let p95: Double
        let lastMs: Double
        if latencies.isEmpty {
            p50 = 0; p95 = 0; lastMs = 0
        } else {
            let sorted = latencies.sorted()
            p50 = sorted[sorted.count / 2]
            p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
            lastMs = latencies.last ?? 0
        }

        let now = Date.now.timeIntervalSince1970
        let cutoff5h = now - 5 * 3600
        let cutoff7d = now - 7 * 86400
        var used5h = 0.0, used7d = 0.0, cost5h = 0.0, cost7d = 0.0
        for sample in tokenHistory {
            let cost = (sample.input * modelSpec.pricingIn
                        + sample.output * modelSpec.pricingOut
                        + sample.cacheRead * modelSpec.pricingIn * 0.10
                        + sample.cacheCreate * modelSpec.pricingIn * 1.25) / 1_000_000
            if sample.ts >= cutoff7d {
                used7d += sample.input + sample.output + sample.cacheRead + sample.cacheCreate
                cost7d += cost
            }
            if sample.ts >= cutoff5h {
                used5h += sample.input + sample.output + sample.cacheRead + sample.cacheCreate
                cost5h += cost
            }
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let prettyCWD = (cwd.isEmpty ? "~" : cwd).replacingOccurrences(of: home, with: "~")
        let started = codexISOToDate(startedAt) ?? .now
        let thinking = codexReasoningEffort(events)
            ?? configuredReasoningEffort(cwd: cwd)
            ?? modelSpec.thinkingLevel

        let agent = Agent(
            kind: kind.rawValue,
            sessionID: shortCodexSessionID(sessionUUID),
            cwd: prettyCWD,
            gitBranch: "",
            gitDirty: cachedGitDirty(cwd: cwd),
            startedAt: started,
            status: status,
            currentTask: String(currentTask.prefix(280)),
            currentTool: currentTool,
            detail: detail,
            progress: progress,
            turn: turn,
            filesRead: filesRead,
            filesEdited: filesEdited,
            log: deriveLog(events),
            subAgents: []
        )
        let model = AgentModel(
            id: modelID,
            name: modelSpec.name,
            version: modelSpec.version,
            provider: modelSpec.provider,
            contextUsed: contextUsed,
            contextMax: modelSpec.contextMax,
            inputTokens: totalIn,
            outputTokens: totalOut,
            cacheReadTokens: totalCacheRead,
            cacheWriteTokens: totalCacheCreate,
            p50ms: p50,
            p95ms: p95,
            lastRequestMs: lastMs,
            latencyHistory: latencies,
            thinking: thinking.map { .effort($0) } ?? .on
        )
        let rateLimits = latestCodexRateLimits(events)
        let planLabel = rateLimits?.planLabel ?? plan
        let quota = Quota(
            plan: planLabel,
            pricingInPerMTok: modelSpec.pricingIn,
            pricingOutPerMTok: modelSpec.pricingOut,
            windows: quotaWindows(
                plan: planLabel,
                rateLimits: rateLimits,
                used5h: used5h,
                used7d: used7d,
                cost5h: cost5h,
                cost7d: cost7d,
                now: now
            )
        )
        return Telemetry(agent: agent, model: model, quota: quota, source: "LIVE")
    }

    private func emptyTelemetry() -> Telemetry {
        var tel = Telemetry.empty()
        tel.agent.kind = kind.rawValue
        tel.agent.detail = "waiting for \(kind.rawValue) rollout jsonl"
        tel.agent.log = [
            LogEntry(id: 1, ts: hms(Date()), tag: .info,
                     msg: "watching \(sessionsDirs.map { $0.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~") }.joined(separator: ", "))")
        ]
        tel.model.name = kind == .codex ? "GPT" : "AGY"
        tel.model.provider = kind.provider
        tel.model.contextMax = 400_000
        tel.quota.plan = plan
        tel.quota.windows = [
            QuotaWindow(label: "5H", used: 0, cap: 8_000_000,
                        costUSD: 0, resetInSec: 5 * 3600),
            QuotaWindow(label: "7D", used: 0, cap: 100_000_000,
                        costUSD: 0, resetInSec: 7 * 86400),
        ]
        tel.hasContent = false
        return tel
    }

    // MARK: - Static helpers

    private static func defaultSessionsDirs(for kind: CodexAgentKind) -> [URL] {
        let codex = URL(fileURLWithPath: NSString("~/.codex/sessions").expandingTildeInPath,
                        isDirectory: true)
        let agy = URL(fileURLWithPath: NSString("~/.gemini/antigravity-cli/brain").expandingTildeInPath,
                      isDirectory: true)
        switch kind {
        case .codex: return [codex]
        case .agy: return [agy]
        }
    }

    private func cachedGitDirty(cwd: String) -> Bool {
        let now = Date.now.timeIntervalSince1970
        guard !cwd.isEmpty else { return false }
        if cwd == lastGitDirtyCwd, now - lastGitDirtyAt < gitDirtyInterval {
            return lastGitDirty
        }
        lastGitDirtyCwd = cwd
        lastGitDirtyAt = now
        lastGitDirty = gitDirtyCodex(cwd: cwd)
        return lastGitDirty
    }

    private func configuredReasoningEffort(cwd: String) -> String? {
        let now = Date.now.timeIntervalSince1970
        if now - lastReasoningConfigReadAt >= reasoningConfigInterval {
            cachedReasoningConfig = CodexReasoningConfig.load(from: kind.configURL)
            lastReasoningConfigReadAt = now
        }
        return cachedReasoningConfig.effort(for: cwd)
    }
}

// MARK: - Event derivation helpers

private struct CodexReasoningConfig {
    var globalEffort: String?
    var projectEfforts: [String: String] = [:]

    func effort(for cwd: String) -> String? {
        let path = NSString(string: cwd).expandingTildeInPath
        let best = projectEfforts
            .filter { project, _ in
                path == project || path.hasPrefix(project.hasSuffix("/") ? project : project + "/")
            }
            .max { a, b in a.key.count < b.key.count }
        return best?.value ?? globalEffort
    }

    static func load(from url: URL) -> CodexReasoningConfig {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return CodexReasoningConfig()
        }

        var config = CodexReasoningConfig()
        var section: String?
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }

            if line.hasPrefix("["), line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast())
                continue
            }

            guard let (key, value) = tomlKeyValue(line),
                  ["model_reasoning_effort", "reasoning_effort"].contains(key),
                  let effort = normalizedReasoningEffort(value) else {
                continue
            }
            if let project = projectPath(from: section) {
                config.projectEfforts[project] = effort
            } else if section == nil {
                config.globalEffort = effort
            }
        }
        return config
    }

    private static func projectPath(from section: String?) -> String? {
        guard let section,
              section.hasPrefix("projects.\""),
              section.hasSuffix("\"") else { return nil }
        return String(section.dropFirst("projects.\"".count).dropLast())
    }
}

private func tomlKeyValue(_ line: String) -> (String, String)? {
    guard let eq = line.firstIndex(of: "=") else { return nil }
    let key = line[..<eq].trimmingCharacters(in: .whitespacesAndNewlines)
    var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty, !value.isEmpty else { return nil }

    if value.hasPrefix("\"") {
        value.removeFirst()
        if let end = value.firstIndex(of: "\"") {
            value = String(value[..<end])
        }
    } else {
        value = value.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    return (key, String(value))
}

private struct CodexEvent {
    let raw: [String: Any]
    let type: String
    let timestamp: TimeInterval
    let payload: [String: Any]

    init(raw: [String: Any]) {
        self.raw = raw
        
        let isTranscript = raw["step_index"] != nil || raw["source"] != nil
        if isTranscript {
            let typeStr = (raw["type"] as? String) ?? ""
            let stepIndex = (raw["step_index"] as? Int) ?? 0
            let contentStr = (raw["content"] as? String) ?? ""
            
            if typeStr == "USER_INPUT" {
                self.type = "event_msg"
                self.payload = [
                    "type": "user_message",
                    "message": contentStr
                ]
            } else if typeStr == "PLANNER_RESPONSE" {
                self.type = "response_item"
                if let toolCalls = raw["tool_calls"] as? [[String: Any]], let firstCall = toolCalls.first {
                    let name = firstCall["name"] as? String ?? "tool"
                    let args = firstCall["args"] as? [String: Any] ?? [:]
                    self.payload = [
                        "type": "function_call",
                        "call_id": "step_\(stepIndex)",
                        "name": name,
                        "arguments": args
                    ]
                } else {
                    self.payload = [
                        "type": "message",
                        "role": "assistant",
                        "content": contentStr
                    ]
                }
            } else if (raw["source"] as? String) == "MODEL" && typeStr != "PLANNER_RESPONSE" {
                self.type = "response_item"
                self.payload = [
                    "type": "function_call_output",
                    "call_id": "step_\(stepIndex - 1)",
                    "output": contentStr
                ]
            } else {
                self.type = typeStr
                self.payload = (raw["payload"] as? [String: Any]) ?? [:]
            }
        } else {
            self.type = (raw["type"] as? String) ?? ""
            self.payload = (raw["payload"] as? [String: Any]) ?? [:]
        }
        
        if let s = (raw["timestamp"] as? String) ?? (raw["created_at"] as? String),
           let d = codexISOToDate(s) {
            self.timestamp = d.timeIntervalSince1970
        } else {
            self.timestamp = 0
        }
    }
}

private func codexReasoningEffort(_ events: [CodexEvent]) -> String? {
    for ev in events.reversed() {
        if let effort = reasoningEffort(in: ev.payload) ?? reasoningEffort(in: ev.raw) {
            return effort
        }
    }
    return nil
}

private func latestCodexRateLimits(_ events: [CodexEvent]) -> CodexRateLimitSnapshot? {
    for ev in events.reversed() {
        guard let raw = ev.payload["rate_limits"] as? [String: Any] else { continue }
        return CodexRateLimitSnapshot(
            planLabel: codexPlanLabel(raw["plan_type"]) ?? codexPlanLabel(raw["limit_name"]),
            primary: codexRateLimitWindow(raw["primary"]),
            secondary: codexRateLimitWindow(raw["secondary"])
        )
    }
    return nil
}

private func codexRateLimitWindow(_ raw: Any?) -> CodexRateLimitWindow? {
    guard let dict = raw as? [String: Any] else { return nil }
    let usedPercent = doubleValue(dict["used_percent"])
    let windowMinutes = doubleValue(dict["window_minutes"])
    let resetsAt = doubleValue(dict["resets_at"])
    guard usedPercent > 0 || windowMinutes > 0 || resetsAt > 0 else { return nil }
    return CodexRateLimitWindow(
        usedPercent: usedPercent,
        windowMinutes: windowMinutes,
        resetsAt: resetsAt
    )
}

private func codexPlanLabel(_ raw: Any?) -> String? {
    guard let value = raw as? String else { return nil }
    let plan = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !plan.isEmpty else { return nil }
    let normalized = plan.lowercased()
        .replacingOccurrences(of: "-", with: "_")
        .replacingOccurrences(of: " ", with: "_")
    switch normalized {
    case "api", "api_key", "api_usage", "usage":
        return "API USAGE"
    case "chatgpt_plus":
        return "PLUS"
    default:
        return normalized
            .split(separator: "_")
            .map { $0.uppercased() }
            .joined(separator: " ")
    }
}

private func quotaWindows(plan: String,
                          rateLimits: CodexRateLimitSnapshot?,
                          used5h: Double,
                          used7d: Double,
                          cost5h: Double,
                          cost7d: Double,
                          now: TimeInterval) -> [QuotaWindow] {
    if isAPIBillingPlan(plan) {
        return [
            QuotaWindow(label: "5H", used: used5h,
                        cap: max(8_000_000, ceilNiceCodex(used5h * 1.3)),
                        costUSD: cost5h,
                        resetInSec: 5 * 3600),
            QuotaWindow(label: "7D", used: used7d,
                        cap: max(100_000_000, ceilNiceCodex(used7d * 1.3)),
                        costUSD: cost7d,
                        resetInSec: 7 * 86400),
        ]
    }

    return [
        subscriptionQuotaWindow(label: "5H", used: used5h,
                                fallbackCap: 8_000_000,
                                rateLimit: rateLimits?.primary,
                                defaultReset: 5 * 3600,
                                now: now),
        subscriptionQuotaWindow(label: "7D", used: used7d,
                                fallbackCap: 100_000_000,
                                rateLimit: rateLimits?.secondary,
                                defaultReset: 7 * 86400,
                                now: now),
    ]
}

private func subscriptionQuotaWindow(label: String,
                                     used: Double,
                                     fallbackCap: Double,
                                     rateLimit: CodexRateLimitWindow?,
                                     defaultReset: Int,
                                     now: TimeInterval) -> QuotaWindow {
    let pct = rateLimit?.usedPercent ?? 0
    let cap: Double
    let displayUsed: Double
    if pct > 0, used > 0 {
        cap = max(used * 100 / pct, 1)
        displayUsed = used
    } else if pct > 0 {
        cap = fallbackCap
        displayUsed = fallbackCap * pct / 100
    } else {
        cap = max(fallbackCap, ceilNiceCodex(used * 1.3))
        displayUsed = used
    }

    let reset: Int
    if let resetsAt = rateLimit?.resetsAt, resetsAt > 0 {
        reset = max(0, Int(resetsAt - now))
    } else {
        reset = defaultReset
    }

    return QuotaWindow(label: label, used: displayUsed, cap: cap,
                       costUSD: 0, resetInSec: reset)
}

private func isAPIBillingPlan(_ plan: String) -> Bool {
    plan.uppercased().contains("API")
}

private func reasoningEffort(in dict: [String: Any], depth: Int = 0) -> String? {
    guard depth < 4 else { return nil }
    for key in ["model_reasoning_effort", "reasoning_effort", "reasoningEffort"] {
        if let effort = normalizedReasoningEffort(dict[key]) {
            return effort
        }
    }
    for key in ["config", "settings", "model", "request", "request_options", "options", "payload"] {
        if let nested = dict[key] as? [String: Any],
           let effort = reasoningEffort(in: nested, depth: depth + 1) {
            return effort
        }
    }
    return nil
}

private func normalizedReasoningEffort(_ value: Any?) -> String? {
    guard let raw = value as? String else { return nil }
    let effort = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !effort.isEmpty else { return nil }
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
    guard effort.rangeOfCharacter(from: allowed.inverted) == nil else { return nil }
    return effort
}

private func currentTask(_ events: [CodexEvent]) -> String {
    for ev in events.reversed() {
        if ev.type == "event_msg",
           (ev.payload["type"] as? String) == "user_message",
           let msg = ev.payload["message"] as? String,
           !msg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return msg.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if ev.type == "response_item",
           (ev.payload["type"] as? String) == "message",
           (ev.payload["role"] as? String) == "user" {
            let text = contentText(ev.payload["content"])
            if !text.isEmpty, !text.hasPrefix("<environment_context>") {
                return text
            }
        }
    }
    return "(no prompt yet)"
}

private func fileCounts(_ events: [CodexEvent]) -> (Int, Int) {
    var reads = 0
    var writes = 0
    for ev in events where ev.type == "response_item" {
        guard (ev.payload["type"] as? String) == "function_call" else { continue }
        let name = (ev.payload["name"] as? String) ?? ""
        let args = decodeArguments(ev.payload["arguments"])
        if isReadCall(name, args) { reads += 1 }
        if isWriteCall(name, args) { writes += 1 }
    }
    return (reads, writes)
}

private func deriveStatus(_ events: [CodexEvent]) -> (AgentStatus, String?, String) {
    let taskStartedIndex = events.lastIndex {
        $0.type == "event_msg" && ($0.payload["type"] as? String) == "task_started"
    }
    let taskCompleteIndex = events.lastIndex {
        $0.type == "event_msg" && ($0.payload["type"] as? String) == "task_complete"
    }

    let activeEvents: ArraySlice<CodexEvent>
    if let completeIndex = taskCompleteIndex,
       taskStartedIndex == nil || completeIndex > taskStartedIndex! {
        let afterComplete = events.index(after: completeIndex)
        let hasActiveEventAfterComplete = events[afterComplete...].contains { ev in
            if ev.type == "response_item" { return true }
            guard ev.type == "event_msg" else { return false }
            let payloadType = ev.payload["type"] as? String
            return payloadType == "task_started"
                || payloadType == "user_message"
                || payloadType == "agent_message"
        }
        if !hasActiveEventAfterComplete {
            return (.idle, nil, "task complete")
        }
        activeEvents = events[afterComplete...]
    } else if let startedIndex = taskStartedIndex {
        activeEvents = events[startedIndex...]
    } else {
        activeEvents = events[events.startIndex...]
    }

    var calls: [(String, [String: Any])] = []
    var completed = Set<String>()
    for ev in activeEvents where ev.type == "response_item" {
        let payloadType = ev.payload["type"] as? String
        if payloadType == "function_call" {
            let cid = (ev.payload["call_id"] as? String) ?? ""
            if !cid.isEmpty { calls.append((cid, ev.payload)) }
        } else if payloadType == "function_call_output" {
            let cid = (ev.payload["call_id"] as? String) ?? ""
            if !cid.isEmpty { completed.insert(cid) }
        }
    }
    for (cid, payload) in calls.reversed() where !completed.contains(cid) {
        let name = (payload["name"] as? String) ?? "tool"
        let args = decodeArguments(payload["arguments"])
        return (.tool, name, toolTarget(name, args).isEmpty ? "running" : toolTarget(name, args))
    }

    for ev in activeEvents.reversed() {
        if ev.type == "event_msg" {
            let payloadType = ev.payload["type"] as? String
            if payloadType == "task_complete" {
                return (.idle, nil, "task complete")
            }
            if payloadType == "task_started" {
                return (.processing, nil, "processing prompt")
            }
            if payloadType == "user_message" {
                return (.processing, nil, "processing prompt")
            }
            if payloadType == "agent_message" {
                let isRecent = ev.timestamp > 0 && Date.now.timeIntervalSince1970 - ev.timestamp < 5
                return (isRecent ? .writing : .idle, nil, "updating user")
            }
            if payloadType == "token_count" {
                continue
            }
        }
        guard ev.type == "response_item" else { continue }
        let payloadType = ev.payload["type"] as? String
        if payloadType == "function_call_output" {
            return (.thinking, nil, "parsing tool result")
        }
        if payloadType == "reasoning" {
            return (.thinking, nil, "reasoning")
        }
        if payloadType == "message" {
            let role = ev.payload["role"] as? String
            if role == "assistant" {
                let isRecent = ev.timestamp > 0 && Date.now.timeIntervalSince1970 - ev.timestamp < 5
                return (isRecent ? .writing : .idle, nil, "awaiting next directive")
            }
            if role == "user" {
                return (.processing, nil, "processing prompt")
            }
        }
    }
    return (.idle, nil, "awaiting next directive")
}

private func deriveLog(_ events: [CodexEvent]) -> [LogEntry] {
    var callNames: [String: String] = [:]
    for ev in events where ev.type == "response_item" {
        guard (ev.payload["type"] as? String) == "function_call" else { continue }
        if let cid = ev.payload["call_id"] as? String {
            callNames[cid] = (ev.payload["name"] as? String) ?? "tool"
        }
    }

    var out: [LogEntry] = []
    var id = 0
    for ev in events.reversed() {
        if out.count >= 30 { break }
        let ts = hmsLocalCodex(ev.timestamp)
        if ev.type == "event_msg" {
            let payloadType = ev.payload["type"] as? String
            if payloadType == "user_message" {
                let msg = ((ev.payload["message"] as? String) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\n", with: " ")
                id += 1
                out.append(LogEntry(id: id, ts: ts, tag: .info,
                                    msg: "prompt.received  ->  \(String(msg.prefix(42)))"))
            } else if payloadType == "agent_message" {
                let msg = ((ev.payload["message"] as? String) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\n", with: " ")
                id += 1
                out.append(LogEntry(id: id, ts: ts, tag: .info,
                                    msg: "agent.update  \(String(msg.prefix(54)))"))
            }
            continue
        }
        guard ev.type == "response_item" else { continue }
        let payloadType = ev.payload["type"] as? String
        if payloadType == "function_call" {
            let name = (ev.payload["name"] as? String) ?? "tool"
            let args = decodeArguments(ev.payload["arguments"])
            let target = toolTarget(name, args)
            id += 1
            out.append(LogEntry(id: id, ts: ts, tag: .info,
                                msg: "tool.call  \(name)  \(target)".trimmingCharacters(in: .whitespaces)))
        } else if payloadType == "function_call_output" {
            let cid = (ev.payload["call_id"] as? String) ?? ""
            let name = callNames[cid] ?? "tool"
            let text = (ev.payload["output"] as? String) ?? ""
            let ok = text.contains("Process exited with code 0")
                || text.contains("code 0")
                || text.contains("\"success\":true")
            id += 1
            out.append(LogEntry(id: id, ts: ts, tag: ok ? .ok : .err,
                                msg: "tool.result  \(name)"))
        }
    }
    return out
}

private func contentText(_ content: Any?) -> String {
    if let s = content as? String { return s }
    guard let blocks = content as? [[String: Any]] else { return "" }
    return blocks.compactMap { block in
        (block["text"] as? String)
            ?? (block["output_text"] as? String)
            ?? (block["input_text"] as? String)
    }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
}

private func decodeArguments(_ raw: Any?) -> [String: Any] {
    if let dict = raw as? [String: Any] { return dict }
    guard let s = raw as? String,
          let data = s.data(using: .utf8),
          let any = try? JSONSerialization.jsonObject(with: data),
          let dict = any as? [String: Any] else { return [:] }
    return dict
}

private func toolTarget(_ name: String, _ args: [String: Any]) -> String {
    for key in ["cmd", "command", "file_path", "path", "pattern", "query", "workdir"] {
        if var value = args[key] as? String,
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            value = value.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path,
                                               with: "~")
            return String(value.prefix(64))
        }
    }
    if name == "apply_patch" { return "patch" }
    return ""
}

private let codexReadCommandPrefixes = [
    "cat ", "find ", "git diff", "git show", "git status", "head ", "jq ",
    "ls", "nl ", "pwd", "rg ", "sed ", "tail ", "wc ",
]

private let codexWriteCommandPrefixes = [
    "git commit", "git mv", "git push", "mv ", "npm run format",
    "pnpm format", "python -m compileall", "ruff ",
]

private func isReadCall(_ name: String, _ args: [String: Any]) -> Bool {
    if ["read_mcp_resource", "view_image"].contains(name) { return true }
    guard name == "exec_command" else { return false }
    let cmd = ((args["cmd"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
    return codexReadCommandPrefixes.contains { cmd.hasPrefix($0) }
}

private func isWriteCall(_ name: String, _ args: [String: Any]) -> Bool {
    if ["apply_patch", "write_stdin"].contains(name) { return true }
    guard name == "exec_command" else { return false }
    let cmd = ((args["cmd"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
    return codexWriteCommandPrefixes.contains { cmd.hasPrefix($0) }
}

private struct CodexModelSpec {
    let name: String
    let version: String
    let contextMax: Double
    let pricingIn: Double
    let pricingOut: Double
    let provider: String
    /// Thinking/reasoning level baked into the model name (e.g. the
    /// "(Medium)" suffix on Antigravity model selections). Used as a
    /// fallback for the thinking indicator when the source doesn't
    /// emit explicit `reasoning_effort` events.
    let thinkingLevel: String?
}

private struct CodexPricing {
    let prefix: String
    let contextMax: Double
    let pricingIn: Double
    let pricingOut: Double
}

private let codexPricingTable = [
    CodexPricing(prefix: "gpt-5.5", contextMax: 400_000, pricingIn: 2.50, pricingOut: 10.00),
    CodexPricing(prefix: "gpt-5", contextMax: 400_000, pricingIn: 2.50, pricingOut: 10.00),
    CodexPricing(prefix: "gpt-4.1", contextMax: 1_000_000, pricingIn: 2.00, pricingOut: 8.00),
    CodexPricing(prefix: "o4-mini", contextMax: 200_000, pricingIn: 1.10, pricingOut: 4.40),
    CodexPricing(prefix: "gemini", contextMax: 1_048_576, pricingIn: 0.075, pricingOut: 0.30),
]

private func parseCodexModelID(_ id: String, observedContextMax: Double) -> CodexModelSpec {
    let raw = id.isEmpty ? "gpt-5" : id
    let lower = raw.lowercased()
    let pricing = codexPricingTable.first { lower.hasPrefix($0.prefix) } ?? codexPricingTable[1]
    let contextMax = observedContextMax > 0 ? observedContextMax : pricing.contextMax

    let version = firstNumber(in: raw) ?? "?"
    // Pull "(Medium)" / "(High)" / "(Low)" off the tail — Antigravity
    // model selections come through as "Gemini 3.5 Flash (Medium)". The
    // parens content is the thinking-effort level, surfaced separately
    // on the model card so the name itself stays clean.
    let thinkingLevel: String? = {
        guard let open = raw.lastIndex(of: "("),
              let close = raw.lastIndex(of: ")"),
              open < close else { return nil }
        let inside = raw[raw.index(after: open)..<close]
            .trimmingCharacters(in: .whitespaces)
        return inside.isEmpty ? nil : inside
    }()
    let name: String
    let provider: String

    if lower.contains("gemini") {
        provider = "google"
        if lower.contains("flash") {
            name = "GEMINI FLASH"
        } else if lower.contains("pro") {
            name = "GEMINI PRO"
        } else if lower.contains("ultra") {
            name = "GEMINI ULTRA"
        } else {
            name = "GEMINI"
        }
    } else if lower.hasPrefix("o") {
        provider = "openai"
        name = raw.uppercased()
    } else if lower.hasPrefix("gpt") {
        provider = "openai"
        let parts = raw.split(separator: "-")
        name = parts.count >= 2 ? "\(parts[0])-\(parts[1])".uppercased() : raw.uppercased()
    } else {
        provider = "openai"
        name = raw.uppercased()
    }

    return CodexModelSpec(name: name, version: version, contextMax: contextMax,
                          pricingIn: pricing.pricingIn, pricingOut: pricing.pricingOut,
                          provider: provider, thinkingLevel: thinkingLevel)
}

private func firstNumber(in s: String) -> String? {
    let pattern = #"(\d+(?:\.\d+)?)"#
    guard let re = try? NSRegularExpression(pattern: pattern),
          let match = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
          let range = Range(match.range(at: 1), in: s) else { return nil }
    return String(s[range])
}

private func doubleValue(_ any: Any?) -> Double {
    if let v = any as? Double { return v }
    if let v = any as? Int { return Double(v) }
    if let v = any as? NSNumber { return v.doubleValue }
    if let v = any as? String { return Double(v) ?? 0 }
    return 0
}

private func shortCodexSessionID(_ uuid: String) -> String {
    let s = uuid.replacingOccurrences(of: "-", with: "").uppercased()
    if s.count < 8 { return "----" }
    return "\(s.prefix(4))-\(s.suffix(4))"
}

private func ceilNiceCodex(_ n: Double) -> Double {
    guard n > 0 else { return 1 }
    let k = floor(log10(n))
    let base = pow(10, k)
    for mult in [1.0, 2.0, 5.0, 10.0] {
        let v = mult * base
        if v >= n { return v }
    }
    return 10 * base
}

private func gitDirtyCodex(cwd: String) -> Bool {
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

private let codexHMSFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
}()

private func hmsLocalCodex(_ ts: TimeInterval) -> String {
    guard ts > 0 else { return "--:--:--" }
    return codexHMSFormatter.string(from: Date(timeIntervalSince1970: ts))
}

private func codexISOToDate(_ s: String) -> Date? {
    CodexSource.iso8601Fractional.date(from: s)
        ?? CodexSource.iso8601.date(from: s)
}

extension CodexSource {
    fileprivate nonisolated(unsafe) static let iso8601Fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    fileprivate nonisolated(unsafe) static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
