// Active session discovery — walks Claude Code's per-PID registry plus
// Codex-format rollout jsonl files and returns the sessions that are worth
// showing in the menu-bar source picker.

import Foundation

struct ActiveSession: Identifiable, Hashable {
    enum Kind: String, Hashable {
        case claude, codex, agy

        var label: String {
            switch self {
            case .claude: return "Claude"
            case .codex: return "Codex"
            case .agy: return "AGY"
            }
        }

        var symbol: String {
            switch self {
            case .claude: return "terminal"
            case .codex: return "command"
            case .agy: return "network"
            }
        }
    }

    let kind: Kind
    let sessionID: String      // full uuid
    let cwd: String
    let jsonl: URL
    let busy: Bool
    let updatedAt: TimeInterval
    let pid: Int

    var id: String { "\(kind.rawValue):\(sessionID)" }

    /// "macos · 3476-E339"
    var displayName: String {
        let base = (cwd as NSString).lastPathComponent
        return "\(base) · \(shortSessionID)"
    }

    var shortSessionID: String {
        let s = sessionID.replacingOccurrences(of: "-", with: "").uppercased()
        guard s.count >= 8 else { return "----" }
        return "\(s.prefix(4))-\(s.suffix(4))"
    }
}

enum SessionDiscovery {
    /// Active = busy or updated within the last 30 minutes.
    static let activeWindow: TimeInterval = 30 * 60
    /// Codex/AGY have no busy registry; a very recent mtime is our live signal.
    static let codexBusyWindow: TimeInterval = 20
    static let cacheWindow: TimeInterval = 5
    private nonisolated(unsafe) static var cachedActive: [ActiveSession] = []
    private nonisolated(unsafe) static var cachedAt: TimeInterval = 0

    static func active(claudeSessionsDir: URL = defaultClaudeSessionsDir,
                       claudeProjectsDir: URL = defaultClaudeProjectsDir,
                       codexSessionsDir: URL = defaultCodexSessionsDir,
                       agySessionsDir: URL = defaultAgySessionsDir,
                       now: Date = .now) -> [ActiveSession] {
        let nowTs = now.timeIntervalSince1970
        if nowTs - cachedAt < cacheWindow {
            return cachedActive
        }
        var out = scanClaude(sessionsDir: claudeSessionsDir,
                             projectsDir: claudeProjectsDir, now: now)
        out += scanCodexFormat(sessionsDir: codexSessionsDir,
                               defaultKind: .codex,
                               now: now)
        out += scanCodexFormat(sessionsDir: agySessionsDir,
                               defaultKind: .agy,
                               now: now)
        let geminiAgySessionsDir = URL(fileURLWithPath: NSString("~/.gemini/antigravity-cli/brain").expandingTildeInPath,
                                       isDirectory: true)
        out += scanCodexFormat(sessionsDir: geminiAgySessionsDir,
                               defaultKind: .agy,
                               now: now)
        var seen = Set<String>()
        out = out.filter { seen.insert($0.id).inserted }
        out.sort {
            if $0.busy != $1.busy { return $0.busy }
            return $0.updatedAt > $1.updatedAt
        }
        cachedActive = out
        cachedAt = nowTs
        return out
    }

    // MARK: - Claude

