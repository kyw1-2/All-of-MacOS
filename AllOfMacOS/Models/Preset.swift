import Foundation
import AppKit
import ColorSync

/// Absorbs any JSON value — used to skip broken entries during resilient decoding.
private struct AnyCodable: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { return }
        if let _ = try? container.decode(Bool.self) { return }
        if let _ = try? container.decode(Int.self) { return }
        if let _ = try? container.decode(Double.self) { return }
        if let _ = try? container.decode(String.self) { return }
        if let _ = try? container.decode([AnyCodable].self) { return }
        if let _ = try? container.decode([String: AnyCodable].self) { return }
    }
    func encode(to encoder: Encoder) throws {}
}

/// Conditional activation group: shared bindings for several applications.
/// Exclusions take precedence over inclusions; an empty inclusion set never matches.
struct ActivationGroup: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var includedBundleIDs: [String]
    var excludedBundleIDs: [String]
    var disableGlobalTriggers: Bool
    var isEnabled: Bool
    var appliesToAllApps: Bool

    private enum CodingKeys: String, CodingKey {
        case id, name, includedBundleIDs, excludedBundleIDs, disableGlobalTriggers, isEnabled, appliesToAllApps
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        includedBundleIDs = try c.decodeIfPresent([String].self, forKey: .includedBundleIDs) ?? []
        excludedBundleIDs = try c.decodeIfPresent([String].self, forKey: .excludedBundleIDs) ?? []
        disableGlobalTriggers = try c.decodeIfPresent(Bool.self, forKey: .disableGlobalTriggers) ?? false
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        appliesToAllApps = try c.decodeIfPresent(Bool.self, forKey: .appliesToAllApps) ?? false
    }
    init(name: String) {
        id = UUID()
        self.name = name
        includedBundleIDs = []
        excludedBundleIDs = []
        disableGlobalTriggers = false
        isEnabled = true
        appliesToAllApps = false
    }

    func matches(_ bundleID: String?) -> Bool {
        guard isEnabled, let bundleID else { return false }
        return (appliesToAllApps || includedBundleIDs.contains(bundleID)) && !excludedBundleIDs.contains(bundleID)
    }
}

