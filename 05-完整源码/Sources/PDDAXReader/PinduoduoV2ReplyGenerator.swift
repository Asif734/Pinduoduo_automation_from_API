import CryptoKit
import Foundation

struct PinduoduoV2ReplyGenerator: DurableJobAutoReplyGenerating, AutoReplyGenerationPolicyProviding, Sendable {
    let rootDirectory: URL
    let client: PinduoduoV2APIClient
    let credentials: any PinduoduoV2CredentialProviding
    let now: @Sendable () -> Date
    let sleep: @Sendable (Duration) async throws -> Void
    let overallWait: TimeInterval

    var serializesGenerationBehindActiveDelivery: Bool { true }

    init(
        rootDirectory: URL,
        client: PinduoduoV2APIClient = PinduoduoV2APIClient(),
        credentials: any PinduoduoV2CredentialProviding = PinduoduoV2EnvironmentCredentialProvider(),
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        overallWait: TimeInterval = 600
    ) {
        self.rootDirectory = rootDirectory
        self.client = client
        self.credentials = credentials
        self.now = now
        self.sleep = sleep
        self.overallWait = overallWait
    }

    func generate(_ capture: AutoReplyCapture) async throws -> CodexReplyResult {
        throw PinduoduoV2ClientError.invalidRequest("Hosted generation requires the durable local job ID")
    }

    func generate(jobID: UUID, capture: AutoReplyCapture) async throws -> CodexReplyResult {
        let key = try credentials.apiKey()
        let store = PinduoduoV2GenerationOutboxStore(rootDirectory: rootDirectory)
        var record = try PinduoduoV2RequestBuilder(rootDirectory: rootDirectory, now: now)
            .freeze(localJobID: jobID, capture: capture)
        guard record.phase != .expired else { throw PinduoduoV2ClientError.expired }
        try validateFrozenFiles(record.files)
        let deadline = now().addingTimeInterval(overallWait)

        if record.hostedJobID == nil {
            _ = try await retryUndecodableResponse(jobID: jobID, uid: capture.uid, deadline: deadline) {
                try await client.status(apiKey: key, now: now())
            }
            var attempt = 0
            while record.hostedJobID == nil {
                try Task.checkCancellation()
                guard now() < deadline else {
                    record.phase = .recoveryRequired
                    try store.save(record)
                    throw PinduoduoV2ClientError.overallDeadline
                }
                do {
                    let frozen = record
                    let accepted = try await retryUndecodableResponse(jobID: jobID, uid: capture.uid, deadline: deadline) {
                        try await client.submit(frozen, apiKey: key)
                    }
                    record.hostedJobID = accepted.jobId
                    record.pollURL = accepted.pollUrl
                    record.phase = accepted.status == "recovery_required" ? .recoveryRequired : .accepted
                    try store.save(record)
                    // A replay may return an original terminal failure caused
                    // by conflicting input. Preserve its binding and poll the
                    // error; rejected input cannot replace synchronized hashes.
                    if accepted.status != "failed" && accepted.status != "expired" {
                        try PinduoduoV2HistoryLedger(rootDirectory: rootDirectory, customerUID: record.customerUid)
                            .markAccepted(messages: record.messageFingerprints, media: record.mediaFingerprints)
                    }
                } catch let error as PinduoduoV2ClientError where error.retryable {
                    attempt += 1
                    try await backoff(attempt: attempt, minimum: error.retryAfter)
                }
            }
        }

        guard let hostedJobID = record.hostedJobID,
              let pollString = record.pollURL,
              let pollURL = URL(string: pollString) else {
            throw PinduoduoV2ClientError.invalidResponse("Accepted outbox is missing its hosted job binding")
        }
        var transientAttempt = 0
        while true {
            try Task.checkCancellation()
            guard now() < deadline else {
                record.phase = .recoveryRequired
                try store.save(record)
                throw PinduoduoV2ClientError.overallDeadline
            }
            do {
                let job = try await retryUndecodableResponse(jobID: jobID, uid: capture.uid, deadline: deadline) {
                    try await client.poll(url: pollURL, expectedJobID: hostedJobID,
                        customerUID: record.customerUid, historyVersion: record.historyVersion, apiKey: key)
                }
                transientAttempt = 0
                switch job.status {
                case "queued", "processing":
                    if record.phase == .recoveryRequired { throw PinduoduoV2ClientError.recoveryPending }
                    try await sleep(.milliseconds(Int.random(in: 1_500...3_000)))
                case "recovery_required":
                    record.phase = .recoveryRequired
                    try store.save(record)
                    throw PinduoduoV2ClientError.recoveryPending
                case "completed":
                    guard let binding = job.binding,
                          let digest = job.resultDigest,
                          let reply = job.reply,
                          let action = CodexReplyAction(rawValue: reply.action),
                          let transferReason = CodexTransferReason(rawValue: reply.transferReason) else {
                        throw PinduoduoV2ClientError.invalidResponse("Completed job omitted validated output")
                    }
                    let receipt = PinduoduoV2GenerationReceipt(
                        jobId: binding.jobId,
                        platform: binding.platform,
                        storeId: binding.storeId,
                        customerUid: binding.customerUid,
                        historyVersion: binding.historyVersion,
                        resultDigest: digest
                    )
                    record.phase = .completed
                    record.result = receipt
                    try store.save(record)
                    var finishedReply = reply.replyText
                    if let violation = CustomerFacingReplyPolicy.violation(in: finishedReply) {
                        let targetIDs = capture.batch?.customerMessageIDs ?? []
                        let targets = capture.fullHistory.filter { targetIDs.contains($0.id) }
                        // Fallbacks scan from the end: prefer identifiable target
                        // language, then retain context for media-only/unclear input.
                        let languageHistory = capture.fullHistory + targets
                        if action == .replyThenTransfer {
                            finishedReply = CustomerFacingFallback.handoff(history: languageHistory)
                        } else if violation == "video processing status" {
                            finishedReply = CustomerFacingFallback.videoQuestion(history: languageHistory)
                        } else {
                            finishedReply = CustomerFacingFallback.productProblemQuestion(history: languageHistory)
                        }
                        AutomationStepLog.record(root: rootDirectory, uid: capture.uid,
                            step: "hosted-generation-wording-completed",
                            detail: "job=\(jobID); \(violation); neutral wording produced during generation; action and result binding preserved")
                    }
                    return CodexReplyResult(
                        reply: finishedReply,
                        threadID: hostedJobID,
                        action: action,
                        transferReason: transferReason,
                        hostedGeneration: receipt
                    )
                case "failed":
                    let code = job.error?.code ?? "CODEX_FAILED"
                    record.phase = .failed
                    record.lastErrorCode = code
                    try store.save(record)
                    throw PinduoduoV2ClientError.jobFailed(code: code, message: job.error?.message)
                case "expired":
                    throw PinduoduoV2ClientError.expired
                default:
                    throw PinduoduoV2ClientError.invalidResponse("Unknown Pinduoduo V2 job state: \(job.status)")
                }
            } catch PinduoduoV2ClientError.expired {
                // Both a terminal JSON reply and HTTP 410 expire the same job.
                record.phase = .expired
                try store.save(record)
                throw PinduoduoV2ClientError.expired
            } catch let error as PinduoduoV2ClientError where error.retryable {
                transientAttempt += 1
                try await backoff(attempt: transientAttempt, minimum: error.retryAfter)
            }
        }
    }

