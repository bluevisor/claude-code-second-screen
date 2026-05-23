// Background weather + location service. Resolves the user's coarse
// location via IP geolocation (ipapi.co) and pulls current conditions
// from Open-Meteo — neither requires an API key or any system permission
// dialog. Renderers read the latest summary synchronously from a
// thread-safe property.

import Foundation
import os
import os.log

final class WeatherService: @unchecked Sendable {
    static let shared = WeatherService()

    private struct State {
        var cached: String?
        var started = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let logger = Logger(subsystem: "tech.bluevisor.NeoDashboard",
                                category: "Weather")

    /// Most recent "CITY, ST · 72°F · CLR" formatted string. Nil until the
    /// first successful refresh.
    var summary: String? {
        state.withLock { $0.cached }
    }

    /// Idempotent — kicks off a detached task that refreshes every 10 min.
    func start() {
        let already = state.withLock { s -> Bool in
            if s.started { return true }
            s.started = true
            return false
        }
        guard !already else { return }
        Task.detached { [weak self] in
            await self?.runLoop()
        }
    }

    // MARK: - Loop

    private func runLoop() async {
        while !Task.isCancelled {
            await refreshOnce()
            // 10 minutes is well under both ipapi.co (1k/day) and
            // Open-Meteo (10k/day) free-tier limits.
            try? await Task.sleep(nanoseconds: 10 * 60 * 1_000_000_000)
        }
    }

    private func refreshOnce() async {
        do {
            let loc = try await fetchLocation()
            guard let lat = loc.latitude, let lon = loc.longitude else {
                logger.warning("location response had no lat/lon")
                return
            }
            let weather = try await fetchWeather(lat: lat, lon: lon)
            let city = loc.city?.uppercased() ?? ""
            let region = (loc.region_code ?? loc.region ?? "").uppercased()
            let temp = weather.current?.temperature_2m
                ?? weather.current_weather?.temperature ?? 0
            let code = weather.current?.weather_code
                ?? weather.current_weather?.weathercode ?? 0
            let cond = condition(for: code)
            let location = [city, region].filter { !$0.isEmpty }.joined(separator: ", ")
            let summary = "\(location) · \(Int(temp.rounded()))°F · \(cond)"
            state.withLock { $0.cached = summary }
            logger.info("weather updated: \(summary, privacy: .public)")
        } catch {
            logger.warning("refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - HTTP

    private struct IPLocation: Decodable {
        let city: String?
        let region: String?
        let region_code: String?
        let latitude: Double?
        let longitude: Double?
    }

    private struct WeatherResponse: Decodable {
        struct Current: Decodable {
            let temperature_2m: Double?
            let weather_code: Int?
            let is_day: Int?
        }
        struct LegacyCurrent: Decodable {
            let temperature: Double?
            let weathercode: Int?
        }
        let current: Current?
        let current_weather: LegacyCurrent?
    }

    private func fetchLocation() async throws -> IPLocation {
        let url = URL(string: "https://ipapi.co/json/")!
        var req = URLRequest(url: url)
        req.setValue("NeoDashboard/0.1", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(IPLocation.self, from: data)
    }

    private func fetchWeather(lat: Double, lon: Double) async throws -> WeatherResponse {
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        c.queryItems = [
            URLQueryItem(name: "latitude", value: String(lat)),
            URLQueryItem(name: "longitude", value: String(lon)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code,is_day"),
            URLQueryItem(name: "temperature_unit", value: "fahrenheit"),
        ]
        let (data, _) = try await URLSession.shared.data(from: c.url!)
        return try JSONDecoder().decode(WeatherResponse.self, from: data)
    }

    /// WMO weather interpretation codes (Open-Meteo docs).
    private func condition(for code: Int) -> String {
        switch code {
        case 0: return "CLR"
        case 1, 2: return "PCLD"
        case 3: return "OVRC"
        case 45, 48: return "FOG"
        case 51, 53, 55, 56, 57: return "DRZL"
        case 61, 63, 65, 66, 67, 80, 81, 82: return "RAIN"
        case 71, 73, 75, 77, 85, 86: return "SNOW"
        case 95, 96, 99: return "STRM"
        default: return "—"
        }
    }
}
