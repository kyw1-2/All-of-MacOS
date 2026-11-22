import XCTest
@testable import AllOfMacOS

@MainActor
final class AOMMenuBarControlTests: XCTestCase {
    func testMenuBarPageIsDiscoverableWithoutChangingLegacyShortcuts() {
        XCTAssertEqual(AOMMainTab.menuBar.title, "Menu Bar")
        XCTAssertEqual(AOMMainTab.menuBar.sidebarSymbol, "menubar.rectangle")
        XCTAssertTrue(AOMFeatureGroup.system.tabs.contains(.menuBar))
        XCTAssertTrue(AOMFeatureSearch.matches(.menuBar, query: "weather"))
        XCTAssertTrue(AOMFeatureSearch.matches(.menuBar, query: "메뉴바"))
        XCTAssertNil(AOMMainTab.menuBar.shortcutKey)
        XCTAssertEqual(AOMMainTab.home.shortcutKey?.character, "1")
    }

    func testWeatherStatusKeepsARealReadingAndItsAccessibilityDetail() {
        let city = WeatherCity(id: 1835848, name: "Seoul", admin: "Seoul", country: "South Korea",
                               timezone: "Asia/Seoul", latitude: 37.56, longitude: 126.97)
        let reading = WeatherReading(cityID: city.id, temperature: 18.4, feelsLike: 17.1,
                                     code: 2, isDay: true, low: 13, high: 20, rainChance: 40,
                                     fetchedAt: Date(), unit: .celsius, nextHours: [18, 17, 16], nextRain: [0, 10, 20])
        XCTAssertEqual(MenuBarWeather.title(reading, display: .temperature), "18°")
        XCTAssertEqual(MenuBarWeather.title(reading, display: .feelsLike), "17°")
        XCTAssertEqual(MenuBarWeather.title(reading, display: .iconOnly), "")
        XCTAssertTrue(MenuBarWeather.spoken(city: city, reading: reading, problem: nil).contains("feels like 17"))
        XCTAssertEqual(MenuBarWeather.symbol(code: reading.code, isDay: true), "cloud.sun")
    }

    func testHiderNeverCreatesForeignItems() {
        XCTAssertEqual(MenuBarHider.lengths(collapsed: false, showsAll: false, hasAlways: false).divider,
                       MenuBarHider.dividerLength)
        XCTAssertEqual(MenuBarHider.lengths(collapsed: true, showsAll: false, hasAlways: false).divider,
                       MenuBarHider.collapsedLength)
        XCTAssertTrue(MenuBarHider.canCollapse(dividerMinX: 100, toggleMinX: 120))
        XCTAssertFalse(MenuBarHider.canCollapse(dividerMinX: 150, toggleMinX: 120))
    }
}
