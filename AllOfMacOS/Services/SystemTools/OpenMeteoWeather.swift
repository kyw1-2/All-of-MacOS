import Foundation

/// The opt-in Weather card in System Tools › This Mac (Raycast's Weather
/// extension). Data from Open-Meteo (open-meteo.com, no key, CC BY 4.0):
/// the geocoding API turns a typed city into coordinates, the forecast API
/// answers in °C and km/h. Nothing is requested until the person turns the
/// card on and picks a place.
enum OpenMeteo {
    struct Place: Codable, Equatable, Hashable, Identifiable, Sendable {
        let id: Int
        let name: String
        let latitude: Double
        let longitude: Double
        let country: String?
        let region: String?
        let timezone: String?

        /// "Seoul, South Korea"; "Busan, North Chungcheong, South Korea".
        var title: String {
            var parts = [name]
            if let region, !region.isEmpty, region != name { parts.append(region) }
            if let country, !country.isEmpty { parts.append(country) }
            return parts.joined(separator: ", ")
        }
    }

    struct Day: Equatable, Sendable, Identifiable {
        let date: Date
        let code: Int
        let high: Double
        let low: Double
        let precipitationChance: Int?
        var id: Date { date }
    }

    struct Forecast: Equatable, Sendable {
        let temperature: Double
        let feelsLike: Double?
        let humidity: Int?
        let windSpeed: Double?
        let code: Int
        let isDay: Bool
        let observed: Date?
        let timezone: TimeZone?
        let days: [Day]
    }

    enum Failure: LocalizedError, Equatable {
        case unreadable
        case service(String)
        var errorDescription: String? {
            switch self {
            case .unreadable: return "Open-Meteo's answer wasn't readable."
            case .service(let reason): return "Open-Meteo refused the request: \(reason)"
            }
        }
    }

    static let geocodingHost = "geocoding-api.open-meteo.com"
    static let forecastHost = "api.open-meteo.com"

