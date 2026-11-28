import AppKit
import SwiftUI

/// 7.6 (Codex W01; Raycast Weather, Menubar Weather): the weather of one
/// city you choose, in a menu bar item of its own ("☁ 6°"), with the
/// details a click away. It needs no permission: no location, no
/// Accessibility, no Screen Recording. Only the chosen city's coordinates go
/// to Open-Meteo (free, no key, CC BY 4.0 — credited in the menu); a city
/// search sends only the name typed.
///
/// A reading is kept for 30 minutes; requests are coalesced, a reply for a
/// city you have since changed is dropped, a 429 waits for its Retry-After,
/// and waking the Mac refreshes only a stale reading. Offline, the last
/// reading stays with its time; with none, the item says so.
struct WeatherCity: Codable, Equatable, Identifiable, Hashable {
    let id: Int
    let name: String
    var admin: String?
    var country: String?
    var timezone: String
    let latitude: Double
    let longitude: Double

    /// "Seoul, Seoul, South Korea" — region and country tell same names apart.
    var label: String { [name, admin, country].compactMap { $0 }.filter { !$0.isEmpty }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator: ", ") }
}

struct WeatherReading: Codable, Equatable {
    let cityID: Int
    var temperature: Double
    /// Nil when the provider left it out: the actual temperature stands in.
    var feelsLike: Double?
    let code: Int
    let isDay: Bool
    var low: Double?
    var high: Double?
    var rainChance: Int?
    let fetchedAt: Date
    var unit: MenuBarWeather.Unit
    /// The next hours' temperatures and rain chances, from the same request (Gemini 7.6 idea).
    var nextHours: [Double]? = nil
    var nextRain: [Int]? = nil
    // 7.9: what a weather app's card shows, from the same one request.
    var humidity: Int? = nil
    var windSpeed: Double? = nil
    var windDirection: Int? = nil
    var uvIndex: Double? = nil
    /// Local wall-clock times ("2026-11-22T07:18") in the city's time zone.
    var sunrise: String? = nil
    var sunset: String? = nil
    var hours: [WeatherHour]? = nil
    var days: [WeatherDay]? = nil
}

/// One hour of the forecast (7.9).
struct WeatherHour: Codable, Equatable {
    /// "2026-11-22T16:00", the city's local time.
    let time: String
    var temperature: Double
    var rain: Int?
    let code: Int
    let isDay: Bool
}

/// One day of the forecast (7.9).
struct WeatherDay: Codable, Equatable {
    /// "2026-11-22".
    let date: String
    let code: Int
    var high: Double
    var low: Double
    var rain: Int?
}

extension WeatherReading {
    /// 7.11: the same observation in another unit — 20 °C reads 68 °F, never
    /// "20°F" — so a unit switch shows at once and offline too. Wind follows
    /// (km/h with °C, mph with °F, as Open-Meteo is asked).
    func converted(to target: MenuBarWeather.Unit) -> WeatherReading {
        guard unit != target else { return self }
        let degrees: (Double) -> Double = target == .fahrenheit ? { $0 * 9 / 5 + 32 } : { ($0 - 32) * 5 / 9 }
        let speed: (Double) -> Double = target == .fahrenheit ? { $0 / 1.609344 } : { $0 * 1.609344 }
        var out = self
        out.temperature = degrees(temperature)
        out.feelsLike = feelsLike.map(degrees)
        out.low = low.map(degrees)
        out.high = high.map(degrees)
        out.nextHours = nextHours?.map(degrees)
        out.windSpeed = windSpeed.map(speed)
        out.hours = hours?.map { hour in var hour = hour; hour.temperature = degrees(hour.temperature); return hour }
        out.days = days?.map { day in var day = day; day.high = degrees(day.high); day.low = degrees(day.low); return day }
        out.unit = target
        return out
    }
}

enum WeatherError: Error, Equatable {
    case offline
    case limited(until: Date)
    case failed(String)

    var message: String {
        switch self {
        case .offline: return "No connection"
        case .limited(let until): return "Open-Meteo asked AOM to wait until \(until.formatted(date: .omitted, time: .shortened))"
        case .failed(let reason): return reason
        }
    }
}

/// Where readings come from: Open-Meteo, or a stand-in in tests.
struct WeatherProvider {
    var search: (String) async throws -> [WeatherCity]
    var fetch: (WeatherCity, MenuBarWeather.Unit) async throws -> WeatherReading

    static let openMeteo = WeatherProvider(
        search: { name in
            var parts = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
            parts.queryItems = [.init(name: "name", value: name), .init(name: "count", value: "10"),
                                .init(name: "language", value: Locale.current.language.languageCode?.identifier ?? "en"),
                                .init(name: "format", value: "json")]
            return try MenuBarWeather.parseCities(try await request(parts.url!))
        },
        fetch: { city, unit in
            var parts = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
            parts.queryItems = [.init(name: "latitude", value: String(city.latitude)), .init(name: "longitude", value: String(city.longitude)),
                                .init(name: "current", value: "temperature_2m,apparent_temperature,weather_code,is_day,relative_humidity_2m,wind_speed_10m,wind_direction_10m,uv_index"),
                                .init(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,sunrise,sunset"),
                                .init(name: "hourly", value: "temperature_2m,precipitation_probability,weather_code,is_day"), .init(name: "forecast_hours", value: "13"),
                                .init(name: "forecast_days", value: "7"), .init(name: "timezone", value: city.timezone),
                                .init(name: "temperature_unit", value: unit == .fahrenheit ? "fahrenheit" : "celsius"),
                                .init(name: "wind_speed_unit", value: unit == .fahrenheit ? "mph" : "kmh")]
            return try MenuBarWeather.parseForecast(try await request(parts.url!), city: city, unit: unit, now: Date())
        })

    private static func request(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("AllOfMacOS-Weather", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw WeatherError.failed("No answer") }
            if http.statusCode == 429 {
                throw WeatherError.limited(until: MenuBarWeather.retryAfter(http.value(forHTTPHeaderField: "Retry-After"), now: Date()))
            }
            guard (200..<300).contains(http.statusCode) else { throw WeatherError.failed("Open-Meteo answered \(http.statusCode)") }
            return data
        } catch let error as URLError {
            // A request AOM cancelled (city or unit changed) is not a failure.
            if error.code == .cancelled { throw CancellationError() }
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost, .dataNotAllowed:
                throw WeatherError.offline
            default: throw WeatherError.failed(ConnectFailureReason.classify(error, host: "Open-Meteo").title)
            }
        }
    }
}

