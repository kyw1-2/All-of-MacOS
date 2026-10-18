import AppKit
import XCTest
@testable import AllOfMacOS

@MainActor
final class WiringResponsivenessTests: XCTestCase {
    private func seedCapture() -> CaptureHistoryEntry {
        CaptureHistory.shared.removeAll()
        let context = CGContext(data: nil, width: 32, height: 24, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return CaptureHistory.shared.add(CaptureResult(image: context.makeImage()!, globalRect: .zero,
                                                        scale: 1, kind: .area), url: nil)
    }

    private func marker(_ name: String) -> TriggerAction {
        var action = TriggerAction(actionType: .setVariable)
        action.parameters.variableName = name
        action.parameters.variableValue = "finished"
        return action
    }

    func testCopyWorkflowWaitsForOutputBeforeNextStep() async throws {
        let oldOutput = CaptureActions.output
        let oldHook = ActionExecutor.onActionExecuted
        let name = "copy_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        defer {
            CaptureActions.output = oldOutput; ActionExecutor.onActionExecuted = oldHook
            ActionExecutor.cancelAllSequences(); WorkflowVariables.remove(name)
            CaptureHistory.shared.removeAll()
        }
        _ = seedCapture()
        ActionExecutor.onActionExecuted = nil
        CaptureActions.output.notify = { _, _ in }
        let started = expectation(description: "copy began")
        let finished = expectation(description: "workflow finished")
        var release: CheckedContinuation<Void, Error>?
        CaptureActions.output.copyImage = { result in
            XCTAssertEqual(result.image.width, 32)
            try await withCheckedThrowingContinuation { continuation in
                release = continuation; started.fulfill()
            }
        }
        ActionExecutor.executeActions([TriggerAction(actionType: .copyLastCapture), marker(name)]) { ok in
            XCTAssertTrue(ok); finished.fulfill()
        }
        await fulfillment(of: [started], timeout: 3)
        XCTAssertNil(WorkflowVariables.value(name), "The next action must wait for clipboard output")
        release?.resume()
        await fulfillment(of: [finished], timeout: 3)
        XCTAssertEqual(WorkflowVariables.value(name), "finished")
    }

