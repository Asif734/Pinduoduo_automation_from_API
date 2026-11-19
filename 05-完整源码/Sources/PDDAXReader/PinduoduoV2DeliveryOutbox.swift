import CryptoKit
import Foundation

protocol PinduoduoV2DeliveryRecording: Sendable {
    func enqueueVerifiedSend(receipt: PinduoduoV2GenerationReceipt, actualSentText: String,
                             serviceMessageID: String, occurredAt: Date) throws
    func enqueueUnknown(receipt: PinduoduoV2GenerationReceipt, occurredAt: Date) throws
    func flushPending() async
}

private struct PinduoduoV2DeliveryOutboxRecord: Codable, Equatable {
    let jobID: String
    let body: PinduoduoV2DeliveryRequest
    let createdAt: Date
    var acknowledgedAt: Date?
    var attempts: Int
}

final class PinduoduoV2DeliveryOutboxStore: @unchecked Sendable {
    private let directory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let lock = NSLock()

    init(rootDirectory: URL) {
        directory = rootDirectory.appendingPathComponent("pinduoduo-v2-delivery-outbox", isDirectory: true)
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    fileprivate func loadOrCreate(receipt: PinduoduoV2GenerationReceipt,
                                  status: PinduoduoV2DeliveryStatus, text: String?,
                                  occurredAt: Date) throws -> PinduoduoV2DeliveryOutboxRecord {
        try locked {
            let url = recordURL(jobID: receipt.jobId, digest: receipt.resultDigest, status: status)
            if FileManager.default.fileExists(atPath: url.path) {
                return try decoder.decode(PinduoduoV2DeliveryOutboxRecord.self, from: Data(contentsOf: url))
            }
            if status == .sent, text?.isEmpty != false || (text?.count ?? 0) > 10_000 {
                throw PinduoduoV2ClientError.invalidRequest("Actual sent text cannot be represented by the delivery contract")
            }
            guard status == .sent || text == nil else {
                throw PinduoduoV2ClientError.invalidRequest("Only sent delivery events may include actualSentText")
            }
            let record = PinduoduoV2DeliveryOutboxRecord(
                jobID: receipt.jobId,
                body: .init(
                    storeId: PinduoduoV2Configuration.storeID,
                    eventId: UUID().uuidString.lowercased(),
                    status: status,
                    occurredAt: PinduoduoV2DateCodec.string(occurredAt),
                    resultDigest: receipt.resultDigest,
                    actualSentText: text
                ),
                createdAt: Date(),
                acknowledgedAt: nil,
                attempts: 0
            )
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try encoder.encode(record).write(to: url, options: .atomic)
            return record
        }
    }

    fileprivate func save(_ record: PinduoduoV2DeliveryOutboxRecord) throws {
        try locked {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try encoder.encode(record).write(
                to: recordURL(jobID: record.jobID, digest: record.body.resultDigest, status: record.body.status),
                options: .atomic
            )
        }
    }

    fileprivate func pending() throws -> [PinduoduoV2DeliveryOutboxRecord] {
        try locked {
            guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
            return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }
                .compactMap { url in
                    let value = try decoder.decode(PinduoduoV2DeliveryOutboxRecord.self, from: Data(contentsOf: url))
                    return value.acknowledgedAt == nil ? value : nil
                }
        }
    }

    private func recordURL(jobID: String, digest: String, status: PinduoduoV2DeliveryStatus) -> URL {
        let material = "\(jobID)|\(digest)|\(status.rawValue)"
        let name = SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name + ".json")
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

struct PinduoduoV2DeliveryRecorder: PinduoduoV2DeliveryRecording, Sendable {
    let client: PinduoduoV2APIClient
    let credentials: any PinduoduoV2CredentialProviding
    let store: PinduoduoV2DeliveryOutboxStore
    let historyRoot: URL

    init(
        rootDirectory: URL,
        client: PinduoduoV2APIClient,
        credentials: any PinduoduoV2CredentialProviding
    ) {
        self.client = client
        self.credentials = credentials
        historyRoot = rootDirectory
        store = PinduoduoV2DeliveryOutboxStore(rootDirectory: rootDirectory)
    }

    func enqueueVerifiedSend(receipt: PinduoduoV2GenerationReceipt, actualSentText: String,
                             serviceMessageID: String, occurredAt: Date) throws {
        try PinduoduoV2HistoryLedger(rootDirectory: historyRoot, customerUID: receipt.customerUid)
            .suppressDeliveredServiceMessage(serviceMessageID)
        _ = try store.loadOrCreate(receipt: receipt, status: .sent, text: actualSentText,
                                   occurredAt: occurredAt)
    }

    func enqueueUnknown(receipt: PinduoduoV2GenerationReceipt, occurredAt: Date) throws {
        _ = try store.loadOrCreate(receipt: receipt, status: .unknown, text: nil,
                                   occurredAt: occurredAt)
    }

    func flushPending() async {
        guard let records = try? store.pending() else { return }
        for record in records {
            do { try await submit(record) }
            catch { continue }
        }
    }

    private func submit(_ original: PinduoduoV2DeliveryOutboxRecord) async throws {
        var record = original
        record.attempts += 1
        try store.save(record)
        let key = try credentials.apiKey()
        _ = try await client.acknowledgeDelivery(jobID: record.jobID, body: record.body, apiKey: key)
        record.acknowledgedAt = Date()
        try store.save(record)
    }
}
