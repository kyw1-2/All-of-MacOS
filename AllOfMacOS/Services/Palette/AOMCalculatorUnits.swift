import Foundation

/// One unit the calculator knows: its dimension, the factor to that
/// dimension's base unit and, for temperatures, an offset
/// (kelvin = value × factor + offset).
struct AOMCalculatorUnit: Hashable {
    enum Dimension: String, Hashable {
        case length, mass, temperature, area, volume, speed, data, dataRate, time, screen, angle
    }

    let id: String
    /// Shown after the number ("km", "°C", "m²", "평").
    let symbol: String
    let dimension: Dimension
    let factor: Double
    var offset: Double = 0
    /// "10 km" has a space; "30°" has none.
    var spaced = true

    func toBase(_ value: Double) -> Double { value * factor + offset }
    func fromBase(_ value: Double) -> Double { (value - offset) / factor }
    /// A difference in this unit, in base units (temperatures change by the
    /// factor only: 9 °F more is 5 K more).
    func deltaToBase(_ value: Double) -> Double { value * factor }
}

/// The calculator's unit catalogue. Names are matched exactly first ("Mb" is
/// a megabit, "MB" a megabyte, "K" kelvin), then case-insensitively for words
/// ("Miles") and for symbols whose case carries no meaning ("KM", "Kg").
enum AOMCalculatorUnits {
    private struct Entry {
        let unit: AOMCalculatorUnit
        /// Spellings matched exactly.
        let exact: [String]
        /// Spellings matched without case.
        let folded: [String]
        /// The unit a lone quantity ("10 km") converts to.
        let target: String?
    }

    private static func entry(_ id: String, _ symbol: String, _ dimension: AOMCalculatorUnit.Dimension, _ factor: Double,
                              offset: Double = 0, spaced: Bool = true, exact: [String] = [], folded: [String] = [],
                              foldSymbol: Bool = true, target: String? = nil) -> Entry {
        let unit = AOMCalculatorUnit(id: id, symbol: symbol, dimension: dimension, factor: factor, offset: offset, spaced: spaced)
        let names = exact.isEmpty ? [id] : exact
        return Entry(unit: unit, exact: names, folded: folded + (foldSymbol ? names : []), target: target)
    }

    /// Lengths that also make squares and cubes (m², ft³ …).
    private static let lengths: [Entry] = [
        entry("nm", "nm", .length, 1e-9, folded: ["nanometer", "nanometers", "nanometre", "nanometres"], foldSymbol: false),
        entry("µm", "µm", .length, 1e-6, exact: ["µm", "μm", "um"],
              folded: ["micrometer", "micrometers", "micrometre", "micrometres", "micron", "microns"], foldSymbol: false),
        entry("mm", "mm", .length, 0.001, folded: ["millimeter", "millimeters", "millimetre", "millimetres"], target: "in"),
        entry("cm", "cm", .length, 0.01, folded: ["centimeter", "centimeters", "centimetre", "centimetres"], target: "in"),
        entry("m", "m", .length, 1, folded: ["meter", "meters", "metre", "metres"], target: "ft"),
        entry("km", "km", .length, 1000, folded: ["kilometer", "kilometers", "kilometre", "kilometres"], target: "mi"),
        entry("in", "in", .length, 0.0254, exact: ["in", "\"", "″"], folded: ["inch", "inches"], target: "cm"),
        entry("ft", "ft", .length, 0.3048, exact: ["ft", "'", "′"], folded: ["foot", "feet"], target: "m"),
        entry("yd", "yd", .length, 0.9144, folded: ["yard", "yards"], target: "m"),
        entry("mi", "mi", .length, 1609.344, folded: ["mile", "miles"], target: "km"),
    ]

