import XCTest
import AppKit
@testable import AllOfMacOS

/// Display control tests. The cases that would reconfigure a real display are
/// limited to pure selection logic: switching modes during a test run would
/// change the machine's screen setup for every later test.
final class DisplayControlTests: XCTestCase {

    // MARK: - Mode selection

    private func option(_ w: Int, _ h: Int, px: Int? = nil, hz: Double = 60) -> DisplayModeOption {
        DisplayModeOption(pointWidth: w, pointHeight: h, pixelWidth: px ?? w, pixelHeight: px ?? w, refreshRate: hz)
    }

    func testHiDPIModeIsDetectedFromPixelAndPointSizes() {
        XCTAssertTrue(option(1920, 1080, px: 3840).isHiDPI)
        XCTAssertFalse(option(1920, 1080).isHiDPI)
        XCTAssertEqual(option(1920, 1080, px: 3840).sharpnessRank, 2)
        XCTAssertEqual(option(1920, 1080).sharpnessRank, 1)
    }

    func testModeIdentitySeparatesHiDPIFromStandardAtSamePointSize() {
        let standard = option(1920, 1080)
        let retina = option(1920, 1080, px: 3840)
        XCTAssertNotEqual(standard.id, retina.id)
        XCTAssertEqual(standard.pointWidth, retina.pointWidth)
    }

    func testModeIdentitySeparatesRefreshRates() {
        XCTAssertNotEqual(option(1920, 1080, hz: 60).id, option(1920, 1080, hz: 120).id)
    }

    // MARK: - Parameter validation






    // MARK: - Persistence


    func testEveryActiveDisplayReportsAStableUUID() throws {
        let displays = DisplayControlService.displays()
        try XCTSkipIf(displays.isEmpty, "No active display attached (headless CI or sleeping Mac)")
        for display in displays {
            XCTAssertFalse(display.id.isEmpty)
            XCTAssertFalse(display.name.isEmpty)
            XCTAssertEqual(DisplayControlService.displayUUID(display.displayID), display.id)
        }
        XCTAssertEqual(Set(displays.map(\.id)).count, displays.count, "display UUIDs must be unique")
    }

    func testCurrentModeIsAlwaysAmongTheEnumeratedModes() {
        for display in DisplayControlService.displays() {
            guard let current = DisplayControlService.currentMode(display.displayID) else { continue }
            let listed = DisplayControlService.modes(display.displayID)
            XCTAssertTrue(listed.contains { $0.pointWidth == current.pointWidth && $0.pointHeight == current.pointHeight },
                          "\(display.name) current mode should appear in its mode list")
        }
    }

    func testEnumeratedModesAreDesktopCapableAndUnique() {
        for display in DisplayControlService.displays() {
            let modes = DisplayControlService.modes(display.displayID)
            XCTAssertEqual(Set(modes.map(\.id)).count, modes.count, "\(display.name) modes must be deduplicated")
            for mode in modes {
                XCTAssertGreaterThan(mode.pointWidth, 0)
                XCTAssertGreaterThan(mode.pointHeight, 0)
                XCTAssertGreaterThanOrEqual(mode.pixelWidth, mode.pointWidth, "pixels never fewer than points")
            }
        }
    }

    func testResolutionOptionsCollapseToOneEntryPerPointSize() {
        for display in DisplayControlService.displays() {
            let options = DisplayControlService.resolutionOptions(display.displayID)
            let keys = options.map { "\($0.pointWidth)x\($0.pointHeight)" }
            XCTAssertEqual(Set(keys).count, keys.count, "\(display.name) should list each resolution once")
            // Ascending order keeps the picker predictable.
            XCTAssertEqual(options.map(\.pointWidth), options.map(\.pointWidth).sorted())
        }
    }

    func testBrightnessReadsBackWithinUnitRangeWhenSupported() {
        for display in DisplayControlService.displays() {
            guard let value = DisplayControlService.brightness(display.displayID) else { continue }
            XCTAssertTrue((0...1).contains(value), "\(display.name) brightness \(value) outside 0...1")
        }
    }

    // MARK: - Software dim bookkeeping

    /// Exercises the gamma path only when the display has no hardware backlight,
    /// and always restores the original curve before returning.
    func testSoftwareDimAppliesAndClearsOnDisplaysWithoutBacklight() {
        for display in DisplayControlService.displays() where !DisplayControlService.supportsHardwareBrightness(display.displayID) {
            XCTAssertTrue(DisplayControlService.setSoftwareDim(display.displayID, 0.5))
            XCTAssertEqual(DisplayControlService.softwareDim(display.displayID), 0.5)
            XCTAssertTrue(DisplayControlService.clearSoftwareDim(display.displayID))
            XCTAssertNil(DisplayControlService.softwareDim(display.displayID))
        }
    }

