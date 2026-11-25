import CryptoKit
import Foundation

struct PinduoduoV2FrozenFile: Codable, Equatable, Sendable {
    let mediaID: String
    let path: String
    let filename: String
    let mimeType: String
    let byteCount: Int
    let sha256: String
}

struct PinduoduoV2GenerationOutboxRecord: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable {
        case frozen
        case accepted
        case completed
        case failed
        case recoveryRequired = "recovery_required"
        case expired
    }

    let localJobID: UUID
    let customerUid: String
    let historyVersion: String
    let idempotencyKey: String
    let requestJSON: Data
    let files: [PinduoduoV2FrozenFile]
    let messageFingerprints: [String: String]
    let mediaFingerprints: [String: String]
    let createdAt: Date
    var phase: Phase
    var hostedJobID: String?
    var pollURL: String?
    var result: PinduoduoV2GenerationReceipt?
    var lastErrorCode: String?
}

final class PinduoduoV2GenerationOutboxStore: @unchecked Sendable {
    let rootDirectory: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let lock = NSLock()

    init(rootDirectory: URL, fileManager: FileManager = .default) {
        self.rootDirectory = rootDirectory.appendingPathComponent("pinduoduo-v2-generation-outbox", isDirectory: true)
        self.fileManager = fileManager
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func load(_ id: UUID) throws -> PinduoduoV2GenerationOutboxRecord? {
        try locked {
            let url = recordURL(id)
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            return try decoder.decode(PinduoduoV2GenerationOutboxRecord.self, from: Data(contentsOf: url))
        }
    }

    func save(_ record: PinduoduoV2GenerationOutboxRecord) throws {
        try locked {
            try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
            try encoder.encode(record).write(to: recordURL(record.localJobID), options: .atomic)
        }
    }

    func mediaDirectory(_ id: UUID) throws -> URL {
        let value = rootDirectory.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
        try fileManager.createDirectory(at: value, withIntermediateDirectories: true)
        return value
    }

    /// The immutable ledger stores hashes, while an accepted frozen request stores
    /// the exact text/timestamp that produced each hash. Candidates are scoped
    /// to one customer/store and must reproduce the ledger hash before reuse.
    func synchronizedMessageCandidates(
        id: String,
        fingerprint: String,
        customerUID: String
    ) throws -> [PinduoduoV2Message] {
        try locked {
            guard fileManager.fileExists(atPath: rootDirectory.path) else { return [] }
            let urls = try fileManager.contentsOfDirectory(
                at: rootDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ).filter { $0.pathExtension == "json" }
            var result: [PinduoduoV2Message] = []
            var seen = Set<String>()
            for url in urls {
                guard let data = try? Data(contentsOf: url),
                      let record = try? decoder.decode(PinduoduoV2GenerationOutboxRecord.self, from: data),
                      record.customerUid == customerUID,
                      record.messageFingerprints[id] == fingerprint,
                      let request = try? JSONDecoder().decode(PinduoduoV2ReplyRequest.self, from: record.requestJSON),
                      request.customerUid == customerUID,
                      request.storeId == PinduoduoV2Configuration.storeID,
                      let message = request.messages.first(where: { $0.id == id }) else { continue }
                let key = [message.role.rawValue, message.text, message.occurredAt]
                    .joined(separator: "\u{1f}")
                if seen.insert(key).inserted { result.append(message) }
            }
            return result
        }
    }

    private func recordURL(_ id: UUID) -> URL {
        rootDirectory.appendingPathComponent(id.uuidString.lowercased() + ".json")
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

private struct PinduoduoV2HistoryLedgerState: Codable {
    var messages: [String: String] = [:]
    var media: [String: String] = [:]
    var suppressedDeliveredServiceIDs: Set<String> = []

    private enum CodingKeys: String, CodingKey {
        case messages, media, suppressedDeliveredServiceIDs
    }

    init(messages: [String: String] = [:], media: [String: String] = [:],
         suppressedDeliveredServiceIDs: Set<String> = []) {
        self.messages = messages
        self.media = media
        self.suppressedDeliveredServiceIDs = suppressedDeliveredServiceIDs
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        messages = try values.decodeIfPresent([String: String].self, forKey: .messages) ?? [:]
        media = try values.decodeIfPresent([String: String].self, forKey: .media) ?? [:]
        suppressedDeliveredServiceIDs = try values.decodeIfPresent(Set<String>.self,
            forKey: .suppressedDeliveredServiceIDs) ?? []
    }
}

final class PinduoduoV2HistoryLedger: @unchecked Sendable {
    private let url: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    init(rootDirectory: URL, customerUID: String, fileManager: FileManager = .default) {
        let digest = SHA256.hash(data: Data(customerUID.utf8)).map { String(format: "%02x", $0) }.joined()
        url = rootDirectory.appendingPathComponent("pinduoduo-v2-history-ledger", isDirectory: true)
            .appendingPathComponent(String(digest.prefix(40)) + ".json")
        self.fileManager = fileManager
    }

    func snapshot() throws -> (messages: [String: String], media: [String: String], suppressedDeliveredServiceIDs: Set<String>) {
        try locked {
            let state = try load()
            return (state.messages, state.media, state.suppressedDeliveredServiceIDs)
        }
    }

    func suppressDeliveredServiceMessage(_ id: String) throws {
        try locked {
            var state = try load()
            guard state.suppressedDeliveredServiceIDs.insert(id).inserted else { return }
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(state).write(to: url, options: .atomic)
        }
    }

    func markAccepted(messages: [String: String], media: [String: String]) throws {
        try locked {
            var state = try load()
            for (id, fingerprint) in messages {
                if let old = state.messages[id], old != fingerprint {
                    throw PinduoduoV2ClientError.invalidRequest("Message ID \(id) changed after synchronization")
                }
                state.messages[id] = fingerprint
            }
            for (id, fingerprint) in media {
                if let old = state.media[id], old != fingerprint {
                    throw PinduoduoV2ClientError.invalidRequest("Media ID \(id) changed after synchronization")
                }
                state.media[id] = fingerprint
            }
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(state).write(to: url, options: .atomic)
        }
    }

    private func load() throws -> PinduoduoV2HistoryLedgerState {
        guard fileManager.fileExists(atPath: url.path) else { return .init() }
        return try JSONDecoder().decode(PinduoduoV2HistoryLedgerState.self, from: Data(contentsOf: url))
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

protocol PinduoduoV2ReplyInstructionsProviding: Sendable {
    func instructions() throws -> String
}

struct PinduoduoV2ReplyInstructionsFileProvider: PinduoduoV2ReplyInstructionsProviding, Sendable {
    let candidates: [URL]

    init(
        candidates: [URL]? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        resourceURL: URL? = Bundle.main.resourceURL
    ) {
        if let candidates { self.candidates = candidates; return }
        var values: [URL] = []
        if let configured = environment["PINDUODUO_REPLY_INSTRUCTIONS_FILE"], !configured.isEmpty {
            values.append(URL(fileURLWithPath: configured))
        }
        values.append(homeDirectory.appendingPathComponent(
            "Library/Application Support/PDDAutoReplyShared/pinduoduo-v2-reply-instructions.txt"
        ))
        values.append(currentDirectory.appendingPathComponent(
            "Resources/CustomerService/pinduoduo-v2-reply-instructions.txt"
        ))
        if let resourceURL {
            values.append(resourceURL.appendingPathComponent(
                "CustomerService/pinduoduo-v2-reply-instructions.txt"
            ))
        }
        var seen = Set<String>()
        self.candidates = values.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    func instructions() throws -> String {
        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw PinduoduoV2ClientError.invalidConfiguration("Pinduoduo V2 reply instructions are missing")
        }
        let value = try String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw PinduoduoV2ClientError.invalidConfiguration("Pinduoduo V2 reply instructions are empty")
        }
        guard value.utf8.count <= 16_384 else {
            throw PinduoduoV2ClientError.invalidConfiguration("Pinduoduo V2 reply instructions exceed 16,384 UTF-8 bytes")
        }
        return value
    }
}

struct PinduoduoV2RequestBuilder: Sendable {
    let rootDirectory: URL
    let now: @Sendable () -> Date

    init(rootDirectory: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.rootDirectory = rootDirectory
        self.now = now
    }

    func freeze(localJobID: UUID, capture: AutoReplyCapture) throws -> PinduoduoV2GenerationOutboxRecord {
        guard let batch = capture.batch else {
            throw PinduoduoV2ClientError.invalidRequest("Frozen customer batch is missing")
        }
        let outbox = PinduoduoV2GenerationOutboxStore(rootDirectory: rootDirectory)
        if let existing = try outbox.load(localJobID) { return existing }

        let requestTime = now()
        let cutoff = requestTime.addingTimeInterval(-48 * 60 * 60)
        // The hosted backend supplies the prompt. Retain the previous client assembly for reference.
        /*
        let configuredInstructions = try PinduoduoV2ReplyInstructionsFileProvider().instructions()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !configuredInstructions.isEmpty else {
            throw PinduoduoV2ClientError.invalidConfiguration("Pinduoduo V2 reply instructions are empty")
        }
        let contextInstructions = "Use the explicit target messages and conversation context dated at or after \(PinduoduoV2DateCodec.string(cutoff)). Ignore any older context retained by the service."
        let instructions = [configuredInstructions, CustomerFacingReplyPolicy.generationInstructions, contextInstructions]
            .joined(separator: "\n\n")
        guard instructions.utf8.count <= 16_384 else {
            throw PinduoduoV2ClientError.invalidConfiguration(
                "Pinduoduo V2 reply instructions exceed 16,384 UTF-8 bytes"
            )
        }
        */
        let ledger = PinduoduoV2HistoryLedger(rootDirectory: rootDirectory, customerUID: capture.uid)
        let synchronized = try ledger.snapshot()
        let futureLimit = requestTime.addingTimeInterval(5 * 60)

        var targetIDs = Array(batch.customerMessageIDs).sorted()
        if targetIDs.isEmpty, batch.incomingHandoffKey != nil,
           let lastCustomer = capture.fullHistory.last(where: { $0.sender == .customer }) {
            targetIDs = [lastCustomer.id]
        }
        guard !targetIDs.isEmpty else {
            throw PinduoduoV2ClientError.invalidRequest("The hosted API requires a real target customer message")
        }

        let historyByID = Dictionary(uniqueKeysWithValues: capture.fullHistory.map { ($0.id, $0) })
        for id in targetIDs {
            guard let message = historyByID[id], message.sender == .customer else {
                throw PinduoduoV2ClientError.invalidRequest("Target \(id) is not a customer row in history")
            }
        }

        // Transcript rows exist only in the API transport. They must not alter
        // AX history, customer cursors, send receipts or the original video text.
        let targetSet = Set(targetIDs)
        var transcriptsByVideo: [String: [PDDChatMessage]] = [:]
        for video in capture.videoAttachments where targetSet.contains(video.messageID) {
            guard let owner = historyByID[video.messageID], owner.kind == .video else {
                throw PinduoduoV2ClientError.invalidRequest("Transcript must belong to a target customer video")
            }
            let rows = Self.transcriptMessages(video: video, owner: owner)
            if let existing = transcriptsByVideo[video.messageID], existing != rows {
                throw PinduoduoV2ClientError.invalidRequest("Conflicting transcripts for one video message")
            }
            transcriptsByVideo[video.messageID] = rows
        }
        let transportHistory = capture.fullHistory.flatMap { message in
            [message] + (transcriptsByVideo[message.id] ?? [])
        }
        let transcriptOwners = Dictionary(uniqueKeysWithValues: transcriptsByVideo.flatMap { sourceID, rows in
            rows.map { ($0.id, sourceID) }
        })
        guard Set(transportHistory.map(\.id)).count == transportHistory.count else {
            throw PinduoduoV2ClientError.invalidRequest("Transcript ID conflicts with existing history")
        }

        var messageFingerprints: [String: String] = [:]
        var canonicalOccurredAtByMessageID: [String: String] = [:]
        for message in transportHistory {
            let currentOccurredAt = transcriptOwners[message.id]
                .flatMap { canonicalOccurredAtByMessageID[$0] }
                ?? PinduoduoV2DateCodec.string(message.capturedAt)
            canonicalOccurredAtByMessageID[message.id] = currentOccurredAt
            var fingerprint = Self.messageFingerprint(message, occurredAt: currentOccurredAt)
            if let old = synchronized.messages[message.id], old != fingerprint {
                let role: PinduoduoV2MessageRole = message.sender == .customer ? .customer : .service
                let candidates = try outbox.synchronizedMessageCandidates(
                    id: message.id,
                    fingerprint: old,
                    customerUID: capture.uid
                )
                guard let recovered = candidates.first(where: { candidate in
                    guard candidate.role == role else { return false }
                    if message.sender == .service, !targetSet.contains(message.id) {
                        return [ChatContentKind.text, .link, .image, .video].contains { kind in
                            let canonical = PDDChatMessage(id: message.id, sender: .service,
                                content: candidate.text, displayTime: nil, kind: kind,
                                capturedAt: message.capturedAt)
                            return Self.messageFingerprint(canonical, occurredAt: candidate.occurredAt) == old
                        }
                    }
                    // AX can enumerate the same text fragments in a different order.
                    // Retain the archived server copy only for previously accepted context.
                    let canReorderContext = message.sender == .customer && message.kind.supportsAXTextFragmentReordering
                        && !targetSet.contains(message.id) && transcriptOwners[message.id] == nil
                    guard candidate.text == message.content || (canReorderContext
                        && PDDMessageBodyText.sameAXTextFragments(candidate.text, message.content)) else { return false }
                    let canonical = PDDChatMessage(id: message.id, sender: message.sender,
                        content: candidate.text, displayTime: message.displayTime, kind: message.kind,
                        capturedAt: message.capturedAt)
                    return Self.messageFingerprint(canonical, occurredAt: candidate.occurredAt) == old
                }) else {
                    throw PinduoduoV2ClientError.invalidRequest("Message ID \(message.id) changed after synchronization")
                }
                canonicalOccurredAtByMessageID[message.id] = recovered.occurredAt
                fingerprint = old
            }
            messageFingerprints[message.id] = fingerprint
        }

        let transcriptIDs = Set(transcriptsByVideo.values.flatMap { $0.map(\.id) })
        let requiredIDs = targetSet.union(transcriptIDs.filter { synchronized.messages[$0] == nil })
        guard requiredIDs.count <= 100 else {
            throw PinduoduoV2ClientError.invalidRequest("Target videos and speech exceed the 100-message request limit")
        }
        let videosWithFrames = Set(capture.videoAttachments.filter { !$0.frames.isEmpty }.map(\.messageID))
        let eligible = transportHistory.filter { message in
            if message.sender == .service,
               synchronized.suppressedDeliveredServiceIDs.contains(message.id) { return false }
            if requiredIDs.contains(message.id) { return true }
            // The first hosted copy fixes the video's frame IDs. Leave a
            // pending video out of context until its frames can travel with it.
            if message.sender == .customer, message.kind == .video,
               !videosWithFrames.contains(message.id) { return false }
            guard synchronized.messages[message.id] == nil else { return false }
            // AX reads can capture an older visible row for the first time.
            // Use its native timestamp for context expiry when available.
            if let milliseconds = PDDAXSnapshotOrder.messageOrdinal(from: message.id),
               milliseconds >= 1_000_000_000_000 {
                return Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000) >= cutoff
            }
            return message.capturedAt >= cutoff
        }
        // Reserve space for the complete target batch and its speech before
        // retaining older context; never truncate speech to fit the window.
        let contextIDs = Set(eligible.filter { !requiredIDs.contains($0.id) }
            .suffix(100 - requiredIDs.count).map(\.id))
        let selected = eligible.filter { requiredIDs.contains($0.id) || contextIDs.contains($0.id) }
        guard requiredIDs.isSubset(of: Set(selected.map(\.id))) else {
            throw PinduoduoV2ClientError.invalidRequest("Target messages do not fit in the 100-message request limit")
        }
        for message in selected where message.capturedAt > futureLimit {
            throw PinduoduoV2ClientError.invalidRequest("Message \(message.id) is more than five minutes in the future")
        }

        let selectedIDs = Set(selected.map(\.id))
        let mediaDirectory = try outbox.mediaDirectory(localJobID)
        var manifest: [PinduoduoV2Media] = []
        var files: [PinduoduoV2FrozenFile] = []
        var referencedMediaIDs: [String] = []
        var mediaIDsByMessage: [String: [String]] = [:]
        var mediaFingerprints: [String: String] = [:]

        for image in capture.imageAttachments where selectedIDs.contains(image.messageID) {
            let mediaID = Self.stableID(prefix: "image", material: "\(image.messageID)|\(image.sha256)")
            let fingerprint = "\(image.messageID)|image|\(image.sha256)|\(image.mimeType.lowercased())"
            try appendMedia(
                id: mediaID, messageID: image.messageID, kind: .image, label: "customer image",
                timestampMs: nil, sourceURL: image.localURL, declaredMIME: image.mimeType,
                declaredSHA256: image.sha256, fingerprint: fingerprint,
                synchronized: synchronized.media, mediaDirectory: mediaDirectory,
                manifest: &manifest, files: &files, references: &referencedMediaIDs,
                idsByMessage: &mediaIDsByMessage, fingerprints: &mediaFingerprints
            )
        }
        for video in capture.videoAttachments where selectedIDs.contains(video.messageID) {
            for frame in video.frames.sorted(by: { $0.timestampSeconds < $1.timestampSeconds }) {
                let timestamp = Int((frame.timestampSeconds * 1_000).rounded())
                let data = try Data(contentsOf: frame.localURL, options: [.mappedIfSafe])
                let digest = Self.sha256(data)
                let mediaID = Self.stableID(prefix: "frame", material: "\(video.messageID)|\(timestamp)|\(digest)")
                let fingerprint = "\(video.messageID)|frame|\(timestamp)|\(digest)|image/jpeg"
                try appendMedia(
                    id: mediaID, messageID: video.messageID, kind: .frame,
                    label: String(format: "video frame %.3fs", frame.timestampSeconds),
                    timestampMs: timestamp, sourceURL: frame.localURL, declaredMIME: "image/jpeg",
                    declaredSHA256: digest, fingerprint: fingerprint,
                    synchronized: synchronized.media, mediaDirectory: mediaDirectory,
                    manifest: &manifest, files: &files, references: &referencedMediaIDs,
                    idsByMessage: &mediaIDsByMessage, fingerprints: &mediaFingerprints
                )
            }
        }

        guard files.count <= 50 else { throw PinduoduoV2ClientError.invalidRequest("More than 50 new media files") }
        let combinedBytes = files.reduce(0) { $0 + $1.byteCount }
        guard combinedBytes <= 50 * 1_024 * 1_024 else {
            throw PinduoduoV2ClientError.invalidRequest("Combined media exceeds 50 MiB")
        }

        let messages = try selected.map { message -> PinduoduoV2Message in
            try Self.validateID(message.id, name: "message id")
            guard message.content.count <= 10_000 else {
                throw PinduoduoV2ClientError.invalidRequest("Message \(message.id) exceeds 10,000 characters")
            }
            return PinduoduoV2Message(
                id: message.id,
                role: message.sender == .customer ? .customer : .service,
                text: message.content,
                occurredAt: canonicalOccurredAtByMessageID[message.id]
                    ?? PinduoduoV2DateCodec.string(message.capturedAt),
                mediaIds: mediaIDsByMessage[message.id] ?? []
            )
        }
        let historyVersion = "batch-" + localJobID.uuidString.lowercased()
        let request = PinduoduoV2ReplyRequest(
            storeId: PinduoduoV2Configuration.storeID,
            customerUid: capture.uid,
            historyVersion: historyVersion,
            idempotencyKey: localJobID.uuidString.lowercased(),
            messages: messages,
            targetMessageIds: targetIDs,
            referencedMediaIds: referencedMediaIDs.isEmpty ? nil : referencedMediaIDs,
            media: manifest,
            replyInstructions: ""
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let requestJSON = try encoder.encode(request)
        guard requestJSON.count <= 200_000 else {
            throw PinduoduoV2ClientError.invalidRequest("Request JSON exceeds 200,000 UTF-8 bytes")
        }
        let selectedFingerprints = Dictionary(uniqueKeysWithValues: selected.map {
            ($0.id, messageFingerprints[$0.id]!)
        })
        let record = PinduoduoV2GenerationOutboxRecord(
            localJobID: localJobID,
            customerUid: capture.uid,
            historyVersion: historyVersion,
            idempotencyKey: localJobID.uuidString.lowercased(),
            requestJSON: requestJSON,
            files: files,
            messageFingerprints: selectedFingerprints,
            mediaFingerprints: mediaFingerprints,
            createdAt: now(),
            phase: .frozen
        )
        try outbox.save(record)
        let speechRows = selected.filter { transcriptIDs.contains($0.id) }
        if !speechRows.isEmpty {
            AutomationStepLog.record(root: rootDirectory, uid: capture.uid,
                step: "hosted-video-transcript-frozen",
                detail: "job=\(localJobID); video_count=\(transcriptsByVideo.values.filter { !$0.isEmpty }.count); transcript_messages=\(speechRows.count); text_characters=\(speechRows.reduce(0) { $0 + $1.content.count })")
        }
        return record
    }

    private func appendMedia(
        id: String,
        messageID: String,
        kind: PinduoduoV2MediaKind,
        label: String,
        timestampMs: Int?,
        sourceURL: URL,
        declaredMIME: String,
        declaredSHA256: String,
        fingerprint: String,
        synchronized: [String: String],
        mediaDirectory: URL,
        manifest: inout [PinduoduoV2Media],
        files: inout [PinduoduoV2FrozenFile],
        references: inout [String],
        idsByMessage: inout [String: [String]],
        fingerprints: inout [String: String]
    ) throws {
        if let old = synchronized[id] {
            guard old == fingerprint else {
                throw PinduoduoV2ClientError.invalidRequest("Media ID \(id) changed after synchronization")
            }
            references.append(id)
            idsByMessage[messageID, default: []].append(id)
            return
        }
        let mime = declaredMIME.lowercased() == "image/jpg" ? "image/jpeg" : declaredMIME.lowercased()
        guard ["image/jpeg", "image/png", "image/webp"].contains(mime) else {
            throw PinduoduoV2ClientError.invalidRequest("Unsupported media MIME \(declaredMIME)")
        }
        let data = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
        guard data.count <= 20 * 1_024 * 1_024 else {
            throw PinduoduoV2ClientError.invalidRequest("Media \(id) exceeds 20 MiB")
        }
        let digest = Self.sha256(data)
        guard digest == declaredSHA256.lowercased() else {
            throw PinduoduoV2ClientError.invalidRequest("Media \(id) bytes changed before freezing")
        }
        try Self.validateMagic(data, mime: mime)
        let ext = mime == "image/png" ? "png" : mime == "image/webp" ? "webp" : "jpg"
        let filename = "\(String(format: "%03d", files.count + 1))-\(id).\(ext)"
        let destination = mediaDirectory.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: destination.path) {
            guard try Data(contentsOf: destination) == data else {
                throw PinduoduoV2ClientError.invalidRequest("Frozen media destination conflict for \(id)")
            }
        } else {
            try data.write(to: destination, options: .atomic)
        }
        manifest.append(.init(id: id, messageId: messageID, kind: kind, label: label, timestampMs: timestampMs))
        files.append(.init(mediaID: id, path: destination.path, filename: filename, mimeType: mime,
                           byteCount: data.count, sha256: digest))
        idsByMessage[messageID, default: []].append(id)
        fingerprints[id] = fingerprint
    }

    private static func messageFingerprint(
        _ message: PDDChatMessage,
        occurredAt: String? = nil
    ) -> String {
        let material = [message.sender.rawValue, message.kind.rawValue, message.content,
                        occurredAt ?? PinduoduoV2DateCodec.string(message.capturedAt)]
            .joined(separator: "\u{1f}")
        return sha256(Data(material.utf8))
    }

    private static func transcriptMessages(
        video: AutoReplyVideoAttachment,
        owner: PDDChatMessage
    ) -> [PDDChatMessage] {
        let segments = video.transcriptSegments.filter {
            $0.startSeconds.isFinite && $0.startSeconds >= 0
                && $0.durationSeconds.isFinite && $0.durationSeconds >= 0
                && ($0.startSeconds + $0.durationSeconds).isFinite
                && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.sorted { $0.startSeconds < $1.startSeconds }
        let timedText = segments.map { segment in
            String(format: "[%.3f-%.3fs] %@", locale: Locale(identifier: "en_US_POSIX"),
                segment.startSeconds, segment.startSeconds + segment.durationSeconds,
                segment.text.trimmingCharacters(in: .whitespacesAndNewlines))
        }.joined(separator: "\n")
        let text = (timedText.isEmpty ? video.transcript ?? "" : timedText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }

        var chunks: [String] = []
        var remaining = text[...]
        while !remaining.isEmpty {
            let end = remaining.index(remaining.startIndex, offsetBy: 9_000,
                limitedBy: remaining.endIndex) ?? remaining.endIndex
            chunks.append(String(remaining[..<end]))
            remaining = remaining[end...]
        }
        return chunks.enumerated().map { index, chunk in
            let content = "Speech transcript for video message \(owner.id) (part \(index + 1)/\(chunks.count)). Automatically transcribed customer speech; may contain recognition errors.\n\(chunk)"
            let id = stableID(prefix: "video-transcript", material: "v1|\(owner.id)|\(index)|\(content)")
            return PDDChatMessage(id: id, sender: .customer, content: content,
                displayTime: nil, kind: .text, capturedAt: owner.capturedAt)
        }
    }

    private static func stableID(prefix: String, material: String) -> String {
        prefix + "-" + String(sha256(Data(material.utf8)).prefix(48))
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func validateID(_ value: String, name: String) throws {
        if value.hasPrefix("fallback-") {
            throw PinduoduoV2ClientError.invalidRequest(
                "A text-derived fallback event ID cannot be synchronized as durable Pinduoduo history"
            )
        }
        guard !value.isEmpty, value.count <= 200,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw PinduoduoV2ClientError.invalidRequest("Invalid \(name)")
        }
    }

    private static func validateMagic(_ data: Data, mime: String) throws {
        let bytes = [UInt8](data.prefix(12))
        let valid: Bool
        switch mime {
        case "image/jpeg": valid = bytes.starts(with: [0xff, 0xd8, 0xff])
        case "image/png": valid = bytes.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
        case "image/webp":
            valid = bytes.count >= 12 && Array(bytes[0..<4]) == Array("RIFF".utf8)
                && Array(bytes[8..<12]) == Array("WEBP".utf8)
        default: valid = false
        }
        guard valid else { throw PinduoduoV2ClientError.invalidRequest("Media bytes do not match \(mime)") }
    }
}