    private static let others: [Entry] = [
        entry("nmi", "nmi", .length, 1852, target: "km"),

        // Mass (base kilogram). 돈 (3.75 g) and 근 (600 g) are the Korean
        // gold and meat units.
        entry("mg", "mg", .mass, 1e-6, folded: ["milligram", "milligrams"]),
        entry("g", "g", .mass, 0.001, folded: ["gram", "grams", "gramme", "grammes"], target: "oz"),
        entry("kg", "kg", .mass, 1, folded: ["kilogram", "kilograms", "kilo", "kilos"], target: "lb"),
        entry("t", "t", .mass, 1000, folded: ["tonne", "tonnes", "ton", "tons", "톤"], target: "lb"),
        entry("oz", "oz", .mass, 0.028349523125, folded: ["ounce", "ounces"], target: "g"),
        entry("lb", "lb", .mass, 0.45359237, exact: ["lb", "lbs"], folded: ["pound", "pounds"], target: "kg"),
        entry("st", "st", .mass, 6.35029318, folded: ["stone", "stones"], target: "kg"),
        entry("ct", "ct", .mass, 0.0002, folded: ["carat", "carats"], target: "g"),
        entry("돈", "돈", .mass, 0.00375, target: "g"),
        entry("근", "근", .mass, 0.6, target: "kg"),

        // Temperature (base kelvin).
        entry("°C", "°C", .temperature, 1, offset: 273.15, exact: ["°C", "°c", "C", "c", "degC"],
              folded: ["celsius", "degc"], foldSymbol: false, target: "°F"),
        entry("°F", "°F", .temperature, 5.0 / 9.0, offset: 273.15 - 32.0 * 5.0 / 9.0, exact: ["°F", "°f", "F", "f", "degF"],
              folded: ["fahrenheit", "degf"], foldSymbol: false, target: "°C"),
        entry("K", "K", .temperature, 1, folded: ["kelvin", "kelvins"], foldSymbol: false, target: "°C"),

        // Area (base square metre); squares of lengths are added below.
        entry("ha", "ha", .area, 1e4, folded: ["hectare", "hectares"], target: "acre"),
        entry("acre", "acre", .area, 4046.8564224, exact: ["acre", "acres", "ac"], target: "m²"),
        entry("평", "평", .area, 400.0 / 121.0, folded: ["pyeong", "pyong"], target: "m²"),

        // Volume (base cubic metre); cubes of lengths are added below.
        entry("mL", "mL", .volume, 1e-6, exact: ["mL", "ml"],
              folded: ["milliliter", "milliliters", "millilitre", "millilitres", "cc"], target: "fl oz"),
        entry("cL", "cL", .volume, 1e-5, exact: ["cL", "cl"], folded: ["centiliter", "centiliters"]),
        entry("dL", "dL", .volume, 1e-4, exact: ["dL", "dl"], folded: ["deciliter", "deciliters"]),
        entry("L", "L", .volume, 1e-3, exact: ["L", "l", "ℓ"], folded: ["liter", "liters", "litre", "litres"], target: "gal"),
        entry("gal", "gal", .volume, 0.003785411784, folded: ["gallon", "gallons"], target: "L"),
        entry("qt", "qt", .volume, 0.000946352946, folded: ["quart", "quarts"], target: "L"),
        entry("pint", "pint", .volume, 0.000473176473, exact: ["pint", "pints"], target: "mL"),
        entry("cup", "cup", .volume, 0.0002365882365, exact: ["cup", "cups"], target: "mL"),
        entry("fl oz", "fl oz", .volume, 2.95735295625e-5, exact: ["fl oz", "floz"],
              folded: ["fluid ounce", "fluid ounces"], target: "mL"),
        entry("tbsp", "tbsp", .volume, 1.478676478125e-5, exact: ["tbsp", "tbs"], folded: ["tablespoon", "tablespoons"], target: "mL"),
        entry("tsp", "tsp", .volume, 4.92892159375e-6, folded: ["teaspoon", "teaspoons"], target: "mL"),

        // Speed (base metre per second).
        entry("m/s", "m/s", .speed, 1, exact: ["m/s", "mps"], target: "km/h"),
        entry("km/h", "km/h", .speed, 1 / 3.6, exact: ["km/h", "kph", "kmh", "kmph", "km/hr"], target: "mph"),
        entry("mph", "mph", .speed, 0.44704, exact: ["mph", "mi/h", "mi/hr"], target: "km/h"),
        entry("kn", "kn", .speed, 1852.0 / 3600.0, exact: ["kn", "kt", "kts"], folded: ["knot", "knots"], target: "km/h"),
        entry("ft/s", "ft/s", .speed, 0.3048, exact: ["ft/s", "fps"], target: "m/s"),

        // Data (base byte). Upper-case prefixes and lower-case "mb" are bytes;
        // "Mb", "Mbit" are bits. KiB, MiB … are powers of 1024.
        entry("bit", "bit", .data, 0.125, exact: ["bit", "bits", "b"], foldSymbol: false, target: "B"),
        entry("B", "B", .data, 1, exact: ["B", "byte", "bytes"], foldSymbol: false),
        entry("kB", "KB", .data, 1e3, exact: ["KB", "kB", "kb"], folded: ["kilobyte", "kilobytes"], foldSymbol: false, target: "KiB"),
        entry("MB", "MB", .data, 1e6, exact: ["MB", "mb"], folded: ["megabyte", "megabytes"], foldSymbol: false, target: "MiB"),
        entry("GB", "GB", .data, 1e9, exact: ["GB", "gb"], folded: ["gigabyte", "gigabytes"], foldSymbol: false, target: "GiB"),
        entry("TB", "TB", .data, 1e12, exact: ["TB", "tb"], folded: ["terabyte", "terabytes"], foldSymbol: false, target: "TiB"),
        entry("PB", "PB", .data, 1e15, exact: ["PB", "pb"], folded: ["petabyte", "petabytes"], foldSymbol: false, target: "PiB"),
        entry("KiB", "KiB", .data, 1024, exact: ["KiB", "kiB", "kib", "KIB"], folded: ["kibibyte", "kibibytes"], foldSymbol: false, target: "kB"),
        entry("MiB", "MiB", .data, 1_048_576, exact: ["MiB", "mib", "MIB"], folded: ["mebibyte", "mebibytes"], foldSymbol: false, target: "MB"),
        entry("GiB", "GiB", .data, 1_073_741_824, exact: ["GiB", "gib", "GIB"], folded: ["gibibyte", "gibibytes"], foldSymbol: false, target: "GB"),
        entry("TiB", "TiB", .data, 1_099_511_627_776, exact: ["TiB", "tib", "TIB"], folded: ["tebibyte", "tebibytes"], foldSymbol: false, target: "TB"),
        entry("PiB", "PiB", .data, 1_125_899_906_842_624, exact: ["PiB", "pib"], foldSymbol: false, target: "PB"),
        entry("kbit", "kbit", .data, 125, exact: ["kbit", "Kbit", "kbits", "Kb"], folded: ["kilobit", "kilobits"], foldSymbol: false, target: "kB"),
        entry("Mbit", "Mbit", .data, 125_000, exact: ["Mbit", "mbit", "Mbits", "Mb"], folded: ["megabit", "megabits"], foldSymbol: false, target: "MB"),
        entry("Gbit", "Gbit", .data, 1.25e8, exact: ["Gbit", "gbit", "Gbits", "Gb"], folded: ["gigabit", "gigabits"], foldSymbol: false, target: "GB"),
        entry("Tbit", "Tbit", .data, 1.25e11, exact: ["Tbit", "Tb"], folded: ["terabit", "terabits"], foldSymbol: false, target: "TB"),

        // Data rate (base byte per second): speed tests report Mbps.
        entry("bps", "bps", .dataRate, 0.125, exact: ["bps", "bit/s"], foldSymbol: false),
        entry("kbps", "kbps", .dataRate, 125, exact: ["kbps", "Kbps", "kbit/s", "Kbit/s"], foldSymbol: false, target: "KB/s"),
        entry("Mbps", "Mbps", .dataRate, 125_000, exact: ["Mbps", "mbps", "Mbit/s", "Mb/s"], foldSymbol: false, target: "MB/s"),
        entry("Gbps", "Gbps", .dataRate, 1.25e8, exact: ["Gbps", "gbps", "Gbit/s", "Gb/s"], foldSymbol: false, target: "GB/s"),
        entry("B/s", "B/s", .dataRate, 1, exact: ["B/s"], foldSymbol: false),
        entry("KB/s", "KB/s", .dataRate, 1e3, exact: ["KB/s", "kB/s", "kb/s"], foldSymbol: false, target: "kbps"),
        entry("MB/s", "MB/s", .dataRate, 1e6, exact: ["MB/s", "mb/s"], foldSymbol: false, target: "Mbps"),
        entry("GB/s", "GB/s", .dataRate, 1e9, exact: ["GB/s", "gb/s"], foldSymbol: false, target: "Gbps"),
        entry("MiB/s", "MiB/s", .dataRate, 1_048_576, exact: ["MiB/s"], foldSymbol: false, target: "MB/s"),

        // Time (base second). A month is 1/12 of the mean Gregorian year.
        entry("ns", "ns", .time, 1e-9, folded: ["nanosecond", "nanoseconds"], foldSymbol: false),
        entry("µs", "µs", .time, 1e-6, exact: ["µs", "μs", "us"], folded: ["microsecond", "microseconds"], foldSymbol: false),
        entry("ms", "ms", .time, 0.001, folded: ["millisecond", "milliseconds"], target: "s"),
        entry("s", "s", .time, 1, exact: ["s", "sec", "secs", "초"], folded: ["second", "seconds"], target: "min"),
        entry("min", "min", .time, 60, exact: ["min", "mins", "분"], folded: ["minute", "minutes"], target: "h"),
        entry("h", "h", .time, 3600, exact: ["h", "hr", "hrs", "시간"], folded: ["hour", "hours"], target: "min"),
        entry("d", "d", .time, 86400, exact: ["d", "일"], folded: ["day", "days"], target: "h"),
        entry("wk", "wk", .time, 604_800, exact: ["wk", "wks", "주"], folded: ["week", "weeks"], target: "d"),
        entry("mo", "mo", .time, 2_629_746, folded: ["month", "months"], target: "d"),
        entry("yr", "yr", .time, 31_556_952, exact: ["yr", "yrs", "y", "년"], folded: ["year", "years"], target: "d"),

        // Screen lengths at 2× (Retina): one point is two pixels.
        entry("pt", "pt", .screen, 1, exact: ["pt", "pts"], folded: ["point", "points"], foldSymbol: false, target: "px"),
        entry("px", "px", .screen, 0.5, folded: ["pixel", "pixels"], foldSymbol: false, target: "pt"),

        // Angle (base radian).
        entry("rad", "rad", .angle, 1, folded: ["radian", "radians"], foldSymbol: false, target: "°"),
        entry("°", "°", .angle, Double.pi / 180, spaced: false, exact: ["°", "deg"], folded: ["degree", "degrees"],
              foldSymbol: false, target: "rad"),
    ]