/// Optional drag activation zones, normalized to the pointer display's visible area.
struct CustomSnapZone: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var isEnabled = true
    var hotX = 0.85, hotY = 0.0, hotWidth = 0.15, hotHeight = 0.15
    var targetX = 0.5, targetY = 0.0, targetWidth = 0.5, targetHeight = 1.0
    var targetDisplay = "pointer" // pointer/current/primary/next

    /// Consistent starter layouts: the visible drop edge and resulting window
    /// destination agree. Older shipped "Left half" mistakenly targeted right.
    enum Layout: String, CaseIterable, Identifiable {
        case leftHalf = "Left Half"
        case rightHalf = "Right Half"
        case maximize = "Maximize"
        case center = "Center"
        case leftThird = "Left Third"
        case rightThird = "Right Third"
        case centerThird = "Center Third"
        case topHalf = "Top Half"
        case bottomHalf = "Bottom Half"
        case topLeft = "Top Left Quarter"
        case topRight = "Top Right Quarter"
        case bottomLeft = "Bottom Left Quarter"
        case bottomRight = "Bottom Right Quarter"
        case leftTwoThirds = "Left Two Thirds"
        case rightTwoThirds = "Right Two Thirds"
        case nextDisplay = "Next Display · Maximize"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .leftHalf: "rectangle.lefthalf.filled"
            case .rightHalf: "rectangle.righthalf.filled"
            case .maximize: "arrow.up.left.and.arrow.down.right"
            case .center: "square.dashed.inset.filled"
            case .leftThird, .rightThird, .centerThird, .leftTwoThirds, .rightTwoThirds: "rectangle.split.3x1"
            case .topHalf, .bottomHalf: "rectangle.split.1x2"
            case .topLeft, .topRight, .bottomLeft, .bottomRight: "rectangle.split.2x2"
            case .nextDisplay: "display.2"
            }
        }
        func zone() -> CustomSnapZone {
            var zone = CustomSnapZone(name: rawValue)
            switch self {
            case .leftHalf:
                (zone.hotX,zone.hotY,zone.hotWidth,zone.hotHeight) = (0, 0.32, 0.10, 0.36)
                (zone.targetX,zone.targetY,zone.targetWidth,zone.targetHeight) = (0,0,0.5,1)
            case .rightHalf:
                (zone.hotX,zone.hotY,zone.hotWidth,zone.hotHeight) = (0.90,0.32,0.10,0.36)
                (zone.targetX,zone.targetY,zone.targetWidth,zone.targetHeight) = (0.5,0,0.5,1)
            case .maximize:
                (zone.hotX,zone.hotY,zone.hotWidth,zone.hotHeight) = (0.36,0,0.28,0.10)
                (zone.targetX,zone.targetY,zone.targetWidth,zone.targetHeight) = (0,0,1,1)
            case .center:
                (zone.hotX,zone.hotY,zone.hotWidth,zone.hotHeight) = (0.43,0.43,0.14,0.14)
                (zone.targetX,zone.targetY,zone.targetWidth,zone.targetHeight) = (0.18,0.14,0.64,0.72)
            case .leftThird:
                (zone.hotX,zone.hotY,zone.hotWidth,zone.hotHeight) = (0,0.14,0.10,0.14)
                (zone.targetX,zone.targetY,zone.targetWidth,zone.targetHeight) = (0,0,0.33,1)
            case .rightThird:
                (zone.hotX,zone.hotY,zone.hotWidth,zone.hotHeight) = (0.90,0.14,0.10,0.14)
                (zone.targetX,zone.targetY,zone.targetWidth,zone.targetHeight) = (0.67,0,0.33,1)
            case .centerThird:
                (zone.hotX,zone.hotY,zone.hotWidth,zone.hotHeight) = (0.23,0.90,0.10,0.10)
                (zone.targetX,zone.targetY,zone.targetWidth,zone.targetHeight) = (1.0/3,0,1.0/3,1)
            case .topHalf:
                (zone.hotX,zone.hotY,zone.hotWidth,zone.hotHeight) = (0.15,0,0.15,0.10)
                (zone.targetX,zone.targetY,zone.targetWidth,zone.targetHeight) = (0,0,1,0.5)
            case .bottomHalf:
                (zone.hotX,zone.hotY,zone.hotWidth,zone.hotHeight) = (0.36,0.90,0.28,0.10)
                (zone.targetX,zone.targetY,zone.targetWidth,zone.targetHeight) = (0,0.5,1,0.5)
            case .topLeft, .topRight, .bottomLeft, .bottomRight:
                let right = self == .topRight || self == .bottomRight
                let bottom = self == .bottomLeft || self == .bottomRight
                (zone.hotX,zone.hotY,zone.hotWidth,zone.hotHeight) = (right ? 0.9 : 0, bottom ? 0.9 : 0, 0.1, 0.1)
                (zone.targetX,zone.targetY,zone.targetWidth,zone.targetHeight) = (right ? 0.5 : 0, bottom ? 0.5 : 0, 0.5, 0.5)
            case .leftTwoThirds, .rightTwoThirds:
                let right = self == .rightTwoThirds
                (zone.hotX,zone.hotY,zone.hotWidth,zone.hotHeight) = (right ? 0.9 : 0,0.71,0.1,0.14)
                (zone.targetX,zone.targetY,zone.targetWidth,zone.targetHeight) = (right ? 1.0/3 : 0,0,2.0/3,1)
            case .nextDisplay:
                (zone.hotX,zone.hotY,zone.hotWidth,zone.hotHeight) = (0.70,0,0.15,0.10)
                (zone.targetX,zone.targetY,zone.targetWidth,zone.targetHeight) = (0,0,1,1)
                zone.targetDisplay = "next"
            }
            return zone
        }
    }

    enum Collection: String, CaseIterable, Identifiable {
        case essentials = "Essentials", corners = "Corners & Halves", complete = "Complete Set"
        var id: String { rawValue }
        var layouts: [Layout] {
            switch self {
            case .essentials: return [.leftHalf, .rightHalf, .maximize]
            case .corners: return [.leftHalf, .rightHalf, .maximize, .topHalf, .bottomHalf, .topLeft, .topRight, .bottomLeft, .bottomRight]
            case .complete: return Layout.allCases
            }
        }
        func replacing(_ zones: [CustomSnapZone]) -> [CustomSnapZone] {
            layouts.map { layout in
                let candidate = layout.zone()
                var selected = zones.first {
                    abs($0.targetX-candidate.targetX) < 0.005 && abs($0.targetY-candidate.targetY) < 0.005 &&
                    abs($0.targetWidth-candidate.targetWidth) < 0.005 && abs($0.targetHeight-candidate.targetHeight) < 0.005 &&
                    $0.targetDisplay == candidate.targetDisplay
                } ?? candidate
                selected.isEnabled = true
                return selected
            }
        }
        func addingMissing(to zones: [CustomSnapZone]) -> [CustomSnapZone] {
            var result = zones
            for layout in layouts {
                let candidate = layout.zone()
                let exists = result.contains {
                    abs($0.targetX-candidate.targetX) < 0.005 && abs($0.targetY-candidate.targetY) < 0.005 &&
                    abs($0.targetWidth-candidate.targetWidth) < 0.005 && abs($0.targetHeight-candidate.targetHeight) < 0.005 &&
                    $0.targetDisplay == candidate.targetDisplay
                }
                if !exists && result.count < 32 { result.append(candidate) }
            }
            return result
        }
    }
    /// Smaller custom drop areas win overlaps; ties preserve saved order.
    static func matching(_ zones: [CustomSnapZone], x: Double, y: Double) -> CustomSnapZone? {
        zones.enumerated().filter { $0.element.hit(x: x, y: y) }.min {
            let a = $0.element.hotWidth * $0.element.hotHeight, b = $1.element.hotWidth * $1.element.hotHeight
            return a == b ? $0.offset < $1.offset : a < b
        }?.element
    }
    func hit(x: Double, y: Double) -> Bool {
        isEnabled && x >= hotX && x <= hotX + hotWidth && y >= hotY && y <= hotY + hotHeight
    }
    var actionParameters: ActionParameters {
        var p = ActionParameters()
        p.snapX = targetX; p.snapY = targetY
        p.snapWidth = targetWidth; p.snapHeight = targetHeight
        p.snapDisplay = targetDisplay
        return p
    }
    var isValid: Bool {
        !name.isEmpty && name.count <= 128 &&
        WindowGeometry.normalizedRect(x: hotX, y: hotY, width: hotWidth, height: hotHeight) != nil &&
        WindowGeometry.normalizedRect(x: targetX, y: targetY, width: targetWidth, height: targetHeight) != nil &&
        ["pointer", "current", "primary", "next"].contains(targetDisplay)
    }
}

