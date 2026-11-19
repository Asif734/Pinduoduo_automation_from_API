import Foundation

enum PinduoduoV2CredentialError: LocalizedError, Equatable {
    case missing([String])
    case unreadable(String)
    case malformed(String)

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
        values.append(currentDirectory.appendingPathComponent(".env"))
        values.append(currentDirectory.deletingLastPathComponent().appendingPathComponent(".env"))
        var bundleAncestor = bundleURL.deletingLastPathComponent()
        for _ in 0..<4 {
            values.append(bundleAncestor.appendingPathComponent(".env"))
            let parent = bundleAncestor.deletingLastPathComponent()
            if parent.path == bundleAncestor.path { break }
            bundleAncestor = parent
        }
        values.append(homeDirectory.appendingPathComponent("Library/Application Support/PDDAutoReplyShared/.env"))
        var seen = Set<String>()
        self.candidateURLs = values.filter { seen.insert($0.standardizedFileURL.path).inserted }
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
