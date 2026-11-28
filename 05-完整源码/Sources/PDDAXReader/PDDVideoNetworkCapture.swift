import Darwin
import Foundation

/// Reads only events appended to PDD's private Chromium NetLog after arming.
struct PDDVideoNetworkCapture: Sendable {
    enum Failure: Error {
        case unavailable
        case ambiguous
    }

    static var sessionLogURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/PDDAutoReplyShared/video-network/netlog.json")
    }

    private struct Header: Decodable {
        struct Constants: Decodable {
            let logEventTypes: [String: Int]
            let logSourceType: [String: Int]
        }
        let constants: Constants
    }

    private struct Event: Decodable {
        struct Source: Decodable {
            let id: Int
            let type: Int
        }
        struct Parameters: Decodable {
            let url: URL?
            let method: String?
            let initiator: String?
            let headers: [String]?
        }
        let type: Int
        let phase: Int
        let source: Source
        let params: Parameters?
    }

    private struct Request {
        let url: URL
        var isVideo = false
        var hasMP4Response = false
    }

    private let file: URL
    private let device: dev_t
    private let inode: ino_t
    private let offset: UInt64
    private let startsAtLineBoundary: Bool
    private let requestSource: Int
    private let startJob: Int
    private let requestHeaders: Int
    private let responseHeaders: Int

    init(file: URL) throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw Failure.unavailable
        }
        // Capture the offset first so records appended while reading the header stay eligible.
        let end = try handle.seekToEnd()
        guard end >= 3 else { throw Failure.unavailable }
        try handle.seek(toOffset: end - 3)
        let tail = try handle.read(upToCount: 3)
        guard tail != Data("]}\n".utf8) else { throw Failure.unavailable }
        let atBoundary = tail?.last == 10
        try handle.seek(toOffset: 0)
        guard let prefix = try handle.read(upToCount: 256 * 1024),
              let newline = prefix.firstIndex(of: 10), newline > 0,
              prefix[prefix.index(before: newline)] == 44 else { throw Failure.unavailable }
        // Chromium writes the constants object on the first line, followed by a comma.
        var headerData = Data(prefix[..<prefix.index(before: newline)])
        headerData.append(125)
        let constants = try JSONDecoder().decode(Header.self, from: headerData).constants
        guard let source = constants.logSourceType["URL_REQUEST"],
              let start = constants.logEventTypes["URL_REQUEST_START_JOB"],
              let request = constants.logEventTypes["HTTP_CACHE_CALLER_REQUEST_HEADERS"],
              let response = constants.logEventTypes["HTTP_TRANSACTION_READ_RESPONSE_HEADERS"] else {
            throw Failure.unavailable
        }

        self.file = file
        device = info.st_dev
        inode = info.st_ino
        offset = end
        startsAtLineBoundary = atBoundary
        requestSource = source
        startJob = start
        requestHeaders = request
        responseHeaders = response
    }

    func wait() async throws -> URL {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        try checkFile(handle, minimumSize: offset)
        try handle.seek(toOffset: offset)

        let clock = ContinuousClock()
        let decoder = JSONDecoder()
        var requests: [Int: Request] = [:]
        var processed: UInt64 = 0
        var pending = Data()
        var skipPartialLine = !startsAtLineBoundary
        var settledSince: ContinuousClock.Instant?
        let readBudget: UInt64 = 16 * 1024 * 1024
        while true {
            try Task.checkCancellation()
            try checkFile(handle, minimumSize: offset + processed)
            if let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty {
                processed += UInt64(chunk.count)
                guard processed <= readBudget else { throw Failure.unavailable }
                pending.append(chunk)
                // CEF flushes newline-delimited events before it closes the JSON document.
                if let lastLineBreak = pending.lastIndex(of: 10) {
                    let lines = pending[...lastLineBreak].split(separator: 10, omittingEmptySubsequences: false)
                    for (index, line) in lines.enumerated() {
                        if index == 0 && skipPartialLine { continue }
                        let json = line.last == 44 ? Data(line.dropLast()) : Data(line)
                        guard let event = try? decoder.decode(Event.self, from: json),
                              event.source.type == requestSource, let params = event.params else { continue }
                        collect(event, params: params, in: &requests)
                    }
                    skipPartialLine = false
                    pending.removeSubrange(...lastLineBreak)
                }
                // Drain a backlog before deciding whether playback is ambiguous.
                continue
            }

            let playback = requests.values.filter(\.isVideo)
            let urls = Set(playback.map(\.url))
            if urls.count > 1 { throw Failure.ambiguous }
            if let match = playback.first(where: \.hasMP4Response), pending.isEmpty {
                let since = settledSince ?? clock.now
                if since.duration(to: clock.now) >= .milliseconds(500) { return match.url }
                settledSince = since
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func checkFile(_ handle: FileHandle, minimumSize: UInt64) throws {
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0,
              info.st_dev == device, info.st_ino == inode,
              info.st_size >= minimumSize else { throw Failure.unavailable }
    }

    private func collect(_ event: Event, params: Event.Parameters, in requests: inout [Int: Request]) {
        let id = event.source.id
        if event.type == startJob, event.phase == 1 {
            guard params.method == "GET", params.initiator == "https://mms.pinduoduo.com",
                  let url = params.url, url.scheme?.lowercased() == "https",
                  url.user == nil, url.password == nil,
                  url.pathExtension.lowercased() == "mp4",
                  PDDVideoHostPolicy.accepts(url.host) else { return }
            requests[id] = Request(url: url)
        } else if event.type == requestHeaders, let headers = params.headers {
            if headers.contains(where: { $0.lowercased() == "sec-fetch-dest: video" }) {
                requests[id]?.isVideo = true
            }
        } else if event.type == responseHeaders, let headers = params.headers,
                  let statusLine = headers.first, statusLine.hasPrefix("HTTP/"),
                  let status = statusLine.split(separator: " ").dropFirst().first,
                  status == "200" || status == "206" {
            if headers.contains(where: { $0.lowercased().hasPrefix("content-type: video/mp4") }) {
                requests[id]?.hasMP4Response = true
            }
        }
    }
}

enum PDDVideoAddressResolver {
    enum Source: String, Sendable {
        case cache, network
    }

    struct Match: Sendable {
        let url: URL
        let source: Source
    }

    static func resolve(
        cacheBudget: Duration = .seconds(20),
        networkBudget: Duration = .seconds(10),
        cache: @escaping @MainActor @Sendable () async throws -> URL,
        network: (@MainActor @Sendable () async throws -> URL)?
    ) async throws -> Match {
        if let network {
            do {
                let url = try await withOperationDeadline(networkBudget, stage: "video-network-address", operation: network)
                return Match(url: url, source: .network)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
            }
        }

        let url = try await withOperationDeadline(cacheBudget, stage: "video-address", operation: cache)
        return Match(url: url, source: .cache)
    }
}
