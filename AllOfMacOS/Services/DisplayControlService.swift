import AppKit
import CoreGraphics
import IOKit

/// One connected display, keyed by the same UUID that `DisplayTopology` uses
/// for snap profiles so a binding survives a reconnect.
struct DisplayTarget: Identifiable, Equatable {
    let id: String            // CGDisplay UUID string; stable across reconnects
    let displayID: CGDirectDisplayID
    let name: String
    let isBuiltIn: Bool

    static func == (lhs: DisplayTarget, rhs: DisplayTarget) -> Bool { lhs.id == rhs.id }
}

/// A selectable display mode. `pointWidth`/`pixelWidth` are kept separate
/// because a HiDPI mode has more pixels than points, and two modes can share a
/// point size while differing in backing scale.
struct DisplayModeOption: Identifiable, Equatable {
    let pointWidth: Int
    let pointHeight: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let refreshRate: Double

    var id: String { "\(pointWidth)x\(pointHeight)@\(pixelWidth)x\(pixelHeight)@\(String(format: "%.2f", refreshRate))" }
    var isHiDPI: Bool { pixelWidth > pointWidth }
    var label: String {
        let base = "\(pointWidth) × \(pointHeight)"
        let suffix = isHiDPI ? " HiDPI" : ""
        let hz = refreshRate > 0 ? String(format: " · %.0f Hz", refreshRate) : ""
        return base + suffix + hz
    }
    /// Ranking key so a requested size resolves to the sharpest mode first.
    var sharpnessRank: Int { pixelWidth / max(1, pointWidth) }

    /// Whether two options describe the same mode. Refresh is compared with the
    /// same tolerance the mode lookup uses, so a display reporting 59.94 Hz
    /// still matches a menu entry built from the same mode.
    func matches(_ other: DisplayModeOption) -> Bool {
        pointWidth == other.pointWidth && pointHeight == other.pointHeight
            && pixelWidth == other.pixelWidth && pixelHeight == other.pixelHeight
            && abs(refreshRate - other.refreshRate) < 0.5
    }

    /// The size only, ignoring backing scale and refresh. Used where the menu
    /// treats two modes as one resolution.
    func matchesSize(_ other: DisplayModeOption) -> Bool {
        pointWidth == other.pointWidth && pointHeight == other.pointHeight
    }
}

/// DisplayServices takes precedence for Apple panels. External monitors can
/// expose brightness and speaker volume independently over DDC/CI.
enum DisplayControlService {

    // MARK: - Enumeration