struct SnapLayoutProfile: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var displayIDs: [String]
    var zones: [CustomSnapZone]
    var requiresOption = false
    var showsPreview = true
    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 128 &&
        !displayIDs.isEmpty && displayIDs.count <= 16 && Set(displayIDs).count == displayIDs.count &&
        displayIDs.allSatisfy { !$0.isEmpty && $0.count <= 256 } && zones.count <= 32 &&
        Set(zones.map(\.id)).count == zones.count && zones.allSatisfy(\.isValid)
    }
}

enum DisplayTopology {
    static func identifier(_ screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
    static var currentIDs: [String] { NSScreen.screens.compactMap(identifier).sorted() }
    static func matching(_ profiles: [SnapLayoutProfile], ids: [String]) -> SnapLayoutProfile? {
        guard !ids.isEmpty else { return nil }
        return profiles.first { $0.displayIDs.sorted() == ids.sorted() }
    }
}

struct Preset: Identifiable, Codable {
    let id: UUID
    var name: String
    var isEnabled: Bool
    var isMaster: Bool
    var triggers: [Trigger]
    var appTargets: [AppTarget]
    var activationGroups: [ActivationGroup]
    var customSnapZones: [CustomSnapZone]
    var snappingEnabled = false
    var snappingRequiresOption = false
    var snappingShowsPreview = true
    var snapProfiles: [SnapLayoutProfile] = []
    var automaticSnapProfiles = false
    var createdAt: Date
    var modifiedAt: Date

    // Resilient decoding: skip triggers that fail to decode (e.g. renamed gestures)
    // instead of failing the entire preset load.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        isMaster = try container.decode(Bool.self, forKey: .isMaster)
        appTargets = try container.decode([AppTarget].self, forKey: .appTargets)
        activationGroups = try container.decodeIfPresent([ActivationGroup].self, forKey: .activationGroups) ?? []
        customSnapZones = try container.decodeIfPresent([CustomSnapZone].self, forKey: .customSnapZones) ?? []
        snappingEnabled = try container.decodeIfPresent(Bool.self, forKey: .snappingEnabled) ?? customSnapZones.contains(where: \.isEnabled)
        snappingRequiresOption = try container.decodeIfPresent(Bool.self, forKey: .snappingRequiresOption) ?? false
        snappingShowsPreview = try container.decodeIfPresent(Bool.self, forKey: .snappingShowsPreview) ?? true
        snapProfiles = try container.decodeIfPresent([SnapLayoutProfile].self, forKey: .snapProfiles) ?? []
        automaticSnapProfiles = try container.decodeIfPresent(Bool.self, forKey: .automaticSnapProfiles) ?? false
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        modifiedAt = try container.decode(Date.self, forKey: .modifiedAt)