@MainActor
final class MenuBarWeather: NSObject, ObservableObject, NSMenuDelegate {
    static let shared = MenuBarWeather()

    enum Display: String, CaseIterable, Codable { case temperature, feelsLike, iconOnly }

    /// 7.11: what sits beside the icon, in the person's order (Menu Bar ›
    /// Weather). An empty list is the icon alone.
    enum Field: String, CaseIterable, Codable, Identifiable {
        case temperature, feelsLike, highLow, rainChance, humidity, wind
        var id: String { rawValue }
        var title: String {
            switch self {
            case .temperature: return "Temperature · 기온"
            case .feelsLike: return "Feels like · 체감"
            case .highLow: return "Today's high and low · 최고/최저"
            case .rainChance: return "Chance of rain today · 강수확률"
            case .humidity: return "Humidity · 습도"
            case .wind: return "Wind speed · 풍속"
            }
        }
    }

    static let fieldsKey = "AOMWeather.fields.v1"

    /// Pure: the fields an older setting means (Temp, Feels or Icon only).
    nonisolated static func fields(migrating display: Display) -> [Field] {
        switch display {
        case .temperature: return [.temperature]
        case .feelsLike: return [.feelsLike]
        case .iconOnly: return []
        }
    }
    enum Unit: String, CaseIterable, Codable { case celsius, fahrenheit }

    static let cityKey = "AOMWeather.city.v1"
    static let readingKey = "AOMWeather.reading.v1"
    static let displayKey = "AOMWeather.display"
    static let unitKey = "AOMWeather.unit"
    static let maxAge: TimeInterval = 30 * 60
    static let recentKey = "AOMWeather.recent.v1"

    /// The last three cities chosen, newest first (Gemini 7.6 idea).
    @Published private(set) var recent: [WeatherCity] = []

    @Published private(set) var city: WeatherCity?
    @Published private(set) var reading: WeatherReading?
    @Published private(set) var problem: WeatherError?
    @Published var display: Display { didSet { UserDefaults.standard.set(display.rawValue, forKey: Self.displayKey); updateItem() } }
    /// 7.11: the menu bar's fields, in order; saved at once, restored at launch.
    @Published var fields: [Field] {
        didSet {
            UserDefaults.standard.set(fields.map(\.rawValue), forKey: Self.fieldsKey)
            updateItem()
        }
    }

    /// The reading for the chosen city in the chosen unit (converted from the
    /// cached one until a new one arrives), or nil.
    var current: WeatherReading? {
        guard let reading, let city, reading.cityID == city.id else { return nil }
        return reading.converted(to: unit)
    }
    @Published var unit: Unit {
        didSet {
            UserDefaults.standard.set(unit.rawValue, forKey: Self.unitKey)
            if oldValue != unit { updateItem(); refresh(force: true) }
        }
    }

    var provider = WeatherProvider.openMeteo
    private var item: NSStatusItem?
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var inFlight: Task<Void, Never>?
    /// Bumped when the city or unit changes: an older reply is dropped.
    private var generation = 0
    private var waitUntil: Date?

    override init() {
        let defaults = UserDefaults.standard
        city = defaults.data(forKey: Self.cityKey).flatMap { try? JSONDecoder().decode(WeatherCity.self, from: $0) }
        reading = defaults.data(forKey: Self.readingKey).flatMap { try? JSONDecoder().decode(WeatherReading.self, from: $0) }
        let oldDisplay = Display(rawValue: defaults.string(forKey: Self.displayKey) ?? "") ?? .temperature
        display = oldDisplay
        // An upgrade keeps what the menu bar showed (an icon-only bar stays icon only).
        if let saved = defaults.stringArray(forKey: Self.fieldsKey) {
            fields = saved.compactMap(Field.init(rawValue:))
        } else {
            fields = Self.fields(migrating: oldDisplay)
        }
        unit = Unit(rawValue: defaults.string(forKey: Self.unitKey) ?? "") ?? (Locale.current.measurementSystem == .us ? .fahrenheit : .celsius)
        recent = defaults.data(forKey: Self.recentKey).flatMap { try? JSONDecoder().decode([WeatherCity].self, from: $0) } ?? []
        super.init()
    }

    // MARK: Lifecycle

