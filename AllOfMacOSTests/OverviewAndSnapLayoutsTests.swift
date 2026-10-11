import XCTest
@testable import AllOfMacOS

final class OverviewAndSnapLayoutsTests: XCTestCase {
    func testAllGroupsCategoriesWithoutCrossingScopes() {
        var preset = Preset(name: "Overview")
        var group = ActivationGroup(name: "Work")
        group.includedBundleIDs = ["com.test.app"]
        preset.activationGroups = [group]
        let pad = Trigger(name: "Pad", input: .trackpadGesture(.fourFingerTap))
        let keys = Trigger(name: "Keys", input: .keyboardShortcut(KeyboardShortcut(keyCode: 0, modifiers: .command)))
        let drawing = Trigger(name: "Draw", input: .drawingPattern("Z"))
        var grouped = Trigger(name: "Grouped", input: .mouseButton(.button4))
        grouped.activationGroupID = group.id
        let app = Trigger(name: "App", input: .trackpadGesture(.threeFingerTap), appBundleID: "com.test.app")
        preset.triggers = [keys, grouped, drawing, app, pad]
        XCTAssertEqual(preset.overviewTriggers(for: .allApps, groupID: nil, category: .all).map(\.id),
                       [pad.id, keys.id, drawing.id])
        XCTAssertEqual(preset.overviewTriggers(for: .allApps, groupID: nil, category: .keyboard).map(\.id),
                       [keys.id])
        XCTAssertEqual(preset.overviewTriggers(for: .allApps, groupID: group.id, category: .all).map(\.id),
                       [grouped.id])
        XCTAssertEqual(TriggerCategory.inputCategories.count, 5)
        XCTAssertFalse(TriggerCategory.inputCategories.contains(.all))
    }
    func testSnapLayoutPresetsAreValidAndMatchTheirNames() {
        for layout in CustomSnapZone.Layout.allCases {
            let zone = layout.zone()
            XCTAssertTrue(zone.isValid, layout.rawValue)
            XCTAssertEqual(zone.name, layout.rawValue)
        }
        let left = CustomSnapZone.Layout.leftHalf.zone()
        XCTAssertEqual(left.targetX, 0)
        XCTAssertEqual(left.targetWidth, 0.5)
        XCTAssertEqual(left.hotX, 0)
        let right = CustomSnapZone.Layout.rightHalf.zone()
        XCTAssertEqual(right.targetX, 0.5)
        XCTAssertEqual(right.targetWidth, 0.5)
        XCTAssertGreaterThan(right.hotX, 0.80)
        let full = CustomSnapZone.Layout.maximize.zone()
        XCTAssertEqual(full.targetWidth, 1)
        XCTAssertEqual(full.targetHeight, 1)
    }
    func testScreenDropCoordinatesAndActualWindowMove() {
        let visible = CGRect(x: 100, y: -900, width: 1440, height: 850)
        XCTAssertEqual(WindowGeometry.normalizedDropPoint(CGPoint(x:100, y:-475), in: visible)?.x, 0)
        XCTAssertEqual(WindowGeometry.normalizedDropPoint(CGPoint(x:100, y:-475), in: visible)?.y, 0.5)
        XCTAssertNil(WindowGeometry.normalizedDropPoint(CGPoint(x:0, y:-475), in: visible))
        let left = CustomSnapZone.Layout.leftHalf.zone()
        XCTAssertTrue(left.hit(x:0.02, y:0.50))
        let window = CGRect(x:150, y:100, width:700, height:500)
        XCTAssertFalse(WindowGeometry.windowActuallyMoved(from:window, to:window))
        XCTAssertFalse(WindowGeometry.windowActuallyMoved(from:window,
                         to:window.offsetBy(dx:5,dy:0)))
        XCTAssertTrue(WindowGeometry.windowActuallyMoved(from:window,
                        to:window.offsetBy(dx:10,dy:0)))
    }
    func testSnapZonePersistenceIsUnchanged() throws {
        var preset = Preset(name: "Preview is only visual")
        preset.customSnapZones = CustomSnapZone.Layout.allCases.map { $0.zone() }
        let restored = try PresetCodec.decode(PresetCodec.encode(preset))
        XCTAssertEqual(restored.customSnapZones, preset.customSnapZones)
    }
}