    /// Squares and cubes of the lengths ("m²", "ft³"), with the Korean
    /// default of m² → 평.
    private static let powers: [Entry] = lengths.flatMap { length -> [Entry] in
        let unit = length.unit
        let squareTargets = ["m": "평", "km": "mi²", "mi": "km²", "ft": "m²", "in": "cm²", "cm": "in²", "yd": "m²"]
        let cubeTargets = ["m": "L", "cm": "mL", "ft": "L", "in": "mL"]
        let square = entry(unit.id + "²", unit.symbol + "²", .area, unit.factor * unit.factor,
                           exact: [unit.symbol + "²", "sq" + unit.symbol], foldSymbol: unit.id != "nm" && unit.id != "µm",
                           target: squareTargets[unit.id])
        let cube = entry(unit.id + "³", unit.symbol + "³", .volume, unit.factor * unit.factor * unit.factor,
                         exact: [unit.symbol + "³"], foldSymbol: unit.id != "nm" && unit.id != "µm",
                         target: cubeTargets[unit.id])
        return [square, cube]
    }

    private static let entries: [Entry] = lengths + others + powers

    static let byID: [String: AOMCalculatorUnit] = Dictionary(entries.map { ($0.unit.id, $0.unit) },
                                                              uniquingKeysWith: { first, _ in first })

