// Thread-safe snapshot of user preferences that renderers need to read
// from the work queue at 30 fps. `AppEnvironment` is `@MainActor`, so
// renderers can't reach into it directly without hopping — and reading
// `UserDefaults` per frame, while safe, smells. This singleton holds the
// preferences in a lock-protected cache; `AppEnvironment` pushes updates
// whenever the user changes a setting.

import Foundation
import os

enum UserPrefs {
    private struct State {
        var timeFormat: AppEnvironment.TimeFormat = .h12
        var temperatureUnit: AppEnvironment.TemperatureUnit = .fahrenheit
        var dateFormat: AppEnvironment.DateFormat = .usDot
    }
    private static let state = OSAllocatedUnfairLock(initialState: State())

    static var timeFormat: AppEnvironment.TimeFormat {
        state.withLock { $0.timeFormat }
    }

    static var temperatureUnit: AppEnvironment.TemperatureUnit {
        state.withLock { $0.temperatureUnit }
    }

    static var dateFormat: AppEnvironment.DateFormat {
        state.withLock { $0.dateFormat }
    }

    static func update(timeFormat: AppEnvironment.TimeFormat) {
        state.withLock { $0.timeFormat = timeFormat }
    }

    static func update(temperatureUnit: AppEnvironment.TemperatureUnit) {
        state.withLock { $0.temperatureUnit = temperatureUnit }
    }

    static func update(dateFormat: AppEnvironment.DateFormat) {
        state.withLock { $0.dateFormat = dateFormat }
    }
}

/// Hours-minutes (and optionally seconds) formatted in the user's chosen
/// time format. `withSeconds` is a hint — callers like the big clock face
/// elide seconds for a calmer reading.
func clockText(_ now: Date,
               format: AppEnvironment.TimeFormat = UserPrefs.timeFormat,
               withSeconds: Bool = false) -> String {
    let cal = Calendar(identifier: .gregorian)
    let c = cal.dateComponents([.hour, .minute, .second], from: now)
    let m = String(format: "%02d", c.minute ?? 0)
    let s = String(format: "%02d", c.second ?? 0)
    switch format {
    case .h24:
        let h = String(format: "%02d", c.hour ?? 0)
        return withSeconds ? "\(h):\(m):\(s)" : "\(h):\(m)"
    case .h12:
        let h = ((c.hour ?? 0) + 11) % 12 + 1
        return withSeconds ? "\(h):\(m):\(s)" : "\(h):\(m)"
    }
}

/// AM / PM suffix when the user is in 12-hour mode, empty otherwise.
func amPm(_ now: Date,
          format: AppEnvironment.TimeFormat = UserPrefs.timeFormat) -> String {
    guard format == .h12 else { return "" }
    let h = Calendar(identifier: .gregorian).component(.hour, from: now)
    return h >= 12 ? "PM" : "AM"
}

/// Numeric date portion in the user's chosen layout. Renderers prepend
/// the weekday separately so the format only owns the digits + separator.
func dateText(_ now: Date,
              format: AppEnvironment.DateFormat = UserPrefs.dateFormat) -> String {
    let cal = Calendar(identifier: .gregorian)
    let c = cal.dateComponents([.day, .month, .year], from: now)
    let d = c.day ?? 0, m = c.month ?? 0, y = c.year ?? 0
    switch format {
    case .usDot:
        return String(format: "%02d.%02d.%04d", m, d, y)
    case .iso:
        return String(format: "%04d-%02d-%02d", y, m, d)
    case .eu:
        return String(format: "%02d.%02d.%04d", d, m, y)
    case .longHuman:
        let mon = DateFormatter().shortMonthSymbols[max(0, m - 1)]
        return String(format: "%@ %d, %04d", mon.uppercased(), d, y)
    }
}
