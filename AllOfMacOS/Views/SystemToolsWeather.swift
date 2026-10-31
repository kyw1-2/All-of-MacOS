import SwiftUI

/// The Weather card in System Tools › This Mac (opt-in), a full-width strip
/// under the gauges so the grid above keeps its even rows: now on the left
/// (glyph, temperature, conditions), then feels-like, humidity and wind,
/// then the next three days. Off, it isn't drawn; the section title's Show
/// Weather turns it on by choosing a place.
struct WeatherCard: View {
    @ObservedObject var model: WeatherCardModel
    @State private var choosing = false

    var body: some View {
        HStack(alignment: .center, spacing: AOMSpace.x6) {
            if let forecast = model.forecast {
                now(forecast)
                details(forecast)
                Spacer(minLength: AOMSpace.x2)
                days(forecast)
            } else if let error = model.error {
                VStack(alignment: .leading, spacing: AOMSpace.x1) {
                    placeLabel
                    Text(error).font(AOMFont.callout).foregroundStyle(AOMColor.warningText).lineLimit(2)
                }
                Spacer(minLength: AOMSpace.x2)
                Button("Try Again") { model.refresh() }
            } else {
                VStack(alignment: .leading, spacing: AOMSpace.x1) {
                    placeLabel
                    Text("Reading the forecast…").font(AOMFont.callout).foregroundStyle(AOMColor.textSecondary)
                }
                Spacer(minLength: AOMSpace.x2)
            }
            optionsMenu
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .aomCard(padding: AOMSpace.cardPadding)
        .help(model.updated.map { "Open-Meteo forecast for \(model.place?.title ?? "") · updated \(AOMRelativeTime.string($0).lowercased()) · refreshes every 30 minutes while this page shows it" }
              ?? "Open-Meteo forecast")
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilitySummary)
        .popover(isPresented: $choosing, arrowEdge: .bottom) {
            WeatherPlacePicker(model: model) { choosing = false }
        }
        .onAppear { model.viewerAppeared() }
        .onDisappear { model.viewerDisappeared() }
    }

    private var placeLabel: some View {
        Label(model.place?.title ?? "Weather", systemImage: "location")
            .font(AOMFont.caption)
            .foregroundStyle(AOMColor.textSecondary)
            .lineLimit(1)
    }

