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
    let temperature: Double
    /// Nil when the provider left it out: the actual temperature stands in.
    var feelsLike: Double?
    let code: Int
    let isDay: Bool
    var low: Double?
    var high: Double?
    var rainChance: Int?
    let fetchedAt: Date
    let unit: MenuBarWeather.Unit
    /// The next hours' temperatures and rain chances, from the same request (Gemini 7.6 idea).
    var nextHours: [Double]? = nil
    var nextRain: [Int]? = nil
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
                                .init(name: "current", value: "temperature_2m,apparent_temperature,weather_code,is_day"),
                                .init(name: "daily", value: "temperature_2m_max,temperature_2m_min,precipitation_probability_max"),
                                .init(name: "hourly", value: "temperature_2m,precipitation_probability"), .init(name: "forecast_hours", value: "6"),
                                .init(name: "forecast_days", value: "1"), .init(name: "timezone", value: city.timezone),
                                .init(name: "temperature_unit", value: unit == .fahrenheit ? "fahrenheit" : "celsius")]
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
            default: throw WeatherError.failed(error.localizedDescription)
            }
        }
    }
}

@MainActor
final class MenuBarWeather: NSObject, ObservableObject, NSMenuDelegate {
    static let shared = MenuBarWeather()

    enum Display: String, CaseIterable, Codable { case temperature, feelsLike, iconOnly }
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
    @Published var unit: Unit {
        didSet {
            UserDefaults.standard.set(unit.rawValue, forKey: Self.unitKey)
            if oldValue != unit { refresh(force: true) }
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
        display = Display(rawValue: defaults.string(forKey: Self.displayKey) ?? "") ?? .temperature
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
            catch is CancellationError { return }
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
        return WeatherReading(cityID: city.id, temperature: temperature,
                              feelsLike: (current["apparent_temperature"] as? NSNumber)?.doubleValue,
                              code: (current["weather_code"] as? NSNumber)?.intValue ?? 0,
                              isDay: ((current["is_day"] as? NSNumber)?.intValue ?? 1) == 1,
                              low: first("temperature_2m_min"), high: first("temperature_2m_max"),
                              rainChance: first("precipitation_probability_max").map { Int($0.rounded()) },
                              fetchedAt: now, unit: unit, nextHours: hours?.isEmpty == false ? hours : nil, nextRain: rain?.isEmpty == false ? rain : nil)
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
        let current = reading.flatMap { $0.cityID == city?.id ? $0 : nil }
        let image = NSImage(systemSymbolName: current.map { Self.symbol(code: $0.code, isDay: $0.isDay) } ?? "cloud.sun",
                            accessibilityDescription: nil)
        image?.isTemplate = true
        button.image = image
        button.imagePosition = display == .iconOnly ? .imageOnly : .imageLeading
        button.title = city == nil ? "" : Self.title(current, display: display)
        button.appearsDisabled = current == nil || !Self.isFresh(current, city: city, unit: unit, now: Date().addingTimeInterval(-Self.maxAge * 3))
        button.setAccessibilityLabel(Self.spoken(city: city, reading: current, problem: problem))
        button.toolTip = Self.spoken(city: city, reading: current, problem: problem)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func info(_ text: String) {
            let entry = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            entry.isEnabled = false
            menu.addItem(entry)
        }
        if let city {
            info(city.label)
            if let reading, reading.cityID == city.id {
                let actual = Int(reading.temperature.rounded()), unitMark = reading.unit == .fahrenheit ? "°F" : "°C"
                let feels = reading.feelsLike.map { " · feels like \(Int($0.rounded()))\(unitMark)" } ?? " · feels like: not given (actual shown)"
                info("\(Self.describe(code: reading.code)), \(actual)\(unitMark)\(feels)")
                if let low = reading.low, let high = reading.high {
                    info("Today \(Int(low.rounded()))° – \(Int(high.rounded()))°" + (reading.rainChance.map { " · rain \($0)%" } ?? ""))
                }
                if let trend = Self.trend(reading) { info(trend) }
                info("Updated \(reading.fetchedAt.formatted(date: .omitted, time: .shortened))" + (problem.map { " · now: \($0.message)" } ?? ""))
            } else {
                info(problem.map { "No weather: \($0.message)" } ?? "No weather yet")
            }
        } else {
            info("Choose a city to see its weather")
        }
        menu.addItem(.separator())
        let show = NSMenuItem(title: "Show", action: nil, keyEquivalent: "")
        let showMenu = NSMenu()
        for (choice, title) in [(Display.temperature, "Temperature"), (.feelsLike, "Feels Like"), (.iconOnly, "Icon Only")] {
            let entry = NSMenuItem(title: title, action: #selector(pickDisplay(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = choice.rawValue
            entry.state = display == choice ? .on : .off
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
        let off = NSMenuItem(title: "Turn Off Weather", action: #selector(turnOff), keyEquivalent: "")
        off.target = self
        menu.addItem(off)
        info("Weather data by Open-Meteo.com (CC BY 4.0)")
    }

    @objc private func pickDisplay(_ sender: NSMenuItem) { display = Display(rawValue: sender.representedObject as? String ?? "") ?? display }
    @objc private func pickUnit(_ sender: NSMenuItem) { unit = Unit(rawValue: sender.representedObject as? String ?? "") ?? unit }
    @objc private func refreshNow() { waitUntil = waitUntil.flatMap { $0 > Date() ? $0 : nil }; refresh(force: true) }
    @objc private func chooseCity() { Self.openCityPicker() }
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
