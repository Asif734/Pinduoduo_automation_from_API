import Foundation

protocol PinduoduoV2Transporting: Sendable {
    func execute(_ request: URLRequest, uploadFile: URL?) async throws -> (Data, HTTPURLResponse)
}

private final class PinduoduoV2NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

final class PinduoduoV2URLSessionTransport: PinduoduoV2Transporting, @unchecked Sendable {
    private let session: URLSession

    init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.waitsForConnectivity = false
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        session = URLSession(configuration: configuration, delegate: PinduoduoV2NoRedirectDelegate(), delegateQueue: nil)
    }

    func execute(_ request: URLRequest, uploadFile: URL?) async throws -> (Data, HTTPURLResponse) {
        let result: (Data, URLResponse)
        if let uploadFile {
            result = try await session.upload(for: request, fromFile: uploadFile)
        } else {
            result = try await session.data(for: request)
        }
        guard let response = result.1 as? HTTPURLResponse else {
            throw PinduoduoV2ClientError.invalidResponse("Response was not HTTP")
        }
        return (result.0, response)
    }
}

private actor PinduoduoV2UploadGate {
    private let limit: Int
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int = 2) { self.limit = max(1, limit) }

    func acquire() async {
        if active < limit {
            active += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            active = max(0, active - 1)
        } else {
            waiters.removeFirst().resume()
        }
    }
}

private actor PinduoduoV2StatusCache {
    private var value: (date: Date, status: PinduoduoV2StatusResponse)?

    func valid(now: Date, lifetime: TimeInterval) -> PinduoduoV2StatusResponse? {
        guard let value, now.timeIntervalSince(value.date) <= lifetime else { return nil }
        return value.status
    }

    func store(_ status: PinduoduoV2StatusResponse, at date: Date) {
        value = (date, status)
    }
}

struct PinduoduoV2APIClient: Sendable {
    let transport: any PinduoduoV2Transporting
    private let uploadGate: PinduoduoV2UploadGate
    private let statusCache: PinduoduoV2StatusCache

    init(
        transport: any PinduoduoV2Transporting = PinduoduoV2URLSessionTransport(),
        maximumConcurrentUploads: Int = 2
    ) {
        self.transport = transport
        uploadGate = PinduoduoV2UploadGate(limit: maximumConcurrentUploads)
        statusCache = PinduoduoV2StatusCache()
    }

    func status(apiKey: String, cacheLifetime: TimeInterval = 60, now: Date = Date()) async throws -> PinduoduoV2StatusResponse {
        if let cached = await statusCache.valid(now: now, lifetime: cacheLifetime) { return cached }
        let url = try endpoint("status", query: ["storeId": PinduoduoV2Configuration.storeID])
        var request = authorizedRequest(url: url, method: "GET", apiKey: apiKey, timeout: 30)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await perform(request)
        try validateHTTP(response, data: data, expected: [200])
        let decoded = try decode(PinduoduoV2StatusResponse.self, from: data, operation: "status")
        try validateReadiness(decoded)
        await statusCache.store(decoded, at: now)
        return decoded
    }

    func submit(_ record: PinduoduoV2GenerationOutboxRecord, apiKey: String) async throws -> PinduoduoV2Acceptance {
        await uploadGate.acquire()
        defer { Task { await uploadGate.release() } }
        let url = try endpoint("replies")
        let data: Data
        let response: HTTPURLResponse
        if record.files.isEmpty {
            var request = authorizedRequest(url: url, method: "POST", apiKey: apiKey, timeout: 30)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = record.requestJSON
            (data, response) = try await perform(request)
        } else {
            let body = try PinduoduoV2MultipartBody.make(record: record)
            defer { try? FileManager.default.removeItem(at: body.url) }
            var request = authorizedRequest(url: url, method: "POST", apiKey: apiKey, timeout: 300)
            request.setValue("multipart/form-data; boundary=\(body.boundary)", forHTTPHeaderField: "Content-Type")
            request.setValue(String(body.byteCount), forHTTPHeaderField: "Content-Length")
            (data, response) = try await perform(request, uploadFile: body.url)
        }
        try validateHTTP(response, data: data, expected: [202])
        let acceptance = try decode(PinduoduoV2Acceptance.self, from: data, operation: "submit")
        try validateAcceptance(acceptance, record: record)
        return acceptance
    }

