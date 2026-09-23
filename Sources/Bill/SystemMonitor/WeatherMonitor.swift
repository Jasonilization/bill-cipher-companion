import Foundation

/// One successful weather observation.
struct WeatherSnapshot: Sendable, Equatable {
    enum Condition: String, Sendable {
        case clear
        case cloudy
        case fog
        case rain
        case snow
        case thunder
        case other

        /// WMO weather-code groups used by Open-Meteo.
        /// https://open-meteo.com/en/docs — `weather_code` follows the
        /// standard WMO 4677 table.
        init(wmoCode: Int) {
            switch wmoCode {
            case 0: self = .clear
            case 1, 2: self = .cloudy
            case 3: self = .cloudy
            case 45, 48: self = .fog
            case 51...67, 80...82: self = .rain
            case 71...77, 85, 86: self = .snow
            case 95...99: self = .thunder
            default: self = .other
            }
        }
    }

    var temperatureC: Double
    var condition: Condition
    var isDay: Bool
    /// From the IP geolocation service — a *city name*, not a precise
    /// location; deliberately coarse so the privacy story stays simple
    /// ("Bill knows roughly where you are, same as any weather app you
    /// typed a zip code into").
    var city: String?

    /// Bill-voice context blurb for chat and generation prompts. Weather is
    /// the user's explicit ask for "relevant" commentary, so it rides along
    /// with the activity summary rather than being asked for on every line.
    var contextBlurb: String {
        var parts: [String] = []
        if let city { parts.append("in \(city)") }
        parts.append("the weather is \(conditionBlurb)")
        parts.append(String(format: "%.0f°C", temperatureC.rounded()))
        return parts.joined(separator: ", ")
    }

    private var conditionBlurb: String {
        switch condition {
        case .clear: return isDay ? "clear skies" : "a clear night sky"
        case .cloudy: return "overcast"
        case .fog: return "foggy"
        case .rain: return "raining"
        case .snow: return "snowing"
        case .thunder: return "storming — thunder and all"
        case .other: return "doing something unclassifiable"
        }
    }
}

/// Pulls local weather from Open-Meteo (no API key, no account — verified
/// live during development) every five minutes, plus once shortly after
/// launch so the first chat message of a session can already mention it.
///
/// Why five minutes rather than a lazy half-hour: the explicit ask was
/// "when it rains exactly outside, report it while it's still raining."
/// Open-Meteo's `minutely_15` nowcast is radar/satellite-based and refreshes
/// far faster than the hourly model, so folding the current 15-minute
/// precipitation slot into the condition makes "IT IS RAINING" land within
/// minutes of the first drop — while the plain `weather_code` alone can lag
/// by an hour. 288 requests a day is comfortably inside Open-Meteo's free
/// tier (10,000/day), and every fetch is short-timeout and silent on
/// failure — weather is garnish, not a dependency; offline machines simply
/// get a Bill who talks about everything except the sky.
///
/// Location is coarse IP geolocation (get.geojs.io, also keyless): the
/// snapshot carries a city name for flavor, never a precise coordinate
/// into anything user-visible.
@MainActor
final class WeatherMonitor {
    /// Fires when a fetch succeeds and the *condition* changed since the
    /// last one announced (temperature drift alone would nag constantly).
    var onConditionChanged: ((WeatherSnapshot) -> Void)?
    /// Fires on every successful fetch — the snapshot provider for chat
    /// context (`CharacterWindowController.contextualized`).
    var onSnapshot: ((WeatherSnapshot) -> Void)?

    private(set) var latest: WeatherSnapshot?
    private var timer: Timer?
    private var lastAnnouncedCondition: WeatherSnapshot.Condition?
    private static let fetchInterval: TimeInterval = 5 * 60