    static func searchURL(_ text: String, count: Int = 8) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = geocodingHost
        components.path = "/v1/search"
        components.queryItems = [URLQueryItem(name: "name", value: text.trimmingCharacters(in: .whitespacesAndNewlines)),
                                 URLQueryItem(name: "count", value: String(count)),
                                 URLQueryItem(name: "language", value: "en"),
                                 URLQueryItem(name: "format", value: "json")]
        return components.url
    }

    static func forecastURL(_ place: Place, days: Int = 4) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = forecastHost
        components.path = "/v1/forecast"
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.4f", place.latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.4f", place.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m,is_day"),
            URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: String(days))
        ]
        return components.url
    }

    /// The geocoding answer: {"results": [{id, name, latitude, longitude,
    /// country, admin1, timezone, …}]}; no `results` key when nothing matched.
    static func parsePlaces(_ data: Data) throws -> [Place] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.unreadable }
        if root["error"] as? Bool == true { throw Failure.service(root["reason"] as? String ?? "unknown reason") }
        return (root["results"] as? [[String: Any]] ?? []).compactMap { entry in
            guard let name = entry["name"] as? String,
                  let latitude = (entry["latitude"] as? NSNumber)?.doubleValue,
                  let longitude = (entry["longitude"] as? NSNumber)?.doubleValue else { return nil }
            let id = (entry["id"] as? NSNumber)?.intValue ?? Int((latitude * 1000).rounded()) * 100_000 + Int((longitude * 1000).rounded())
            return Place(id: id, name: name, latitude: latitude, longitude: longitude,
                         country: entry["country"] as? String, region: entry["admin1"] as? String,
                         timezone: entry["timezone"] as? String)
        }
    }

    /// The forecast answer: `current` (temperature_2m, weather_code, …) and
    /// `daily` (parallel arrays: time, weather_code, temperature_2m_max/min,
    /// precipitation_probability_max). Times are local to the place
    /// (`timezone=auto`), which `utc_offset_seconds` pins down.
    static func parseForecast(_ data: Data) throws -> Forecast {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.unreadable }
        if root["error"] as? Bool == true { throw Failure.service(root["reason"] as? String ?? "unknown reason") }
        guard let current = root["current"] as? [String: Any],
              let temperature = (current["temperature_2m"] as? NSNumber)?.doubleValue else { throw Failure.unreadable }
        let offset = (root["utc_offset_seconds"] as? NSNumber)?.intValue
        let zone = (root["timezone"] as? String).flatMap(TimeZone.init(identifier:)) ?? offset.flatMap(TimeZone.init(secondsFromGMT:))
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.timeZone = zone ?? TimeZone(secondsFromGMT: 0)
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.timeZone = dayFormatter.timeZone
        timeFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm"

        var days: [Day] = []
        if let daily = root["daily"] as? [String: Any], let times = daily["time"] as? [String] {
            let codes = daily["weather_code"] as? [Any] ?? []
            let highs = daily["temperature_2m_max"] as? [Any] ?? []
            let lows = daily["temperature_2m_min"] as? [Any] ?? []
            let rain = daily["precipitation_probability_max"] as? [Any] ?? []
            for (index, time) in times.enumerated() {
                guard let date = dayFormatter.date(from: time),
                      index < highs.count, index < lows.count,
                      let high = (highs[index] as? NSNumber)?.doubleValue,
                      let low = (lows[index] as? NSNumber)?.doubleValue else { continue }
                let code = index < codes.count ? (codes[index] as? NSNumber)?.intValue ?? -1 : -1
                let chance = index < rain.count ? (rain[index] as? NSNumber)?.intValue : nil
                days.append(Day(date: date, code: code, high: high, low: low, precipitationChance: chance))
            }
        }
        return Forecast(temperature: temperature,
                        feelsLike: (current["apparent_temperature"] as? NSNumber)?.doubleValue,
                        humidity: (current["relative_humidity_2m"] as? NSNumber)?.intValue,
                        windSpeed: (current["wind_speed_10m"] as? NSNumber)?.doubleValue,
                        code: (current["weather_code"] as? NSNumber)?.intValue ?? -1,
                        isDay: (current["is_day"] as? NSNumber)?.intValue != 0,
                        observed: (current["time"] as? String).flatMap(timeFormatter.date(from:)),
                        timezone: zone, days: days)
    }

    /// WMO weather interpretation codes (Open-Meteo's `weather_code`).
    static func condition(_ code: Int) -> String {
        switch code {
        case 0: return "Clear"
        case 1: return "Mostly clear"
        case 2: return "Partly cloudy"
        case 3: return "Overcast"
        case 45, 48: return "Fog"
        case 51, 53, 55: return "Drizzle"
        case 56, 57: return "Freezing drizzle"
        case 61: return "Light rain"
        case 63: return "Rain"
        case 65: return "Heavy rain"
        case 66, 67: return "Freezing rain"
        case 71: return "Light snow"
        case 73: return "Snow"
        case 75: return "Heavy snow"
        case 77: return "Snow grains"
        case 80, 81: return "Rain showers"
        case 82: return "Violent rain showers"
        case 85, 86: return "Snow showers"
        case 95: return "Thunderstorm"
        case 96, 99: return "Thunderstorm with hail"
        default: return "Unknown"
        }
    }

    static func symbol(_ code: Int, isDay: Bool = true) -> String {
        switch code {
        case 0: return isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: return isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51, 53, 55, 56, 57: return "cloud.drizzle.fill"
        case 61, 63, 80, 81: return "cloud.rain.fill"
        case 65, 82: return "cloud.heavyrain.fill"
        case 66, 67: return "cloud.sleet.fill"
        case 71, 73, 75, 77, 85, 86: return "cloud.snow.fill"
        case 95: return "cloud.bolt.rain.fill"
        case 96, 99: return "cloud.hail.fill"
        default: return "questionmark.circle"
        }
    }
}