    func start() {
        guard item == nil else { return }
        // One item, however often the module is turned off and on.
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "AOMMenuBarWeather"
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        self.item = item
        updateItem()
        let timer = Timer(timeInterval: 300, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        if city == nil { DispatchQueue.main.async { Self.openCityPicker() } } else { refresh() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        inFlight?.cancel()
        inFlight = nil
        generation += 1
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
    }

    func choose(_ city: WeatherCity) {
        self.city = city
        if let data = try? JSONEncoder().encode(city) { UserDefaults.standard.set(data, forKey: Self.cityKey) }
        recent = Self.remember(city, in: recent)
        if let data = try? JSONEncoder().encode(recent) { UserDefaults.standard.set(data, forKey: Self.recentKey) }
        reading = nil
        UserDefaults.standard.removeObject(forKey: Self.readingKey)
        // The item shows the new city at once, even while a 429 wait holds the request.
        updateItem()
        refresh(force: true)
    }

    /// Pure: `city` first, then up to two others, each once.
    nonisolated static func remember(_ city: WeatherCity, in recent: [WeatherCity]) -> [WeatherCity] {
        Array(([city] + recent.filter { $0.id != city.id }).prefix(3))
    }

    /// "Next 6 h: 3° → -1° · rain up to 40%".
    nonisolated static func trend(_ reading: WeatherReading) -> String? {
        guard let hours = reading.nextHours, let first = hours.first, let last = hours.last, hours.count >= 2 else { return nil }
        var text = "Next \(hours.count) h: \(Int(first.rounded()))° → \(Int(last.rounded()))°"
        if let rain = reading.nextRain?.max(), rain > 0 { text += " · rain up to \(rain)%" }
        return text
    }

    // MARK: Refresh

    /// Pure: a reading is used for 30 minutes, for its own city and unit.
    nonisolated static func isFresh(_ reading: WeatherReading?, city: WeatherCity?, unit: Unit, now: Date) -> Bool {
        guard let reading, let city, reading.cityID == city.id, reading.unit == unit else { return false }
        return now.timeIntervalSince(reading.fetchedAt) < maxAge
    }

    func refresh(force: Bool = false) {
        guard let city else { updateItem(); return }
        let now = Date()
        if let waitUntil, now < waitUntil { return }
        if !force, Self.isFresh(reading, city: city, unit: unit, now: now) { return }
        if force { inFlight?.cancel(); inFlight = nil; generation += 1 }
        guard inFlight == nil else { return }       // one request at a time
        let generation = generation, unit = unit, provider = provider
        inFlight = Task { [weak self] in
            let result: Result<WeatherReading, WeatherError>
            do { result = .success(try await provider.fetch(city, unit)) }
            catch let error as WeatherError { result = .failure(error) }
            catch is CancellationError {
                // Gemini 7.9: a cancel AOM didn't ask for (the network layer)
                // must still free the slot, or refreshing stops for good.
                if let self, generation == self.generation { self.inFlight = nil }
                return
            }
            catch { result = .failure(.failed(error.localizedDescription)) }
            // Only the current request clears the slot (Gemini 7.6: an old one
            // used to clear the new one's, so two could run at once).
            guard let self, generation == self.generation else { return }
            self.inFlight = nil
            guard self.city?.id == city.id else { return }
            switch result {
            case .success(let reading):
                self.reading = reading
                self.problem = nil
                if let data = try? JSONEncoder().encode(reading) { UserDefaults.standard.set(data, forKey: Self.readingKey) }
            case .failure(let error):
                self.problem = error
                if case .limited(let until) = error { self.waitUntil = until }
            }
            self.updateItem()
        }
    }

    // MARK: Pure parts

    /// Seconds or an HTTP date; at least a minute, at most a day.
    nonisolated static func retryAfter(_ header: String?, now: Date) -> Date {
        if let header, let seconds = Double(header.trimmingCharacters(in: .whitespaces)) {
            return now.addingTimeInterval(min(86_400, max(60, seconds)))
        }
        if let header {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            if let date = formatter.date(from: header) { return min(now.addingTimeInterval(86_400), max(now.addingTimeInterval(60), date)) }
        }
        return now.addingTimeInterval(600)
    }

    nonisolated static func parseCities(_ data: Data) throws -> [WeatherCity] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw WeatherError.failed("Unreadable answer") }
        let results = object["results"] as? [[String: Any]] ?? []
        return results.compactMap { row in
            guard let id = row["id"] as? Int, let name = row["name"] as? String,
                  let latitude = row["latitude"] as? Double, let longitude = row["longitude"] as? Double else { return nil }
            return WeatherCity(id: id, name: name, admin: row["admin1"] as? String, country: row["country"] as? String,
                               timezone: row["timezone"] as? String ?? "auto", latitude: latitude, longitude: longitude)
        }
    }