    private func now(_ forecast: OpenMeteo.Forecast) -> some View {
        HStack(alignment: .center, spacing: AOMSpace.x3) {
            WeatherGlyph(code: forecast.code, isDay: forecast.isDay)
                .font(AOMFont.display)
                .frame(minWidth: AOMIcon.hudGlyph)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: AOMSpace.x0_5) {
                placeLabel
                Text(Self.temperature(forecast.temperature))
                    .font(AOMFont.metricLarge)
                    .foregroundStyle(AOMColor.text)
                    .lineLimit(1)
                Text(conditions(forecast))
                    .font(AOMFont.callout)
                    .foregroundStyle(AOMColor.textSecondary)
                    .lineLimit(1)
            }
        }
        .layoutPriority(1)
    }

    private func details(_ forecast: OpenMeteo.Forecast) -> some View {
        VStack(alignment: .leading, spacing: AOMSpace.x1) {
            if let feels = forecast.feelsLike { fact("Feels like", Self.temperature(feels)) }
            if let humidity = forecast.humidity { fact("Humidity", "\(humidity)%") }
            if let wind = forecast.windSpeed { fact("Wind", Self.speed(wind)) }
        }
        .font(AOMFont.callout)
    }

    private func fact(_ title: String, _ value: String) -> some View {
        HStack(spacing: AOMSpace.x2) {
            Text(title).foregroundStyle(AOMColor.textSecondary)
            Text(value).monospacedDigit().foregroundStyle(AOMColor.text)
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }

    private func days(_ forecast: OpenMeteo.Forecast) -> some View {
        HStack(spacing: AOMSpace.x5) {
            ForEach(forecast.days.dropFirst().prefix(3)) { day in
                VStack(spacing: AOMSpace.x1) {
                    Text(Self.weekday(day.date, zone: forecast.timezone))
                        .font(AOMFont.caption)
                        .foregroundStyle(AOMColor.textSecondary)
                    WeatherGlyph(code: day.code, isDay: true)
                        .font(AOMFont.title)
                        .frame(height: AOMIcon.tileBadge)
                    Text("\(Int(day.high.rounded()))° \(Int(day.low.rounded()))°")
                        .font(AOMFont.callout.monospacedDigit())
                        .foregroundStyle(AOMColor.text)
                }
                .fixedSize()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(Self.weekday(day.date, zone: forecast.timezone)): \(OpenMeteo.condition(day.code)), high \(Self.temperature(day.high)), low \(Self.temperature(day.low))")
            }
        }
    }

    private var optionsMenu: some View {
        Menu {
            Button("Refresh") { model.refresh() }.disabled(model.loading)
            Button("Change Place…") { choosing = true }
            Divider()
            Button("Turn Off Weather") { model.setOn(false) }
        } label: {
            if model.loading {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "ellipsis.circle").imageScale(.large).foregroundStyle(AOMColor.textSecondary)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Refresh, change the place or turn the weather off")
        .accessibilityLabel("Weather options")
    }

    private func conditions(_ forecast: OpenMeteo.Forecast) -> String {
        var parts = [OpenMeteo.condition(forecast.code)]
        if let today = forecast.days.first {
            parts.append("H \(Int(today.high.rounded()))° L \(Int(today.low.rounded()))°")
            if let chance = today.precipitationChance, chance >= 20 { parts.append("\(chance)% rain") }
        }
        return parts.joined(separator: " · ")
    }

    private var accessibilitySummary: String {
        guard let forecast = model.forecast else { return "Weather, \(model.place?.name ?? "no place chosen")" }
        return "Weather in \(model.place?.name ?? ""), \(Self.temperature(forecast.temperature)), \(conditions(forecast))"
    }

    /// Open-Meteo answers in °C and km/h; MeasurementFormatter shows the
    /// person's own units.
    static func temperature(_ celsius: Double) -> String {
        let formatter = MeasurementFormatter()
        formatter.unitStyle = .short
        formatter.numberFormatter.maximumFractionDigits = 0
        return formatter.string(from: Measurement(value: celsius, unit: UnitTemperature.celsius))
    }

    static func speed(_ kilometresPerHour: Double) -> String {
        let formatter = MeasurementFormatter()
        formatter.unitStyle = .medium
        formatter.numberFormatter.maximumFractionDigits = 0
        return formatter.string(from: Measurement(value: kilometresPerHour, unit: UnitSpeed.kilometersPerHour))
    }

    static func weekday(_ date: Date, zone: TimeZone?) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = zone ?? .current
        formatter.setLocalizedDateFormatFromTemplate("EEE")
        return formatter.string(from: date)
    }
}

/// A weather glyph that reads on the light card too: clouds in the
/// secondary label colour (multicolour clouds are white), the sun and
/// lightning yellow, rain and snow blue.
struct WeatherGlyph: View {
    let code: Int
    var isDay = true

    var body: some View {
        let name = OpenMeteo.symbol(code, isDay: isDay)
        let cloud = AOMColor.textSecondary
        switch name {
        case "sun.max.fill":
            Image(systemName: name).foregroundStyle(Color.yellow)
        case "moon.stars.fill":
            Image(systemName: name).symbolRenderingMode(.palette).foregroundStyle(Color.yellow, cloud)
        case "cloud.sun.fill", "cloud.moon.fill":
            Image(systemName: name).symbolRenderingMode(.palette).foregroundStyle(cloud, Color.yellow)
        case "cloud.bolt.rain.fill":
            Image(systemName: name).symbolRenderingMode(.palette).foregroundStyle(cloud, Color.yellow, Color.blue)
        case "cloud.drizzle.fill", "cloud.rain.fill", "cloud.heavyrain.fill", "cloud.sleet.fill", "cloud.hail.fill":
            Image(systemName: name).symbolRenderingMode(.palette).foregroundStyle(cloud, Color.blue)
        case "cloud.snow.fill":
            Image(systemName: name).symbolRenderingMode(.palette).foregroundStyle(cloud, Color.cyan)
        default:
            Image(systemName: name).foregroundStyle(cloud)
        }
    }
}

