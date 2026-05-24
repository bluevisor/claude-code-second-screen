// Background weather + location service. Tries CoreLocation first for
// neighborhood-level accuracy (Wi-Fi/BT fingerprinting) and falls back
// to ipapi.co when CoreLocation is denied or unavailable. Current
// conditions come from Open-Meteo. Renderers read the latest summary
// synchronously from a thread-safe property.

import CoreLocation
import Foundation
import os
import os.log

final class WeatherService: @unchecked Sendable {
    static let shared = WeatherService()

    private struct State {
        var cached: String?
        var started = false
        var refreshRequested = false
        /// Last resolved coords + place name. Cached for an hour so we
        /// only hit CoreLocation/geocoding occasionally; weather still
        /// refreshes on the normal 10-minute cadence.
        var place: ResolvedPlace?
        var placeFetchedAt: TimeInterval = 0
    }
    private struct ResolvedPlace {
        let city: String
        let region: String
        let latitude: Double
        let longitude: Double
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let logger = Logger(subsystem: "tech.bluevisor.NeoDashboard",
                                category: "Weather")
    private let locator = SystemLocator()
    private static let placeTTL: TimeInterval = 60 * 60

    /// Most recent "CITY, ST · 72°F · CLEAR" formatted string. Nil until the
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

    /// Force the next refresh to happen as soon as the poll loop next
    /// notices (≤ 10 s latency).
    func refreshNow() {
        state.withLock { $0.refreshRequested = true }
    }

    // MARK: - Loop

    private func runLoop() async {
        while !Task.isCancelled {
            await refreshOnce()
            // 60 × 10 s = 10 min, polling `refreshRequested` each tick
            // so user-triggered refreshes wake the loop quickly without
            // any AsyncStream / task-group plumbing that strict Swift 6
            // concurrency tends to reject.
            for _ in 0..<60 {
                if Task.isCancelled { return }
                if (try? await Task.sleep(nanoseconds: 10 * 1_000_000_000)) == nil {
                    return
                }
                let wake = state.withLock { s -> Bool in
                    let r = s.refreshRequested
                    s.refreshRequested = false
                    return r
                }
                if wake { break }
            }
        }
    }