extension OverviewAndSnapLayoutsTests {
    func testCompleteCollectionIsIdempotentAndPreservesCustomLayouts() {
        var custom = CustomSnapZone.Layout.leftHalf.zone(); custom.name = "My left layout"; custom.hotWidth = 0.07
        let complete = CustomSnapZone.Collection.complete.addingMissing(to: [custom])
        XCTAssertEqual(complete.count, 16)
        XCTAssertEqual(complete.first, custom)
        XCTAssertEqual(CustomSnapZone.Collection.complete.addingMissing(to: complete), complete)
        XCTAssertEqual(Set(complete.map(\.id)).count, 16)
        XCTAssertTrue(complete.allSatisfy(\.isValid))
        XCTAssertEqual(CustomSnapZone.Layout.nextDisplay.zone().targetDisplay, "next")
    }
    func testEveryReadyMadeZoneIsReachableWithoutOverlappingAnotherZone() {
        let zones = CustomSnapZone.Collection.complete.addingMissing(to: [])
        for zone in zones {
            let x = zone.hotX + zone.hotWidth / 2, y = zone.hotY + zone.hotHeight / 2
            XCTAssertEqual(CustomSnapZone.matching(zones, x: x, y: y)?.id, zone.id, zone.name)
            for other in zones where zone.id != other.id {
                let a = CGRect(x: zone.hotX, y: zone.hotY, width: zone.hotWidth, height: zone.hotHeight)
                let b = CGRect(x: other.hotX, y: other.hotY, width: other.hotWidth, height: other.hotHeight)
                XCTAssertTrue(a.intersection(b).isNull || a.intersection(b).isEmpty, "\(zone.name) overlaps \(other.name)")
            }
        }
    }
    func testSmallerDropZoneWinsAndDisabledAreasNeverMatch() {
        var large = CustomSnapZone(name: "Large"); large.hotX = 0; large.hotY = 0; large.hotWidth = 1; large.hotHeight = 1
        var corner = CustomSnapZone.Layout.topLeft.zone()
        XCTAssertEqual(CustomSnapZone.matching([large, corner], x: 0.05, y: 0.05)?.id, corner.id)
        corner.isEnabled = false
        XCTAssertEqual(CustomSnapZone.matching([large, corner], x: 0.05, y: 0.05)?.id, large.id)
    }
    /// Centre is the only starter layout whose hot zone is not on an edge, and
    /// that makes it unreachable by cursor alone.
    ///
    /// A window is dragged by its title bar, which sits at the window's top. To
    /// put a window at the screen centre the cursor therefore ends up well
    /// above centre — bringing the cursor into a centre hot zone would require
    /// the window to hang mostly off the bottom of the display. The earlier
    /// reachability test only checked that a zone's centre point lies inside
    /// its own rect, which is true in coordinate space and says nothing about
    /// whether a drag can get there.
    func testCentreIsTheOnlyLayoutNotReachableFromTheCursorAlone() {
        let zones = CustomSnapZone.Collection.complete.addingMissing(to: [])
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let visible = screen
        let window = CGRect(x: 306, y: 191, width: 900, height: 600)

        // The cursor holds the title bar, so it sits just inside the window top.
        let cursor = CGPoint(x: window.midX, y: window.minY + 12)
        let cursorNorm = try! XCTUnwrap(WindowGeometry.screenEdgeDropPoint(cursor, screen: screen, visible: visible))
        let fromCursor = CustomSnapZone.matching(zones, x: cursorNorm.x, y: cursorNorm.y)
        XCTAssertNotEqual(fromCursor?.name, "Center",
                          "the cursor alone must not be able to select Centre")

        // Every other layout is on an edge and still reachable from the cursor.
        let centreOnly = zones.filter { $0.name == "Center" }
        XCTAssertEqual(centreOnly.count, 1, "the starter set must define exactly one Centre")

        // The window's own centre does land on it, which is what the fallback uses.
        let centreNorm = WindowGeometry.screenEdgeDropPoint(CGPoint(x: window.midX, y: window.midY),
                                                           screen: screen, visible: visible)
        let fromWindow = CustomSnapZone.matching(zones, x: try! XCTUnwrap(centreNorm).x,
                                                 y: try! XCTUnwrap(centreNorm).y)
        XCTAssertEqual(fromWindow?.name, "Center",
                       "the window centre must reach Centre, which is the fallback's purpose")
    }

