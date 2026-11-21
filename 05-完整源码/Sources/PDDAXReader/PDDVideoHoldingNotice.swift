import Foundation

/// Retained so checkpoints written before removal of the courtesy timer still load.
struct PDDVideoHoldingNotice: Codable, Equatable, Sendable, Identifiable {
    static let message = "请稍等一下。方便的话，也可以补充描述一下具体情况。"
    let id: UUID
    var uid: String
    var messageIDs: Set<String>
    let capturedAt: Date
    let text: String
    var attemptedAt: Date?
    var finishedAt: Date?
    var outcome: String?
    var confirmedServiceMessageID: String?

    init(uid: String, messageIDs: Set<String>, capturedAt: Date) {
        id = UUID(); self.uid = uid; self.messageIDs = messageIDs
        self.capturedAt = capturedAt; text = Self.message
    }
}

/// Join only messages whose shared history actually contains every target ID.
/// Keeps the chronological customer intent and all original media attachments.
enum PDDVideoReplyBatch {
    static func joining(_ captures: [AutoReplyCapture]) -> AutoReplyCapture? {
        guard let first = captures.first, captures.allSatisfy({ $0.uid == first.uid && $0.batch?.incomingHandoffKey == nil }),
              let latest = captures.max(by: { $0.customerCursor.count < $1.customerCursor.count }) else { return nil }
        let ids = Set(captures.flatMap { $0.batch?.events.map(\.messageID) ?? [] })
        guard ids.isSubset(of: Set(latest.fullHistory.map(\.id))),
              let timeline = try? AutoReplyTimeline.make(messages: latest.fullHistory),
              let whole = try? timeline.freeze(after: .empty) else { return nil }
        let events = whole.events.filter { ids.contains($0.messageID) }
        guard events.count == ids.count else { return nil }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let lines = try? events.map({ String(decoding: try encoder.encode($0), as: UTF8.self) }) else { return nil }
        func unique<T>(_ values: [T], key: (T) -> String) -> [T] {
            var seen = Set<String>(); return values.filter { seen.insert(key($0)).inserted }
        }
        return AutoReplyCapture(uid: first.uid, fullHistory: latest.fullHistory,
            batch: .init(startCursor: captures.compactMap { $0.batch?.startCursor }.min(by: { $0.count < $1.count }) ?? .empty,
                         endCursor: latest.customerCursor, events: events, targetCustomerJSONL: lines.joined(separator: "\n")),
            customerCursor: latest.customerCursor, unexpectedServiceMessageIDs: [],
            ocrDiagnostic: captures.compactMap(\.ocrDiagnostic).joined(separator: "; "),
            imageAttachments: unique(captures.flatMap(\.imageAttachments), key: { $0.messageID }),
            videoAttachments: unique(captures.flatMap(\.videoAttachments), key: { $0.messageID }),
            pendingVideoMessageIDs: Array(Set(captures.flatMap(\.pendingVideoMessageIDs))).sorted())
    }
}
