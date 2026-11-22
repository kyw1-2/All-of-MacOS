import AppKit
import XCTest
@testable import AllOfMacOS

/// 7.9: the Bartender-style menu bar layout, the Bar, and the weather card.
@MainActor
final class AOM79Tests: XCTestCase {
    private func item(_ name: String, x: CGFloat, id: String = "", owner: String = "com.example.app", pid: pid_t = 50) -> AOMMenuShelfItem {
        AOMMenuShelfItem(pid: pid, ownerBundleID: owner, ownerName: "App", title: name, axIdentifier: id, ordinal: 0, siblings: 1,
                         frame: CGRect(x: x, y: 0, width: 28, height: 24), axDescription: name)
    }

    // MARK: Lanes

    func testSectionsFollowAOMsDividersEvenWhenCollapsed() {
        let divider = CGRect(x: 1000, y: 0, width: 12, height: 24)
        let always = CGRect(x: 800, y: 0, width: 12, height: 24)
        XCTAssertEqual(MenuBarLayoutPolicy.section(of: CGRect(x: 1100, y: 0, width: 28, height: 24), divider: divider, always: always), .shown)
        XCTAssertEqual(MenuBarLayoutPolicy.section(of: CGRect(x: 900, y: 0, width: 28, height: 24), divider: divider, always: always), .hidden)
        XCTAssertEqual(MenuBarLayoutPolicy.section(of: CGRect(x: 700, y: 0, width: 28, height: 24), divider: divider, always: always), .alwaysHidden)
        XCTAssertEqual(MenuBarLayoutPolicy.section(of: CGRect(x: 900, y: 0, width: 28, height: 24), divider: divider, always: nil), .hidden)
        // Collapsed: the divider is 10,000 pt wide and ends where it always did.
        let collapsed = CGRect(x: 1012 - 10_000, y: 0, width: 10_000, height: 24)
        XCTAssertEqual(MenuBarLayoutPolicy.section(of: CGRect(x: 1100, y: 0, width: 28, height: 24), divider: collapsed, always: nil), .shown)
        XCTAssertEqual(MenuBarLayoutPolicy.section(of: CGRect(x: -4000, y: 0, width: 28, height: 24), divider: collapsed, always: nil), .hidden)
        XCTAssertEqual(MenuBarLayoutPolicy.section(of: nil, divider: divider, always: nil), .hidden)
        XCTAssertEqual(MenuBarLayoutPolicy.section(of: CGRect(x: 10, y: 0, width: 28, height: 24), divider: nil, always: nil), .shown,
                       "without the Hider everything is shown")
    }

    func testLanesReadLeftToRightAndSystemItemsAreLocked() {
        let own = pid_t(1)
        let items = [MenuBarLayoutItem(item: item("B", x: 300), section: .shown),
                     MenuBarLayoutItem(item: item("A", x: 100), section: .shown),
                     MenuBarLayoutItem(item: item("H", x: 50), section: .hidden)]
        XCTAssertEqual(MenuBarLayoutPolicy.lanes(items)[.shown]?.map(\.item.title), ["A", "B"])
        XCTAssertEqual(MenuBarLayoutPolicy.lanes(items)[.alwaysHidden]?.count, 0)
        let clock = item("Clock", x: 1, id: "com.apple.menuextra.clock", owner: "com.apple.MenuBarAgent")
        XCTAssertNotNil(MenuBarLayoutPolicy.lockedReason(clock, ownPID: own))
        XCTAssertNotNil(MenuBarLayoutPolicy.lockedReason(item("Menu Bar Hider divider", x: 1, pid: own), ownPID: own))
        XCTAssertTrue(MenuBarLayoutPolicy.isHiderControl(item("Show hidden menu bar items", x: 1, pid: own), ownPID: own))
        XCTAssertNil(MenuBarLayoutPolicy.lockedReason(item("Weather", x: 1, pid: own), ownPID: own), "AOM's own icons move like any other")
        XCTAssertNil(MenuBarLayoutPolicy.lockedReason(item("Dropbox", x: 1), ownPID: own))
    }

    func testDropPointsLandOnTheRightSideOfTheDivider() throws {
        let divider = CGRect(x: 1000, y: 4, width: 12, height: 24)
        let always = CGRect(x: 800, y: 4, width: 12, height: 24)
        XCTAssertGreaterThan(try XCTUnwrap(MenuBarLayoutPolicy.dropPoint(section: .shown, before: nil, divider: divider, always: always)).x, divider.maxX)
        XCTAssertLessThan(try XCTUnwrap(MenuBarLayoutPolicy.dropPoint(section: .hidden, before: nil, divider: divider, always: always)).x, divider.minX)
        XCTAssertLessThan(try XCTUnwrap(MenuBarLayoutPolicy.dropPoint(section: .alwaysHidden, before: nil, divider: divider, always: always)).x, always.minX)
        XCTAssertNil(MenuBarLayoutPolicy.dropPoint(section: .alwaysHidden, before: nil, divider: divider, always: nil))
        let neighbor = CGRect(x: 1200, y: 4, width: 28, height: 24)
        let before = try XCTUnwrap(MenuBarLayoutPolicy.dropPoint(section: .shown, before: neighbor, divider: divider, always: always))
        XCTAssertTrue(before.x > neighbor.minX && before.x < neighbor.midX, "over the neighbour's left half puts it to the left")
        XCTAssertEqual(before.y, neighbor.midY)
    }