/// The card's state: off by default, a chosen place, the last forecast and
/// when it arrived. While the card is on and the System Tools page is
/// showing it, it refreshes every 30 minutes; nothing runs while it is off
/// or nobody is looking.
@MainActor
final class WeatherCardModel: ObservableObject {
    static let shared = WeatherCardModel()
    nonisolated static let enabledKey = "AOMSystemToolsWeatherEnabled"
    nonisolated static let placeKey = "AOMSystemToolsWeatherPlace"
    nonisolated static let refreshInterval: TimeInterval = 30 * 60

    @Published private(set) var isOn: Bool
    @Published private(set) var place: OpenMeteo.Place?
    @Published private(set) var forecast: OpenMeteo.Forecast?
    @Published private(set) var updated: Date?
    @Published private(set) var loading = false
    @Published private(set) var error: String?

    private let defaults: UserDefaults
    private let session: URLSession
    private var timer: Timer?
    private var viewers = 0

    init(defaults: UserDefaults = .standard, session: URLSession = .shared) {
        self.defaults = defaults
        self.session = session
        isOn = defaults.bool(forKey: Self.enabledKey)
        place = defaults.data(forKey: Self.placeKey).flatMap { try? JSONDecoder().decode(OpenMeteo.Place.self, from: $0) }
    }

    /// Whether a refresh is due: never fetched, or older than 30 minutes.
    nonisolated static func isStale(updated: Date?, now: Date = Date()) -> Bool {
        guard let updated else { return true }
        return now.timeIntervalSince(updated) >= refreshInterval
    }

    func search(_ text: String) async throws -> [OpenMeteo.Place] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, !PresetManager.isUIPreview, let url = OpenMeteo.searchURL(trimmed) else { return [] }
        let (data, response) = try await session.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        do {
            return try OpenMeteo.parsePlaces(data)
        } catch OpenMeteo.Failure.unreadable where !(200..<300).contains(status) {
            throw OpenMeteo.Failure.service("HTTP \(status)")
        }
    }

    /// Picking a place turns the card on.
    func choose(_ place: OpenMeteo.Place) {
        self.place = place
        if let data = try? JSONEncoder().encode(place) { defaults.set(data, forKey: Self.placeKey) }
        forecast = nil
        updated = nil
        setOn(true)
    }

    func setOn(_ on: Bool) {
        isOn = on
        defaults.set(on, forKey: Self.enabledKey)
        if on { refreshIfStale(); scheduleTimer() } else { timer?.invalidate(); timer = nil; error = nil }
    }

    /// The page's card calls these from onAppear / onDisappear.
    func viewerAppeared() {
        viewers += 1
        guard isOn else { return }
        refreshIfStale()
        scheduleTimer()
    }

    func viewerDisappeared() {
        viewers = max(0, viewers - 1)
        if viewers == 0 { timer?.invalidate(); timer = nil }
    }

    private func scheduleTimer() {
        guard isOn, viewers > 0, timer == nil else { return }
        let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func refreshIfStale() {
        if Self.isStale(updated: updated) { refresh() }
    }

    /// Isolated UI previews: shows a sample without saving or fetching.
    func setPreview(place: OpenMeteo.Place, forecast: OpenMeteo.Forecast) {
        guard PresetManager.isUIPreview else { return }
        self.place = place
        self.forecast = forecast
        updated = Date()
        isOn = true
    }

    func refresh() {
        // Isolated previews never touch the network.
        guard isOn, let place, !loading, !PresetManager.isUIPreview, let url = OpenMeteo.forecastURL(place) else { return }
        loading = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let (data, response) = try await self.session.data(from: url)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 200
                do {
                    self.forecast = try OpenMeteo.parseForecast(data)
                } catch OpenMeteo.Failure.unreadable where !(200..<300).contains(status) {
                    throw OpenMeteo.Failure.service("HTTP \(status)")
                }
                self.updated = Date()
                self.error = nil
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            self.loading = false
        }
    }
}