    func start() {
        stop()
        // First pull shortly after launch — off the launch critical path,
        // and late enough that a cold-start's network stack is up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.fetch()
        }
        timer = Timer.scheduledTimer(withTimeInterval: Self.fetchInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.fetch() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func fetch() {
        Task { [weak self] in
            guard let snapshot = await Self.pull() else { return }
            guard let self else { return }
            self.latest = snapshot
            self.onSnapshot?(snapshot)
            if snapshot.condition != self.lastAnnouncedCondition {
                self.lastAnnouncedCondition = snapshot.condition
                self.onConditionChanged?(snapshot)
            }
        }
    }

    // MARK: - Network

    /// The full pull: IP geolocation, then Open-Meteo's current-conditions
    /// endpoint. Static so a debug path could exercise it without a
    /// running monitor.
    static func pull() async -> WeatherSnapshot? {
        guard let geo = await geolocate() else { return nil }
        guard let snapshot = await currentWeather(latitude: geo.latitude, longitude: geo.longitude, city: geo.city) else { return nil }
        return snapshot
    }

    private struct GeoLocation {
        var latitude: Double
        var longitude: Double
        var city: String?
    }

    private static func geolocate() async -> GeoLocation? {
        var request = URLRequest(url: URL(string: "https://get.geojs.io/v1/ip/geo.json")!)
        request.timeoutInterval = 10
        guard
            let (data, response) = try? await URLSession.shared.data(for: request),
            let http = response as? HTTPURLResponse, http.statusCode == 200
        else { return nil }
        struct GeoJSON: Decodable {
            var latitude: String
            var longitude: String
            var city: String?
        }
        guard let decoded = try? JSONDecoder().decode(GeoJSON.self, from: data),
              let latitude = Double(decoded.latitude),
              let longitude = Double(decoded.longitude)
        else { return nil }
        return GeoLocation(latitude: latitude, longitude: longitude, city: decoded.city)
    }

    private static func currentWeather(latitude: Double, longitude: Double, city: String?) async -> WeatherSnapshot? {
        // Rounded coordinates: the request URL is the only thing that could
        // ever leak into a log, and ~11km precision keeps that boring.
        let lat = (latitude * 100).rounded() / 100
        let lon = (longitude * 100).rounded() / 100
        let endpoint = "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)&current=temperature_2m,weather_code,is_day&minutely_15=precipitation"
        var request = URLRequest(url: URL(string: endpoint)!)
        request.timeoutInterval = 10
        guard
            let (data, response) = try? await URLSession.shared.data(for: request),
            let http = response as? HTTPURLResponse, http.statusCode == 200
        else { return nil }
        struct WeatherJSON: Decodable {
            struct Current: Decodable {
                var temperature_2m: Double
                var weather_code: Int
                var is_day: Int
            }
            struct Minutely: Decodable {
                var precipitation: [Double]?
            }
            var current: Current
            /// Absent for some regions — the code-based condition remains
            /// authoritative wherever the nowcast has no radar coverage.
            var minutely_15: Minutely?
        }
        guard let decoded = try? JSONDecoder().decode(WeatherJSON.self, from: data) else { return nil }
        return WeatherSnapshot(
            temperatureC: decoded.current.temperature_2m,
            condition: Self.resolveCondition(
                wmoCode: decoded.current.weather_code,
                nowcastPrecipitation: decoded.minutely_15?.precipitation
            ),
            isDay: decoded.current.is_day == 1,
            city: city
        )
    }

    /// Fuses the (hourly, laggy) WMO code with the (radar-based, ~minutes
    /// fresh) nowcast precipitation:
    /// - Nowcast says the current 15-minute slot is wet → report rain (or
    ///   better) *now*, even while the code still claims "clear". This is
    ///   the "it's raining exactly outside" path.
    /// - Code says rain but the current *and* next nowcast slots are dry →
    ///   the shower already passed; report clouds instead of insisting on
    ///   rain that ended an hour ago.
    /// Snow and thunder keep their code-derived identities — the nowcast's
    /// mm are water-equivalent and can't distinguish snow, and thunder is a
    /// code-level call.
    private static func resolveCondition(wmoCode: Int, nowcastPrecipitation: [Double]?) -> WeatherSnapshot.Condition {
        var condition = WeatherSnapshot.Condition(wmoCode: wmoCode)
        let currentSlot = nowcastPrecipitation?.first ?? 0
        let nextSlot = nowcastPrecipitation?.dropFirst().first ?? 0
        // 0.05mm: drizzle counts, condensation noise doesn't.
        if currentSlot > 0.05 {
            if condition != .thunder && condition != .snow {
                condition = .rain
            }
        } else if condition == .rain, currentSlot <= 0.05, nextSlot <= 0.05 {
            condition = .cloudy
        }
        return condition
    }
}