    func testSaveWorkflowAttachesFileBeforeNextStep() async throws {
        let oldOutput = CaptureActions.output
        let oldHook = ActionExecutor.onActionExecuted
        let name = "save_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer {
            CaptureActions.output = oldOutput; ActionExecutor.onActionExecuted = oldHook
            ActionExecutor.cancelAllSequences(); WorkflowVariables.remove(name)
            CaptureHistory.shared.removeAll(); try? FileManager.default.removeItem(at: url)
        }
        let entry = seedCapture()
        ActionExecutor.onActionExecuted = nil
        CaptureActions.output.notify = { _, _ in }
        let started = expectation(description: "save began")
        let finished = expectation(description: "workflow finished")
        var release: CheckedContinuation<URL, Error>?
        CaptureActions.output.writeImage = { _ in
            try await withCheckedThrowingContinuation { continuation in
                release = continuation; started.fulfill()
            }
        }
        ActionExecutor.executeActions([TriggerAction(actionType: .saveLastCapture), marker(name)]) { ok in
            XCTAssertTrue(ok); XCTAssertEqual(entry.fileURL, url); finished.fulfill()
        }
        await fulfillment(of: [started], timeout: 3)
        XCTAssertNil(entry.fileURL)
        XCTAssertNil(WorkflowVariables.value(name))
        try Data("private output".utf8).write(to: url)
        release?.resume(returning: url)
        await fulfillment(of: [finished], timeout: 3)
        XCTAssertEqual(WorkflowVariables.value(name), "finished")
    }

    func testFailedCopySaveAndPinStopWorkflow() async {
        let oldOutput = CaptureActions.output
        let oldHook = ActionExecutor.onActionExecuted
        let name = "failure_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        defer {
            CaptureActions.output = oldOutput; ActionExecutor.onActionExecuted = oldHook
            ActionExecutor.cancelAllSequences(); WorkflowVariables.remove(name)
            CaptureHistory.shared.removeAll()
        }
        _ = seedCapture()
        ActionExecutor.onActionExecuted = nil
        CaptureActions.output.notify = { _, _ in }
        CaptureActions.output.copyImage = { _ in throw CocoaError(.fileWriteNoPermission) }
        CaptureActions.output.writeImage = { _ in throw CocoaError(.fileWriteNoPermission) }
        for type in [ActionType.copyLastCapture, .saveLastCapture, .pinLastCapture] {
            let finished = expectation(description: type.rawValue)
            ActionExecutor.executeActions([TriggerAction(actionType: type), marker(name)]) { ok in
                XCTAssertFalse(ok); finished.fulfill()
            }
            await fulfillment(of: [finished], timeout: 3)
            XCTAssertNil(WorkflowVariables.value(name))
        }
    }

    func testOCRWorkflowHonorsPerActionLineBreakOverride() async {
        let oldOutput = CaptureActions.output
        let oldHook = ActionExecutor.onActionExecuted
        let oldBreaks = CaptureSettings.ocrKeepsLineBreaks
        defer {
            CaptureActions.output = oldOutput; ActionExecutor.onActionExecuted = oldHook
            CaptureSettings.ocrKeepsLineBreaks = oldBreaks
            ActionExecutor.cancelAllSequences(); CaptureHistory.shared.removeAll()
        }
        _ = seedCapture()
        ActionExecutor.onActionExecuted = nil
        CaptureSettings.ocrKeepsLineBreaks = true
        CaptureActions.output.notify = { _, _ in }
        var observed: [Bool] = []
        var copied: [String] = []
        CaptureActions.output.recognize = { _, keepsBreaks in
            observed.append(keepsBreaks); return "one two"
        }
        CaptureActions.output.copyText = { copied.append($0); return true }
        for override in [false, true, nil] as [Bool?] {
            var action = TriggerAction(actionType: .ocrLastCapture)
            action.parameters.ocrKeepsLineBreaks = override
            let finished = expectation(description: "OCR")
            ActionExecutor.executeActions([action]) { ok in XCTAssertTrue(ok); finished.fulfill() }
            await fulfillment(of: [finished], timeout: 3)
        }
        XCTAssertEqual(observed, [false, true, true])
        XCTAssertEqual(copied, ["one two", "one two", "one two"])
    }

    func testEvictedCaptureLoadsFullPixelsAsynchronouslyAndKeepsEdits() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = CaptureHistory(directory: directory, residentByteBudget: 0)
        let source = seedCapture().image
        let entry = history.add(CaptureResult(image: source, globalRect: .zero, scale: 1, kind: .area), url: nil)
        await history.flushPendingCacheWrites()
        XCTAssertFalse(entry.isResident)
        let loaded = await entry.loadImage()
        XCTAssertEqual(loaded.width, 32)
        XCTAssertEqual(loaded.height, 24)
        entry.evictResidentImage()
        let pending = Task { await entry.loadImage() }
        await Task.yield()
        let edited = try XCTUnwrap(QuickAccessImageTools.resized(source, width: 17, height: 13))
        history.replaceImage(of: entry, with: edited, scale: 1)
        _ = await pending.value
        let latest = await entry.loadImage()
        XCTAssertEqual(latest.width, 17, "An old disk decode must not replace edited pixels")
        await history.flushPendingCacheWrites()
        CaptureHistory.shared.removeAll()
    }

    func testOlderExportAndTransformCannotAttachToNewerEdit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = CaptureHistory(directory: directory)
        let source = seedCapture().image
        defer { CaptureHistory.shared.removeAll() }
        let entry = history.add(CaptureResult(image: source, globalRect: .zero, scale: 1, kind: .area), url: nil)
        let oldRevision = entry.imageRevision
        let edited = try XCTUnwrap(QuickAccessImageTools.resized(source, width: 17, height: 13))
        history.replaceImage(of: entry, with: edited, scale: 1)
        let oldExport = directory.appendingPathComponent("old-export.png")
        XCTAssertFalse(history.attachFile(oldExport, to: entry, ifRevision: oldRevision))
        XCTAssertNil(entry.fileURL)
        XCTAssertFalse(history.replaceImage(of: entry, with: source, scale: 1, ifRevision: oldRevision))
        XCTAssertEqual(entry.pixelWidth, 17)
        XCTAssertTrue(history.attachFile(oldExport, to: entry, ifRevision: entry.imageRevision))
        await history.flushPendingCacheWrites()
    }

    func testTransformRendersOffMainThread() async throws {
        let image = seedCapture().image
        defer { CaptureHistory.shared.removeAll() }
        let rotated = await QuickAccessImageTools.renderAsync(image) { image in
            XCTAssertFalse(Thread.isMainThread)
            return QuickAccessImageTools.rotatedLeft(image)
        }
        XCTAssertEqual(try XCTUnwrap(rotated).width, 24)
        XCTAssertEqual(rotated?.height, 32)
    }
}
