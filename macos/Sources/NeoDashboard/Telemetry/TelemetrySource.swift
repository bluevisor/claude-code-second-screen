// A source produces a fresh `Telemetry` whenever asked.
//
// Sources own their own ingestion state (file offsets, accumulators, …) and
// `tick()` returns the latest snapshot. The render loop calls `tick()` at
// ~1 Hz; sources should be cheap on the steady state and do their heavy work
// only when there's actually new data to consume.

import Foundation

protocol TelemetrySource: AnyObject {
    /// Human-readable name for the menu bar ("Claude Code", "Demo", …).
    var label: String { get }

    /// Latest telemetry. Implementations should be idempotent — calling
    /// twice in a row without new data must not change the result.
    func tick() -> Telemetry
}
