import Foundation

enum PinduoduoV2Configuration {
    static let origin = URL(string: "https://grozziie.zjweiting.com:8035")!
    static let baseURL = URL(string: "https://grozziie.zjweiting.com:8035/api/codex/pinduoduo/v2")!
    static let storeID = "pinduoduo-default"
    static let platform = "pinduoduo"
    static let authenticationHeader = "X-Pinduoduo-Key"
}

enum PinduoduoV2MessageRole: String, Codable, Sendable {
    case customer
    case service
    case notice
}

struct PinduoduoV2Message: Codable, Equatable, Sendable {
    let id: String
    let role: PinduoduoV2MessageRole
    let text: String
    let occurredAt: String
    let mediaIds: [String]
}

enum PinduoduoV2MediaKind: String, Codable, Sendable {
    case image
    case frame
}

struct PinduoduoV2Media: Codable, Equatable, Sendable {
    let id: String
    let messageId: String
    let kind: PinduoduoV2MediaKind
    let label: String?
    let timestampMs: Int?

    enum CodingKeys: String, CodingKey {
        case id, messageId, kind, label, timestampMs
    }
}

struct PinduoduoV2ReplyRequest: Codable, Equatable, Sendable {
    let storeId: String
    let customerUid: String
    let historyVersion: String
    let idempotencyKey: String
    let messages: [PinduoduoV2Message]
    let targetMessageIds: [String]
    let referencedMediaIds: [String]?
    let media: [PinduoduoV2Media]
    let replyInstructions: String

    enum CodingKeys: String, CodingKey {
        case storeId, customerUid, historyVersion, idempotencyKey, messages
        case targetMessageIds, referencedMediaIds, media, replyInstructions
    }
}

struct PinduoduoV2ReplyPayload: Codable, Equatable, Sendable {
    let action: String
    let replyText: String
    let transferReason: String
    let productId: String
    let productQuery: String
    let skuLabel: String
    let reason: String

    enum CodingKeys: String, CodingKey {
        case action
        case replyText = "reply_text"
        case transferReason = "transfer_reason"
        case productId = "product_id"
        case productQuery = "product_query"
        case skuLabel = "sku_label"
        case reason
    }
}

struct PinduoduoV2Binding: Codable, Equatable, Sendable {
    let jobId: String
    let platform: String
    let storeId: String
    let customerUid: String
    let historyVersion: String
}

struct PinduoduoV2Acceptance: Codable, Equatable, Sendable {
    let jobId: String
    let status: String
    let createdAt: String
    let updatedAt: String
    let platform: String
    let storeId: String
    let customerUid: String
    let historyVersion: String
    let pollUrl: String
}

struct PinduoduoV2JobError: Codable, Equatable, Sendable {
    let code: String
    let message: String?
}

struct PinduoduoV2JobResponse: Codable, Equatable, Sendable {
    let jobId: String
    let status: String
    let platform: String?
    let storeId: String?
    let customerUid: String?
    let historyVersion: String?
    let binding: PinduoduoV2Binding?
    let resultDigest: String?
    let reply: PinduoduoV2ReplyPayload?
    let error: PinduoduoV2JobError?
}

struct PinduoduoV2StatusResponse: Codable, Equatable, Sendable {
    struct Agent: Codable, Equatable, Sendable {
        let connected: Bool
        let contextV2Supported: Bool
    }
    struct Library: Codable, Equatable, Sendable {
        let ready: Bool
        let demo: Bool
    }
    struct Local: Codable, Equatable, Sendable {
        let enabled: Bool
        let library: Library
    }
    struct Capabilities: Codable, Equatable, Sendable {
        let orderContext: String?
    }

    let contextEnabled: Bool
    let platform: String
    let storeId: String
    let agent: Agent
    let local: Local
    let capabilities: Capabilities?
}

enum PinduoduoV2DeliveryStatus: String, Codable, Sendable {
    case sent
    case failed
    case unknown
}

struct PinduoduoV2DeliveryRequest: Codable, Equatable, Sendable {
    let storeId: String
    let eventId: String
    let status: PinduoduoV2DeliveryStatus
    let occurredAt: String
    let resultDigest: String
    let actualSentText: String?
}

struct PinduoduoV2DeliveryResponse: Codable, Equatable, Sendable {
    let jobId: String
    let storeId: String
    let eventId: String
    let status: PinduoduoV2DeliveryStatus
    let occurredAt: String
    let resultDigest: String
    let actualSentText: String?
    let recorded: Bool
}

struct PinduoduoV2GenerationReceipt: Codable, Equatable, Sendable {
    let jobId: String
    let platform: String
    let storeId: String
    let customerUid: String
    let historyVersion: String
    let resultDigest: String
}

enum PinduoduoV2ClientError: Error, LocalizedError, Equatable {
    case invalidConfiguration(String)
    case invalidRequest(String)
    case invalidResponse(String)
    case invalidJSON(operation: String, field: String, problem: String)
    case http(status: Int, code: String?, message: String?, retryAfter: TimeInterval?)
    case transport(String)
    case jobFailed(code: String, message: String?)
    case overallDeadline
    case recoveryPending
    case expired

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let value): return value
        case .invalidRequest(let value): return value
        case .invalidResponse(let value): return value
        case .invalidJSON(let operation, let field, let problem):
            return "Pinduoduo V2 \(operation) JSON: \(problem) at \(field)"
        case .http(let status, let code, let message, _):
            return ["HTTP \(status)", code, message].compactMap { $0 }.joined(separator: " ")
        case .transport(let value): return value
        case .jobFailed(let code, let message): return [code, message].compactMap { $0 }.joined(separator: " ")
        case .overallDeadline: return "Pinduoduo V2 job wait deadline expired; the original job remains recoverable"
        case .recoveryPending: return "Hosted recovery required"
        case .expired: return "Pinduoduo V2 job result expired"
        }
    }

    var retryable: Bool {
        switch self {
        case .transport, .overallDeadline: return true
        case .http(let status, _, _, _): return status == 429 || status == 503
        case .invalidConfiguration, .invalidRequest, .invalidResponse, .invalidJSON, .jobFailed, .expired, .recoveryPending: return false
        }
    }

    var retryAfter: TimeInterval? {
        if case .http(_, _, _, let value) = self { return value }
        return nil
    }
}

enum PinduoduoV2DateCodec {
    private static func formatter() -> ISO8601DateFormatter {
        let value = ISO8601DateFormatter()
        value.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        value.timeZone = TimeZone(secondsFromGMT: 0)
        return value
    }

    static func string(_ date: Date) -> String { formatter().string(from: date) }
}