    private static let exactIndex: [String: String] = {
        var index: [String: String] = [:]
        for entry in entries { for name in entry.exact where index[name] == nil { index[name] = entry.unit.id } }
        return index
    }()

    private static let foldedIndex: [String: String] = {
        var index: [String: String] = [:]
        for entry in entries { for name in entry.folded where index[name.lowercased()] == nil { index[name.lowercased()] = entry.unit.id } }
        return index
    }()

    private static let targets: [String: String] = {
        var map: [String: String] = [:]
        for entry in entries { if let target = entry.target { map[entry.unit.id] = target } }
        return map
    }()

    /// The unit spelled `name`, or nil.
    static func lookup(_ name: String) -> AOMCalculatorUnit? {
        if let id = exactIndex[name] { return byID[id] }
        if let id = foldedIndex[name.lowercased()] { return byID[id] }
        return nil
    }

    static func unit(_ id: String) -> AOMCalculatorUnit? { byID[id] }

    /// m → m², ft → ft²; nil for anything that is not a length.
    static func squared(_ unit: AOMCalculatorUnit) -> AOMCalculatorUnit? {
        unit.dimension == .length ? byID[unit.id + "²"] : nil
    }

    /// m → m³, cm → cm³; nil for anything that is not a length.
    static func cubed(_ unit: AOMCalculatorUnit) -> AOMCalculatorUnit? {
        unit.dimension == .length ? byID[unit.id + "³"] : nil
    }

    /// What "10 km" alone converts to (mi), or nil when nothing obvious.
    static func defaultTarget(for unit: AOMCalculatorUnit) -> AOMCalculatorUnit? {
        targets[unit.id].flatMap { byID[$0] }
    }

    /// The base unit of a dimension, for results built from two units.
    static func base(of dimension: AOMCalculatorUnit.Dimension) -> AOMCalculatorUnit? {
        switch dimension {
        case .length: return byID["m"]
        case .mass: return byID["kg"]
        case .temperature: return byID["K"]
        case .area: return byID["m²"]
        case .volume: return byID["m³"]
        case .speed: return byID["m/s"]
        case .data: return byID["B"]
        case .dataRate: return byID["B/s"]
        case .time: return byID["s"]
        case .screen: return byID["pt"]
        case .angle: return byID["rad"]
        }
    }

    /// Words that start a two-word unit ("sq ft", "fl oz", "nautical miles").
    static let multiWordStarts: Set<String> = ["sq", "square", "cubic", "fl", "fluid", "nautical"]
}
