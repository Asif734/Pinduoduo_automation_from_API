import Foundation

struct PDDAlternateVideoDownloadClient: Sendable {
    func download(from sourceURL: URL, to destinationURL: URL) async throws -> URL {
        guard sourceURL.scheme?.lowercased() == "https",
              let host = sourceURL.host?.lowercased(),
              PDDVideoHostPolicy.accepts(host) else {
            throw PDDCustomerVideoError.downloadRejected
        }
        let addresses = await addresses(for: host)
        guard !addresses.isEmpty else { throw PDDCustomerVideoError.downloadFailed }
        let candidates = Array(addresses.prefix(3))
        return try await withThrowingTaskGroup(of: URL?.self) { group in
            var temporaryURLs: [URL] = []
            for address in candidates {
                let temporary = destinationURL.deletingLastPathComponent()
                    .appendingPathComponent(".alternate-\(UUID().uuidString).partial")
                temporaryURLs.append(temporary)
                group.addTask {
                    await curl(sourceURL, host: host, address: address, destination: temporary)
                        ? temporary : nil
                }
            }
            var winner: URL?
            while let result = try await group.next() {
                if let result { winner = result; group.cancelAll(); break }
            }
            defer {
                temporaryURLs.forEach { try? FileManager.default.removeItem(at: $0) }
            }
            try await group.waitForAll()
            try Task.checkCancellation()
            guard let winner else { throw PDDCustomerVideoError.downloadFailed }
            try? FileManager.default.removeItem(at: destinationURL)
            try FileManager.default.moveItem(at: winner, to: destinationURL)
            return destinationURL
        }
    }

    private func addresses(for host: String) async -> [String] {
        await withTaskGroup(of: [String].self) { group in
            for server in ["223.5.5.5", "119.29.29.29"] {
                group.addTask { Self.query(host: host, server: server) }
            }
            var result: [String] = []
            var seen = Set<String>()
            for await values in group {
                for value in values where Self.isPublicIPv4(value) && seen.insert(value).inserted {
                    result.append(value)
                }
            }
            return result
        }
    }

    private static func query(host: String, server: String) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/dig")
        process.arguments = ["+short", "+time=2", "+tries=1", "@\(server)", host, "A"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return [] }
            return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .split(whereSeparator: \Character.isNewline).map(String.init)
        } catch { return [] }
    }

    private func curl(
        _ sourceURL: URL, host: String, address: String, destination: URL
    ) async -> Bool {
        guard !Task.isCancelled else { return false }
        try? FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let timeout = PDDUnlimitedVideoDownloadSessionPolicy.transferTimeoutSeconds
        let result = await BoundedProcess.run(.init(
            executable: URL(fileURLWithPath: "/usr/bin/curl"),
            arguments: [
                "--config", "-", "--fail", "--silent", "--show-error",
                "--connect-timeout", "5", "--max-time", String(timeout),
                "--output", destination.path, "--resolve", "\(host):443:\(address)"
            ],
            standardInput: Data("url = \"\(sourceURL.absoluteString)\"\n".utf8)
        ), softDeadline: .seconds(timeout), hardDeadline: .seconds(timeout))
        return !Task.isCancelled && result.termination == .exited(0)
    }

    private static func isPublicIPv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        if parts[0] == 10 || parts[0] == 127 || parts[0] == 0 { return false }
        if parts[0] == 169 && parts[1] == 254 { return false }
        if parts[0] == 172 && (16...31).contains(parts[1]) { return false }
        if parts[0] == 192 && parts[1] == 168 { return false }
        if parts[0] >= 224 { return false }
        return true
    }
}