    private static func scanClaude(sessionsDir: URL, projectsDir: URL, now: Date) -> [ActiveSession] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: sessionsDir, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]) else { return [] }
        let cutoff = now.timeIntervalSince1970 - activeWindow
        var found: [ActiveSession] = []
        for url in items where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let any = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            // Accept both "interactive" (the user's terminal CLI) and "bg"
            // (background-mode sessions like Claude Code in agent loops);
            // both write rollouts to the same projects directory.
            let kind = (any["kind"] as? String) ?? ""
            guard kind == "interactive" || kind == "bg",
                  let sessionId = any["sessionId"] as? String,
                  let cwd = any["cwd"] as? String,
                  let pid = any["pid"] as? Int else { continue }
            // updatedAt is in ms since epoch.
            let updatedMs = (any["updatedAt"] as? Double)
                ?? Double((any["updatedAt"] as? Int) ?? 0)
            let updated = updatedMs / 1000.0
            let busy = (any["status"] as? String) == "busy"
            if !busy && updated < cutoff { continue }
            let jsonl = jsonlURL(projectsDir: projectsDir,
                                 cwd: cwd, sessionId: sessionId)
            guard fm.fileExists(atPath: jsonl.path) else { continue }
            found.append(ActiveSession(
                kind: .claude, sessionID: sessionId, cwd: cwd, jsonl: jsonl,
                busy: busy, updatedAt: updated, pid: pid))
        }
        return found
    }

    private static func jsonlURL(projectsDir: URL, cwd: String, sessionId: String) -> URL {
        let dirName = cwd.replacingOccurrences(of: "/", with: "-")
        return projectsDir
            .appendingPathComponent(dirName, isDirectory: true)
            .appendingPathComponent("\(sessionId).jsonl")
    }

    // MARK: - Codex / AGY

    private struct CodexMetadata {
        var kind: ActiveSession.Kind
        var sessionID: String
        var cwd: String
    }

    private static func scanCodexFormat(sessionsDir: URL,
                                        defaultKind: ActiveSession.Kind,
                                        now: Date) -> [ActiveSession] {
        let fm = FileManager.default
        let options: FileManager.DirectoryEnumerationOptions = defaultKind == .agy ? [] : [.skipsHiddenFiles]
        guard let it = fm.enumerator(at: sessionsDir,
                                     includingPropertiesForKeys: [.contentModificationDateKey],
                                     options: options) else { return [] }
        let cutoff = now.timeIntervalSince1970 - activeWindow
        var candidates: [(url: URL, mtime: TimeInterval)] = []
        candidates.reserveCapacity(16)
        let maxCandidates = 12
        let pathIsAgyRoot = sessionsDir.path.contains("/.agy/")
        let pathIsCodexRoot = sessionsDir.path.contains("/.codex/")
        let kindPathNeedle = "/.\(defaultKind.rawValue)/"
        let kindFileNeedle = "\(defaultKind.rawValue)"
        var found: [ActiveSession] = []
        for case let url as URL in it where url.pathExtension == "jsonl" {
            guard let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate?.timeIntervalSince1970,
                mtime >= cutoff else { continue }
            if pathIsAgyRoot || !pathIsCodexRoot || url.path.contains(kindPathNeedle) {
                candidates.append((url, mtime))
            } else if defaultKind == .codex || url.lastPathComponent.localizedCaseInsensitiveContains(kindFileNeedle) {
                candidates.append((url, mtime))
            }
        }
        for candidate in candidates.sorted(by: { $0.mtime > $1.mtime }).prefix(maxCandidates) {
            let url = candidate.url
            let mtime = candidate.mtime
            guard let meta = codexMetadata(url: url, defaultKind: defaultKind) else { continue }
            let busy = mtime >= now.timeIntervalSince1970 - codexBusyWindow
            found.append(ActiveSession(
                kind: meta.kind,
                sessionID: meta.sessionID,
                cwd: meta.cwd,
                jsonl: url,
                busy: busy,
                updatedAt: mtime,
                pid: 0
            ))
        }
        return found
    }

    private static func codexMetadata(url: URL,
                                      defaultKind: ActiveSession.Kind) -> CodexMetadata? {
        if url.path.contains("transcript.jsonl") {
            let sessionID = rolloutID(from: url)
            let cwd = FileManager.default.currentDirectoryPath
            return CodexMetadata(kind: .agy, sessionID: sessionID, cwd: cwd)
        }
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        guard let data = try? fh.read(upToCount: 128 * 1024),
              let text = String(data: data, encoding: .utf8) else { return nil }
        var sessionID = ""
        var cwd = ""
        var originator = ""
        var source = ""
        var hasGemini = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true).prefix(60) {
            guard let d = raw.data(using: .utf8),
                  let any = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            let type = any["type"] as? String
            let payload = any["payload"] as? [String: Any] ?? [:]
            if type == "session_meta" {
                sessionID = (payload["id"] as? String) ?? sessionID
                cwd = (payload["cwd"] as? String) ?? cwd
                originator = (payload["originator"] as? String) ?? originator
                source = (payload["source"] as? String) ?? source
            } else if type == "turn_context" {
                cwd = (payload["cwd"] as? String) ?? cwd
                if let model = payload["model"] as? String, model.lowercased().contains("gemini") {
                    hasGemini = true
                }
            }
            if !sessionID.isEmpty, !cwd.isEmpty { break }
        }
        if sessionID.isEmpty { sessionID = rolloutID(from: url) }
        guard !sessionID.isEmpty else { return nil }
        let path = url.path.lowercased()
        let discriminator = "\(originator) \(source) \(path)".lowercased()
        var kind: ActiveSession.Kind = discriminator.contains("agy") ? .agy : defaultKind
        if hasGemini {
            kind = .agy
        }
        return CodexMetadata(kind: kind,
                             sessionID: sessionID,
                             cwd: cwd.isEmpty ? "~" : cwd)
    }

    static func rolloutID(from url: URL) -> String {
        let base = url.deletingPathExtension().lastPathComponent
        if base == "transcript" || base == "transcript_full" {
            let components = url.pathComponents
            if let brainIndex = components.firstIndex(of: "brain"), brainIndex + 1 < components.count {
                return components[brainIndex + 1]
            }
        }
        let parts = base.split(separator: "-")
        guard parts.count >= 5 else { return "" }
        return parts.suffix(5).joined(separator: "-")
    }

    // MARK: - Defaults

    static let defaultClaudeSessionsDir: URL = URL(
        fileURLWithPath: NSString("~/.claude/sessions").expandingTildeInPath,
        isDirectory: true)
    static let defaultClaudeProjectsDir: URL = URL(
        fileURLWithPath: NSString("~/.claude/projects").expandingTildeInPath,
        isDirectory: true)
    static let defaultCodexSessionsDir: URL = URL(
        fileURLWithPath: NSString("~/.codex/sessions").expandingTildeInPath,
        isDirectory: true)
    static let defaultAgySessionsDir: URL = URL(
        fileURLWithPath: NSString("~/.gemini/antigravity-cli/brain").expandingTildeInPath,
        isDirectory: true)
}