    func testImageCacheKeysRoundTripThroughFileNames() {
        for key in ["com.apple.MenuBarAgent|ax:com.apple.menuextra.battery", "com.kakao|desc:카카오톡 새 메시지", "a/b+c|pos:3"] {
            let file = MenuBarLayoutModel.file(forKey: key)
            XCTAssertFalse(file.contains("/"))
            XCTAssertEqual(MenuBarLayoutModel.key(fromFile: file), key)
        }
    }

    func testSampleFillsEveryLaneWithLongNames() {
        let model = MenuBarLayoutModel.shared
        model.loadSample()
        let lanes = model.lanes
        XCTAssertGreaterThanOrEqual(model.items.count, 18)
        for section in MenuBarSection.allCases { XCTAssertFalse(lanes[section]?.isEmpty ?? true, section.title) }
        XCTAssertTrue(model.items.contains { $0.item.title.count > 15 }, "long names are part of the check")
        let hidden = model.items.first { $0.section == .hidden }!
        model.move(hidden.id, to: .shown)
        XCTAssertEqual(model.items.first { $0.id == hidden.id }?.section, .shown)
        let locked = model.items.first { $0.lockedReason != nil }!
        model.move(locked.id, to: .hidden)
        XCTAssertEqual(model.items.first { $0.id == locked.id }?.section, .shown, "locked items stay")
    }

    // MARK: Weather card

    func testForecastCarriesTheWholeCard() throws {
        let json = #"""
        {"current":{"temperature_2m":4.4,"apparent_temperature":1.1,"weather_code":0,"is_day":1,"relative_humidity_2m":56,
                    "wind_speed_10m":4.3,"wind_direction_10m":246,"uv_index":0.65},
         "hourly":{"time":["2026-11-22T16:00","2026-11-22T17:00"],"temperature_2m":[4.4,3.9],
                   "precipitation_probability":[0,30],"weather_code":[0,61],"is_day":[1,0]},
         "daily":{"time":["2026-11-22","2026-11-23"],"weather_code":[0,61],"temperature_2m_max":[9.1,7.4],
                  "temperature_2m_min":[-1.2,0.8],"precipitation_probability_max":[10,70],
                  "sunrise":["2026-11-22T07:18","2026-11-23T07:19"],"sunset":["2026-11-22T17:16","2026-11-23T17:16"]}}
        """#
        let city = WeatherCity(id: 1, name: "Seoul", timezone: "Asia/Seoul", latitude: 37.5, longitude: 127)
        let reading = try MenuBarWeather.parseForecast(Data(json.utf8), city: city, unit: .celsius, now: Date())
        XCTAssertEqual(reading.humidity, 56)
        XCTAssertEqual(reading.windDirection, 246)
        XCTAssertEqual(reading.sunrise, "2026-11-22T07:18")
        XCTAssertEqual(reading.hours?.count, 2)
        XCTAssertEqual(reading.hours?.last?.code, 61)
        XCTAssertEqual(reading.hours?.last?.isDay, false)
        XCTAssertEqual(reading.days?.map(\.rain), [10, 70])
        XCTAssertEqual(reading.high, 9.1)
        // An old cache without the new fields still decodes.
        let old = try JSONDecoder().decode(WeatherReading.self, from: Data(#"{"cityID":1,"temperature":3,"code":0,"isDay":true,"fetchedAt":0,"unit":"celsius"}"#.utf8))
        XCTAssertNil(old.days)
    }

    func testCompassAndUVBands() {
        XCTAssertEqual(MenuBarWeather.compass(0), "N")
        XCTAssertEqual(MenuBarWeather.compass(246), "SW")
        XCTAssertEqual(MenuBarWeather.compass(350), "N")
        XCTAssertEqual(MenuBarWeather.compass(-90), "W")
        XCTAssertEqual(MenuBarWeather.uvBand(0.6), "Low")
        XCTAssertEqual(MenuBarWeather.uvBand(3.1), "Moderate")
        XCTAssertEqual(MenuBarWeather.uvBand(11), "Extreme")
        XCTAssertEqual(MenuBarWeather.colorSymbol(code: 61, isDay: true), "cloud.rain.fill")
    }

    func testRevealModeDefaultsToTheMenuBar() {
        let saved = UserDefaults.standard.object(forKey: MenuBarHider.revealModeKey)
        defer { UserDefaults.standard.set(saved, forKey: MenuBarHider.revealModeKey) }
        UserDefaults.standard.removeObject(forKey: MenuBarHider.revealModeKey)
        XCTAssertEqual(MenuBarHider.revealMode, .menuBar)
        MenuBarHider.revealMode = .bar
        XCTAssertEqual(MenuBarHider.revealMode, .bar)
    }
}
