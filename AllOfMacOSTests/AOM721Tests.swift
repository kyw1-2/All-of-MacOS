import XCTest
@testable import AllOfMacOS

/// 7.21: agent pipe reader (race + lost last line) and the design pass.
final class AOM721Tests: XCTestCase {
    func testPipeReaderSplitsLinesAcrossChunks() {
        let reader = AgentPipeReader()
        XCTAssertEqual(reader.appendOutput(Data("{\"a\":1}\n{\"b\"".utf8)), ["{\"a\":1}"])
        XCTAssertEqual(reader.appendOutput(Data(":2}\n".utf8)), ["{\"b\":2}"])
        XCTAssertEqual(reader.appendOutput(Data()), [])
    }

    /// The final line often arrives without a newline right before exit; it
    /// used to be dropped, so a finished answer read as "didn't answer".
    func testPipeReaderKeepsUnterminatedLastLineAtExit() {
        let reader = AgentPipeReader()
        XCTAssertEqual(reader.appendOutput(Data("one\ntw".utf8)), ["one"])
        XCTAssertEqual(reader.finishOutput(Data("o".utf8)), ["two"])
        XCTAssertEqual(reader.finishOutput(Data()), [])
    }

    func testPipeReaderErrorTailIsBoundedAndThreadSafe() {
        let reader = AgentPipeReader(errorLimit: 100)
        DispatchQueue.concurrentPerform(iterations: 200) { index in
            reader.appendError(Data(String(repeating: "x", count: index % 7 + 1).utf8))
            _ = reader.errorText()
            _ = reader.appendOutput(Data("line \(index)\n".utf8))
        }
        XCTAssertLessThanOrEqual(reader.errorText().utf8.count, 100)
        XCTAssertTrue(reader.errorText(Data("tail".utf8)).hasSuffix("tail"))
    }

    func testWritingToAnExitedReaderThrowsInsteadOfRaisingSIGPIPE() throws {
        let pipe = Pipe()
        AgentPipeReader.disableSIGPIPE(pipe.fileHandleForWriting)
        try pipe.fileHandleForReading.close()
        XCTAssertThrowsError(try pipe.fileHandleForWriting.write(contentsOf: Data("hello\n".utf8)))
    }

    /// Every segmented picker goes through the neutral-selection helper.
    func testSegmentedPickersUseTheNeutralHelper() throws {
        let views = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("AllOfMacOS")
        let files = FileManager.default.enumerator(at: views, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        var offenders: [String] = []
        for file in files where file.lastPathComponent != "AOMDesignKit.swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            if source.contains(".pickerStyle(.segmented)") { offenders.append(file.lastPathComponent) }
        }
        XCTAssertEqual(offenders, [], "use .aomSegmented()")
    }
}
