// Auto source - follows the newest active Claude, Codex, or AGY session and
// dispatches to the concrete tailer for that session format.

import Foundation

final class AutoTelemetrySource: TelemetrySource {
    let label = "Auto"

    private let claudeSource: ClaudeCodeSource
    private let codexSource: CodexSource
    private let agySource: CodexSource

    init(claudeSource: ClaudeCodeSource,
         codexSource: CodexSource,
         agySource: CodexSource) {
        self.claudeSource = claudeSource
        self.codexSource = codexSource
        self.agySource = agySource
    }

    func tick() -> Telemetry {
        guard let session = SessionDiscovery.active().first else {
            return Telemetry.empty()
        }
        switch session.kind {
        case .claude:
            claudeSource.setPinned(session.jsonl)
            return claudeSource.tick()
        case .codex:
            codexSource.setPinned(session.jsonl)
            return codexSource.tick()
        case .agy:
            agySource.setPinned(session.jsonl)
            return agySource.tick()
        }
    }
}