        // Decode triggers one-by-one, skipping any that fail
        var triggersContainer = try container.nestedUnkeyedContainer(forKey: .triggers)
        var decodedTriggers: [Trigger] = []
        while !triggersContainer.isAtEnd {
            if let trigger = try? triggersContainer.decode(Trigger.self) {
                decodedTriggers.append(trigger)
            } else {
                // Skip the broken entry by decoding it as a generic JSON object
                _ = try? triggersContainer.decode(AnyCodable.self)
            }
        }
        triggers = decodedTriggers
        if decodedTriggers.count < (try? container.decode([AnyCodable].self, forKey: .triggers))?.count ?? 0 {
            NSLog("[PresetManager] Warning: some triggers were skipped due to decode errors")
        }
    }

    init(name: String, isMaster: Bool = false) {
        self.id = UUID()
        self.name = name
        self.isEnabled = true
        self.isMaster = isMaster
        self.triggers = []
        self.appTargets = [.allApps]
        self.activationGroups = []
        self.customSnapZones = []
        self.createdAt = Date()
        self.modifiedAt = Date()
    }

    /// Unified overview: the category is a presentation filter, not a new
    /// execution scope. Group/app/global boundaries must never bleed together.
    func overviewTriggers(for appTarget: AppTarget, groupID: UUID?,
                          category: TriggerCategory) -> [Trigger] {
        let scoped = triggers.filter { trigger in
            if let groupID { return trigger.activationGroupID == groupID }
            return trigger.activationGroupID == nil && trigger.appBundleID == appTarget.bundleID
        }
        return scoped.filter { category == .all || $0.input.category == category }
            .sorted { a, b in
                let ai = TriggerCategory.inputCategories.firstIndex(of: a.input.category) ?? Int.max
                let bi = TriggerCategory.inputCategories.firstIndex(of: b.input.category) ?? Int.max
                if ai != bi { return ai < bi }
                return a.order == b.order ? a.displayName < b.displayName : a.order < b.order
            }
    }

    func triggers(for appTarget: AppTarget, category: TriggerCategory) -> [Trigger] {
        triggers.filter { trigger in
            trigger.input.category == category &&
            trigger.activationGroupID == nil &&
            trigger.appBundleID == appTarget.bundleID
        }.sorted { $0.order < $1.order }
    }

    func triggers(forGroup id: UUID, category: TriggerCategory) -> [Trigger] {
        triggers.filter { $0.activationGroupID == id && $0.input.category == category }
            .sorted { $0.order < $1.order }
    }

    func movePeers(of trigger: Trigger) -> [Trigger] {
        TriggerListQuery.sorted(triggers.filter {
            $0.activationGroupID == trigger.activationGroupID &&
            (trigger.activationGroupID != nil || $0.appBundleID == trigger.appBundleID) &&
            $0.input.category == trigger.input.category && $0.isFavorite == trigger.isFavorite
        }, mode: .manual)
    }
    func canMoveTrigger(_ id: UUID, offset: Int) -> Bool {
        guard offset == -1 || offset == 1, let trigger = triggers.first(where: { $0.id == id }) else { return false }
        let peers = movePeers(of: trigger)
        guard let index = peers.firstIndex(where: { $0.id == id }) else { return false }
        return peers.indices.contains(index + offset)
    }
    @discardableResult
    mutating func moveTrigger(_ id: UUID, offset: Int) -> Bool {
        guard canMoveTrigger(id, offset: offset), let trigger = triggers.first(where: { $0.id == id }) else { return false }
        var peers = movePeers(of: trigger)
        guard let index = peers.firstIndex(where: { $0.id == id }) else { return false }
        peers.swapAt(index, index + offset)
        let order = Dictionary(uniqueKeysWithValues: peers.enumerated().map { ($0.element.id, $0.offset) })
        for index in triggers.indices { if let value = order[triggers[index].id] { triggers[index].order = value } }
        modifiedAt = Date(); return true
    }

    mutating func addTrigger(_ trigger: Trigger) {
        var trigger = trigger
        let peers = movePeers(of: trigger)
        if let maximum = peers.map(\.order).max(), maximum == Int.max {
            let order = Dictionary(uniqueKeysWithValues: peers.enumerated().map { ($0.element.id, $0.offset) })
            for index in triggers.indices { if let value = order[triggers[index].id] { triggers[index].order = value } }
            trigger.order = peers.count
        } else { trigger.order = (peers.map(\.order).max() ?? -1) + 1 }
        triggers.append(trigger)
        modifiedAt = Date()
    }

    mutating func removeTrigger(id: UUID) {
        triggers.removeAll { $0.id == id }
        modifiedAt = Date()
    }

    mutating func updateTrigger(_ trigger: Trigger) {
        if let index = triggers.firstIndex(where: { $0.id == trigger.id }) {
            triggers[index] = trigger
            modifiedAt = Date()
        }
    }
}