    func poll(url: URL, expectedJobID: String, customerUID: String, historyVersion: String,
              apiKey: String) async throws -> PinduoduoV2JobResponse {
        let canonicalURL = try canonicalPollURL(url, expectedJobID: expectedJobID)
        var request = authorizedRequest(url: canonicalURL, method: "GET", apiKey: apiKey, timeout: 30)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await perform(request)
        if response.statusCode == 410 { throw PinduoduoV2ClientError.expired }
        try validateHTTP(response, data: data, expected: [200])
        let job = try decode(PinduoduoV2JobResponse.self, from: data, operation: "poll")
        guard job.jobId == expectedJobID else {
            throw PinduoduoV2ClientError.invalidResponse("Poll jobId does not match the accepted job")
        }
        if let platform = job.platform, platform != PinduoduoV2Configuration.platform {
            throw PinduoduoV2ClientError.invalidResponse("Poll platform binding mismatch")
        }
        if let store = job.storeId, store != PinduoduoV2Configuration.storeID {
            throw PinduoduoV2ClientError.invalidResponse("Poll store binding mismatch")
        }
        if let uid = job.customerUid, uid != customerUID {
            throw PinduoduoV2ClientError.invalidResponse("Poll customer binding mismatch")
        }
        if let version = job.historyVersion, version != historyVersion {
            throw PinduoduoV2ClientError.invalidResponse("Poll history binding mismatch")
        }
        if job.status == "completed" {
            try validateCompleted(job, rawData: data, customerUID: customerUID, historyVersion: historyVersion)
        }
        return job
    }

    func acknowledgeDelivery(jobID: String, body: PinduoduoV2DeliveryRequest,
                             apiKey: String) async throws -> PinduoduoV2DeliveryResponse {
        let url = try endpoint("replies/\(encodePath(jobID))/delivery")
        var request = authorizedRequest(url: url, method: "POST", apiKey: apiKey, timeout: 30)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await perform(request)
        try validateHTTP(response, data: data, expected: [200])
        let decoded = try decode(PinduoduoV2DeliveryResponse.self, from: data, operation: "delivery")
        guard decoded.jobId == jobID,
              decoded.storeId == body.storeId,
              decoded.eventId == body.eventId,
              decoded.status == body.status,
              decoded.resultDigest == body.resultDigest,
              decoded.recorded else {
            throw PinduoduoV2ClientError.invalidResponse("Delivery acknowledgement binding mismatch")
        }
        return decoded
    }

    private func validateReadiness(_ value: PinduoduoV2StatusResponse) throws {
        guard value.contextEnabled,
              value.platform == PinduoduoV2Configuration.platform,
              value.storeId == PinduoduoV2Configuration.storeID,
              value.agent.connected,
              value.agent.contextV2Supported,
              value.local.enabled,
              value.local.library.ready,
              !value.local.library.demo else {
            throw PinduoduoV2ClientError.invalidConfiguration("Pinduoduo V2 status is not ready for production generation")
        }
    }

    private func validateAcceptance(_ value: PinduoduoV2Acceptance,
                                    record: PinduoduoV2GenerationOutboxRecord) throws {
        // Field names are sufficient to diagnose a contract failure. Never
        // include returned values, raw bodies or credentials in diagnostics.
        let checks: [(String, Bool)] = [
            ("jobId", !value.jobId.isEmpty),
            ("platform", value.platform == PinduoduoV2Configuration.platform),
            ("storeId", value.storeId == PinduoduoV2Configuration.storeID),
            ("customerUid", value.customerUid == record.customerUid),
            ("historyVersion", value.historyVersion == record.historyVersion),
            ("status", ["queued", "processing", "completed", "recovery_required", "failed", "expired"].contains(value.status))
        ]
        let rejected = checks.filter { !$0.1 }.map { $0.0 }
        guard rejected.isEmpty else {
            throw PinduoduoV2ClientError.invalidResponse("Invalid Pinduoduo V2 acceptance fields: \(rejected.joined(separator: ","))")
        }
        guard !value.pollUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let poll = URL(string: value.pollUrl, relativeTo: PinduoduoV2Configuration.origin) else {
            throw PinduoduoV2ClientError.invalidResponse("Invalid Pinduoduo V2 acceptance fields: pollUrl")
        }
        _ = try canonicalPollURL(poll, expectedJobID: value.jobId)
    }

