// Background weather + location service. Tries CoreLocation first for
// neighborhood-level accuracy (Wi-Fi/BT fingerprinting) and falls back
// to ipapi.co when CoreLocation is denied or unavailable. Current
// conditions come from Open-Meteo. Renderers read the latest summary
// synchronously from a thread-safe property.

import AppKit
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

    private init() {
        // When the user finally clicks Allow, drop the cached IP-based
        // place and trigger an immediate refresh so the LCD swaps to
        // the real location within seconds instead of the next 10-min
        // tick.
        locator.onAuthorizationGranted = { [weak self] in
            self?.state.withLock { s in
                s.place = nil
                s.placeFetchedAt = 0
                s.refreshRequested = true
            }
        }
    }

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

    /// Drop any IP-based/stale place cache so the next refresh goes
    /// back through CoreLocation and can surface the system prompt.
    func requestPreciseLocationNow() {
        state.withLock { s in
            s.place = nil
            s.placeFetchedAt = 0
            s.refreshRequested = true
        }
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
        let (coords, why) = await locator.requestLocationWithReason()
        if let coords {
            let (city, region) = await reverseGeocode(coords)
            place = ResolvedPlace(city: city.uppercased(),
                                  region: region.uppercased(),
                                  latitude: coords.coordinate.latitude,
                                  longitude: coords.coordinate.longitude)
            logger.info("CoreLocation: \(place.city, privacy: .public), \(place.region, privacy: .public)")
        } else {
            logger.info("CoreLocation unavailable (\(why, privacy: .public)) — falling back to IP")
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
    /// Bound on a single resolution attempt once authorization is in
    /// hand. We use a much longer ceiling (`firstAuthTimeout`) while
    /// waiting on the permission alert so the user actually has time
    /// to click before we abandon the call.
    private static let timeout: TimeInterval = 12
    private static let firstAuthTimeout: TimeInterval = 120
    private let logger = Logger(subsystem: "tech.bluevisor.NeoDashboard",
                                category: "Locator")
    /// Called once on the main thread the first time CoreLocation
    /// authorization transitions to `.authorized`. WeatherService wires
    /// it to `refreshNow()` so the LCD updates from the IP-fallback
    /// city to the real one as soon as the user clicks Allow.
    var onAuthorizationGranted: (@Sendable () -> Void)?

    private struct State {
        var continuation: CheckedContinuation<CLLocation?, Never>?
        var didRequest = false
        var timeoutToken = 0
        var notifiedGrant = false
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
        if Thread.isMainThread {
            configureManager()
        } else {
            DispatchQueue.main.sync { [self] in
                configureManager()
            }
        }
    }

    private func configureManager() {
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func requestLocation() async -> CLLocation? {
        await requestLocationWithReason().location
    }

    /// Same as `requestLocation` but returns a tag describing why a
    /// location wasn't returned (used for diagnostic logging when the
    /// caller has to fall back to IP geolocation).
    func requestLocationWithReason() async -> (location: CLLocation?, reason: String) {
        // `locationServicesEnabled()` can block — keep it off the main
        // queue. It's safe to call from any thread.
        if !CLLocationManager.locationServicesEnabled() {
            return (nil, "system Location Services disabled")
        }
        // Pick the timeout up front: when auth is .notDetermined the
        // user needs time to find and click the permission alert. Once
        // authorized, real fixes resolve in well under a second.
        let initialStatus: CLAuthorizationStatus = await MainActor.run {
            manager.authorizationStatus
        }
        let attemptTimeout: TimeInterval = (initialStatus == .notDetermined)
            ? Self.firstAuthTimeout
            : Self.timeout
        let result: CLLocation? = await withCheckedContinuation { (cont: CheckedContinuation<CLLocation?, Never>) in
            let token: Int? = lock.withLock { s -> Int? in
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
            DispatchQueue.main.asyncAfter(deadline: .now() + attemptTimeout) { [weak self] in
                self?.timeoutFire(token: token)
            }
        }
        if let result { return (result, "ok") }
        // Sample the authorisation state on the main thread so the log
        // line is meaningful (denied vs not-determined vs timed-out).
        let status: CLAuthorizationStatus = await MainActor.run {
            manager.authorizationStatus
        }
        let reason: String
        switch status {
        case .notDetermined: reason = "auth notDetermined after \(Int(attemptTimeout))s — prompt never resolved"
        case .denied:        reason = "auth denied — enable in System Settings → Privacy & Security → Location Services"
        case .restricted:    reason = "auth restricted by parental controls / MDM"
        case .authorized, .authorizedAlways: reason = "authorized but no fix within \(Int(attemptTimeout))s"
        @unknown default:    reason = "unknown auth status"
        }
        return (nil, reason)
    }

    /// Main-thread only.
    private func kickoff() {
        let status = manager.authorizationStatus
        let statusName = authString(status)
        logger.info("kickoff: authStatus=\(statusName, privacy: .public)")
        switch status {
        case .notDetermined:
            // CoreLocationAgent will only surface its prompt for an
            // application that is "regular" enough to be activatable.
            // NeoDashboard is LSUIElement / `.accessory` by default, so
            // `NSApp.activate` is a no-op — the prompt is generated but
            // never displayed and the auth status sticks at
            // `.notDetermined` forever. Briefly flip to `.regular` so
            // the prompt actually shows, then restore the policy after
            // the user has had time to respond.
            promoteForAuthPrompt()
            logger.info("calling requestWhenInUseAuthorization (LSUIElement → temporarily .regular)")
            manager.requestWhenInUseAuthorization()
        case .restricted, .denied:
            logger.info("auth not available (\(statusName, privacy: .public)) — resolving nil")
            resume(nil)
        case .authorized, .authorizedAlways:
            startRequest()
        @unknown default:
            resume(nil)
        }
    }

    /// Save the current activation policy, switch to `.regular` so the
    /// CoreLocationAgent prompt can attach to us, then schedule a
    /// restore once the user has plausibly had time to respond.
    private func promoteForAuthPrompt() {
        MainActor.assumeIsolated {
            let previous = NSApp.activationPolicy()
            if previous != .regular {
                NSApp.setActivationPolicy(.regular)
            }
            NSApp.activate(ignoringOtherApps: true)
            // Restore the policy after the prompt has had a chance to be
            // dismissed — long enough that flipping back doesn't kill the
            // CoreLocationAgent alert, short enough that we don't leave a
            // stray Dock icon around for the whole session.
            if previous != .regular {
                DispatchQueue.main.asyncAfter(deadline: .now() + 90) {
                    MainActor.assumeIsolated {
                        // Only restore if no other Locator caller has
                        // promoted us in the meantime.
                        if NSApp.activationPolicy() == .regular {
                            NSApp.setActivationPolicy(previous)
                        }
                    }
                }
            }
        }
    }

    private func authString(_ status: CLAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorized: return "authorized"
        case .authorizedAlways: return "authorizedAlways"
        @unknown default: return "unknown(\(status.rawValue))"
        }
    }

    /// Main-thread only. Issues `manager.requestLocation()` exactly
    /// once per pending fix. Authorization must already be granted —
    /// calling this while `.notDetermined` causes an immediate
    /// `kCLErrorDenied` from CoreLocation and resumes the continuation
    /// with nil.
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
        let status = manager.authorizationStatus
        let statusName = self.authString(status)
        logger.info("auth changed: \(statusName, privacy: .public)")
        switch status {
        case .authorized, .authorizedAlways:
            // Fire the one-shot grant notification so WeatherService can
            // schedule an immediate refresh — even if the current call
            // already timed out, the user still gets accurate weather
            // within seconds of clicking Allow.
            let shouldNotify = lock.withLock { s -> Bool in
                if s.notifiedGrant { return false }
                s.notifiedGrant = true
                return true
            }
            if shouldNotify { onAuthorizationGranted?() }
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
        logger.info("didUpdateLocations: \(locations.count) location(s)")
        resume(locations.last)
    }

    func locationManager(_ manager: CLLocationManager,
                         didFailWithError error: Error) {
        let status = manager.authorizationStatus
        let statusName = self.authString(status)
        logger.warning("didFailWithError: \(error.localizedDescription, privacy: .public) (auth=\(statusName, privacy: .public))")
        // While auth is still pending, ignore the immediate
        // `kCLErrorDenied` that CoreLocation surfaces in response to a
        // stale request — the user hasn't decided yet and the next
        // auth-change callback will re-issue the fix.
        if status == .notDetermined { return }
        resume(nil)
    }
}
