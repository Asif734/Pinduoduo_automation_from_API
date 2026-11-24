import Foundation

/// On-disk diagnostic evidence, independent of the bounded UI event list.
enum AutomationStepLog {
    enum DiagnosticFolder: String {
        case capture = "capture-diagnostics"
        case transfer = "transfer-diagnostics"
    }

    enum ArchiveError: LocalizedError {
        case noLogs
        case compressionFailed

        var errorDescription: String? {
            switch self {
            case .noLogs: return "No saved logs."
            case .compressionFailed: return "Could not compress the logs."
            }
        }
    }

    private static let lock = NSLock()

    private static func directory(in root: URL) -> URL {
        root.appendingPathComponent("logs", isDirectory: true)
    }

    static func writeDiagnostic(root: URL, folder: DiagnosticFolder, name: String, data: Data) throws -> URL {
        try lock.withLock {
            let folderURL = directory(in: root).appendingPathComponent(folder.rawValue, isDirectory: true)
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
            let file = folderURL.appendingPathComponent(name)
            try data.write(to: file, options: .atomic)
            return file
        }
    }

    static func exportArchive(root: URL, to destination: URL) throws {
        let files = FileManager.default
        let scratch = files.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: scratch) }

        let logs = directory(in: root)
        let snapshot = directory(in: scratch)
        try lock.withLock {
            guard files.fileExists(atPath: logs.path),
                  try !files.contentsOfDirectory(atPath: logs.path).isEmpty else {
                throw ArchiveError.noLogs
            }
            try files.copyItem(at: logs, to: snapshot)
        }

        // Compress the snapshot outside the lock so live logging can continue.
        let archive = scratch.appendingPathComponent("report.zip")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        zip.arguments = ["-c", "-k", "--keepParent", snapshot.path, archive.path]
        try zip.run()
        zip.waitUntilExit()
        guard zip.terminationStatus == 0 else { throw ArchiveError.compressionFailed }
        try Data(contentsOf: archive, options: .mappedIfSafe).write(to: destination, options: .atomic)
    }

    static func deleteLogs(root: URL) throws -> Bool {
        try lock.withLock {
            let logs = directory(in: root)
            guard FileManager.default.fileExists(atPath: logs.path) else { return false }
            try FileManager.default.removeItem(at: logs)
            return true
        }
    }

    static func record(root: URL?, uid: String?, step: String, detail: String = "") {
        guard let root else { return }
        lock.lock()
        defer { lock.unlock() }
        do {
            let directory = directory(in: root)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("automation-steps.jsonl")
            let event = AutoReplyEvent(id: UUID(), timestamp: Date(), uid: uid, kind: step, detail: detail)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            var data = try encoder.encode(event)
            data.append(0x0A)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.synchronize()
        } catch {
            NSLog("Automation step log failed (%@): %@", step, error.localizedDescription)
        }
    }
}