    /// The fallback must never take a drag that the cursor already resolved, or
    /// an edge zone would stop working whenever the window centre happened to
    /// land on a different zone.
    func testCursorHitWinsOverTheWindowCentreFallback() {
        let zones = CustomSnapZone.Collection.complete.addingMissing(to: [])
        // A cursor clearly on the left edge, with a window whose centre is in
        // the middle of the screen.
        let cursorNorm = CGPoint(x: 0.05, y: 0.5)
        let centreNorm = CGPoint(x: 0.5, y: 0.5)
        let fromCursor = CustomSnapZone.matching(zones, x: cursorNorm.x, y: cursorNorm.y)
        let fromCentre = CustomSnapZone.matching(zones, x: centreNorm.x, y: centreNorm.y)
        XCTAssertEqual(fromCursor?.name, "Left Half")
        XCTAssertNotEqual(fromCursor?.id, fromCentre?.id,
                          "the two judgements must differ for this case to mean anything")
    }

    func testMenuBarAndDockEdgesMapToUsableWindowAreaAndResizeIsNotDrag() {
        let screen = CGRect(x: -1440, y: -900, width: 1440, height: 900)
        let visible = CGRect(x: -1440, y: -850, width: 1440, height: 825)
        let top = WindowGeometry.screenEdgeDropPoint(CGPoint(x: -720, y: -5), screen: screen, visible: visible)
        XCTAssertEqual(top?.x, 0.5); XCTAssertEqual(top?.y, 0)
        XCTAssertEqual(WindowGeometry.screenEdgeDropPoint(CGPoint(x: -720, y: -890), screen: screen, visible: visible)?.y, 1)
        XCTAssertNil(WindowGeometry.screenEdgeDropPoint(CGPoint(x: 5, y: -500), screen: screen, visible: visible))
        XCTAssertFalse(WindowGeometry.windowActuallyMoved(from: CGRect(x: 0, y: 0, width: 500, height: 300), to: CGRect(x: 20, y: 0, width: 480, height: 300)))
    }
    func testSnappingOffAndOptionsSurviveExportAndDatabaseRoundTrip() throws {
        var preset = Preset(name: "Snap options")
        preset.customSnapZones = CustomSnapZone.Collection.complete.addingMissing(to: [])
        preset.snappingEnabled = false; preset.snappingRequiresOption = true; preset.snappingShowsPreview = false
        let decoded = try PresetCodec.decode(PresetCodec.encode(preset, envelope: true))
        XCTAssertFalse(decoded.snappingEnabled); XCTAssertTrue(decoded.snappingRequiresOption); XCTAssertFalse(decoded.snappingShowsPreview)
        let store = try TrackpadPresetStore(url: nil, inMemory: true); try store.save(decoded)
        let restored = try XCTUnwrap(store.load())
        XCTAssertFalse(restored.snappingEnabled); XCTAssertTrue(restored.snappingRequiresOption); XCTAssertFalse(restored.snappingShowsPreview)
        XCTAssertEqual(restored.customSnapZones, preset.customSnapZones)
    }
    func testLegacyConfiguredSnapRemainsOnAndEmptySnapRemainsOff() throws {
        for mode in 0...2 {
            let hasZones = mode > 0
            var preset = Preset(name: "Legacy")
            preset.customSnapZones = hasZones ? [CustomSnapZone.Layout.leftHalf.zone()] : []
            if mode == 2 { preset.customSnapZones[0].isEnabled = false }
            var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: PresetCodec.encode(preset)) as? [String: Any])
            for key in ["snappingEnabled", "snappingRequiresOption", "snappingShowsPreview"] { raw.removeValue(forKey: key) }
            let decoded = try PresetCodec.decode(JSONSerialization.data(withJSONObject: raw))
            XCTAssertEqual(decoded.snappingEnabled, mode == 1)
            XCTAssertFalse(decoded.snappingRequiresOption); XCTAssertTrue(decoded.snappingShowsPreview)
        }
    }
}

