import SwiftUI

/// The Weather card in System Tools › This Mac (opt-in). Off, it isn't drawn;
/// the section title's Weather button turns it on by choosing a place.
struct WeatherCard: View {
    @ObservedObject var model: WeatherCardModel
    @State private var choosing = false

    var body: some View {
        VStack(alignment: .leading, spacing: AOMSpace.x1) {
            HStack(spacing: AOMSpace.x1) {
                Label(model.place?.name ?? "Weather", systemImage: "location")
                    .font(AOMFont.caption)
                    .foregroundStyle(AOMColor.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: AOMSpace.x1)
                if model.loading { ProgressView().controlSize(.mini) }
                Menu {
                    Button("Refresh") { model.refresh() }.disabled(model.loading)
                    Button("Change Place…") { choosing = true }
                    Divider()
                    Button("Turn Off Weather") { model.setOn(false) }
                } label: {
                    Image(systemName: "ellipsis.circle").imageScale(.medium)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Weather options")
                .accessibilityLabel("Weather options")
            }
            if let forecast = model.forecast {
                HStack(alignment: .firstTextBaseline, spacing: AOMSpace.x2) {
                    Image(systemName: OpenMeteo.symbol(forecast.code, isDay: forecast.isDay))
                        .symbolRenderingMode(.multicolor)
                        .font(AOMFont.title)
                        .accessibilityHidden(true)
                    Text(Self.temperature(forecast.temperature))
                        .font(AOMFont.metricLarge)
                        .foregroundStyle(AOMColor.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                Text(detail(forecast))
                    .font(AOMFont.callout)
                    .foregroundStyle(AOMColor.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: AOMSpace.x2) {
                    ForEach(forecast.days.dropFirst().prefix(3)) { day in
                        HStack(spacing: AOMSpace.x0_5 + 1) {
                            Text(Self.weekday(day.date, zone: forecast.timezone))
                                .foregroundStyle(AOMColor.textSecondary)
                            Image(systemName: OpenMeteo.symbol(day.code))
                                .symbolRenderingMode(.multicolor)
                                .imageScale(.small)
                            Text("\(Int(day.high.rounded()))°")
                                .foregroundStyle(AOMColor.text)
                        }
                        .font(AOMFont.caption.monospacedDigit())
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(Self.weekday(day.date, zone: forecast.timezone)): \(OpenMeteo.condition(day.code)), high \(Self.temperature(day.high))")
                    }
                }
            } else if let error = model.error {
                Text(error).font(AOMFont.callout).foregroundStyle(AOMColor.warningText).lineLimit(2)
                Button("Try Again") { model.refresh() }.controlSize(.small)
            } else {
                Text("…").font(AOMFont.metricLarge).foregroundStyle(AOMColor.textSecondary)
                Text("Reading the forecast").font(AOMFont.callout).foregroundStyle(AOMColor.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .aomCard(padding: AOMSpace.cardPadding)
        .help(model.updated.map { "Open-Meteo forecast for \(model.place?.title ?? "") · updated \(AOMRelativeTime.string($0).lowercased()) · refreshes every 30 minutes while shown" }
              ?? "Open-Meteo forecast")
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilitySummary)
        .popover(isPresented: $choosing, arrowEdge: .bottom) {
            WeatherPlacePicker(model: model) { choosing = false }
        }
        .onAppear { model.viewerAppeared() }
        .onDisappear { model.viewerDisappeared() }
    }

    private func detail(_ forecast: OpenMeteo.Forecast) -> String {
        var parts = [OpenMeteo.condition(forecast.code)]
        if let today = forecast.days.first {
            parts.append("H \(Int(today.high.rounded()))° L \(Int(today.low.rounded()))°")
            if let chance = today.precipitationChance, chance >= 20 { parts.append("\(chance)% rain") }
        }
        return parts.joined(separator: " · ")
    }

    private var accessibilitySummary: String {
        guard let forecast = model.forecast else { return "Weather, \(model.place?.name ?? "no place chosen")" }
        return "Weather in \(model.place?.name ?? ""), \(Self.temperature(forecast.temperature)), \(detail(forecast))"
    }

    /// Open-Meteo answers in °C; MeasurementFormatter shows the person's unit.
    static func temperature(_ celsius: Double) -> String {
        let formatter = MeasurementFormatter()
        formatter.unitStyle = .short
        formatter.numberFormatter.maximumFractionDigits = 0
        return formatter.string(from: Measurement(value: celsius, unit: UnitTemperature.celsius))
    }

    static func weekday(_ date: Date, zone: TimeZone?) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = zone ?? .current
        formatter.setLocalizedDateFormatFromTemplate("EEE")
        return formatter.string(from: date)
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