    nonisolated static func parseForecast(_ data: Data, city: WeatherCity, unit: Unit, now: Date) throws -> WeatherReading {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = object["current"] as? [String: Any],
              let temperature = (current["temperature_2m"] as? NSNumber)?.doubleValue else { throw WeatherError.failed("The forecast had no temperature") }
        let daily = object["daily"] as? [String: Any]
        func first(_ key: String) -> Double? { ((daily?[key] as? [Any])?.first as? NSNumber)?.doubleValue }
        let hourly = object["hourly"] as? [String: Any]
        let hours = (hourly?["temperature_2m"] as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue }
        let rain = (hourly?["precipitation_probability"] as? [Any])?.compactMap { ($0 as? NSNumber)?.intValue }
        var reading = WeatherReading(cityID: city.id, temperature: temperature,
                              feelsLike: (current["apparent_temperature"] as? NSNumber)?.doubleValue,
                              code: (current["weather_code"] as? NSNumber)?.intValue ?? 0,
                              isDay: ((current["is_day"] as? NSNumber)?.intValue ?? 1) == 1,
                              low: first("temperature_2m_min"), high: first("temperature_2m_max"),
                              rainChance: first("precipitation_probability_max").map { Int($0.rounded()) },
                              fetchedAt: now, unit: unit, nextHours: hours?.isEmpty == false ? hours : nil, nextRain: rain?.isEmpty == false ? rain : nil)
        // 7.9: the rest of the card. Every part is optional; a missing one
        // just isn't drawn.
        func number(_ key: String) -> Double? { (current[key] as? NSNumber)?.doubleValue }
        reading.humidity = number("relative_humidity_2m").map { Int($0.rounded()) }
        reading.windSpeed = number("wind_speed_10m")
        reading.windDirection = number("wind_direction_10m").map { Int($0.rounded()) }
        reading.uvIndex = number("uv_index")
        func strings(_ source: [String: Any]?, _ key: String) -> [String] { (source?[key] as? [Any])?.compactMap { $0 as? String } ?? [] }
        func numbers(_ source: [String: Any]?, _ key: String) -> [Double?] { (source?[key] as? [Any])?.map { ($0 as? NSNumber)?.doubleValue } ?? [] }
        reading.sunrise = strings(daily, "sunrise").first
        reading.sunset = strings(daily, "sunset").first
        let times = strings(hourly, "time"), temps = numbers(hourly, "temperature_2m")
        let rains = numbers(hourly, "precipitation_probability"), codes = numbers(hourly, "weather_code"), days = numbers(hourly, "is_day")
        let hourRows: [WeatherHour] = times.indices.compactMap { index in
            guard temps.indices.contains(index), let temp = temps[index] else { return nil }
            return WeatherHour(time: times[index], temperature: temp,
                               rain: rains.indices.contains(index) ? rains[index].map { Int($0.rounded()) } : nil,
                               code: codes.indices.contains(index) ? Int(codes[index] ?? 0) : 0,
                               isDay: days.indices.contains(index) ? (days[index] ?? 1) == 1 : true)
        }
        reading.hours = hourRows.isEmpty ? nil : hourRows
        let dates = strings(daily, "time"), highs = numbers(daily, "temperature_2m_max"), lows = numbers(daily, "temperature_2m_min")
        let dayCodes = numbers(daily, "weather_code"), dayRain = numbers(daily, "precipitation_probability_max")
        let dayRows: [WeatherDay] = dates.indices.compactMap { index in
            guard highs.indices.contains(index), lows.indices.contains(index), let high = highs[index], let low = lows[index] else { return nil }
            return WeatherDay(date: dates[index], code: dayCodes.indices.contains(index) ? Int(dayCodes[index] ?? 0) : 0,
                              high: high, low: low, rain: dayRain.indices.contains(index) ? dayRain[index].map { Int($0.rounded()) } : nil)
        }
        reading.days = dayRows.isEmpty ? nil : dayRows
        return reading
    }

    /// Pure (7.9): N, NE … NW for a wind direction in degrees.
    nonisolated static func compass(_ degrees: Int) -> String {
        let points = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let normalized = ((degrees % 360) + 360) % 360
        return points[Int((Double(normalized) / 45).rounded()) % 8]
    }

    /// Pure (7.9): the UV index's band (WHO).
    nonisolated static func uvBand(_ index: Double) -> String {
        switch index {
        case ..<3: return "Low"
        case ..<6: return "Moderate"
        case ..<8: return "High"
        case ..<11: return "Very high"
        default: return "Extreme"
        }
    }

    /// Filled, coloured symbols for the card (the menu bar keeps the outline ones).
    nonisolated static func colorSymbol(code: Int, isDay: Bool) -> String {
        switch code {
        case 0: return isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: return isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51...57: return "cloud.drizzle.fill"
        case 61...67, 80...82: return "cloud.rain.fill"
        case 71...77, 85, 86: return "cloud.snow.fill"
        case 95...99: return "cloud.bolt.rain.fill"
        default: return "thermometer.medium"
        }
    }

    /// 7.11: the text beside the icon — "20°C · 습도 64% · 강수 30%" — and the
    /// whole of it for the tooltip. Missing values are left out; a long
    /// combination drops its last fields first to stay within `limit`.
    nonisolated static func line(_ reading: WeatherReading?, fields: [Field], limit: Int = 30) -> (text: String, full: String) {
        guard !fields.isEmpty else { return ("", "") }
        guard let reading else { return ("—", "") }
        let suffix = reading.unit == .fahrenheit ? "°F" : "°C"
        func degrees(_ value: Double) -> String { "\(Int(value.rounded()))\(suffix)" }
        let parts: [String] = fields.compactMap { field in
            switch field {
            case .temperature: return degrees(reading.temperature)
            case .feelsLike: return reading.feelsLike.map { "체감 " + degrees($0) }
            case .highLow:
                guard let high = reading.high, let low = reading.low else { return nil }
                return "↑\(degrees(high)) ↓\(degrees(low))"
            case .rainChance: return reading.rainChance.map { "강수 \($0)%" }
            case .humidity: return reading.humidity.map { "습도 \($0)%" }
            case .wind:
                return reading.windSpeed.map { "바람 \(Int($0.rounded()))" + (reading.unit == .fahrenheit ? "mph" : "km/h") }
            }
        }
        guard !parts.isEmpty else { return ("—", "") }
        let full = parts.joined(separator: " · ")
        var shown = parts
        while shown.count > 1, shown.joined(separator: " · ").count > limit { shown.removeLast() }
        return (shown.joined(separator: " · "), full)
    }

    /// "6°", the feels-like value (or the actual one when it's missing), or nothing beside the icon.
    nonisolated static func title(_ reading: WeatherReading?, display: Display) -> String {
        guard let reading else { return "—" }
        switch display {
        case .temperature: return "\(Int(reading.temperature.rounded()))°"
        case .feelsLike: return "\(Int((reading.feelsLike ?? reading.temperature).rounded()))°"
        case .iconOnly: return ""
        }
    }