    static func displays() -> [DisplayTarget] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).compactMap { id in
            guard let uuid = displayUUID(id) else { return nil }
            return DisplayTarget(id: uuid,
                                 displayID: id,
                                 name: name(for: id),
                                 isBuiltIn: CGDisplayIsBuiltin(id) != 0)
        }
    }

    static func displayUUID(_ id: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    private static func name(for id: CGDirectDisplayID) -> String {
        if let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }) { return screen.localizedName }
        return CGDisplayIsBuiltin(id) != 0 ? "Built-in Display" : "Display \(id)"
    }

    // MARK: - Main Display

    /// Sets the specified display as the macOS Main Display by translating
    /// all active display origins so that the target display is positioned at (0, 0).
    static func setMainDisplay(_ targetID: CGDirectDisplayID) -> Bool {
        guard CGDisplayIsMain(targetID) == 0 else { return true }
        var configRef: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configRef) == .success, let config = configRef else { return false }

        let targetBounds = CGDisplayBounds(targetID)
        let deltaX = -targetBounds.origin.x
        let deltaY = -targetBounds.origin.y

        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            CGCancelDisplayConfiguration(config)
            return false
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else {
            CGCancelDisplayConfiguration(config)
            return false
        }

        for id in ids {
            let bounds = CGDisplayBounds(id)
            let newX = Int32(bounds.origin.x + deltaX)
            let newY = Int32(bounds.origin.y + deltaY)
            CGConfigureDisplayOrigin(config, id, newX, newY)
        }

        let result = CGCompleteDisplayConfiguration(config, .permanently)
        return result == .success
    }

    // MARK: - Brightness

    private typealias GetBrightnessFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightnessFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias CanChangeFn = @convention(c) (CGDirectDisplayID) -> Bool

    /// DisplayServices is private but stable; it is loaded lazily so a future
    /// removal degrades to the software dim instead of failing to launch.
    private static let displayServices: (get: GetBrightnessFn, set: SetBrightnessFn, canChange: CanChangeFn)? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW),
              let getSym = dlsym(handle, "DisplayServicesGetBrightness"),
              let setSym = dlsym(handle, "DisplayServicesSetBrightness"),
              let canSym = dlsym(handle, "DisplayServicesCanChangeBrightness")
        else { return nil }
        return (unsafeBitCast(getSym, to: GetBrightnessFn.self),
                unsafeBitCast(setSym, to: SetBrightnessFn.self),
                unsafeBitCast(canSym, to: CanChangeFn.self))
    }()

    static func supportsHardwareBrightness(_ id: CGDirectDisplayID) -> Bool {
        displayServices?.canChange(id) == true || MonitorControls.shared.level(id, .brightness) != nil
    }

    static func hasNativeBrightness(_ id: CGDirectDisplayID) -> Bool {
        displayServices?.canChange(id) == true
    }

    static func brightness(_ id: CGDirectDisplayID) -> Float? {
        if let ds = displayServices, ds.canChange(id) {
            var value: Float = 0
            if ds.get(id, &value) == 0 { return value }
        }
        return MonitorControls.shared.level(id, .brightness) ?? softwareDim(id)
    }

    /// DDC requests are asynchronous. Callers that display feedback use the
    /// completion to distinguish an accepted request from an applied level.
    @discardableResult
    static func setBrightness(_ id: CGDirectDisplayID, _ value: Float,
                              completion: ((Bool) -> Void)? = nil) -> Bool {
        guard value.isFinite else { return false }
        let clamped = min(1, max(0, value))
        if let ds = displayServices, ds.canChange(id) {
            let ok = ds.set(id, clamped) == 0
            completion?(ok)
            return ok
        }
        let previousDim = softwareDim(id)
        if MonitorControls.shared.request(id, .brightness, clamped, completion: { result in
            switch result {
            case .applied:
                if softwareDim(id) == previousDim { _ = clearSoftwareDim(id) }
                completion?(true)
            case .failed:
                let applied = setSoftwareDim(id, max(0.1, clamped))
                completion?(applied)
            case .cancelled:
                completion?(false)
            }
        }) { return true }
        let ok = setSoftwareDim(id, max(0.1, clamped))
        completion?(ok)
        return ok
    }

    /// The first 10% of the combined brightness slider extends below
    /// the monitor's actual backlight minimum; higher levels use hardware DDC.
    /// Built-in Apple panels preserve their native brightness behavior.
    static func combinedBrightness(_ id: CGDirectDisplayID) -> Float? {
        guard CGDisplayIsBuiltin(id) == 0,
              let hardware = MonitorControls.shared.level(id, .brightness) else { return brightness(id) }
        return MonitorCombinedBrightness.slider(hardware: hardware, gain: softwareDim(id) ?? 1)
    }

    @discardableResult
    static func setCombinedBrightness(_ id: CGDirectDisplayID, _ value: Float,
                                      completion: ((Bool) -> Void)? = nil) -> Bool {
        guard value.isFinite else { completion?(false); return false }
        guard CGDisplayIsBuiltin(id) == 0,
              MonitorControls.shared.level(id, .brightness) != nil else {
            return setBrightness(id, value, completion: completion)
        }
        let target = MonitorCombinedBrightness.target(slider: value)
        let accepted = MonitorControls.shared.request(id, .brightness, target.hardware) { result in
            guard result == .applied else { completion?(false); return }
            let success = target.gain < 1
                ? setSoftwareDim(id, target.gain)
                : clearSoftwareDim(id)
            completion?(success)
        }
        if !accepted { completion?(false) }
        return accepted
    }

    // Preserve the calibrated table, including nonlinear color profiles.
    private struct Gamma {
        var red: [Float]
        var green: [Float]
        var blue: [Float]

        init?(_ id: CGDirectDisplayID) {
            let capacity = CGDisplayGammaTableCapacity(id)
            guard capacity > 0, capacity <= 65_536 else { return nil }
            var r = [Float](repeating: 0, count: Int(capacity))
            var g = r, b = r
            var count: UInt32 = 0
            guard CGGetDisplayTransferByTable(id, capacity, &r, &g, &b, &count) == .success,
                  count > 0, count <= capacity else { return nil }
            red = Array(r.prefix(Int(count)))
            green = Array(g.prefix(Int(count)))
            blue = Array(b.prefix(Int(count)))
        }

        func apply(to id: CGDirectDisplayID, gain: Float) -> Bool {
            CGSetDisplayTransferByTable(id, UInt32(red.count), red.map { $0 * gain },
                                        green.map { $0 * gain }, blue.map { $0 * gain }) == .success
        }
    }

    private static var originalGamma: [CGDirectDisplayID: Gamma] = [:]
    private static var currentDim: [CGDirectDisplayID: Float] = [:]
    private static let gammaLock = NSLock()

    static func softwareDim(_ id: CGDirectDisplayID) -> Float? {
        gammaLock.lock(); defer { gammaLock.unlock() }
        return currentDim[id]
    }

    @discardableResult
    static func setSoftwareDim(_ id: CGDirectDisplayID, _ level: Float) -> Bool {
        let gain = min(1, max(0, level))
        gammaLock.lock(); defer { gammaLock.unlock() }
        guard let base = originalGamma[id] ?? Gamma(id), base.apply(to: id, gain: gain) else { return false }
        originalGamma[id] = base
        currentDim[id] = gain
        return true
    }

    static func discardSoftwareDim(_ id: CGDirectDisplayID) {
        gammaLock.lock(); defer { gammaLock.unlock() }
        originalGamma.removeValue(forKey: id)
        currentDim.removeValue(forKey: id)
    }

    @discardableResult
    static func clearSoftwareDim(_ id: CGDirectDisplayID) -> Bool {
        gammaLock.lock(); defer { gammaLock.unlock() }
        guard let base = originalGamma[id] else { return true }
        guard base.apply(to: id, gain: 1) else { return false }
        originalGamma[id] = nil
        currentDim[id] = nil
        return true
    }

    /// Clears every software dim. Used when the app terminates so a crash or
    /// quit never leaves the screen darkened.
    static func clearAllSoftwareDims() {
        for id in displays().map(\.displayID) { clearSoftwareDim(id) }
    }

    // MARK: - Modes

    /// Enumerates modes with the duplicate-low-resolution flag set.
    ///
    /// Without this flag CoreGraphics omits the scaled variants, so a HiDPI
    /// mode is simply absent from the list — including the mode a 4K display is
    /// already using. Every enumeration in this service goes through here so a
    /// mode can always be matched back, which is what makes a change reversible.
    ///
    /// The flag's real value is `kCGDisplayResolution`, not a key spelled like
    /// its Swift name; using a string literal silently returns the same list as
    /// passing nil.
    private static func allModes(_ id: CGDirectDisplayID) -> [CGDisplayMode] {
        let options: CFDictionary = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue!] as CFDictionary
        return (CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode]) ?? []
    }

    /// Converts a CoreGraphics mode to the value type. Every mode crossing this
    /// boundary is read here, so the point/pixel/refresh triple cannot drift
    /// between enumeration, the current mode, and the markers.
    private static func modeOption(_ mode: CGDisplayMode) -> DisplayModeOption {
        DisplayModeOption(pointWidth: mode.width,
                          pointHeight: mode.height,
                          pixelWidth: mode.pixelWidth,
                          pixelHeight: mode.pixelHeight,
                          refreshRate: mode.refreshRate)
    }

    static func modes(_ id: CGDirectDisplayID) -> [DisplayModeOption] {
        var seen = Set<String>()
        var options: [DisplayModeOption] = []
        for mode in allModes(id) {
            // Non-GUI modes (640x480 class) cannot host a desktop.
            guard mode.isUsableForDesktopGUI() else { continue }
            let option = modeOption(mode)
            guard seen.insert(option.id).inserted else { continue }
            options.append(option)
        }
        return options
    }

    static func currentMode(_ id: CGDirectDisplayID) -> DisplayModeOption? {
        guard let mode = CGDisplayCopyDisplayMode(id) else { return nil }
        return modeOption(mode)
    }

    /// Modes that share one point size, so a resolution entry can offer its
    /// available refresh rates without duplicating the resolution.
    static func refreshRates(_ id: CGDirectDisplayID, pointWidth: Int, pointHeight: Int, hiDPI: Bool) -> [Double] {
        modes(id).filter {
            $0.pointWidth == pointWidth && $0.pointHeight == pointHeight && $0.isHiDPI == hiDPI
        }.map(\.refreshRate).sorted()
    }

    /// Distinct point sizes, one entry per size.
    ///
    /// `preferringHiDPI` picks which backing scale represents a size that
    /// offers both. BetterDisplay's slider keeps the current HiDPI/LoDPI type
    /// as it moves between sizes, so the menu passes the active scale and the
    /// entry it shows is the one it will apply. Nil falls back to the sharpest,
    /// which is the right default when there is no current mode to match.
    static func resolutionOptions(_ id: CGDirectDisplayID,
                                  preferringHiDPI: Bool? = nil) -> [DisplayModeOption] {
        var best: [String: DisplayModeOption] = [:]
        for option in modes(id) {
            let key = "\(option.pointWidth)x\(option.pointHeight)"
            if let existing = best[key] {
                if isBetter(option, than: existing, preferringHiDPI: preferringHiDPI) {
                    best[key] = option
                }
            } else {
                best[key] = option
            }
        }
        return best.values.sorted {
            $0.pointWidth != $1.pointWidth ? $0.pointWidth < $1.pointWidth
                                           : $0.pointHeight < $1.pointHeight
        }
    }

    /// Whether `candidate` should represent a size instead of `existing`.
    /// A requested scale wins outright; otherwise the sharper mode wins.
    private static func isBetter(_ candidate: DisplayModeOption,
                                 than existing: DisplayModeOption,
                                 preferringHiDPI: Bool?) -> Bool {
        if let preferringHiDPI {
            let candidateMatches = candidate.isHiDPI == preferringHiDPI
            let existingMatches = existing.isHiDPI == preferringHiDPI
            if candidateMatches != existingMatches { return candidateMatches }
        }
        return candidate.sharpnessRank > existing.sharpnessRank
    }

    // MARK: - Mode markers

    /// A familiar size worth calling out while the user moves through the list.
    ///
    /// `default` is the panel's factory-preferred size, which is what
    /// `kDisplayModeDefaultFlag` marks; it is the 100% baseline a resolution
    /// percentage is measured against. This hardware reports exactly one such
    /// mode per display, so the marker is unambiguous.
    ///
    /// There is deliberately no "native" marker. `kDisplayModeNativeFlag` and
    /// the largest pixel area both match two modes on both displays here
    /// (960x540 and 1920x1080 on the external panel), so marking either would
    /// point at a size the hardware does not single out.
    enum ModeMarker: String {
        case current
        case `default`

        var label: String {
            switch self {
            case .current: return "Current"
            case .default: return "Default"
            }
        }
    }

    /// The markers that apply to one point size, in a fixed order so a menu
    /// entry reads the same way every time it is built.
    static func markers(_ id: CGDirectDisplayID,
                        for option: DisplayModeOption) -> [ModeMarker] {
        var result: [ModeMarker] = []
        if let current = currentMode(id),
           current.pointWidth == option.pointWidth, current.pointHeight == option.pointHeight {
            result.append(.current)
        }
        if isDefaultMode(id, pointWidth: option.pointWidth, pointHeight: option.pointHeight) {
            result.append(.default)
        }
        return result
    }

    /// Whether any enumerated mode at this point size carries the default flag.
    ///
    /// Matched on point size rather than the full mode triple: the flag sits on
    /// the LoDPI entry, but the option the menu shows may be the HiDPI one at
    /// the same size, and the user reads both as the same resolution.
    private static func isDefaultMode(_ id: CGDirectDisplayID,
                                      pointWidth: Int, pointHeight: Int) -> Bool {
        allModes(id).contains {
            $0.width == pointWidth && $0.height == pointHeight
                && $0.ioFlags & UInt32(kDisplayModeDefaultFlag) != 0
        }
    }

    /// The size the display was designed around, used as the percentage
    /// baseline. Nil when the hardware marks no default mode.
    static func defaultMode(_ id: CGDirectDisplayID) -> DisplayModeOption? {
        guard let mode = allModes(id).first(where: {
            $0.isUsableForDesktopGUI() && $0.ioFlags & UInt32(kDisplayModeDefaultFlag) != 0
        }) else { return nil }
        return modeOption(mode)
    }

    /// Whether the display's current mode can be selected again from its own
    /// enumerated list. False means leaving it strands the display: macOS hides
    /// the active HiDPI mode on some panels, and CoreGraphics cannot select a
    /// mode it does not enumerate, so the user would have to restore it from
    /// System Settings.
    static func canReturnToCurrentMode(_ id: CGDirectDisplayID) -> Bool {
        guard let current = currentMode(id) else { return false }
        return modes(id).contains {
            $0.pointWidth == current.pointWidth && $0.pointHeight == current.pointHeight
                && $0.pixelWidth == current.pixelWidth && $0.pixelHeight == current.pixelHeight
        }
    }

    /// Whether the display can switch to the opposite backing scale at its
    /// current point size. False when only one scale exists at that size, which
    /// is what decides if a High Resolution toggle is worth offering.
    static func canToggleHiDPI(_ id: CGDirectDisplayID) -> Bool {
        guard let current = currentMode(id) else { return false }
        return modes(id).contains {
            $0.pointWidth == current.pointWidth && $0.pointHeight == current.pointHeight
                && $0.isHiDPI != current.isHiDPI
        }
    }

    /// Switches the display between HiDPI and LoDPI at its current point size,
    /// the way BetterDisplay's High Resolution toggle does.
    ///
    /// The size is held rather than the backing scale, so the desktop keeps the
    /// same amount of workspace and only the sharpness changes. An exact
    /// counterpart may not exist, in which case this refuses rather than
    /// silently landing on a different size.
    @discardableResult
    static func setHiDPI(_ id: CGDirectDisplayID, _ hiDPI: Bool) -> Bool {
        guard let current = currentMode(id) else { return false }
        return setMode(id,
                       pointWidth: current.pointWidth,
                       pointHeight: current.pointHeight,
                       refreshRate: current.refreshRate,
                       hiDPI: hiDPI)
    }

    /// Applies a mode. `hiDPI` is a preference, not a requirement: when the
    /// requested backing scale is unavailable the sharpest candidate is used so
    /// the requested size still lands instead of failing.
    ///
    /// Refuses when the display's current mode is not enumerable; see
    /// `canReturnToCurrentMode` for why that would be one-way.
    @discardableResult
    static func setMode(_ id: CGDirectDisplayID,
                        pointWidth: Int,
                        pointHeight: Int,
                        refreshRate: Double? = nil,
                        hiDPI: Bool? = nil) -> Bool {
        guard canReturnToCurrentMode(id) else {
            NSLog("[DisplayControl] refusing mode change: current mode is not re-selectable")
            return false
        }
        let candidates = modes(id).filter { $0.pointWidth == pointWidth && $0.pointHeight == pointHeight }
        guard !candidates.isEmpty else { return false }
        let match = candidates.min { lhs, rhs in
            score(lhs, refreshRate: refreshRate, hiDPI: hiDPI) < score(rhs, refreshRate: refreshRate, hiDPI: hiDPI)
        }
        guard let target = match else { return false }
        return apply(target, to: id)
    }

    private static func score(_ option: DisplayModeOption, refreshRate: Double?, hiDPI: Bool?) -> Int {
        var penalty = 0
        if let hiDPI, option.isHiDPI != hiDPI { penalty += 1000 }
        if let refreshRate, refreshRate > 0, abs(option.refreshRate - refreshRate) > 0.5 { penalty += 100 }
        // Prefer the sharpest backing scale, then the highest refresh rate.
        penalty -= option.sharpnessRank * 10
        penalty -= Int(option.refreshRate / 10)
        return penalty
    }

    /// CoreGraphics invalidates a CGDisplayMode obtained before a configuration
    /// change, so the target is always re-enumerated and matched on every field
    /// immediately before use. Reusing a saved mode returns kCGErrorIllegalArgument
    /// (1000) and silently leaves the display in its previous mode.
    private static func apply(_ option: DisplayModeOption, to id: CGDirectDisplayID) -> Bool {
        guard let target = allModes(id).first(where: {
            $0.width == option.pointWidth && $0.height == option.pointHeight
                && $0.pixelWidth == option.pixelWidth && $0.pixelHeight == option.pixelHeight
                && abs($0.refreshRate - option.refreshRate) < 0.5
        }) else { return false }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
        CGConfigureDisplayWithDisplayMode(config, id, target, nil)
        return CGCompleteDisplayConfiguration(config, .permanently) == .success
    }
}