/// Type a city, pick it. The search asks Open-Meteo's geocoding API only
/// when Search is pressed (or Return), never while typing.
struct WeatherPlacePicker: View {
    @ObservedObject var model: WeatherCardModel
    let done: () -> Void
    @State private var text = ""
    @State private var results: [OpenMeteo.Place] = []
    @State private var searching = false
    @State private var message: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: AOMSpace.x3) {
            Text("Weather").font(AOMFont.headline)
            Text("Search for a city. AOM asks Open-Meteo for its forecast every 30 minutes while this page shows it; nothing else is sent.")
                .font(AOMFont.callout)
                .foregroundStyle(AOMColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: AOMSpace.x2) {
                TextField("City", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit(search)
                Button("Search", action: search)
                    .disabled(text.trimmingCharacters(in: .whitespaces).count < 2 || searching)
            }
            if searching {
                ProgressView().controlSize(.small)
            } else if let message {
                Text(message).font(AOMFont.callout).foregroundStyle(AOMColor.textSecondary)
            }
            if !results.isEmpty {
                List(results) { place in
                    Button {
                        model.choose(place)
                        done()
                    } label: {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(place.name).font(AOMFont.body)
                            Text(place.title).font(AOMFont.caption).foregroundStyle(AOMColor.textSecondary).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.bordered(alternatesRowBackgrounds: true))
                .frame(height: min(220, CGFloat(results.count) * 40 + 8))
            }
            HStack {
                Link("Weather data by Open-Meteo.com", destination: URL(string: "https://open-meteo.com/")!)
                    .font(AOMFont.caption)
                Spacer()
                if model.isOn { Button("Turn Off") { model.setOn(false); done() } }
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
            }
        }
        .padding(AOMSpace.x4)
        .frame(width: 360)
        .onAppear { focused = true }
    }

    private func search() {
        let query = text.trimmingCharacters(in: .whitespaces)
        guard query.count >= 2, !searching else { return }
        searching = true
        message = nil
        Task { @MainActor in
            do {
                results = try await model.search(query)
                message = results.isEmpty ? "No place called “\(query)”." : nil
            } catch {
                results = []
                message = "Couldn't search: \(error.localizedDescription)"
            }
            searching = false
        }
    }
}

extension WeatherCardModel {
    /// Isolated UI previews only (`--aom-preview-weather`): a sample place
    /// and forecast, no network.
    func loadPreviewSample() {
        guard PresetManager.isUIPreview, ProcessInfo.processInfo.arguments.contains("--aom-preview-weather") else { return }
        let seoul = OpenMeteo.Place(id: 1835848, name: "Seoul", latitude: 37.566, longitude: 126.9784,
                                    country: "South Korea", region: "Seoul", timezone: "Asia/Seoul")
        let calendar = Calendar(identifier: .gregorian)
        let today = calendar.startOfDay(for: Date())
        let days = (0..<4).map { offset in
            OpenMeteo.Day(date: calendar.date(byAdding: .day, value: offset, to: today) ?? today,
                          code: [3, 53, 3, 0][offset], high: [14.1, 9.8, 13.6, 15.2][offset],
                          low: [7.4, 6.4, 7.0, 6.1][offset], precipitationChance: [47, 91, 41, 5][offset])
        }
        let forecast = OpenMeteo.Forecast(temperature: 8.1, feelsLike: 5.4, humidity: 49, windSpeed: 1.8, code: 2, isDay: false,
                                          observed: Date(), timezone: TimeZone(identifier: "Asia/Seoul"), days: days)
        setPreview(place: seoul, forecast: forecast)
    }
}
