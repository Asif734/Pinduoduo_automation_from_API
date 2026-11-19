import Foundation

enum PDDVideoFallbackRecovery {
    static let reply = "视频已收到，您希望我重点帮您查看哪个问题？也可以描述一下具体表现。"

    /// Preserve already-sent questions and retire media waits restored by the
    /// earlier retry policy. Never resend that question or reopen the video.
    static func settleSentFallbacks(in state: inout AutoReplyPersistentState, root: URL, at date: Date) throws -> Bool {
        let records = try PDDDurableVideoTransferStore.persistedRecords(
            at: root.appendingPathComponent("videos/transfer-state.json")
        )
        var changed = false
        for index in state.jobs.indices {
            let job = state.jobs[index]
            guard [.completed, .failed].contains(job.state), job.deliveryOutcome == .sent,
                  job.omittedAt == nil, job.reply == reply, job.hostedGeneration == nil,
                  job.videoAttachments.isEmpty, job.capture.videoAttachments.isEmpty,
                  let batch = job.capture.batch, !batch.events.isEmpty,
                  batch.events.allSatisfy({ $0.kind == .video }),
                  batch.events.allSatisfy({ event in
                      records.contains { $0.uid == job.uid && $0.messageID == event.messageID
                          && ($0.phase == .waitingForRetry || $0.phase == .terminalFailure) }
                  }),
                  !state.jobs.contains(where: { other in
                      other.id != job.id && other.uid == job.uid
                          && other.videoAttachments.contains { batch.customerMessageIDs.contains($0.messageID) }
                  }) else { continue }
            guard job.state == .failed || state.pendingVideoBatches.contains(where: {
                $0.uid == job.uid && !batch.customerMessageIDs.isDisjoint(with: Set($0.expectedMessageIDs))
            }) else { continue }
            try CustomerMessageReceipts(root: root).acknowledgeVideoFallback(
                uid: job.uid, messageIDs: batch.customerMessageIDs
            )
            state.jobs[index].state = .completed
            state.jobs[index].lastError = nil
            let detail = "source=\(job.id); message_ids=\(batch.customerMessageIDs.sorted().joined(separator: ",")); product question already sent; no video retry"
            state.events.append(.init(id: UUID(), timestamp: date, uid: job.uid,
                kind: "video-fallback-awaiting-customer", detail: detail))
            AutomationStepLog.record(root: root, uid: job.uid,
                step: "video-fallback-awaiting-customer", detail: detail)
            changed = true
        }
        return changed
    }
}