    /// WMO weather codes as SF Symbols.
    nonisolated static func symbol(code: Int, isDay: Bool) -> String {
        switch code {
        case 0: return isDay ? "sun.max" : "moon.stars"
        case 1, 2: return isDay ? "cloud.sun" : "cloud.moon"
        case 3: return "cloud"
        case 45, 48: return "cloud.fog"
        case 51...57: return "cloud.drizzle"
        case 61...67, 80...82: return "cloud.rain"
        case 71...77, 85, 86: return "cloud.snow"
        case 95...99: return "cloud.bolt.rain"
        default: return "thermometer.medium"
        }
    }

    nonisolated static func describe(code: Int) -> String {
        switch code {
        case 0: return "Clear"
        case 1: return "Mostly clear"
        case 2: return "Partly cloudy"
        case 3: return "Overcast"
        case 45, 48: return "Fog"
        case 51...57: return "Drizzle"
        case 61...67: return "Rain"
        case 71...77: return "Snow"
        case 80...82: return "Showers"
        case 85, 86: return "Snow showers"
        case 95...99: return "Thunderstorm"
        default: return "Weather"
        }
    }

    /// What VoiceOver reads for the item.
    nonisolated static func spoken(city: WeatherCity?, reading: WeatherReading?, problem: WeatherError?) -> String {
        guard let city else { return "Weather: choose a city" }
        guard let reading, reading.cityID == city.id else {
            return "Weather in \(city.name): no reading yet" + (problem.map { ", \($0.message)" } ?? "")
        }
        var text = "Weather in \(city.name): \(describe(code: reading.code)), \(Int(reading.temperature.rounded())) degrees"
        if let feels = reading.feelsLike { text += ", feels like \(Int(feels.rounded()))" }
        return text + ". Updated \(reading.fetchedAt.formatted(date: .omitted, time: .shortened))"
    }

    // MARK: Item and menu

