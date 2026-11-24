import XCTest
@testable import PDDAXReader

final class AutomationStepLogTests: XCTestCase {
    func testLogArchiveIncludesDiagnosticFilesAndExcludesRuntimeData() throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let root = scratch.appendingPathComponent("runtime")
        AutomationStepLog.record(root: root, uid: nil, step: "before-export")
        let diagnostic = try AutomationStepLog.writeDiagnostic(
            root: root, folder: .transfer, name: "test.json", data: Data("{}".utf8)
        )
        let state = root.appendingPathComponent("state.json")
        try Data("private runtime state".utf8).write(to: state)

        let archive = scratch.appendingPathComponent("report.zip")
        try AutomationStepLog.exportArchive(root: root, to: archive)
        AutomationStepLog.record(root: root, uid: nil, step: "after-export")

        let extracted = scratch.appendingPathComponent("extracted")
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", archive.path, extracted.path]
        try unzip.run()
        unzip.waitUntilExit()
        XCTAssertEqual(unzip.terminationStatus, 0)
        let exportedLog = try String(contentsOf: extracted.appendingPathComponent("logs/automation-steps.jsonl"))
        XCTAssertTrue(exportedLog.contains("before-export"))
        XCTAssertFalse(exportedLog.contains("after-export"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: extracted.path), ["logs"])
        XCTAssertEqual(
            try Data(contentsOf: extracted.appendingPathComponent("logs/transfer-diagnostics/test.json")),
            try Data(contentsOf: diagnostic)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: state.path))
    }

    func testDeleteClearsLogsAndNewEventsStartFresh() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        AutomationStepLog.record(root: root, uid: nil, step: "deleted-event")
        let diagnostic = try AutomationStepLog.writeDiagnostic(
            root: root, folder: .capture, name: "test.json", data: Data("{}".utf8)
        )
        let receipts = root.appendingPathComponent("message-receipts.json")
        let contents = Data("{}".utf8)
        try contents.write(to: receipts)

        XCTAssertTrue(try AutomationStepLog.deleteLogs(root: root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: diagnostic.path))
        XCTAssertFalse(try AutomationStepLog.deleteLogs(root: root))
        XCTAssertEqual(try Data(contentsOf: receipts), contents)

        AutomationStepLog.record(root: root, uid: nil, step: "new-event")
        let log = try String(contentsOf: root.appendingPathComponent("logs/automation-steps.jsonl"))
        XCTAssertTrue(log.contains("new-event"))
        XCTAssertFalse(log.contains("deleted-event"))
    }

    func testExportWithNoLogsPreservesExistingFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("report.zip")
        let contents = Data("previous report".utf8)
        try contents.write(to: destination)
        XCTAssertThrowsError(try AutomationStepLog.exportArchive(root: root, to: destination))
        XCTAssertEqual(try Data(contentsOf: destination), contents)
    }

    func testConcurrentStepsAppendCompleteRecordsAndPreserveEarlierLogs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        AutomationStepLog.record(root: root, uid: "customer", step: "initial")
        DispatchQueue.concurrentPerform(iterations: 20) { index in
            AutomationStepLog.record(root: root, uid: "customer", step: "step-\(index)", detail: "line\n\(index)")
        }
        let text = try String(contentsOf: root.appendingPathComponent("logs/automation-steps.jsonl"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let events = try text.split(separator: "\n").map { try decoder.decode(AutoReplyEvent.self, from: Data($0.utf8)) }
        XCTAssertEqual(events.count, 21)
        XCTAssertEqual(events.first?.kind, "initial")
        XCTAssertEqual(Set(events.map(\.kind)).count, 21)
        XCTAssertTrue(events.allSatisfy { $0.uid == "customer" })
    }
}
