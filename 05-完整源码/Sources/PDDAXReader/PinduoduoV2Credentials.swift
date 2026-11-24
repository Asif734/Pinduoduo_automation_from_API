import Darwin
import Foundation

enum PinduoduoV2CredentialError: LocalizedError, Equatable {
    case missing([String])
    case unreadable(String)
    case malformed(String)
    case invalidKey

    var errorDescription: String? {
        switch self {
        case .missing(let paths):
            return BilingualText.lines(
                "未在 .env 中找到 PINDUODUO_V2_API_KEY（已检查：\(paths.joined(separator: ", "))）",
                "PINDUODUO_V2_API_KEY was not found in .env (checked: \(paths.joined(separator: ", ")))"
            )
        case .unreadable(let path):
            return BilingualText.lines("无法读取密钥文件：\(path)", "The credential file is unreadable: \(path)")
        case .malformed(let path):
            return BilingualText.lines("密钥文件格式无效：\(path)", "The credential file is malformed: \(path)")
        case .invalidKey:
            return BilingualText.lines("请输入一行有效的 API 密钥。", "Enter a single API key without spaces.")
        }
    }
}

protocol PinduoduoV2CredentialProviding: Sendable {
    func apiKey() throws -> String
}

struct PinduoduoV2EnvironmentCredentialProvider: PinduoduoV2CredentialProviding, Sendable {
    static let variableName = "PINDUODUO_V2_API_KEY"
    let candidateURLs: [URL]

    init(
        candidateURLs: [URL]? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        bundleURL: URL = Bundle.main.bundleURL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        if let candidateURLs {
            self.candidateURLs = candidateURLs
            return
        }
        var values: [URL] = []
        if let configured = environment["PINDUODUO_ENV_FILE"], !configured.isEmpty {
            values.append(URL(fileURLWithPath: configured))
        }
        values.append(Self.configurationURL(homeDirectory: homeDirectory))
        values.append(currentDirectory.appendingPathComponent(".env"))
        values.append(currentDirectory.deletingLastPathComponent().appendingPathComponent(".env"))
        var bundleAncestor = bundleURL.deletingLastPathComponent()
        for _ in 0..<4 {
            values.append(bundleAncestor.appendingPathComponent(".env"))
            let parent = bundleAncestor.deletingLastPathComponent()
            if parent.path == bundleAncestor.path { break }
            bundleAncestor = parent
        }
        var seen = Set<String>()
        self.candidateURLs = values.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private static func configurationURL(homeDirectory: URL) -> URL {
        homeDirectory.appendingPathComponent("Library/Application Support/PDDAutoReplyShared/.env")
    }

    static func saveAPIKey(_ input: String, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        let key = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let invalid = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        guard !key.isEmpty, key.rangeOfCharacter(from: invalid) == nil else {
            throw PinduoduoV2CredentialError.invalidKey
        }

        let files = FileManager.default
        let destination = configurationURL(homeDirectory: homeDirectory)
        let folder = destination.deletingLastPathComponent()
        try files.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var lines: [String] = []
        if files.fileExists(atPath: destination.path) {
            let existing = try String(contentsOf: destination, encoding: .utf8)
            lines = existing.split(whereSeparator: \Character.isNewline).map(String.init).filter { line in
                var name = line.prefix { $0 != "=" }.trimmingCharacters(in: .whitespaces)
                if name.hasPrefix("export ") {
                    name = String(name.dropFirst(7)).trimmingCharacters(in: .whitespaces)
                }
                return name != variableName
            }
        }
        lines.append("\(variableName)=\"\(key)\"")

        let staging = folder.appendingPathComponent(".credential-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: staging) }
        let temporary = staging.appendingPathComponent(".env")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: temporary)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        guard rename(temporary.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    func apiKey() throws -> String {
        let manager = FileManager.default
        for url in candidateURLs where manager.fileExists(atPath: url.path) {
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
                throw PinduoduoV2CredentialError.unreadable(url.path)
            }
            let values = try parse(contents, path: url.path)
            if let key = values[Self.variableName]?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
                return key
            }
        }
        throw PinduoduoV2CredentialError.missing(candidateURLs.map(\.path))
    }

    private func parse(_ contents: String, path: String) throws -> [String: String] {
        var result: [String: String] = [:]
        for rawLine in contents.split(omittingEmptySubsequences: false, whereSeparator: \Character.isNewline) {
            var line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)) }
            guard let separator = line.firstIndex(of: "=") else {
                throw PinduoduoV2CredentialError.malformed(path)
            }
            let name = String(line[..<separator]).trimmingCharacters(in: CharacterSet.whitespaces)
            var value = String(line[line.index(after: separator)...]).trimmingCharacters(in: CharacterSet.whitespaces)
            guard !name.isEmpty else { throw PinduoduoV2CredentialError.malformed(path) }
            if value.count >= 2,
               (value.first == "\"" && value.last == "\"" || value.first == "'" && value.last == "'") {
                value.removeFirst()
                value.removeLast()
            }
            result[name] = value
        }
        return result
    }
}