    private func validateCompleted(_ job: PinduoduoV2JobResponse, rawData: Data,
                                   customerUID: String, historyVersion: String) throws {
        guard let binding = job.binding,
              binding.jobId == job.jobId,
              binding.platform == PinduoduoV2Configuration.platform,
              binding.storeId == PinduoduoV2Configuration.storeID,
              binding.customerUid == customerUID,
              binding.historyVersion == historyVersion,
              let digest = job.resultDigest,
              digest.range(of: #"^(?:sha256:)?[0-9a-f]{64}$"#, options: .regularExpression) != nil,
              let reply = job.reply else {
            throw PinduoduoV2ClientError.invalidResponse("Completed result binding or digest is invalid")
        }
        guard let root = try JSONSerialization.jsonObject(with: rawData) as? [String: Any],
              let rawReply = root["reply"] as? [String: Any],
              Set(rawReply.keys) == ["action", "reply_text", "transfer_reason", "product_id", "product_query", "sku_label", "reason"],
              rawReply.values.allSatisfy({ $0 is String }) else {
            throw PinduoduoV2ClientError.invalidResponse("Reply must contain exactly seven string fields")
        }
        let text = reply.replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              reply.productId.isEmpty, reply.productQuery.isEmpty, reply.skuLabel.isEmpty,
              let action = CodexReplyAction(rawValue: reply.action),
              let reason = CodexTransferReason(rawValue: reply.transferReason),
              (action == .reply && reason == .none)
                || (action == .replyThenTransfer && reason != .none) else {
            throw PinduoduoV2ClientError.invalidResponse("Reply action or required fields are invalid")
        }
    }

    private func canonicalPollURL(_ suppliedURL: URL, expectedJobID: String) throws -> URL {
        let url: URL
        if suppliedURL.scheme == nil,
           let resolved = URL(string: suppliedURL.relativeString,
                              relativeTo: PinduoduoV2Configuration.origin)?.absoluteURL {
            url = resolved
        } else {
            url = suppliedURL.absoluteURL
        }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let normalizedPath = url.path.removingPercentEncoding?
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let expectedPath = "/api/codex/pinduoduo/v2/replies/\(expectedJobID)"
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let storeValues = components?.queryItems?
            .filter { $0.name == "storeId" }
            .compactMap(\.value) ?? []
        guard url.scheme?.lowercased() == "https",
              url.host?.lowercased() == PinduoduoV2Configuration.origin.host?.lowercased(),
              url.port == PinduoduoV2Configuration.origin.port,
              url.user == nil, url.password == nil, url.fragment == nil,
              normalizedPath == expectedPath,
              storeValues.isEmpty || storeValues.allSatisfy({ $0 == PinduoduoV2Configuration.storeID }) else {
            throw PinduoduoV2ClientError.invalidResponse("Poll URL escaped the authorized Pinduoduo V2 origin or scope")
        }
        // Never forward optional or unknown query parameters from the acceptance
        // envelope. Poll only the locally reconstructed, authorized endpoint.
        return try endpoint("replies/\(encodePath(expectedJobID))", query: [
            "storeId": PinduoduoV2Configuration.storeID
        ])
    }

    private func endpoint(_ relative: String, query: [String: String] = [:]) throws -> URL {
        var components = URLComponents(url: PinduoduoV2Configuration.baseURL.appendingPathComponent(relative),
                                       resolvingAgainstBaseURL: false)
        if !query.isEmpty {
            components?.queryItems = query.sorted(by: { $0.key < $1.key }).map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components?.url else { throw PinduoduoV2ClientError.invalidConfiguration("Invalid V2 endpoint") }
        return url
    }

    private func authorizedRequest(url: URL, method: String, apiKey: String, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue(apiKey, forHTTPHeaderField: PinduoduoV2Configuration.authenticationHeader)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func perform(_ request: URLRequest, uploadFile: URL? = nil) async throws -> (Data, HTTPURLResponse) {
        do { return try await transport.execute(request, uploadFile: uploadFile) }
        catch let error as PinduoduoV2ClientError { throw error }
        catch { throw PinduoduoV2ClientError.transport(error.localizedDescription) }
    }

    private func validateHTTP(_ response: HTTPURLResponse, data: Data, expected: Set<Int>) throws {
        guard expected.contains(response.statusCode) else {
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let nested = object?["error"] as? [String: Any]
            let code = (object?["code"] ?? nested?["code"]) as? String
            let message = (object?["message"] ?? nested?["message"]) as? String
            let retryAfter = Self.retryDelay(response.value(forHTTPHeaderField: "Retry-After"))
            throw PinduoduoV2ClientError.http(
                status: response.statusCode, code: code, message: message, retryAfter: retryAfter
            )
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data, operation: String) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch {
            // Coding paths are schema keys. Decoder descriptions and bodies may
            // include private response values, so they are deliberately omitted.
            let path: [any CodingKey]
            let problem: String
            switch error {
            case DecodingError.keyNotFound(let key, let context):
                path = context.codingPath + [key]; problem = "missing field"
            case DecodingError.valueNotFound(_, let context):
                path = context.codingPath; problem = "missing value"
            case DecodingError.typeMismatch(_, let context):
                path = context.codingPath; problem = "unexpected type"
            case DecodingError.dataCorrupted(let context):
                path = context.codingPath; problem = "invalid data"
            default:
                path = []; problem = "cannot decode response"
            }
            let field = path.isEmpty ? "response body" : path.map(\.stringValue).joined(separator: ".")
            throw PinduoduoV2ClientError.invalidJSON(operation: operation, field: field, problem: problem)
        }
    }

    private func encodePath(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?%#"))) ?? value
    }

    private static func retryDelay(_ value: String?, now: Date = Date()) -> TimeInterval? {
        guard let value else { return nil }
        if let seconds = TimeInterval(value.trimmingCharacters(in: .whitespaces)), seconds >= 0 {
            return seconds
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        guard let date = formatter.date(from: value) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }
}

private enum PinduoduoV2MultipartBody {
    struct Result {
        let url: URL
        let boundary: String
        let byteCount: Int64
    }

    static func make(record: PinduoduoV2GenerationOutboxRecord) throws -> Result {
        let boundary = "PDDV2-" + UUID().uuidString
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdd-v2-upload-\(UUID().uuidString).multipart")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        func write(_ string: String) throws { try handle.write(contentsOf: Data(string.utf8)) }
        try write("--\(boundary)\r\n")
        try write("Content-Disposition: form-data; name=\"request\"\r\n")
        try write("Content-Type: application/json\r\n\r\n")
        try handle.write(contentsOf: record.requestJSON)
        try write("\r\n")
        for file in record.files {
            try write("--\(boundary)\r\n")
            try write("Content-Disposition: form-data; name=\"images\"; filename=\"\(file.filename)\"\r\n")
            try write("Content-Type: \(file.mimeType)\r\n\r\n")
            let source = try FileHandle(forReadingFrom: URL(fileURLWithPath: file.path))
            defer { try? source.close() }
            while let chunk = try source.read(upToCount: 1_048_576), !chunk.isEmpty {
                try handle.write(contentsOf: chunk)
            }
            try write("\r\n")
        }
        try write("--\(boundary)--\r\n")
        try handle.synchronize()
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        let byteCount = size?.int64Value ?? 0
        guard byteCount > 0, byteCount <= 55 * 1_024 * 1_024 else {
            try? FileManager.default.removeItem(at: url)
            throw PinduoduoV2ClientError.invalidRequest("Multipart body exceeds the 55 MiB admission limit")
        }
        return Result(url: url, boundary: boundary, byteCount: byteCount)
    }
}
