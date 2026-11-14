import XCTest
@testable import AllOfMacOS

final class SystemToolsCatalogTests: XCTestCase {
    func testEveryOfferedToolBelongsToExactlyOneSection() {
        var seen: [SystemToolID: SystemToolGroup] = [:]
        for info in SystemToolCatalog.all {
            XCTAssertNil(seen[info.id], "\(info.id.rawValue) is listed twice")
            seen[info.id] = info.group
        }
        for group in SystemToolGroup.allCases {
            let listed = SystemToolCatalog.tools(in: group)
            XCTAssertFalse(listed.isEmpty, "\(group.name) has no tools")
            for info in listed { XCTAssertEqual(info.group, group) }
        }
        // The sections are the page's order and every one of them is offered.
        XCTAssertEqual(SystemToolCatalog.all.count, SystemToolID.allCases.count)
    }

    func testNoRemovedIDIsOffered() {
        let offered = Set(SystemToolCatalog.all.map(\.id.rawValue))
        for removed in SystemToolMigration.removed {
            XCTAssertFalse(offered.contains(removed), "removed id \(removed) is still offered")
        }
    }

    func testEveryGroupIsReachableFromTheInventory() {
        let inventory = Set(SystemToolsInventory.groups.map(\.name))
        for group in SystemToolGroup.allCases {
            // Homebrew is only listed when brew is installed; the rest always are.
            if group == .homebrew { continue }
            XCTAssertTrue(inventory.contains(group.name), "\(group.name) is missing from the inventory")
        }
    }
}

final class SystemToolMigrationTests: XCTestCase {
    func testMergedIdsMapToTheSurvivingTool() {
        let expected: [String: SystemToolID] = [
            "topCPU": .activity, "topMemory": .activity,
            "ejectAll": .eject, "ejectDisk": .eject,
            "backupNow": .timeMachine, "backupStatus": .timeMachine,
            "portLookup": .ports, "listeningPorts": .ports,
            "copyIP": .networkInfo, "publicIP": .networkInfo, "wifiDetails": .networkInfo, "dnsServers": .networkInfo,
            "cache": .freeUpSpace, "largeFiles": .freeUpSpace, "oldDownloads": .freeUpSpace,
            "devJunk": .freeUpSpace, "duplicates": .freeUpSpace, "folderSizes": .freeUpSpace,
            "tailscale": .vpn, "openVPN": .vpn
        ]
        for (raw, id) in expected { XCTAssertEqual(SystemToolMigration.map[raw], id, raw) }
        for brew in ["brewOutdated", "brewUpgradeAll", "brewInstalled", "brewUpdate", "brewCleanup", "brewDoctor",
                     "brewServices", "brewSearch"] {
            XCTAssertEqual(SystemToolMigration.map[brew], .homebrew, brew)
        }
    }

    func testEveryMappedIDSurvivesAndIsNotAlsoRemoved() {
        for (raw, id) in SystemToolMigration.map {
            XCTAssertNotNil(SystemToolCatalog.all.first { $0.id == id }, "\(raw) maps to a tool that isn't offered")
            XCTAssertFalse(SystemToolMigration.removed.contains(raw), "\(raw) is both merged and removed")
        }
    }

    func testEveryMergedIDReachesATool() {
        for raw in SystemToolMigration.map.keys {
            XCTAssertEqual(SystemToolsModel.storedTools([raw]).count, 1, "\(raw) was dropped instead of merged")
        }
    }

    func testStoredListsMigrateMergeAndDropUnknownIDs() {
        let stored = ["topCPU", "topMemory", "darkMode", "copyIP", "removedTool", "pdfmerge", "darkMode", "brewDoctor"]
        XCTAssertEqual(SystemToolsModel.storedTools(stored), [.activity, .darkMode, .networkInfo, .homebrew])
        XCTAssertEqual(SystemToolsModel.storedTools(nil), [])
    }

    func testStoredListsKeepKeptRawValues() {
        let kept = ["darkMode", "keepAwake", "finder", "networkInfo", "freeUpSpace", "homebrew", "shotfolder"]
        XCTAssertEqual(SystemToolsModel.storedTools(kept).map(\.rawValue), kept)
    }
}
