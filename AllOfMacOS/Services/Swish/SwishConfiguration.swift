import Foundation
import AppKit

/// Configuration model and preferences adapter for Swish-style window interactions.
final class SwishConfiguration: ObservableObject {
    static let shared = SwishConfiguration()

    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: "AOMSwishEnabled") }
    }

    @Published var requireModifier: Bool {
        didSet { UserDefaults.standard.set(requireModifier, forKey: "AOMSwishRequireModifier") }
    }

    @Published var modifierFlag: UInt {
        didSet { UserDefaults.standard.set(modifierFlag, forKey: "AOMSwishModifierFlag") }
    }

    @Published var allowChaining: Bool {
        didSet { UserDefaults.standard.set(allowChaining, forKey: "AOMSwishAllowChaining") }
    }

    @Published var hapticFeedback: Bool {
        didSet { UserDefaults.standard.set(hapticFeedback, forKey: "AOMSwishHapticFeedback") }
    }

    @Published var edgeTriggerBand: CGFloat {
        didSet { UserDefaults.standard.set(Double(edgeTriggerBand), forKey: "AOMSwishEdgeTriggerBand") }
    }

    @Published var blacklistedBundleIDs: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(blacklistedBundleIDs), forKey: "AOMSwishBlacklist")
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.isEnabled = defaults.object(forKey: "AOMSwishEnabled") as? Bool ?? true
        self.requireModifier = defaults.object(forKey: "AOMSwishRequireModifier") as? Bool ?? false
        // Default modifier: 262144 (NSEvent.ModifierFlags.control.rawValue)
        self.modifierFlag = defaults.object(forKey: "AOMSwishModifierFlag") as? UInt ?? NSEvent.ModifierFlags.control.rawValue
        self.allowChaining = defaults.object(forKey: "AOMSwishAllowChaining") as? Bool ?? true
        self.hapticFeedback = defaults.object(forKey: "AOMSwishHapticFeedback") as? Bool ?? true
        self.edgeTriggerBand = CGFloat(defaults.object(forKey: "AOMSwishEdgeTriggerBand") as? Double ?? 28.0)
        
        let storedBlacklist = defaults.stringArray(forKey: "AOMSwishBlacklist")
        if let storedBlacklist {
            self.blacklistedBundleIDs = Set(storedBlacklist)
        } else {
            // Native Swish defaults
            self.blacklistedBundleIDs = [
                "com.apple.Spotlight",
                "com.apple.CharacterPaletteIM",
                "com.apple.PIPAgent",
                "com.apple.controlcenter",
                "com.apple.notificationcenterui",
                "com.apple.dock",
                "com.kyw.allofmacos"
            ]
        }
    }

    func isBlacklisted(bundleID: String?) -> Bool {
        guard let bundleID else { return true }
        return blacklistedBundleIDs.contains(bundleID)
    }
}
