import AppKit

/// Hex parsing plus the persisted "My Colors" and recent colours of the
/// annotate colour picker. Colours are stored as uppercase `RRGGBBAA`.
struct AnnotationColorLibrary: Equatable {
    static let myColorsKey = "AOMAnnotationMyColors"
    static let recentColorsKey = "AOMAnnotationRecentColors"
    /// CleanShot shows a limit alert for custom colours; AOM keeps 16.
    static let myColorsLimit = 16
    static let recentLimit = 10

    var myColors: [String] = []
    var recent: [String] = []

    enum AddResult: Equatable { case added, duplicate, limitReached, invalid }

    // MARK: - Hex

    /// Accepts `RGB`, `RRGGBB` or `RRGGBBAA`, with or without `#`.
    static func normalizedHex(_ text: String) -> String? {
        var hex = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        switch hex.count {
        case 3: hex = hex.map { "\($0)\($0)" }.joined() + "FF"
        case 6: hex += "FF"
        case 8: break
        default: return nil
        }
        return hex
    }

    /// (r, g, b, a) in 0…255.
    static func components(ofHex text: String) -> (Int, Int, Int, Int)? {
        guard let hex = normalizedHex(text), let value = UInt32(hex, radix: 16) else { return nil }
        return (Int((value >> 24) & 255), Int((value >> 16) & 255), Int((value >> 8) & 255), Int(value & 255))
    }

    static func hex(r: Int, g: Int, b: Int, a: Int = 255) -> String {
        func clamp(_ v: Int) -> Int { min(255, max(0, v)) }
        return String(format: "%02X%02X%02X%02X", clamp(r), clamp(g), clamp(b), clamp(a))
    }

    static func hex(of color: NSColor, alpha: Double? = nil) -> String {
        let rgb = color.usingColorSpace(.sRGB) ?? NSColor.black
        return hex(r: Int((rgb.redComponent * 255).rounded()), g: Int((rgb.greenComponent * 255).rounded()),
                   b: Int((rgb.blueComponent * 255).rounded()),
                   a: Int(((alpha ?? Double(rgb.alphaComponent)) * 255).rounded()))
    }

    static func color(fromHex text: String) -> NSColor? {
        guard let (r, g, b, a) = components(ofHex: text) else { return nil }
        return NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255,
                       alpha: CGFloat(a) / 255)
    }

    // MARK: - Collections

    mutating func addToMyColors(_ text: String) -> AddResult {
        guard let hex = Self.normalizedHex(text) else { return .invalid }
        if myColors.contains(hex) { return .duplicate }
        guard myColors.count < Self.myColorsLimit else { return .limitReached }
        myColors.append(hex)
        return .added
    }

    /// "Update with Current Color".
    mutating func replaceMyColor(at index: Int, with text: String) -> Bool {
        guard myColors.indices.contains(index), let hex = Self.normalizedHex(text) else { return false }
        myColors[index] = hex
        return true
    }

    mutating func removeMyColor(at index: Int) {
        guard myColors.indices.contains(index) else { return }
        myColors.remove(at: index)
    }

    /// Most-recent-first, de-duplicated, capped.
    mutating func noteRecent(_ text: String) {
        guard let hex = Self.normalizedHex(text) else { return }
        recent.removeAll { $0 == hex }
        recent.insert(hex, at: 0)
        if recent.count > Self.recentLimit { recent.removeLast(recent.count - Self.recentLimit) }
    }

    // MARK: - Persistence (JSON in UserDefaults)

    static func load(_ defaults: UserDefaults = .standard) -> AnnotationColorLibrary {
        func read(_ key: String, limit: Int) -> [String] {
            guard let data = defaults.data(forKey: key),
                  let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
            var seen = Set<String>()
            return list.compactMap(normalizedHex).filter { seen.insert($0).inserted }.prefix(limit).map { $0 }
        }
        return AnnotationColorLibrary(myColors: read(myColorsKey, limit: myColorsLimit),
                                      recent: read(recentColorsKey, limit: recentLimit))
    }

    func save(_ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(myColors) { defaults.set(data, forKey: Self.myColorsKey) }
        if let data = try? JSONEncoder().encode(recent) { defaults.set(data, forKey: Self.recentColorsKey) }
    }
}