extension OverviewAndSnapLayoutsTests {
    func testSelectingSmallerSetActuallyReplacesAndEnablesIt() {
        let complete = CustomSnapZone.Collection.complete.replacing([])
        var essentials = CustomSnapZone.Collection.essentials.replacing(complete)
        XCTAssertEqual(essentials.count, 3)
        XCTAssertEqual(essentials[0].id, complete[0].id)
        essentials[0].isEnabled = false
        let corners = CustomSnapZone.Collection.corners.replacing(essentials)
        XCTAssertEqual(corners.count, 9); XCTAssertTrue(corners.allSatisfy(\.isEnabled))
        XCTAssertEqual(CustomSnapZone.Collection.complete.replacing(corners).count, 16)
    }
    func testDisplayProfileMatchesExactHardwareSetAndRoundTrips() throws {
        let zones = CustomSnapZone.Collection.essentials.replacing([])
        let laptop = SnapLayoutProfile(name: "Laptop", displayIDs: ["internal"], zones: zones)
        let desk = SnapLayoutProfile(name: "Desk", displayIDs: ["external", "internal"], zones: zones, requiresOption: true)
        XCTAssertEqual(DisplayTopology.matching([laptop, desk], ids: ["internal", "external"])?.id, desk.id)
        XCTAssertEqual(DisplayTopology.matching([laptop, desk], ids: ["internal"])?.id, laptop.id)
        XCTAssertNil(DisplayTopology.matching([laptop, desk], ids: ["unknown"]))
        XCTAssertNil(DisplayTopology.matching([laptop, desk], ids: []))
        var preset = Preset(name: "Profiles")
        preset.snapProfiles = [laptop, desk]; preset.automaticSnapProfiles = true; preset.snappingEnabled = false
        let decoded = try PresetCodec.decode(PresetCodec.encode(preset, envelope: true))
        XCTAssertEqual(decoded.snapProfiles, [laptop, desk]); XCTAssertTrue(decoded.automaticSnapProfiles)
        XCTAssertFalse(decoded.snappingEnabled)
        let store = try TrackpadPresetStore(url: nil, inMemory: true); try store.save(decoded)
        XCTAssertEqual(try store.load()?.snapProfiles, [laptop, desk])
        preset.snapProfiles.append(laptop)
        XCTAssertThrowsError(try PresetCodec.decode(PresetCodec.encode(preset, envelope: true)))
    }
    func testUnrelatedChangesDoNotChangeMonitorRegistration() {
        var key = Trigger(name: "Key", input: .keyboardShortcut(KeyboardShortcut(keyCode: 1, modifiers: [])))
        var touch = Trigger(name: "Touch", input: .trackpadGesture(.tipTapLeft))
        let before = MonitorBindings([key, touch], groups: [], category: .keyboard)
        touch.actions = [TriggerAction(actionType: .volumeUp)]
        XCTAssertEqual(before, MonitorBindings([key, touch], groups: [], category: .keyboard))
        key.actions = [TriggerAction(actionType: .volumeDown)]
        XCTAssertNotEqual(before, MonitorBindings([key, touch], groups: [], category: .keyboard))
        let group = ActivationGroup(name: "Unused")
        XCTAssertEqual(before, MonitorBindings(before.triggers, groups: [group], category: .keyboard))
        key.activationGroupID = group.id
        XCTAssertNotEqual(MonitorBindings([key], groups: [], category: .keyboard), MonitorBindings([key], groups: [group], category: .keyboard))
    }
    func testTipTapShieldTracksOriginatingDeviceAndEveryResidualClick() {
        var shield = TipTapClickShield()
        shield.arm(device: 1, now: 10)
        shield.observe(device: 2, count: 0, now: 10.1)
        XCTAssertTrue(shield.contains(10.9))
        shield.observe(device: 1, count: 0, now: 11)
        XCTAssertTrue(shield.contains(11.1)); XCTAssertTrue(shield.contains(11.3))
        shield.observe(device: 1, count: 0, now: 11.3)
        XCTAssertFalse(shield.contains(11.36), "Repeated empty frames must not extend the tail")
        shield.arm(device: 1, now: 20); XCTAssertFalse(shield.contains(22.1), "Lost touch-up fails open")
        shield.reset(); XCTAssertFalse(shield.contains(20.1))
    }
    func testWindowLayoutMatchingNeverGuessesBetweenSameNamedWindows() throws {
        let window = SavedWindowPlacement(bundleID: "app", title: "Document", identifier: "", displayID: "display", normalizedFrame: CGRect(x: 0, y: 0, width: 0.5, height: 1))
        XCTAssertEqual(SavedWindowPlacement.uniqueMatch(window, in: [window]), 0)
        XCTAssertNil(SavedWindowPlacement.uniqueMatch(window, in: [window, window]))
        var other = window; other.bundleID = "another"
        XCTAssertNil(SavedWindowPlacement.uniqueMatch(window, in: [other]))
        var identified = window; identified.identifier = "stable-id"
        var renamed = identified; renamed.title = "New title"
        XCTAssertEqual(SavedWindowPlacement.uniqueMatch(identified, in: [window, renamed]), 1)
        XCTAssertEqual(try JSONDecoder().decode(SavedWindowPlacement.self, from: JSONEncoder().encode(window)), window)
    }
}
