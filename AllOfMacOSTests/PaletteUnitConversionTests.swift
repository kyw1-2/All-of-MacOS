import XCTest
@testable import AllOfMacOS

/// Unit conversions in the calculator: length, mass, temperature, area
/// (with 평), volume, speed, data sizes (KB vs KiB) and rates, time, screen
/// points at 2×, angles, compound quantities and the "in" ambiguity.
final class PaletteUnitConversionTests: XCTestCase {
    private func answer(_ text: String) -> String? {
        AOMCalculator.evaluate(text, locale: Locale(identifier: "en_US"))?.display
    }

    func testLength() {
        XCTAssertEqual(answer("10 km in mi"), "6.21371 mi")
        XCTAssertEqual(answer("1 mi to km"), "1.60934 km")
        XCTAssertEqual(answer("10 cm in in"), "3.93701 in", "the second “in” is the inch")
        XCTAssertEqual(answer("10 in to cm"), "25.4 cm", "“in” before “to” is the inch")
        XCTAssertEqual(answer("10 in in cm"), "25.4 cm")
        XCTAssertEqual(answer("6 feet in meters"), "1.8288 m")
        XCTAssertEqual(answer("1 nautical mile in km"), "1.852 km")
        XCTAssertEqual(answer("1 KM in M"), "1000 m", "symbols without meaningful case match in any case")
    }

    func testMass() {
        XCTAssertEqual(answer("70 kg in lb"), "154.324 lb")
        XCTAssertEqual(answer("1 lb in g"), "453.592 g")
        XCTAssertEqual(answer("16 oz to lb"), "1 lb")
        XCTAssertEqual(answer("10 돈 in g"), "37.5 g", "the Korean gold unit")
        XCTAssertEqual(answer("1 근 in g"), "600 g")
    }

    func testTemperature() {
        XCTAssertEqual(answer("100 °F in °C"), "37.7778 °C")
        XCTAssertEqual(answer("0 C to F"), "32 °F")
        XCTAssertEqual(answer("300 K in C"), "26.85 °C")
        XCTAssertEqual(answer("-40 °C in °F"), "-40 °F")
        XCTAssertEqual(answer("37.5 ℃"), "99.5 °F", "a lone temperature converts to the other scale")
        XCTAssertEqual(answer("20 °C + 9 °F"), "25 °C", "adding a temperature adds a difference")
    }

    func testAreaIncludingPyeong() {
        XCTAssertEqual(answer("30 평 in m2"), "99.1736 m²")
        XCTAssertEqual(answer("30평"), "99.1736 m²", "a lone 평 converts to square metres")
        XCTAssertEqual(answer("100 m² in 평"), "30.25 평")
        XCTAssertEqual(answer("84 m^2 in pyeong"), "25.41 평")
        XCTAssertEqual(answer("1 acre in m²"), "4046.86 m²")
        XCTAssertEqual(answer("1 ha in acres"), "2.47105 acre")
        XCTAssertEqual(answer("100 sq ft in m2"), "9.2903 m²")
        XCTAssertEqual(answer("3 m * 4 m"), "12 m²")
    }

    func testVolume() {
        XCTAssertEqual(answer("1 gal in L"), "3.78541 L")
        XCTAssertEqual(answer("500 mL in fl oz"), "16.907 fl oz")
        XCTAssertEqual(answer("2 cups in ml"), "473.176 mL")
        XCTAssertEqual(answer("1 m³ in L"), "1000 L")
        XCTAssertEqual(answer("1000 cm3 in L"), "1 L")
    }

    func testSpeed() {
        XCTAssertEqual(answer("100 km/h in mph"), "62.1371 mph")
        XCTAssertEqual(answer("10 m/s in km/h"), "36 km/h")
        XCTAssertEqual(answer("20 knots in km/h"), "37.04 km/h")
        XCTAssertEqual(answer("100 km / 2 h"), "50 km/h")
    }

