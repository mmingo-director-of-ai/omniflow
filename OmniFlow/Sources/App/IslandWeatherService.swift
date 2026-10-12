import Combine
import CoreLocation
import Security
import WeatherKit

/// Current conditions for the island's Weather panel, from Apple WeatherKit.
/// Fetched only while the panel is visible and the last result is over 30
/// minutes old. Until the WeatherKit capability and provisioning profile exist
/// for this app, WeatherKit refuses the request and the panel says so.
@MainActor
final class IslandWeatherService: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = IslandWeatherService()

    struct Conditions: Equatable {
        let temperature: Measurement<UnitTemperature>
        let high: Measurement<UnitTemperature>?
        let low: Measurement<UnitTemperature>?
        let summary: String
        let symbol: String
        let place: String?
        let fetched: Date
    }

    enum Status: Equatable {
        case idle, locating, loading, ready(Conditions)
        case needsSetup(String)
        case failed(String)
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var attribution: (logo: URL, legal: URL)?

    private let location = CLLocationManager()
    private var work: Task<Void, Never>?
    private var lastFetch: Date?

    private override init() {
        super.init()
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyThreeKilometers
    }

    /// Called when the Weather panel becomes the visible page.
    /// WeatherKit only works when the app is signed with its entitlement; without
    /// it, say so up front instead of asking for location first.
    static var hasWeatherKitEntitlement: Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.weatherkit" as CFString, nil) else { return false }
        return (value as? Bool) == true
    }

    func refreshIfStale(now: Date = .now) {
        if case .needsSetup = status { return }
        guard Self.hasWeatherKitEntitlement else {
            status = .needsSetup("Weather needs setup: enable WeatherKit for OmniFlow in the Apple Developer portal.")
            return
        }
        if let lastFetch, now.timeIntervalSince(lastFetch) < 30 * 60, case .ready = status { return }
        guard work == nil else { return }
        switch location.authorizationStatus {
        case .notDetermined:
            status = .locating
            location.requestWhenInUseAuthorization()
            scheduleLocationTimeout()
        case .denied, .restricted:
            status = .failed("Allow Location for OmniFlow in System Settings to see local weather.")
        default:
            status = .locating
            location.requestLocation()
            scheduleLocationTimeout()
        }
    }

    private var timeout: Task<Void, Never>?
    private func scheduleLocationTimeout() {
        timeout?.cancel()
        timeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            guard let self, status == .locating else { return }
            status = .failed("OmniFlow couldn't get your location. Check Location Services for OmniFlow in System Settings.")
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            let service = IslandWeatherService.shared
            let status = service.location.authorizationStatus
            if status == .authorizedAlways || status == .authorized { service.location.requestLocation() }
            else if status == .denied || status == .restricted {
                service.status = .failed("Allow Location for OmniFlow in System Settings to see local weather.")
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let place = locations.last else { return }
        Task { @MainActor in IslandWeatherService.shared.fetch(for: place) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in IslandWeatherService.shared.status = .failed("OmniFlow couldn't find your location for weather.") }
    }

    private func fetch(for place: CLLocation) {
        guard work == nil else { return }
        status = .loading
        work = Task { [weak self] in
            defer { self?.work = nil }
            do {
                let (current, daily) = try await WeatherService.shared.weather(for: place, including: .current, .daily)
                let today = daily.forecast.first
                let mark = try? await WeatherService.shared.attribution
                guard let self else { return }
                if let mark { attribution = (mark.combinedMarkDarkURL, mark.legalPageURL) }
                lastFetch = .now
                status = .ready(.init(temperature: current.temperature, high: today?.highTemperature, low: today?.lowTemperature,
                                      summary: current.condition.description, symbol: current.symbolName, place: nil, fetched: .now))
            } catch {
                guard let self else { return }
                // No WeatherKit entitlement/profile: the auth service is unreachable or refuses the app.
                let text = String(describing: error)
                if text.contains("authservice") || text.contains("JWT") || text.contains("xpcConnectionFailed") || text.contains("401") {
                    status = .needsSetup("Weather needs setup: enable WeatherKit for OmniFlow in the Apple Developer portal.")
                } else {
                    status = .failed("Weather is unavailable right now.")
                }
            }
        }
    }
}