    private func refreshOnce() async {
        do {
            let unit = UserPrefs.temperatureUnit
            let place = try await resolvePlace()
            let weather = try await fetchWeather(lat: place.latitude,
                                                 lon: place.longitude,
                                                 unit: unit)
            let temp = weather.current?.temperature_2m
                ?? weather.current_weather?.temperature ?? 0
            let code = weather.current?.weather_code
                ?? weather.current_weather?.weathercode ?? 0
            let cond = condition(for: code)
            let location = [place.city, place.region]
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
            let summary = "\(location) · \(Int(temp.rounded()))\(unit.rawValue) · \(cond)"
            state.withLock { $0.cached = summary }
            logger.info("weather updated: \(summary, privacy: .public)")
        } catch {
            logger.warning("refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Location resolution

    private func resolvePlace() async throws -> ResolvedPlace {
        // Cached for an hour — covers the common stationary case.
        let now = Date.now.timeIntervalSince1970
        if let cached = state.withLock({ s -> ResolvedPlace? in
            guard let p = s.place, now - s.placeFetchedAt < Self.placeTTL else {
                return nil
            }
            return p
        }) {
            return cached
        }

        let place: ResolvedPlace
        if let coords = await locator.requestLocation() {
            let (city, region) = await reverseGeocode(coords)
            place = ResolvedPlace(city: city.uppercased(),
                                  region: region.uppercased(),
                                  latitude: coords.coordinate.latitude,
                                  longitude: coords.coordinate.longitude)
            logger.info("CoreLocation: \(place.city, privacy: .public), \(place.region, privacy: .public)")
        } else {
            // Fall back to IP geolocation. Lower accuracy (city-level
            // routing, often off by ~10 mi) but works without permission.
            let ip = try await fetchIPLocation()
            guard let lat = ip.latitude, let lon = ip.longitude else {
                throw URLError(.cannotParseResponse)
            }
            place = ResolvedPlace(
                city: (ip.city ?? "").uppercased(),
                region: (ip.region_code ?? ip.region ?? "").uppercased(),
                latitude: lat,
                longitude: lon
            )
            logger.info("IP geo: \(place.city, privacy: .public), \(place.region, privacy: .public)")
        }
        state.withLock { s in
            s.place = place
            s.placeFetchedAt = now
        }
        return place
    }

    private func reverseGeocode(_ loc: CLLocation) async -> (city: String, region: String) {
        let geocoder = CLGeocoder()
        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(loc)
            if let p = placemarks.first {
                let city = p.locality ?? p.subLocality ?? p.subAdministrativeArea ?? ""
                let region = p.administrativeArea ?? ""
                return (city, region)
            }
        } catch {
            logger.warning("reverse geocode failed: \(error.localizedDescription, privacy: .public)")
        }
        return ("", "")
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

    private func fetchIPLocation() async throws -> IPLocation {
        let url = URL(string: "https://ipapi.co/json/")!
        var req = URLRequest(url: url)
        req.setValue("NeoDashboard/0.1", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(IPLocation.self, from: data)
    }

    private func fetchWeather(lat: Double, lon: Double,
                              unit: AppEnvironment.TemperatureUnit) async throws -> WeatherResponse {
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        c.queryItems = [
            URLQueryItem(name: "latitude", value: String(lat)),
            URLQueryItem(name: "longitude", value: String(lon)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code,is_day"),
            URLQueryItem(name: "temperature_unit", value: unit.openMeteoParam),
        ]
        let (data, _) = try await URLSession.shared.data(from: c.url!)
        return try JSONDecoder().decode(WeatherResponse.self, from: data)
    }

    /// WMO weather interpretation codes (Open-Meteo docs).
    private func condition(for code: Int) -> String {
        switch code {
        case 0: return "CLEAR"
        case 1: return "MOSTLY CLEAR"
        case 2: return "PARTLY CLOUDY"
        case 3: return "OVERCAST"
        case 45, 48: return "FOG"
        case 51, 53, 55, 56, 57: return "DRIZZLE"
        case 61, 63, 65, 66, 67, 80, 81, 82: return "RAIN"
        case 71, 73, 75, 77, 85, 86: return "SNOW"
        case 95, 96, 99: return "THUNDERSTORM"
        default: return "—"
        }
    }
}

// MARK: - CoreLocation bridge

/// Async wrapper around CLLocationManager. CLLocationManager requires
/// that its methods be called from the thread the manager was created
/// on (typically main) — calling from a background queue silently
/// breaks the delegate flow and the continuation never resolves. This
/// class dispatches every manager call to `DispatchQueue.main`, and a
/// timeout makes sure callers always fall through to IP geolocation if
/// the system never produces a fix.
private final class SystemLocator: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    private let manager: CLLocationManager
    private let lock = OSAllocatedUnfairLock(initialState: State())
    private static let timeout: TimeInterval = 8

    private struct State {
        var continuation: CheckedContinuation<CLLocation?, Never>?
        var didRequest = false
        var timeoutToken = 0
    }

    override init() {
        // Build the manager on main so its delegate callback queue is
        // the main thread, matching where we dispatch our calls below.
        let m: CLLocationManager
        if Thread.isMainThread {
            m = CLLocationManager()
        } else {
            m = DispatchQueue.main.sync { CLLocationManager() }
        }
        self.manager = m
        super.init()
        DispatchQueue.main.async { [self] in
            manager.delegate = self
            manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        }
    }

    func requestLocation() async -> CLLocation? {
        // `locationServicesEnabled()` can block — keep it off the main
        // queue. It's safe to call from any thread.
        if !CLLocationManager.locationServicesEnabled() { return nil }
        return await withCheckedContinuation { (cont: CheckedContinuation<CLLocation?, Never>) in
            let token: Int? = lock.withLock { s -> Int? in
                // Coalesce — refuse a second concurrent fix so the
                // caller can fall back to IP rather than queue forever.
                if s.continuation != nil { return nil }
                s.continuation = cont
                s.didRequest = false
                s.timeoutToken &+= 1
                return s.timeoutToken
            }
            guard let token else {
                cont.resume(returning: nil)
                return
            }
            DispatchQueue.main.async { [weak self] in self?.kickoff() }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeout) { [weak self] in
                self?.timeoutFire(token: token)
            }
        }
    }

    /// Main-thread only.
    private func kickoff() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .restricted, .denied:
            resume(nil)
        case .authorized, .authorizedAlways:
            startRequest()
        @unknown default:
            resume(nil)
        }
    }

    /// Main-thread only.
    private func startRequest() {
        let already = lock.withLock { s -> Bool in
            if s.didRequest { return true }
            s.didRequest = true
            return false
        }
        guard !already else { return }
        manager.requestLocation()
    }

    private func timeoutFire(token: Int) {
        let stale = lock.withLock { s -> Bool in
            return s.timeoutToken != token || s.continuation == nil
        }
        if stale { return }
        resume(nil)
    }

    private func resume(_ value: CLLocation?) {
        let cont = lock.withLock { s -> CheckedContinuation<CLLocation?, Never>? in
            let c = s.continuation
            s.continuation = nil
            s.didRequest = false
            return c
        }
        cont?.resume(returning: value)
    }

    // MARK: CLLocationManagerDelegate (called on main, the manager's queue)

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorized, .authorizedAlways:
            startRequest()
        case .denied, .restricted:
            resume(nil)
        case .notDetermined:
            break
        @unknown default:
            resume(nil)
        }
    }

    func locationManager(_ manager: CLLocationManager,
                         didUpdateLocations locations: [CLLocation]) {
        resume(locations.last)
    }

    func locationManager(_ manager: CLLocationManager,
                         didFailWithError error: Error) {
        resume(nil)
    }
}