    private func updateItem() {
        guard let button = item?.button else { return }
        let current = self.current
        let image = NSImage(systemSymbolName: current.map { Self.symbol(code: $0.code, isDay: $0.isDay) } ?? "cloud.sun",
                            accessibilityDescription: nil)
        image?.isTemplate = true
        button.image = image?.withSymbolConfiguration(.init(pointSize: 13, weight: .semibold)) ?? image
        button.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        let line = Self.line(current, fields: fields)
        button.imagePosition = fields.isEmpty ? .imageOnly : .imageLeading
        button.title = city == nil ? "" : line.text
        // A disabled NSStatusBarButton renders all weather content washed out.
        // Keep contrast even offline; stale data is called out by its timestamp
        // and the accessibility description, never by making the item illegible.
        button.appearsDisabled = false
        let spoken = Self.spoken(city: city, reading: current, problem: problem)
        button.setAccessibilityLabel(spoken)
        // The whole line (when shortened) and when it was measured, also offline.
        button.toolTip = line.full.isEmpty || line.full == line.text ? spoken : "\(line.full)\n\(spoken)"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let card = NSMenuItem(title: "Weather details", action: nil, keyEquivalent: "")
        let summary = NSHostingView(rootView: WeatherMenuCard(city: city, reading: current, problem: problem))
        summary.frame = NSRect(x: 0, y: 0, width: WeatherMenuCard.width, height: 10)
        summary.frame.size.height = summary.fittingSize.height
        card.view = summary
        menu.addItem(card)
        menu.addItem(.separator())
        // 7.11: the menu bar's own fields, then the full editor in Settings.
        let display = NSMenuItem(title: "Menu Bar Display…", action: #selector(openDisplaySettings), keyEquivalent: ",")
        display.target = self
        menu.addItem(display)
        let show = NSMenuItem(title: "Show", action: nil, keyEquivalent: "")
        let showMenu = NSMenu()
        for field in Field.allCases {
            let entry = NSMenuItem(title: field.title, action: #selector(toggleField(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = field.rawValue
            entry.state = fields.contains(field) ? .on : .off
            showMenu.addItem(entry)
        }
        showMenu.addItem(.separator())
        for (choice, title) in [(Unit.celsius, "Celsius (°C)"), (.fahrenheit, "Fahrenheit (°F)")] {
            let entry = NSMenuItem(title: title, action: #selector(pickUnit(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = choice.rawValue
            entry.state = unit == choice ? .on : .off
            showMenu.addItem(entry)
        }
        show.submenu = showMenu
        menu.addItem(show)
        let refresh = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        refresh.isEnabled = city != nil
        menu.addItem(refresh)
        let choose = NSMenuItem(title: city == nil ? "Choose City…" : "Change City…", action: #selector(chooseCity), keyEquivalent: "")
        choose.target = self
        menu.addItem(choose)
        for other in recent where other.id != city?.id {
            let entry = NSMenuItem(title: "Switch to \(other.name)", action: #selector(pickRecent(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = other.id
            entry.toolTip = other.label
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        let manage = NSMenuItem(title: "Manage Menu Bar…", action: #selector(openManagement), keyEquivalent: "")
        manage.target = self
        menu.addItem(manage)
        let off = NSMenuItem(title: "Turn Off Weather", action: #selector(turnOff), keyEquivalent: "")
        off.target = self
        menu.addItem(off)
    }

    /// `--aom-preview-menubar-sample`: a full reading for Seoul, no network.
    func loadSample() {
        let seoul = WeatherCity(id: 1835848, name: "서울특별시", admin: "Seoul", country: "South Korea", timezone: "Asia/Seoul",
                                latitude: 37.566, longitude: 126.978)
        city = seoul
        let hours = (0..<13).map { index in
            WeatherHour(time: String(format: "2026-11-22T%02d:00", (16 + index) % 24), temperature: 4.4 - Double(index) * 0.6,
                        rain: [0, 0, 10, 20, 40, 60, 40, 20, 10, 0, 0, 0, 0][index], code: [0, 1, 2, 3, 61, 61, 3, 2, 1, 0, 0, 0, 0][index],
                        isDay: index < 2)
        }
        let days = [("2026-11-22", 0, 9.1, -1.2, 10), ("2026-11-23", 61, 7.4, 0.8, 70), ("2026-11-24", 3, 5.0, -2.5, 20),
                    ("2026-11-25", 71, 1.2, -6.1, 60), ("2026-11-26", 1, 3.3, -4.8, 0), ("2026-11-27", 2, 6.0, -1.0, 10),
                    ("2026-11-28", 0, 8.2, 0.4, 0)].map { WeatherDay(date: $0.0, code: $0.1, high: $0.2, low: $0.3, rain: $0.4) }
        var sample = WeatherReading(cityID: seoul.id, temperature: 4.4, feelsLike: 1.1, code: 0, isDay: true, low: -1.2, high: 9.1,
                                    rainChance: 10, fetchedAt: Date(), unit: .celsius,
                                    nextHours: hours.map(\.temperature), nextRain: hours.compactMap(\.rain))
        sample.humidity = 56
        sample.windSpeed = 4.3
        sample.windDirection = 246
        sample.uvIndex = 3.1
        sample.sunrise = "2026-11-22T07:18"
        sample.sunset = "2026-11-22T17:16"
        sample.hours = hours
        sample.days = days
        reading = sample
        problem = nil
    }

    @objc private func pickUnit(_ sender: NSMenuItem) { unit = Unit(rawValue: sender.representedObject as? String ?? "") ?? unit }
    @objc private func toggleField(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let field = Field(rawValue: raw) else { return }
        if let index = fields.firstIndex(of: field) { fields.remove(at: index) } else { fields.append(field) }
    }

    @objc private func openDisplaySettings() { MenuBarNavigation.open(tab: .weather) }

    @objc private func refreshNow() { waitUntil = waitUntil.flatMap { $0 > Date() ? $0 : nil }; refresh(force: true) }
    @objc private func chooseCity() { Self.openCityPicker() }
    @objc private func openManagement() { MenuBarNavigation.open() }
    @objc private func pickRecent(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? Int, let other = recent.first(where: { $0.id == id }) { choose(other) }
    }
    @objc private func turnOff() { AOMModuleSwitches.shared.set(.weather, on: false) }

    static func openCityPicker() {
        AOMToolWindows.shared.show("weather.city", title: "Weather City", size: NSSize(width: 460, height: 420),
                                   minSize: NSSize(width: 380, height: 300), autosave: "AOMWeatherCityWindow") {
            WeatherCityPicker(weather: .shared)
        }
    }
}

/// Search a city by name and pick one; only the name typed is sent.
struct WeatherCityPicker: View {
    @ObservedObject var weather: MenuBarWeather
    @State private var query = ""
    @State private var results: [WeatherCity] = []
    @State private var searching = false
    @State private var problem: String?
    @State private var ticket = 0
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: AOMSpace.x3) {
            Text("Choose the city for the menu bar weather").font(AOMFont.section)
            HStack {
                TextField("City name, e.g. Seoul or 부산", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit(search)
                Button("Search", action: search).disabled(query.trimmingCharacters(in: .whitespaces).count < 2 || searching)
            }
            if let problem { Text(problem).font(AOMFont.callout).foregroundStyle(AOMColor.warningText) }
            List(results) { city in
                Button {
                    weather.choose(city)
                    AOMToolWindows.shared.close("weather.city")
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(city.label)
                        Text("\(city.timezone) · \(String(format: "%.2f, %.2f", city.latitude, city.longitude))")
                            .font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Use \(city.label)")
            }
            .overlay { if searching { ProgressView() } else if results.isEmpty { Text(problem == nil ? "Search for your city" : "").foregroundStyle(AOMColor.textSecondary) } }
            Text("No location permission is used: only the name you type goes to Open-Meteo, and then the chosen city's coordinates.")
                .font(AOMFont.caption).foregroundStyle(AOMColor.textTertiary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(AOMSpace.x4)
        .onAppear { focused = true }
    }

    private func search() {
        let name = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.count >= 2 else { return }
        ticket += 1
        let mine = ticket
        searching = true
        problem = nil
        let provider = weather.provider
        Task { @MainActor in
            let found: Result<[WeatherCity], Error> = await { do { return .success(try await provider.search(name)) } catch { return .failure(error) } }()
            guard mine == ticket else { return }
            searching = false
            switch found {
            case .success(let cities):
                results = cities
                if cities.isEmpty { problem = "No city called “\(name)”" }
            case .failure(let error):
                results = []
                problem = (error as? WeatherError)?.message ?? error.localizedDescription
            }
        }
    }
}


/// 7.9: the weather card in the menu — a weather app's hierarchy in a menu's
/// width: city and condition, the temperature large with today's range,
/// six details (humidity, wind, UV, rain, sunrise, sunset), the next eight
/// hours and the week with range bars on one scale. Tight spacing, every row
/// earns its place; nothing is drawn for data the provider left out.
struct WeatherMenuCard: View {
    static let width: CGFloat = 360

    let city: WeatherCity?
    let reading: WeatherReading?
    let problem: WeatherError?

    private var timeZone: TimeZone { city.flatMap { TimeZone(identifier: $0.timezone) } ?? .current }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let reading {
                hero(reading)
                details(reading)
                if let hours = reading.hours, hours.count > 1 { hourly(hours) }
                if let days = reading.days, days.count > 1 { weekly(days, now: reading) }
            } else {
                Text(city == nil ? "Choose a city below to see the weather." : "No reading yet — Refresh when you're online.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            }
            footer
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .frame(width: Self.width, alignment: .topLeading)
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(city?.name ?? "Weather").font(.system(size: 14, weight: .semibold)).lineLimit(1)
            if let admin = city?.country, !admin.isEmpty {
                Text(admin).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if let reading {
                Text(reading.fetchedAt.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                    .help("Updated")
            }
        }
    }

    private func hero(_ reading: WeatherReading) -> some View {
        HStack(alignment: .center, spacing: 12) {
            WeatherGlyph(code: reading.code, isDay: reading.isDay, size: 34)
                .frame(width: 44)
            Text("\(Int(reading.temperature.rounded()))°")
                .font(.system(size: 42, weight: .semibold, design: .rounded).monospacedDigit())
                .lineLimit(1)
            VStack(alignment: .leading, spacing: 2) {
                Text(MenuBarWeather.describe(code: reading.code)).font(.system(size: 13, weight: .semibold))
                HStack(spacing: 8) {
                    if let high = reading.high { Text("↑ \(Int(high.rounded()))°") }
                    if let low = reading.low { Text("↓ \(Int(low.rounded()))°") }
                    if let feels = reading.feelsLike { Text("Feels \(Int(feels.rounded()))°").foregroundStyle(.secondary) }
                }
                .font(.system(size: 11.5, weight: .medium).monospacedDigit())
            }
            Spacer(minLength: 0)
        }
    }

    /// Gemini 7.9: four wider chips (2 × 2) and one line for the sun, so
    /// "104 km/h NNW" or "11 · Extreme" fit at a readable size; plain stacks,
    /// not a lazy grid, so the menu item measures its height right.
    private func details(_ reading: WeatherReading) -> some View {
        var chips: [(String, String, String)] = []
        if let humidity = reading.humidity { chips.append(("humidity.fill", "\(humidity)%", "Humidity")) }
        if let wind = reading.windSpeed {
            let unit = reading.unit == .fahrenheit ? "mph" : "km/h"
            let direction = reading.windDirection.map { " " + MenuBarWeather.compass($0) } ?? ""
            chips.append(("wind", "\(Int(wind.rounded())) \(unit)\(direction)", "Wind"))
        }
        if let uv = reading.uvIndex { chips.append(("sun.max.fill", "\(Int(uv.rounded())) · \(MenuBarWeather.uvBand(uv))", "UV index")) }
        if let rain = reading.rainChance { chips.append(("umbrella.fill", "\(rain)%", "Rain today")) }
        let rows = stride(from: 0, to: chips.count, by: 2).map { Array(chips[$0..<min($0 + 2, chips.count)]) }
        let sunrise = reading.sunrise.flatMap(clock), sunset = reading.sunset.flatMap(clock)
        return VStack(spacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 6) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, chip in chipView(chip) }
                    if row.count == 1 { Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
                }
            }
            if sunrise != nil || sunset != nil {
                HStack(spacing: 14) {
                    if let sunrise { Label { Text("Sunrise \(sunrise)") } icon: { Image(systemName: "sunrise.fill").symbolRenderingMode(.multicolor) } }
                    if let sunset { Label { Text("Sunset \(sunset)") } icon: { Image(systemName: "sunset.fill").symbolRenderingMode(.multicolor) } }
                    Spacer(minLength: 0)
                }
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .padding(.horizontal, 2)
            }
        }
    }

    private func chipView(_ chip: (String, String, String)) -> some View {
        HStack(spacing: 7) {
            Image(systemName: chip.0).symbolRenderingMode(.multicolor).font(.system(size: 13)).frame(width: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(chip.1).font(.system(size: 12.5, weight: .semibold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.85)
                Text(chip.2).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .weatherWell(radius: 8)
        .accessibilityElement(children: .combine)
    }

    private func hourly(_ hours: [WeatherHour]) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(hours.prefix(8).enumerated()), id: \.offset) { index, hour in
                VStack(spacing: 3) {
                    // Now is the reading itself, so it matches the big number (Gemini 7.9).
                    let now = index == 0 ? reading : nil
                    Text(index == 0 ? "Now" : hourLabel(hour.time)).font(.system(size: 10, weight: index == 0 ? .semibold : .regular))
                        .foregroundStyle(index == 0 ? .primary : .secondary).lineLimit(1).minimumScaleFactor(0.8)
                    WeatherGlyph(code: now?.code ?? hour.code, isDay: now?.isDay ?? hour.isDay, size: 13).frame(height: 16)
                    Text("\(Int((now?.temperature ?? hour.temperature).rounded()))°").font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                    Text(hour.rain.map { $0 >= 20 ? "\($0)%" : " " } ?? " ")
                        .font(.system(size: 9, weight: .medium).monospacedDigit()).foregroundStyle(Color.blue)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.vertical, 6)
        .weatherWell(radius: 8)
    }

    private func weekly(_ days: [WeatherDay], now: WeatherReading) -> some View {
        let lowest = days.map(\.low).min() ?? 0, highest = days.map(\.high).max() ?? 1
        return VStack(spacing: 2) {
            ForEach(Array(days.prefix(7).enumerated()), id: \.offset) { index, day in
                HStack(spacing: 6) {
                    Text(index == 0 ? "Today" : dayLabel(day.date)).font(.system(size: 11.5, weight: index == 0 ? .semibold : .regular))
                        .frame(width: 46, alignment: .leading).lineLimit(1)
                    WeatherGlyph(code: day.code, isDay: true, size: 12).frame(width: 20)
                    Text(day.rain.map { $0 >= 20 ? "\($0)%" : "" } ?? "")
                        .font(.system(size: 9.5, weight: .medium).monospacedDigit()).foregroundStyle(Color.blue)
                        .frame(width: 28, alignment: .leading)
                    Text("\(Int(day.low.rounded()))°").font(.system(size: 11.5).monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 30, alignment: .trailing)
                    WeatherRangeBar(low: day.low, high: day.high, lowest: lowest, highest: highest,
                                    current: index == 0 ? now.temperature : nil, fahrenheit: now.unit == .fahrenheit)
                        .frame(height: 5)
                    Text("\(Int(day.high.rounded()))°").font(.system(size: 11.5, weight: .medium).monospacedDigit())
                        .frame(width: 30, alignment: .trailing)
                }
                .frame(height: 20)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .weatherWell(radius: 8)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if let problem {
                Label(problem.message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).lineLimit(1)
            } else if let reading, Date().timeIntervalSince(reading.fetchedAt) > MenuBarWeather.maxAge {
                Text("Last saved reading").foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Text("Open-Meteo · CC BY 4.0").foregroundStyle(.tertiary)
        }
        .font(.system(size: 9.5))
    }

    // MARK: Times in the city's own zone

    private func parse(_ text: String, format: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter.date(from: text)
    }

    private func clock(_ text: String) -> String? {
        guard let date = parse(text, format: "yyyy-MM-dd'T'HH:mm") else { return nil }
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        return formatter.string(from: date)
    }

    private func hourLabel(_ text: String) -> String {
        guard let date = parse(text, format: "yyyy-MM-dd'T'HH:mm") else { return String(text.suffix(5).prefix(2)) }
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("j")
        return formatter.string(from: date)
    }

    private func dayLabel(_ text: String) -> String {
        guard let date = parse(text, format: "yyyy-MM-dd") else { return text }
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("EEE")
        return formatter.string(from: date)
    }
}

/// A day's range on the week's scale, cool to warm, with now as a dot.
struct WeatherRangeBar: View {
    let low: Double
    let high: Double
    let lowest: Double
    let highest: Double
    var current: Double?
    var fahrenheit = false

    var body: some View {
        GeometryReader { geometry in
            let span = max(1, highest - lowest)
            let start = CGFloat((low - lowest) / span) * geometry.size.width
            let end = CGFloat((high - lowest) / span) * geometry.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule()
                    .fill(LinearGradient(colors: [Self.color(celsius(low)), Self.color(celsius(high))], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(5, end - start))
                    .offset(x: start)
                if let current {
                    Circle().fill(Color.white).overlay(Circle().strokeBorder(Color.black.opacity(0.4), lineWidth: 0.75))
                        .frame(width: 6, height: 6)
                        .offset(x: min(max(0, CGFloat((current - lowest) / span) * geometry.size.width - 3), geometry.size.width - 6))
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func celsius(_ value: Double) -> Double { fahrenheit ? (value - 32) * 5 / 9 : value }

    /// Blue below freezing through green and yellow to orange-red in heat (°C scale).
    static func color(_ celsius: Double) -> Color {
        switch celsius {
        case ..<0: return Color(red: 0.36, green: 0.62, blue: 0.98)
        case ..<10: return Color(red: 0.33, green: 0.80, blue: 0.85)
        case ..<18: return Color(red: 0.45, green: 0.82, blue: 0.45)
        case ..<25: return Color(red: 0.98, green: 0.80, blue: 0.25)
        default: return Color(red: 0.98, green: 0.47, blue: 0.22)
        }
    }
}

private struct WeatherWell: ViewModifier {
    let radius: CGFloat
    @Environment(\.colorScheme) private var scheme

    /// A quiet fill, with a hairline in light mode where the fill alone
    /// disappears on white (Gemini 7.9).
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(Color.primary.opacity(scheme == .dark ? 0.07 : 0.045), in: shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(scheme == .dark ? 0.06 : 0.09), lineWidth: 0.5))
    }
}

extension View {
    fileprivate func weatherWell(radius: CGFloat) -> some View { modifier(WeatherWell(radius: radius)) }
}

/// A weather symbol that reads in both modes: Apple's multicolour symbols in
/// dark mode; in light mode their white clouds vanish on white, so each kind
/// of weather gets its own tint (sun orange, cloud grey, rain blue …).
struct WeatherGlyph: View {
    let code: Int
    let isDay: Bool
    var size: CGFloat = 13
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let symbol = Image(systemName: MenuBarWeather.colorSymbol(code: code, isDay: isDay)).font(.system(size: size))
        if scheme == .dark {
            symbol.symbolRenderingMode(.multicolor)
        } else {
            symbol.symbolRenderingMode(.hierarchical).foregroundStyle(Self.tint(code: code, isDay: isDay))
        }
    }

    static func tint(code: Int, isDay: Bool) -> Color {
        switch code {
        case 0, 1: return isDay ? Color.orange : Color.indigo
        case 2: return isDay ? Color(red: 0.85, green: 0.55, blue: 0.15) : Color.indigo
        case 3, 45, 48: return Color.gray
        case 51...67, 80...82: return Color.blue
        case 71...77, 85, 86: return Color.cyan
        case 95...99: return Color.purple
        default: return Color.secondary
        }
    }
}