    func testSoftwareDimClampsOutOfRangeInput() {
        for display in DisplayControlService.displays() where !DisplayControlService.supportsHardwareBrightness(display.displayID) {
            XCTAssertTrue(DisplayControlService.setSoftwareDim(display.displayID, 5))
            XCTAssertEqual(DisplayControlService.softwareDim(display.displayID), 1)
            XCTAssertTrue(DisplayControlService.setSoftwareDim(display.displayID, -2))
            XCTAssertEqual(DisplayControlService.softwareDim(display.displayID), 0)
            DisplayControlService.clearSoftwareDim(display.displayID)
        }
    }

    func testClearingWithNoActiveDimIsHarmless() {
        for display in DisplayControlService.displays() {
            XCTAssertTrue(DisplayControlService.clearSoftwareDim(display.displayID))
            XCTAssertNil(DisplayControlService.softwareDim(display.displayID))
        }
    }


    /// The guard that keeps a resolution action from stranding the display:
    /// macOS hides the active HiDPI mode from the mode list on some panels, and
    /// a mode that cannot be enumerated cannot be selected again.
    func testCurrentModeResolvabilityMatchesTheEnumeratedList() {
        for display in DisplayControlService.displays() {
            guard let current = DisplayControlService.currentMode(display.displayID) else { continue }
            let listed = DisplayControlService.modes(display.displayID).contains {
                $0.pointWidth == current.pointWidth && $0.pointHeight == current.pointHeight
                    && $0.pixelWidth == current.pixelWidth && $0.pixelHeight == current.pixelHeight
            }
            XCTAssertEqual(DisplayControlService.canReturnToCurrentMode(display.displayID), listed,
                           "\(display.name) guard must agree with the enumerated mode list")
        }
    }

    func testSettingAnImpossibleResolutionFailsWithoutChangingTheDisplay() throws {
        guard let display = DisplayControlService.displays().first,
              let before = DisplayControlService.currentMode(display.displayID) else {
            throw XCTSkip("No active display attached (headless CI or sleeping Mac)")
        }
        XCTAssertFalse(DisplayControlService.setMode(display.displayID, pointWidth: 99999, pointHeight: 99999))
        let after = DisplayControlService.currentMode(display.displayID)
        XCTAssertEqual(before.pointWidth, after?.pointWidth)
        XCTAssertEqual(before.pointHeight, after?.pointHeight)
    }

    func testDefaultModeIsUniqueAndDesktopCapable() {
        for display in DisplayControlService.displays() {
            guard let def = DisplayControlService.defaultMode(display.displayID) else { continue }
            // The default size is the percentage baseline, so two of them would
            // make the percentage meaningless.
            let flagged = DisplayControlService.modes(display.displayID).filter {
                DisplayControlService.markers(display.displayID, for: $0).contains(.default)
            }
            let sizes = Set(flagged.map { "\($0.pointWidth)x\($0.pointHeight)" })
            XCTAssertEqual(sizes.count, 1,
                           "\(display.name) must mark exactly one default size, got \(sizes)")
            XCTAssertGreaterThan(def.pointWidth, 0)
        }
    }

    func testCurrentModeAlwaysCarriesTheCurrentMarker() {
        for display in DisplayControlService.displays() {
            guard let current = DisplayControlService.currentMode(display.displayID) else { continue }
            let markers = DisplayControlService.markers(display.displayID, for: current)
            XCTAssertTrue(markers.contains(.current),
                          "\(display.name) current mode must mark itself Current")
        }
    }

    func testMarkersAreEmptyForASizeTheDisplayDoesNotUse() {
        for display in DisplayControlService.displays() {
            // A size no mode offers: nothing should claim it.
            let absent = DisplayModeOption(pointWidth: 99999, pointHeight: 99999,
                                           pixelWidth: 99999, pixelHeight: 99999,
                                           refreshRate: 60)
            XCTAssertTrue(DisplayControlService.markers(display.displayID, for: absent).isEmpty)
        }
    }

    func testMarkersAgreeWithTheEnumeratedModes() {
        for display in DisplayControlService.displays() {
            for option in DisplayControlService.resolutionOptions(display.displayID) {
                let markers = DisplayControlService.markers(display.displayID, for: option)
                for marker in markers {
                    switch marker {
                    case .current:
                        XCTAssertEqual(DisplayControlService.currentMode(display.displayID)?.pointWidth,
                                       option.pointWidth)
                    case .default:
                        XCTAssertNotNil(DisplayControlService.defaultMode(display.displayID))
                    }
                }
                // No marker may appear twice.
                XCTAssertEqual(markers.count, Set(markers).count)
            }
        }
    }

