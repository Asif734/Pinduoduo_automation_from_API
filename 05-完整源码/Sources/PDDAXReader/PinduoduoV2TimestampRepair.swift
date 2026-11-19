import CryptoKit
import Foundation

/// A definitively rejected request can become a new corrected task only when
/// previously synchronized data proves that timestamps alone were wrong.
/// Pending execution, uncertain sends, changed text and media are excluded.
enum PinduoduoV2TimestampRepair {
    private struct Instructions: PinduoduoV2ReplyInstructionsProviding {
        let value: String
        func instructions() throws -> String { value }
    }

    static func replacement(for job: AutoReplyJob, root: URL) throws -> UUID? {
        let store = PinduoduoV2GenerationOutboxStore(rootDirectory: root)
        guard !job.sendWasInvoked, job.deliveryOutcome == .notSent,
              job.supersededByJobID == nil, job.outgoingImages.isEmpty,
              job.capture.batch?.incomingHandoffKey == nil,
              let original = try store.load(job.id), original.phase == .failed,
              original.lastErrorCode == "MESSAGE_ID_CONFLICT", original.result == nil,
              original.localJobID == job.id, original.customerUid == job.uid,
              original.files.isEmpty else { return nil }
        let request = try JSONDecoder().decode(PinduoduoV2ReplyRequest.self, from: original.requestJSON)
        guard request.media.isEmpty, request.customerUid == job.uid,
              Set(request.targetMessageIds) == job.capture.batch?.customerMessageIDs else { return nil }
        let ledger = try PinduoduoV2HistoryLedger(rootDirectory: root, customerUID: job.uid).snapshot()
        var canonical: [String: PinduoduoV2Message] = [:]
        var changedTimestamp = false
        for message in request.messages {
            guard let fingerprint = ledger.messages[message.id], message.mediaIds.isEmpty else { return nil }
            let candidates = try store.synchronizedMessageCandidates(id: message.id, fingerprint: fingerprint, customerUID: job.uid)
                .filter { $0.role == message.role && $0.text == message.text && $0.mediaIds.isEmpty }
            guard candidates.count == 1, let proven = candidates.first else { return nil }
            canonical[message.id] = proven
            changedTimestamp = changedTimestamp || message.occurredAt != proven.occurredAt
        }
        guard changedTimestamp else { return nil }
        let hash = SHA256.hash(data: Data("pdd-timestamp-repair:\(job.id.uuidString)".utf8))
            .map { String(format: "%02x", $0) }.joined()
        let hex = String(hash.prefix(32))
        let parts = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { range in
            String(hex[hex.index(hex.startIndex, offsetBy: range.lowerBound)..<hex.index(hex.startIndex, offsetBy: range.upperBound)])
        }
        let id = UUID(uuidString: parts.joined(separator: "-"))!
        let corrected = try PinduoduoV2RequestBuilder(rootDirectory: root,
            instructionsProvider: Instructions(value: request.replyInstructions)).freeze(localJobID: id, capture: job.capture)
        let newRequest = try JSONDecoder().decode(PinduoduoV2ReplyRequest.self, from: corrected.requestJSON)
        guard corrected.files.isEmpty, newRequest.media.isEmpty,
              Set(newRequest.targetMessageIds) == Set(request.targetMessageIds),
              newRequest.historyVersion != original.historyVersion,
              newRequest.messages.allSatisfy({ message in
                  guard let proven = canonical[message.id] else { return false }
                  return message.role == proven.role && message.text == proven.text
                      && message.occurredAt == proven.occurredAt && message.mediaIds == proven.mediaIds
              }) else { return nil }
        return id
    }
}
