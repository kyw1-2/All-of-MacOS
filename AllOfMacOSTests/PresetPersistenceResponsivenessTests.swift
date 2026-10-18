import XCTest
@testable import AllOfMacOS

final class PresetPersistenceResponsivenessTests: XCTestCase {
    func testRapidEditsFlushLatestSnapshotAndCannotReappearAfterSynchronousSave() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AOM-preset-async-\(UUID())")
        let manager = PresetManager(directory: directory)
        defer { manager.flushPendingWrites(); try? FileManager.default.removeItem(at: directory) }
        var preset = Preset(name: "Typing")
        for i in 0..<100 { preset.name = "Edit \(i)"; manager.scheduleSave(preset) }
        manager.flushPendingWrites()
        XCTAssertEqual(manager.loadPreset()?.name, "Edit 99")
        manager.scheduleSave(Preset(name: "Superseded"))
        manager.save(Preset(name: "Explicit final save"), createBackup: false)
        manager.flushPendingWrites()
        XCTAssertEqual(manager.loadPreset()?.name, "Explicit final save")
        let reopened = PresetManager(directory: directory)
        XCTAssertEqual(reopened.loadPreset()?.name, "Explicit final save")
    }
}