    func testDataSizesDistinguishDecimalAndBinaryPrefixes() {
        XCTAssertEqual(answer("1 KiB in KB"), "1.024 KB")
        XCTAssertEqual(answer("1 GB in GiB"), "0.931323 GiB")
        XCTAssertEqual(answer("1 MiB in KB"), "1048.58 KB")
        XCTAssertEqual(answer("64 GB in GiB"), "59.6046 GiB")
        XCTAssertEqual(answer("1 TB in GB"), "1000 GB")
        XCTAssertEqual(answer("8 Mb in MB"), "1 MB", "“Mb” is a megabit")
        XCTAssertEqual(answer("8 mb in MB"), "8 MB", "lower-case “mb” means megabytes, as people write it")
        XCTAssertEqual(answer("1 GB"), "0.931323 GiB", "a lone size shows the other prefix family")
    }

    func testDataRates() {
        XCTAssertEqual(answer("500 Mbps in MB/s"), "62.5 MB/s")
        XCTAssertEqual(answer("1 Gbps in MB/s"), "125 MB/s")
        XCTAssertEqual(answer("100 MB/s in Mbps"), "800 Mbps")
    }

    func testTime() {
        XCTAssertEqual(answer("90 min in h"), "1.5 h")
        XCTAssertEqual(answer("1 d in h"), "24 h")
        XCTAssertEqual(answer("1 h 30 min in min"), "90 min", "compound quantities add up")
        XCTAssertEqual(answer("2시간 in 분"), "120 min")
        XCTAssertEqual(answer("1 wk in d"), "7 d")
    }

    func testScreenPointsAtTwoX() {
        XCTAssertEqual(answer("100 px in pt"), "50 pt")
        XCTAssertEqual(answer("24 pt in px"), "48 px")
        XCTAssertEqual(answer("44 pt"), "88 px")
    }

    func testAngles() {
        XCTAssertEqual(answer("180 deg in rad"), "3.14159 rad")
        XCTAssertEqual(answer("1 rad in degrees"), "57.2958°")
    }

    func testCompoundFeetAndInches() {
        XCTAssertEqual(answer("5 ft 11 in in cm"), "180.34 cm")
        XCTAssertEqual(answer("5'11\" in cm"), "180.34 cm")
    }

    func testArithmeticKeepsTheLeftUnit() {
        XCTAssertEqual(answer("1 km + 500 m"), "1.5 km")
        XCTAssertEqual(answer("3 × 500 g"), "1500 g")
        XCTAssertEqual(answer("10 km / 4"), "2.5 km")
        XCTAssertEqual(answer("20% of 150 km"), "30 km")
    }

    func testIncompatibleUnitsGiveNoAnswer() {
        XCTAssertNil(answer("10 km in kg"))
        XCTAssertNil(answer("1 kg + 1 m"))
        XCTAssertNil(answer("100 in km"), "a plain number has no unit to convert")
        XCTAssertNil(answer("10 / 2 km"))
    }

    func testConversionResultKindAndQuestion() throws {
        let result = try XCTUnwrap(AOMCalculator.evaluate("10 km in mi", locale: Locale(identifier: "en_US")))
        XCTAssertEqual(result.kind, .conversion)
        XCTAssertEqual(result.expression, "10 km in mi")
        XCTAssertEqual(try XCTUnwrap(result.value), 6.2137, accuracy: 0.0001)
    }

    func testUnitCatalogue() throws {
        let meter = try XCTUnwrap(AOMCalculatorUnits.lookup("m"))
        XCTAssertEqual(AOMCalculatorUnits.squared(meter)?.symbol, "m²")
        XCTAssertEqual(AOMCalculatorUnits.cubed(meter)?.symbol, "m³")
        XCTAssertNil(AOMCalculatorUnits.squared(try XCTUnwrap(AOMCalculatorUnits.lookup("kg"))))
        XCTAssertEqual(AOMCalculatorUnits.lookup("Mb")?.id, "Mbit")
        XCTAssertEqual(AOMCalculatorUnits.lookup("MB")?.id, "MB")
        XCTAssertEqual(AOMCalculatorUnits.lookup("K")?.dimension, .temperature)
        XCTAssertNil(AOMCalculatorUnits.lookup("k"), "lower-case k is not kelvin")
        XCTAssertEqual(AOMCalculatorUnits.defaultTarget(for: meter)?.id, "ft")
    }
}