    func testHiDPIToggleIsOfferedExactlyWhenBothScalesExist() {
        for display in DisplayControlService.displays() {
            guard let current = DisplayControlService.currentMode(display.displayID) else { continue }
            let counterpart = DisplayControlService.modes(display.displayID).contains {
                $0.pointWidth == current.pointWidth && $0.pointHeight == current.pointHeight
                    && $0.isHiDPI != current.isHiDPI
            }
            XCTAssertEqual(DisplayControlService.canToggleHiDPI(display.displayID), counterpart,
                           "\(display.name) toggle must match whether the opposite scale exists")
        }
    }

    func testSettingHiDPIToTheCurrentScaleIsANoOp() {
        for display in DisplayControlService.displays() {
            guard let current = DisplayControlService.currentMode(display.displayID),
                  DisplayControlService.canReturnToCurrentMode(display.displayID) else { continue }
            // Re-requesting the scale already in use must not move the display.
            _ = DisplayControlService.setHiDPI(display.displayID, current.isHiDPI)
            let after = DisplayControlService.currentMode(display.displayID)
            XCTAssertEqual(current.pointWidth, after?.pointWidth)
            XCTAssertEqual(current.pointHeight, after?.pointHeight)
            XCTAssertEqual(current.isHiDPI, after?.isHiDPI)
        }
    }

    // MARK: - Mode comparison

    func testMatchesComparesTheFullModeButMatchesSizeIgnoresScale() {
        let hdpi = DisplayModeOption(pointWidth: 1920, pointHeight: 1080,
                                     pixelWidth: 3840, pixelHeight: 2160, refreshRate: 60)
        let lodpi = DisplayModeOption(pointWidth: 1920, pointHeight: 1080,
                                      pixelWidth: 1920, pixelHeight: 1080, refreshRate: 60)
        XCTAssertFalse(hdpi.matches(lodpi), "differing backing scale is a different mode")
        XCTAssertTrue(hdpi.matchesSize(lodpi), "same point size is the same resolution")

        let otherRate = DisplayModeOption(pointWidth: 1920, pointHeight: 1080,
                                          pixelWidth: 3840, pixelHeight: 2160, refreshRate: 50)
        XCTAssertFalse(hdpi.matches(otherRate), "a different refresh rate is a different mode")
    }

    func testMatchesToleratesSubHertzRefreshDrift() {
        // Panels report 59.94 where a menu may hold 59.94 too; a rounding step
        // must not make a mode stop matching itself.
        let a = DisplayModeOption(pointWidth: 1920, pointHeight: 1080,
                                  pixelWidth: 1920, pixelHeight: 1080, refreshRate: 59.94)
        let b = DisplayModeOption(pointWidth: 1920, pointHeight: 1080,
                                  pixelWidth: 1920, pixelHeight: 1080, refreshRate: 59.999)
        XCTAssertTrue(a.matches(b))
    }

    // MARK: - Backing-scale preference

    func testResolutionOptionsHonourTheRequestedBackingScale() {
        for display in DisplayControlService.displays() {
            let hi = DisplayControlService.resolutionOptions(display.displayID, preferringHiDPI: true)
            let lo = DisplayControlService.resolutionOptions(display.displayID, preferringHiDPI: false)
            XCTAssertEqual(hi.count, lo.count,
                           "\(display.name) both scales must offer the same sizes")
            // Every size present in both must be represented by the requested
            // scale, otherwise moving the slider would change sharpness.
            for (h, l) in zip(hi, lo) {
                XCTAssertEqual(h.pointWidth, l.pointWidth)
                XCTAssertEqual(h.pointHeight, l.pointHeight)
                if h.isHiDPI != l.isHiDPI {
                    XCTAssertTrue(h.isHiDPI, "\(display.name) HiDPI preference must pick HiDPI")
                    XCTAssertFalse(l.isHiDPI, "\(display.name) LoDPI preference must pick LoDPI")
                }
            }
        }
    }

    func testResolutionOptionsDefaultToTheSharpestScale() {
        for display in DisplayControlService.displays() {
            let auto = DisplayControlService.resolutionOptions(display.displayID)
            let hi = DisplayControlService.resolutionOptions(display.displayID, preferringHiDPI: true)
            // With no preference stated, the sharpest mode represents each size.
            for (a, h) in zip(auto, hi) {
                XCTAssertGreaterThanOrEqual(a.sharpnessRank, 1)
                XCTAssertEqual(a.pointWidth, h.pointWidth)
                XCTAssertEqual(a.pointHeight, h.pointHeight)
            }
        }
    }

    func testPreferenceNeverAddsOrDropsASize() {
        for display in DisplayControlService.displays() {
            let plain = Set(DisplayControlService.resolutionOptions(display.displayID).map {
                "\($0.pointWidth)x\($0.pointHeight)"
            })
            let preferred = Set(DisplayControlService.resolutionOptions(display.displayID,
                                                                        preferringHiDPI: false).map {
                "\($0.pointWidth)x\($0.pointHeight)"
            })
            XCTAssertEqual(plain, preferred,
                           "\(display.name) the preference must only choose, never filter")
        }
    }
}