    private func retryUndecodableResponse<Value>(jobID: UUID, uid: String, deadline: Date,
        operation: () async throws -> Value) async throws -> Value {
        var retries = 0
        while true {
            try Task.checkCancellation()
            do { return try await operation() }
            catch let error as PinduoduoV2ClientError {
                guard case .invalidJSON = error, retries < 2, now() < deadline else { throw error }
                retries += 1
                AutomationStepLog.record(root: rootDirectory, uid: uid, step: "hosted-response-decode-retry",
                    detail: "job=\(jobID); \(error.localizedDescription)")
                try await backoff(attempt: retries)
                guard now() < deadline else { throw error }
            }
        }
    }

    private func backoff(attempt: Int, minimum: TimeInterval? = nil) async throws {
        let seconds = min(30.0, pow(2.0, Double(max(0, attempt - 1))))
        let jitter = Double.random(in: 0...(seconds * 0.25))
        try await sleep(.milliseconds(Int(max(seconds + jitter, minimum ?? 0) * 1_000)))
    }

    private func validateFrozenFiles(_ files: [PinduoduoV2FrozenFile]) throws {
        for file in files {
            let url = URL(fileURLWithPath: file.path)
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard data.count == file.byteCount, digest == file.sha256 else {
                throw PinduoduoV2ClientError.invalidRequest("Frozen media changed for \(file.mediaID)")
            }
        }
    }
}
