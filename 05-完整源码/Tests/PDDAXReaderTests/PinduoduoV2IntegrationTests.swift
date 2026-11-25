import CryptoKit
import Foundation
import XCTest
@testable import PDDAXReader

final class PinduoduoV2IntegrationTests: XCTestCase {
    func testNewBatchIncludesOnlyLast48HoursOfContextAndPreservesExplicitTargets() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let cutoff = now.addingTimeInterval(-48 * 60 * 60)
        let expired = PDDChatMessage(id: "expired-context", sender: .service, content: "Earlier reply",
            displayTime: nil, kind: .text, capturedAt: cutoff.addingTimeInterval(-1))
        let recent = PDDChatMessage(id: "recent-context", sender: .service, content: "Current setup",
            displayTime: nil, kind: .text, capturedAt: cutoff)
        let oldTarget = PDDChatMessage(id: "unanswered-target", sender: .customer, content: "Please help",
            displayTime: nil, kind: .text, capturedAt: cutoff.addingTimeInterval(-3))
        let current = PDDChatMessage(id: "new-target", sender: .customer, content: "How do I connect it?",
            displayTime: nil, kind: .text, capturedAt: now)
        let capture = try makeCapture(uid: "two-day-context", messages: [oldTarget, expired, recent, current],
            targets: [oldTarget.id, current.id])
        let frozen = try PinduoduoV2RequestBuilder(rootDirectory: root, now: { now })
            .freeze(localJobID: UUID(), capture: capture)
        let request = try JSONDecoder().decode(PinduoduoV2ReplyRequest.self, from: frozen.requestJSON)
        XCTAssertEqual(request.messages.map(\.id), [oldTarget.id, recent.id, current.id])
        XCTAssertEqual(Set(request.targetMessageIds), [oldTarget.id, current.id])
        XCTAssertTrue(request.replyInstructions.isEmpty, "The backend supplies the policy for new requests")
    }

    func testExistingFrozenRequestKeepsItsOriginalPromptWhenRetried() throws {
        let root = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let capture = try makeCapture(uid: "customer", messages: [message("q", .customer, "转亭子", seconds: 0)], targets: ["q"])
        let id = UUID()
        let builder = PinduoduoV2RequestBuilder(rootDirectory: root)
        let record = try builder.freeze(localJobID: id, capture: capture)
        var request = try XCTUnwrap(JSONSerialization.jsonObject(with: record.requestJSON) as? [String: Any])
        XCTAssertEqual(request["replyInstructions"] as? String, "")
        request["replyInstructions"] = "Previously submitted policy"
        let legacy = PinduoduoV2GenerationOutboxRecord(
            localJobID: id, customerUid: record.customerUid, historyVersion: record.historyVersion,
            idempotencyKey: record.idempotencyKey, requestJSON: try JSONSerialization.data(withJSONObject: request),
            files: record.files, messageFingerprints: record.messageFingerprints, mediaFingerprints: record.mediaFingerprints,
            createdAt: record.createdAt, phase: .accepted, hostedJobID: "existing-job"
        )
        try PinduoduoV2GenerationOutboxStore(rootDirectory: root).save(legacy)

        let repeated = try builder.freeze(localJobID: id, capture: capture)
        XCTAssertEqual(repeated.requestJSON, legacy.requestJSON)
        XCTAssertEqual(repeated.idempotencyKey, legacy.idempotencyKey)
        XCTAssertEqual(repeated.hostedJobID, legacy.hostedJobID)
    }

    func testBundledMerchantPolicyKeptForReference() throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let policy = project.appendingPathComponent("Resources/CustomerService/pinduoduo-v2-reply-instructions.txt")
        let instructions = try PinduoduoV2ReplyInstructionsFileProvider(candidates: [policy]).instructions()
        XCTAssertTrue(instructions.contains("如果调整后问题仍然存在，请先暂停试打。"))
        XCTAssertTrue(instructions.contains("请问您之前是从哪里下载安装包的？我们先确认来源，再继续安装。"))
        XCTAssertTrue(instructions.contains("Keep contact and payments within Pinduoduo"))
        XCTAssertTrue(instructions.contains("Never tie money, coupons, gifts, or other benefits to a review"))
        XCTAssertLessThanOrEqual(instructions.utf8.count, 16_384)
    }

    func testGenerationFinishesObservedIdentityRepliesAsNeutralHelpWithoutParking() async throws {
        for (customerText, generated, expected) in [
            ("转亭子", "您是想转人工客服吗？", "请问您的产品遇到了什么问题？麻烦您描述一下具体表现，我来帮您排查。"),
            ("在吗", "在的，您刚才是想转人工客服吗？", "请问您的产品遇到了什么问题？麻烦您描述一下具体表现，我来帮您排查。"),
            ("Can you help me?", "Would you like a human agent?", "What problem are you having with the product? Please describe what happens so I can help you troubleshoot."),
            ("打印不了", "I am an AI assistant.", "请问您的产品遇到了什么问题？麻烦您描述一下具体表现，我来帮您排查。"),
            ("打印不了", "我是AI客服。", "请问您的产品遇到了什么问题？麻烦您描述一下具体表现，我来帮您排查。"),
            ("Please help", "I’m a robot.", "What problem are you having with the product? Please describe what happens so I can help you troubleshoot."),
            ("Please help", "I am a real person.", "What problem are you having with the product? Please describe what happens so I can help you troubleshoot.")
        ] {
            let root = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
            let capture = try makeCapture(uid: "customer", messages: [message("q", .customer, customerText, seconds: 0)], targets: ["q"])
            let id = UUID()
            var record = try PinduoduoV2RequestBuilder(rootDirectory: root).freeze(localJobID: id, capture: capture)
            record.phase = .accepted; record.hostedJobID = "existing-job"
            record.pollURL = "/api/codex/pinduoduo/v2/replies/existing-job?storeId=pinduoduo-default"
            try PinduoduoV2GenerationOutboxStore(rootDirectory: root).save(record)
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: completedJSON(jobID: "existing-job", uid: "customer", historyVersion: record.historyVersion)) as? [String: Any])
            var reply = object["reply"] as! [String: Any]; reply["reply_text"] = generated; object["reply"] = reply
            let transport = RecordingV2Transport(responses: [.success(response(status: 200, body: json(object)))])
            let generator = PinduoduoV2ReplyGenerator(rootDirectory: root, client: .init(transport: transport), credentials: FixedV2Credential(value: "key"))
            let result = try await generator.generate(jobID: id, capture: capture)
            XCTAssertEqual(result.reply, expected)
            XCTAssertEqual(result.action, .reply)
            XCTAssertEqual(result.transferReason, .none)
            XCTAssertEqual(result.hostedGeneration?.jobId, "existing-job")
            XCTAssertEqual(result.hostedGeneration?.resultDigest, String(repeating: "a", count: 64))
            let completed = try XCTUnwrap(PinduoduoV2GenerationOutboxStore(rootDirectory: root).load(id))
            XCTAssertEqual(completed.phase, .completed)
            XCTAssertEqual(completed.requestJSON, record.requestJSON)
            XCTAssertEqual(transport.requests.map { $0.request.httpMethod }, ["GET"])
        }
    }

    func testMediaOnlyWordingCompletionKeepsPreviousCustomerLanguage() async throws {
        let root = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let image = PDDChatMessage(id: "photo", sender: .customer, content: "[图片]", displayTime: nil, kind: .image, capturedAt: Date())
        let capture = try makeCapture(uid: "customer", messages: [message("previous", .customer, "Can you help me with this printer?", seconds: -5), image], targets: ["photo"])
        let id = UUID()
        // An already accepted media request needs no reupload to poll its result.
        let record = PinduoduoV2GenerationOutboxRecord(localJobID: id, customerUid: "customer", historyVersion: "accepted-photo", idempotencyKey: id.uuidString, requestJSON: Data(), files: [], messageFingerprints: [:], mediaFingerprints: [:], createdAt: Date(), phase: .accepted, hostedJobID: "existing-job", pollURL: "/api/codex/pinduoduo/v2/replies/existing-job?storeId=pinduoduo-default")
        try PinduoduoV2GenerationOutboxStore(rootDirectory: root).save(record)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: completedJSON(jobID: "existing-job", uid: "customer", historyVersion: "accepted-photo")) as? [String: Any])
        var reply = object["reply"] as! [String: Any]; reply["reply_text"] = "Would you like a human agent?"; object["reply"] = reply
        let transport = RecordingV2Transport(responses: [.success(response(status: 200, body: json(object)))])
        let generator = PinduoduoV2ReplyGenerator(rootDirectory: root, client: .init(transport: transport), credentials: FixedV2Credential(value: "key"))
        let result = try await generator.generate(jobID: id, capture: capture)
        XCTAssertEqual(result.reply, "What problem are you having with the product? Please describe what happens so I can help you troubleshoot.")
    }

    func testGenerationKeepsApprovedTransferActionWithNeutralWording() async throws {
        let root = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let capture = try makeCapture(uid: "customer", messages: [message("q", .customer, "请继续处理售后", seconds: 0)], targets: ["q"])
        let id = UUID()
        var record = try PinduoduoV2RequestBuilder(rootDirectory: root).freeze(localJobID: id, capture: capture)
        record.phase = .accepted; record.hostedJobID = "existing-job"; record.pollURL = "/api/codex/pinduoduo/v2/replies/existing-job?storeId=pinduoduo-default"
        try PinduoduoV2GenerationOutboxStore(rootDirectory: root).save(record)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: completedJSON(jobID: "existing-job", uid: "customer", historyVersion: record.historyVersion)) as? [String: Any])
        var reply = object["reply"] as! [String: Any]
        reply["reply_text"] = "我帮您转人工客服处理。"; reply["action"] = "reply_then_transfer"; reply["transfer_reason"] = "refund_operation"; object["reply"] = reply
        let transport = RecordingV2Transport(responses: [.success(response(status: 200, body: json(object)))])
        let generator = PinduoduoV2ReplyGenerator(rootDirectory: root, client: .init(transport: transport), credentials: FixedV2Credential(value: "key"))
        let result = try await generator.generate(jobID: id, capture: capture)
        XCTAssertEqual(result.reply, "我为您转接同事继续协助。")
        XCTAssertEqual(result.action, .replyThenTransfer)
        XCTAssertEqual(result.transferReason, .refundOperation)
    }

    @MainActor func testDefinitiveTimestampConflictGetsOneCorrectedDurableTask() throws {
        let root = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let capture = try makeCapture(uid: "customer", messages: [message("q", .customer, "question", seconds: 0)], targets: ["q"])
        let builder = PinduoduoV2RequestBuilder(rootDirectory: root)
        let accepted = try builder.freeze(localJobID: UUID(), capture: capture)
        let request = try JSONDecoder().decode(PinduoduoV2ReplyRequest.self, from: accepted.requestJSON)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: accepted.requestJSON) as? [String: Any])
        var rows = try XCTUnwrap(object["messages"] as? [[String: Any]])
        rows[0]["occurredAt"] = "2020-01-01T00:00:00.000Z"; object["messages"] = rows
        let id = UUID()
        object["historyVersion"] = "rejected-version"; object["idempotencyKey"] = id.uuidString
        let rejected = PinduoduoV2GenerationOutboxRecord(localJobID: id, customerUid: "customer",
            historyVersion: "rejected-version", idempotencyKey: id.uuidString, requestJSON: json(object), files: [],
            messageFingerprints: [:], mediaFingerprints: [:], createdAt: Date(timeIntervalSince1970: 1_700_000_000), phase: .failed,
            hostedJobID: "failed-original", lastErrorCode: "MESSAGE_ID_CONFLICT")
        try PinduoduoV2GenerationOutboxStore(rootDirectory: root).save(rejected)
        try PinduoduoV2HistoryLedger(rootDirectory: root, customerUID: "customer")
            .markAccepted(messages: accepted.messageFingerprints, media: [:])
        var job = AutoReplyJob(id: id, uid: "customer", sequence: 1, state: .quarantined, capture: capture,
            reply: nil, deliveryOutcome: .notSent, confirmedServiceMessageID: nil, retries: 1, nextAttemptAt: nil, lastError: "MESSAGE_ID_CONFLICT")
        let replacementID = try XCTUnwrap(PinduoduoV2TimestampRepair.replacement(for: job, root: root))
        XCTAssertEqual(try PinduoduoV2TimestampRepair.replacement(for: job, root: root), replacementID)
        XCTAssertNotEqual(replacementID, id)
        let corrected = try XCTUnwrap(PinduoduoV2GenerationOutboxStore(rootDirectory: root).load(replacementID))
        let correctedRequest = try JSONDecoder().decode(PinduoduoV2ReplyRequest.self, from: corrected.requestJSON)
        XCTAssertEqual(correctedRequest.messages, request.messages)
        XCTAssertEqual(correctedRequest.targetMessageIds, ["q"])
        XCTAssertNotEqual(corrected.idempotencyKey, rejected.idempotencyKey)
        XCTAssertEqual(try PinduoduoV2GenerationOutboxStore(rootDirectory: root).load(id), rejected)
        var state = AutoReplyPersistentState.empty; state.jobs = [job]; state.nextSequence = 1
        let stateStore = AutoReplyStore(rootDirectory: root); try stateStore.save(state)
        let generator = PinduoduoV2ReplyGenerator(rootDirectory: root)
        for outcome in [AutoReplyDeliveryOutcome.sent, .uncertain] {
            var covering = AutoReplyJob(id: UUID(), uid: "customer", sequence: 2, state: .completed,
                capture: capture, reply: "already attempted", deliveryOutcome: outcome,
                confirmedServiceMessageID: outcome == .sent ? "posted" : nil,
                retries: 0, nextAttemptAt: nil, lastError: nil)
            covering.sendWasInvoked = true
            state.jobs = [job, covering]; state.nextSequence = 2; try stateStore.save(state)
            let covered = try AutoReplyScheduler(driver: TimestampRepairDriver(), generator: generator, store: stateStore)
            XCTAssertEqual(covered.jobs.count, 2, "Sent or uncertain overlapping work cannot create a duplicate reply")
            XCTAssertNil(covered.jobs.first?.supersededByJobID)
        }
        state.jobs = [job]; state.nextSequence = 1; try stateStore.save(state)
        let scheduler = try AutoReplyScheduler(driver: TimestampRepairDriver(), generator: generator, store: stateStore)
        XCTAssertEqual(scheduler.jobs.count, 2)
        XCTAssertEqual(scheduler.jobs.first?.supersededByJobID, replacementID)
        XCTAssertEqual(scheduler.jobs.last?.id, replacementID)
        XCTAssertEqual(scheduler.jobs.last?.state, .queued)
        XCTAssertEqual(try stateStore.load().answeredCursors["customer"] ?? .empty, .empty)
        let restarted = try AutoReplyScheduler(driver: TimestampRepairDriver(), generator: generator, store: stateStore)
        XCTAssertEqual(restarted.jobs.count, 2)
        var failedAgain = corrected; failedAgain.phase = .failed; failedAgain.lastErrorCode = "MESSAGE_ID_CONFLICT"
        try PinduoduoV2GenerationOutboxStore(rootDirectory: root).save(failedAgain)
        let correctedJob = AutoReplyJob(id: replacementID, uid: "customer", sequence: 2, state: .quarantined,
            capture: capture, reply: nil, deliveryOutcome: .notSent, confirmedServiceMessageID: nil,
            retries: 1, nextAttemptAt: nil, lastError: "MESSAGE_ID_CONFLICT")
        XCTAssertNil(try PinduoduoV2TimestampRepair.replacement(for: correctedJob, root: root), "An unchanged corrected request cannot create another retry")
        job.sendWasInvoked = true
        XCTAssertNil(try PinduoduoV2TimestampRepair.replacement(for: job, root: root))
    }

    func testFailedAcceptancePollsOriginalErrorWithoutPoisoningSynchronizedHistory() async throws {
        let root = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let capture = try makeCapture(uid: "customer", messages: [message("q", .customer, "question", seconds: 0)], targets: ["q"])
        let localID = UUID()
        let record = try PinduoduoV2RequestBuilder(rootDirectory: root).freeze(localJobID: localID, capture: capture)
        let ledger = PinduoduoV2HistoryLedger(rootDirectory: root, customerUID: "customer")
        try ledger.markAccepted(messages: ["q": "previously-accepted-fingerprint"], media: [:])
        let acceptance = json(["jobId": "hosted", "status": "failed", "createdAt": "now", "updatedAt": "now",
            "platform": "pinduoduo", "storeId": "pinduoduo-default", "customerUid": "customer",
            "historyVersion": record.historyVersion, "pollUrl": "/api/codex/pinduoduo/v2/replies/hosted"])
        let failed = json(["jobId": "hosted", "status": "failed", "error": ["code": "MESSAGE_ID_CONFLICT"]])
        let transport = RecordingV2Transport(responses: [
            .success(response(status: 200, body: readyStatusJSON())),
            .success(response(status: 202, body: acceptance)),
            .success(response(status: 200, body: failed))
        ])
        let generator = PinduoduoV2ReplyGenerator(rootDirectory: root, client: .init(transport: transport),
            credentials: FixedV2Credential(value: "key"), sleep: { _ in })
        do {
            _ = try await generator.generate(jobID: localID, capture: capture); XCTFail("Failed job cannot produce a reply")
        } catch PinduoduoV2ClientError.jobFailed(let code, _) {
            XCTAssertEqual(code, "MESSAGE_ID_CONFLICT")
        }
        XCTAssertEqual(try PinduoduoV2GenerationOutboxStore(rootDirectory: root).load(localID)?.phase, .failed)
        XCTAssertEqual(try ledger.snapshot().messages["q"], "previously-accepted-fingerprint")
        XCTAssertEqual(transport.requests.count, 3)
    }

    func testAcceptanceBindingFailureNamesOnlyRejectedField() async throws {
        let root = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let record = try PinduoduoV2RequestBuilder(rootDirectory: root).freeze(localJobID: UUID(),
            capture: makeCapture(uid: "customer", messages: [message("q", .customer, "question", seconds: 0)], targets: ["q"]))
        let body = json(["jobId": "hosted", "status": "queued", "createdAt": "now", "updatedAt": "now",
            "platform": "pinduoduo", "storeId": "pinduoduo-default", "customerUid": "private-wrong-customer",
            "historyVersion": record.historyVersion, "pollUrl": "/api/codex/pinduoduo/v2/replies/hosted"])
        let client = PinduoduoV2APIClient(transport: RecordingV2Transport(responses: [.success(response(status: 202, body: body))]))
        do {
            _ = try await client.submit(record, apiKey: "private-key"); XCTFail("Wrong customer must be rejected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("customerUid"))
            XCTAssertFalse(error.localizedDescription.contains("private-wrong-customer"))
            XCTAssertFalse(error.localizedDescription.contains("private-key"))
        }
    }

    func testIdempotentAcceptanceCanReturnOriginalFailedOrExpiredJob() async throws {
        let root = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let record = try PinduoduoV2RequestBuilder(rootDirectory: root).freeze(localJobID: UUID(),
            capture: makeCapture(uid: "customer", messages: [message("q", .customer, "question", seconds: 0)], targets: ["q"]))
        for status in ["failed", "expired"] {
            let body = json(["jobId": "hosted", "status": status, "createdAt": "now", "updatedAt": "now",
                "platform": "pinduoduo", "storeId": "pinduoduo-default", "customerUid": "customer",
                "historyVersion": record.historyVersion, "pollUrl": "/api/codex/pinduoduo/v2/replies/hosted"])
            let transport = RecordingV2Transport(responses: [.success(response(status: 202, body: body))])
            let accepted = try await PinduoduoV2APIClient(transport: transport).submit(record, apiKey: "key")
            XCTAssertEqual(accepted.jobId, "hosted")
            XCTAssertEqual(accepted.status, status)
        }
    }

    func testPendingVideoCanUploadFirstFramesAfterAnEarlierTextRequest() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let frame = root.appendingPathComponent("frame.jpg")
        try Data([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3]).write(to: frame)
        let video = PDDChatMessage(id: "pending-video", sender: .customer, content: "[视频]",
            displayTime: nil, kind: .video, capturedAt: Date().addingTimeInterval(-10))
        let question = message("question", .customer, "The printer feeds blank paper", seconds: 0)
        let builder = PinduoduoV2RequestBuilder(rootDirectory: root)
        let history = [video, question]
        let textCapture = try makeCapture(uid: "late-frames", messages: history, targets: [question.id])
        let first = try builder.freeze(localJobID: UUID(), capture: textCapture)
        let textRequest = try JSONDecoder().decode(PinduoduoV2ReplyRequest.self, from: first.requestJSON)
        XCTAssertEqual(textRequest.messages.map(\.id), [question.id])
        try PinduoduoV2HistoryLedger(rootDirectory: root, customerUID: textCapture.uid)
            .markAccepted(messages: first.messageFingerprints, media: first.mediaFingerprints)

        var videoCapture = try makeCapture(uid: textCapture.uid, messages: history, targets: [video.id])
        videoCapture.videoAttachments = [speechVideo(video.id, frame: frame)]
        let second = try builder.freeze(localJobID: UUID(), capture: videoCapture)
        let videoRequest = try JSONDecoder().decode(PinduoduoV2ReplyRequest.self, from: second.requestJSON)
        XCTAssertEqual(videoRequest.targetMessageIds, [video.id])
        XCTAssertEqual(videoRequest.media.map(\.messageId), [video.id])
        XCTAssertEqual(videoRequest.messages[0].mediaIds, videoRequest.media.map(\.id))
    }

    func testVideoSpeechTravelsBesideFramesWithOriginalMessageBinding() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let frame = root.appendingPathComponent("frame.jpg")
        try Data([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3]).write(to: frame)
        var capture = try makeCapture(uid: "speech-customer", messages: [
            videoMessage("video-one"), videoMessage("video-two")
        ], targets: ["video-one", "video-two"])
        capture.videoAttachments = [
            speechVideo("video-one", frame: frame, segments: [
                .init(startSeconds: 2, durationSeconds: 1, text: "It does not feed paper."),
                .init(startSeconds: 0.25, durationSeconds: 1, text: "This printer turns on.")
            ]),
            speechVideo("video-two", frame: frame, transcript: "The screen is blank.")
        ]
        let original = capture
        let record = try PinduoduoV2RequestBuilder(rootDirectory: root)
            .freeze(localJobID: UUID(), capture: capture)
        let request = try JSONDecoder().decode(PinduoduoV2ReplyRequest.self, from: record.requestJSON)
        let speech = request.messages.filter { $0.id.hasPrefix("video-transcript-") }
        XCTAssertEqual(speech.count, 2)
        XCTAssertEqual(speech[0].role, .customer)
        XCTAssertTrue(speech[0].text.contains("video message video-one"))
        XCTAssertTrue(speech[0].text.contains("[0.250-1.250s] This printer turns on.\n[2.000-3.000s] It does not feed paper."))
        XCTAssertTrue(speech[1].text.contains("video message video-two"))
        XCTAssertTrue(speech[1].text.contains("The screen is blank."))
        XCTAssertTrue(speech.allSatisfy { $0.mediaIds.isEmpty })
        XCTAssertEqual(request.media.map(\.messageId), ["video-one", "video-two"])
        for source in ["video-one", "video-two"] {
            let row = try XCTUnwrap(request.messages.first { $0.id == source })
            XCTAssertEqual(row.text, "[video]")
            XCTAssertEqual(row.mediaIds, request.media.filter { $0.messageId == source }.map(\.id))
            XCTAssertEqual(speech.first { $0.text.contains("video message \(source) ") }?.occurredAt, row.occurredAt)
        }
        XCTAssertEqual(Set(request.targetMessageIds), ["video-one", "video-two"])
        XCTAssertEqual(capture, original, "Transport speech must not change local capture or target receipts")
        XCTAssertTrue(speech.allSatisfy { record.messageFingerprints[$0.id] != nil })
        XCTAssertFalse(request.replyInstructions.contains("It does not feed paper."))
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: record.requestJSON) as? [String: Any])
        XCTAssertNil(raw["transcriptions"])
        XCTAssertNil(raw["mediaSources"])
        XCTAssertTrue(record.files.allSatisfy { $0.mimeType == "image/jpeg" })
    }

    func testSpeechIsFrozenForRetryAndNewVideoOccurrenceGetsDifferentSpeechID() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        var capture = try makeCapture(uid: "speech-freeze", messages: [videoMessage("video-one")], targets: ["video-one"])
        capture.videoAttachments = [speechVideo("video-one", transcript: "Original spoken problem.")]
        let builder = PinduoduoV2RequestBuilder(rootDirectory: root)
        let first = try builder.freeze(localJobID: id, capture: capture)
        let firstRequest = try JSONDecoder().decode(PinduoduoV2ReplyRequest.self, from: first.requestJSON)
        capture.videoAttachments = [speechVideo("video-one", transcript: "Changed transcript after freezing.")]
        let repeated = try builder.freeze(localJobID: id, capture: capture)
        XCTAssertEqual(repeated.requestJSON, first.requestJSON)
        XCTAssertEqual(repeated.idempotencyKey, first.idempotencyKey)
        XCTAssertEqual(repeated.messageFingerprints, first.messageFingerprints)
        var resent = try makeCapture(uid: "speech-freeze", messages: [videoMessage("video-two")], targets: ["video-two"])
        resent.videoAttachments = [speechVideo("video-two", transcript: "Original spoken problem.")]
        let second = try builder.freeze(localJobID: UUID(), capture: resent)
        let secondRequest = try JSONDecoder().decode(PinduoduoV2ReplyRequest.self, from: second.requestJSON)
        XCTAssertNotEqual(firstRequest.messages.last?.id, secondRequest.messages.last?.id)
    }

    func testAddingSpeechDoesNotMutatePreviouslySynchronizedVideo() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var capture = try makeCapture(uid: "speech-existing", messages: [videoMessage("video-one")], targets: ["video-one"])
        let builder = PinduoduoV2RequestBuilder(rootDirectory: root)
        let first = try builder.freeze(localJobID: UUID(), capture: capture)
        let ledger = PinduoduoV2HistoryLedger(rootDirectory: root, customerUID: capture.uid)
        try ledger.markAccepted(messages: first.messageFingerprints, media: first.mediaFingerprints)
        capture.videoAttachments = [speechVideo("video-one", transcript: "I hear a clicking sound.")]
        let second = try builder.freeze(localJobID: UUID(), capture: capture)
        let request = try JSONDecoder().decode(PinduoduoV2ReplyRequest.self, from: second.requestJSON)
        XCTAssertEqual(second.messageFingerprints["video-one"], first.messageFingerprints["video-one"])
        XCTAssertEqual(request.messages.first?.text, "[video]")
        XCTAssertEqual(request.messages.filter { $0.id.hasPrefix("video-transcript-") }.count, 1)
        try ledger.markAccepted(messages: second.messageFingerprints, media: second.mediaFingerprints)
        let third = try builder.freeze(localJobID: UUID(), capture: capture)
        let thirdRequest = try JSONDecoder().decode(PinduoduoV2ReplyRequest.self, from: third.requestJSON)
        XCTAssertEqual(thirdRequest.messages.map(\.id), ["video-one"], "Already synchronized speech remains server context")
    }

    func testLongSpeechIsSplitWithoutDroppingTextOrTargetAtHistoryLimit() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let speech = String(repeating: "纸张不动，请帮忙。", count: 1_200)
        var history = [videoMessage("video-one")]
        history += (0..<99).map { message("context-\($0)", .service, "Earlier context", seconds: -1) }
        var capture = try makeCapture(uid: "speech-long", messages: history, targets: ["video-one"])
        capture.videoAttachments = [speechVideo("video-one", transcript: speech)]
        let record = try PinduoduoV2RequestBuilder(rootDirectory: root).freeze(localJobID: UUID(), capture: capture)
        let request = try JSONDecoder().decode(PinduoduoV2ReplyRequest.self, from: record.requestJSON)
        let parts = request.messages.filter { $0.id.hasPrefix("video-transcript-") }
        XCTAssertEqual(request.messages.count, 100)
        XCTAssertEqual(request.targetMessageIds, ["video-one"])
        XCTAssertEqual(parts.count, 2)
        let restored = parts.map { $0.text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).last.map(String.init) ?? "" }.joined()
        XCTAssertEqual(restored, speech)
        XCTAssertTrue(request.messages.allSatisfy { $0.text.count <= 10_000 })
    }

    func testTranscriptUsesCanonicalTimestampForLegacySynchronizedVideo() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let date = Date(timeIntervalSince1970: 1_700_000_000.480)
        let source = PDDChatMessage(id: "video-one", sender: .customer, content: "[video]",
            displayTime: nil, kind: .video, capturedAt: date)
        var capture = try makeCapture(uid: "speech-legacy-time", messages: [source], targets: [source.id])
        let builder = PinduoduoV2RequestBuilder(rootDirectory: root)
        let first = try builder.freeze(localJobID: UUID(), capture: capture)
        try PinduoduoV2HistoryLedger(rootDirectory: root, customerUID: capture.uid)
            .markAccepted(messages: first.messageFingerprints, media: first.mediaFingerprints)
        let truncated = PDDChatMessage(id: source.id, sender: source.sender, content: source.content,
            displayTime: nil, kind: .video, capturedAt: Date(timeIntervalSince1970: floor(date.timeIntervalSince1970)))
        capture = try makeCapture(uid: capture.uid, messages: [truncated], targets: [source.id])
        capture.videoAttachments = [speechVideo(source.id, transcript: "The paper does not move.")]
        let second = try builder.freeze(localJobID: UUID(), capture: capture)
        let request = try JSONDecoder().decode(PinduoduoV2ReplyRequest.self, from: second.requestJSON)
        XCTAssertEqual(request.messages.count, 2)
        XCTAssertEqual(request.messages[0].occurredAt, PinduoduoV2DateCodec.string(date))
        XCTAssertEqual(request.messages[1].occurredAt, request.messages[0].occurredAt)
        XCTAssertEqual(second.messageFingerprints[source.id], first.messageFingerprints[source.id])
    }

    func testUnavailableOrUnrelatedSpeechDoesNotInventCustomerMessages() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var capture = try makeCapture(uid: "speech-empty", messages: [videoMessage("video-one"), videoMessage("old-video")], targets: ["video-one"])
        capture.videoAttachments = [speechVideo("video-one", transcript: " \n "), speechVideo("old-video", transcript: "Unrelated old speech")]
        let record = try PinduoduoV2RequestBuilder(rootDirectory: root).freeze(localJobID: UUID(), capture: capture)
        let request = try JSONDecoder().decode(PinduoduoV2ReplyRequest.self, from: record.requestJSON)
        XCTAssertFalse(request.messages.contains { $0.id.hasPrefix("video-transcript-") })
        XCTAssertFalse(String(decoding: record.requestJSON, as: UTF8.self).contains("Unrelated old speech"))
    }

    private func videoMessage(_ id: String) -> PDDChatMessage {
        .init(id: id, sender: .customer, content: "[video]", displayTime: nil, kind: .video,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    private func speechVideo(_ id: String, frame: URL? = nil, transcript: String? = nil,
        segments: [PDDVideoTranscriptSegment] = []) -> AutoReplyVideoAttachment {
        .init(messageID: id, localURL: URL(fileURLWithPath: "/not-uploaded/video.mp4"),
            sha256: String(repeating: "0", count: 64), byteCount: 1, durationSeconds: 8,
            width: 1, height: 1, videoCodec: "h264", audioCodec: "aac",
            frames: frame.map { [.init(timestampSeconds: 1, localURL: $0)] } ?? [],
            transcript: transcript, transcriptSegments: segments, diagnostic: nil)
    }

    func testReplyInstructionsTransferExplicitRepairButNotOrdinaryTroubleshooting() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let instructionsURL = sourceRoot.appendingPathComponent(
            "Resources/CustomerService/pinduoduo-v2-reply-instructions.txt"
        )
        let instructions = try String(contentsOf: instructionsURL, encoding: .utf8)

        XCTAssertTrue(instructions.contains(
            "An explicit current request to have the product repaired or serviced"
        ))
        XCTAssertTrue(instructions.contains(
            "use reply_then_transfer with refund_operation"
        ))
        XCTAssertTrue(instructions.contains(
            "Do not infer a repair request merely because the customer reports a fault"
        ))
        XCTAssertTrue(instructions.contains(
            "asks how to troubleshoot or fix it themselves"
        ))
    }

    func testEnvironmentCredentialProviderReadsOnlyConfiguredVariable() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let env = root.appendingPathComponent(".env")
        try Data("IGNORED=value\nPINDUODUO_V2_API_KEY='private-pdd-key'\n".utf8).write(to: env)

        let provider = PinduoduoV2EnvironmentCredentialProvider(candidateURLs: [env])
        XCTAssertEqual(try provider.apiKey(), "private-pdd-key")
    }

    func testInAppCredentialSetupWorksWithoutProjectFiles() throws {
        let home = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let provider = PinduoduoV2EnvironmentCredentialProvider(
            environment: [:], currentDirectory: home.appendingPathComponent("Finder"),
            bundleURL: home.appendingPathComponent("Applications/Pinduoduo.app"), homeDirectory: home
        )
        XCTAssertThrowsError(try provider.apiKey())
        try PinduoduoV2EnvironmentCredentialProvider.saveAPIKey(" sample-key\n", homeDirectory: home)
        XCTAssertEqual(try provider.apiKey(), "sample-key")
        let path = home.appendingPathComponent("Library/Application Support/PDDAutoReplyShared/.env").path
        let permissions = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testInAppCredentialUpdateKeepsOtherSettingsAndRejectsMultilineInput() throws {
        let home = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let config = home.appendingPathComponent("Library/Application Support/PDDAutoReplyShared")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        let env = config.appendingPathComponent(".env")
        try Data("OTHER=preserved\nexport PINDUODUO_V2_API_KEY=previous\n".utf8).write(to: env)
        let provider = PinduoduoV2EnvironmentCredentialProvider(candidateURLs: [env])
        XCTAssertThrowsError(try PinduoduoV2EnvironmentCredentialProvider.saveAPIKey("bad\nkey", homeDirectory: home))
        XCTAssertEqual(try provider.apiKey(), "previous")
        try PinduoduoV2EnvironmentCredentialProvider.saveAPIKey("replacement", homeDirectory: home)
        XCTAssertEqual(try provider.apiKey(), "replacement")
        XCTAssertTrue(try String(contentsOf: env, encoding: .utf8).contains("OTHER=preserved"))
    }

    func testTextRequestUsesExactPDDContractAndStableFrozenIdentity() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let jobID = UUID()
        let capture = try makeCapture(uid: "GZC-100", messages: [
            message("service-1", .service, "Hello", seconds: -3),
            message("middlePanel_list_1", .customer, "same", seconds: -2),
            message("middlePanel_list_2", .customer, "same", seconds: -1)
        ], targets: ["middlePanel_list_1", "middlePanel_list_2"])

        let builder = PinduoduoV2RequestBuilder(rootDirectory: root)
        let first = try builder.freeze(localJobID: jobID, capture: capture)
        let second = try builder.freeze(localJobID: jobID, capture: capture)
        XCTAssertEqual(first.requestJSON, second.requestJSON)
        XCTAssertEqual(first.files, second.files)
        XCTAssertEqual(first.idempotencyKey, second.idempotencyKey)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: first.requestJSON) as? [String: Any])
        XCTAssertEqual(Set(object.keys), [
            "storeId", "customerUid", "historyVersion", "idempotencyKey", "messages",
            "targetMessageIds", "media", "replyInstructions"
        ])
        XCTAssertEqual(object["storeId"] as? String, "pinduoduo-default")
        XCTAssertNil(object["platform"])
        XCTAssertNil(object["testOnly"])
        XCTAssertEqual((object["messages"] as? [[String: Any]])?.count, 3)
        XCTAssertEqual(Set(object["targetMessageIds"] as? [String] ?? []), ["middlePanel_list_1", "middlePanel_list_2"])
        XCTAssertEqual(first.idempotencyKey, jobID.uuidString.lowercased())
    }

    func testImageAndVideoFramesUseOrderedMultipartManifest() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let imageURL = root.appendingPathComponent("image.png")
        let frameURL = root.appendingPathComponent("frame.jpg")
        let imageData = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3])
        let frameData = Data([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3])
        try imageData.write(to: imageURL)
        try frameData.write(to: frameURL)
        var capture = try makeCapture(uid: "GZC-200", messages: [
            .init(id: "middlePanel_list_img", sender: .customer, content: "[image]", displayTime: nil,
                  kind: .image, capturedAt: Date()),
            .init(id: "middlePanel_list_vid", sender: .customer, content: "[video]", displayTime: nil,
                  kind: .video, capturedAt: Date())
        ], targets: ["middlePanel_list_img", "middlePanel_list_vid"])
        capture.imageAttachments = [.init(
            messageID: "middlePanel_list_img", sourceURL: imageURL, localURL: imageURL,
            mimeType: "image/png", byteCount: imageData.count, sha256: sha256(imageData)
        )]
        capture.videoAttachments = [.init(
            messageID: "middlePanel_list_vid", localURL: root.appendingPathComponent("video.mp4"),
            sha256: String(repeating: "0", count: 64), byteCount: 1, durationSeconds: 2,
            width: 1, height: 1, videoCodec: "h264", audioCodec: nil,
            frames: [.init(timestampSeconds: 1.25, localURL: frameURL)], transcript: nil,
            diagnostic: nil
        )]

        let record = try PinduoduoV2RequestBuilder(rootDirectory: root).freeze(localJobID: UUID(), capture: capture)
        let request = try JSONDecoder().decode(PinduoduoV2ReplyRequest.self, from: record.requestJSON)
        XCTAssertEqual(request.media.map(\.kind), [.image, .frame])
        XCTAssertEqual(request.media.map(\.messageId), ["middlePanel_list_img", "middlePanel_list_vid"])
        XCTAssertEqual(request.media[1].timestampMs, 1_250)
        XCTAssertEqual(record.files.map(\.mediaID), request.media.map(\.id))
        XCTAssertTrue(record.files.allSatisfy { !$0.path.hasSuffix(".mp4") })
    }

    func testBuilderRejectsTextDerivedFallbackTargetID() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = try makeCapture(uid: "GZC-300", messages: [
            message("fallback-abc", .customer, "hello", seconds: 0)
        ], targets: ["fallback-abc"])
        XCTAssertThrowsError(try PinduoduoV2RequestBuilder(rootDirectory: root)
            .freeze(localJobID: UUID(), capture: capture))
    }

    func testRetainedPromptLoaderValidatesEmptyAndOversizedFiles() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyFile = root.appendingPathComponent("unavailable-legacy-policy.txt")
        let policy = PinduoduoV2ReplyInstructionsFileProvider(candidates: [legacyFile])
        XCTAssertThrowsError(try policy.instructions())

        try Data("  \n".utf8).write(to: legacyFile)
        XCTAssertThrowsError(try policy.instructions())
        try Data(String(repeating: "界", count: 5_462).utf8).write(to: legacyFile)
        XCTAssertThrowsError(try policy.instructions())
    }

    func testSynchronizedMessageIDCannotBeChangedButIdenticalTextWithNewIDRemainsNewEvent() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstMessage = message("middlePanel_list_1", .customer, "same text", seconds: -2)
        let original = try makeCapture(uid: "GZC-302", messages: [firstMessage],
            targets: ["middlePanel_list_1"])
        let first = try PinduoduoV2RequestBuilder(rootDirectory: root)
            .freeze(localJobID: UUID(), capture: original)
        try PinduoduoV2HistoryLedger(rootDirectory: root, customerUID: "GZC-302")
            .markAccepted(messages: first.messageFingerprints, media: first.mediaFingerprints)

        let newEvent = try makeCapture(uid: "GZC-302", messages: [
            firstMessage,
            message("middlePanel_list_2", .customer, "same text", seconds: -1)
        ], targets: ["middlePanel_list_2"])
        let second = try PinduoduoV2RequestBuilder(rootDirectory: root)
            .freeze(localJobID: UUID(), capture: newEvent)
        let request = try JSONDecoder().decode(PinduoduoV2ReplyRequest.self, from: second.requestJSON)
        XCTAssertEqual(request.messages.map(\.id), ["middlePanel_list_2"])

        let changed = try makeCapture(uid: "GZC-302", messages: [
            .init(id: firstMessage.id, sender: firstMessage.sender, content: "changed under old id",
                  displayTime: firstMessage.displayTime, kind: firstMessage.kind,
                  capturedAt: firstMessage.capturedAt),
            message("middlePanel_list_3", .customer, "new question", seconds: 0)
        ], targets: ["middlePanel_list_1", "middlePanel_list_3"])
        XCTAssertThrowsError(try PinduoduoV2RequestBuilder(rootDirectory: root)
            .freeze(localJobID: UUID(), capture: changed))
    }

    func testChangedPreviouslySyncedContextDoesNotParkANewTarget() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let uid = "GZC-302"
        let old = message("middlePanel_list_old", .customer, "Line A\nLine B", seconds: -2)
        let builder = PinduoduoV2RequestBuilder(rootDirectory: root)
        let first = try builder.freeze(localJobID: UUID(), capture: makeCapture(uid: uid, messages: [old], targets: [old.id]))
        try PinduoduoV2HistoryLedger(rootDirectory: root, customerUID: uid)
            .markAccepted(messages: first.messageFingerprints, media: first.mediaFingerprints)
        let changed = message(old.id, .customer, "Line B\nLine A", seconds: -2)
        let next = message("middlePanel_list_new", .customer, "New question", seconds: 0)
        let frozen = try builder.freeze(localJobID: UUID(), capture: makeCapture(uid: uid, messages: [changed, next], targets: [next.id]))
        let request = try JSONDecoder().decode(PinduoduoV2ReplyRequest.self, from: frozen.requestJSON)
        XCTAssertEqual(request.messages.map(\.id), [next.id])
        XCTAssertEqual(request.targetMessageIds, [next.id])
        XCTAssertNil(frozen.messageFingerprints[old.id])
    }

    func testReorderedAcceptedLinkContextDoesNotParkNewTextButChangedURLDoes() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let uid = "GZC-LINK"
        let imageURL = "https://chat-img.pddugc.com/chat-pic-mall-user-v1/unit-test.jpeg"
        let original = PDDChatMessage(id: "middlePanel_list_old", sender: .customer,
            content: "Customer:\n/unit-test.jpeg\n\(imageURL)\n这是刚买的", displayTime: nil,
            kind: .link, capturedAt: Date().addingTimeInterval(-20))
        let builder = PinduoduoV2RequestBuilder(rootDirectory: root)
        let first = try builder.freeze(localJobID: UUID(),
            capture: makeCapture(uid: uid, messages: [original], targets: [original.id]))
        try PinduoduoV2HistoryLedger(rootDirectory: root, customerUID: uid)
            .markAccepted(messages: first.messageFingerprints, media: first.mediaFingerprints)
        let next = message("middlePanel_list_new", .customer, "用数据线连接的", seconds: 0)
        func recapture(link: String, targets: [String]) throws -> AutoReplyCapture {
            let earlier = PDDChatMessage(id: original.id, sender: .customer,
                content: "这是刚买的\nCustomer:\n/unit-test.jpeg\n\(link)", displayTime: nil,
                kind: .link, capturedAt: original.capturedAt)
            return try makeCapture(uid: uid, messages: [earlier, next], targets: targets)
        }
        let reordered = try recapture(link: imageURL, targets: [next.id])
        let changed = try recapture(link: imageURL + "?different=1", targets: [next.id])
        let retargeted = try recapture(link: imageURL, targets: [original.id, next.id])
        XCTAssertThrowsError(try builder.freeze(localJobID: UUID(), capture: changed))
        XCTAssertThrowsError(try builder.freeze(localJobID: UUID(), capture: retargeted))

        let frozen = try builder.freeze(localJobID: UUID(), capture: reordered)
        let request = try JSONDecoder().decode(PinduoduoV2ReplyRequest.self, from: frozen.requestJSON)
        XCTAssertEqual(request.messages.map(\.id), [next.id])
        XCTAssertEqual(request.targetMessageIds, [next.id])
    }

    func testLegacyWholeSecondTimestampRecoversOnlyFromMatchingFrozenFingerprint() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let originalDate = Date(timeIntervalSince1970: 1_794_631_389.480)
        let firstMessage = PDDChatMessage(
            id: "middlePanel_list_legacy", sender: .service, content: "unchanged reply",
            displayTime: nil, kind: .text, capturedAt: originalDate
        )
        let original = try makeCapture(
            uid: "GZC-LEGACY", messages: [
                firstMessage,
                message("middlePanel_list_first", .customer, "first", seconds: -1)
            ], targets: ["middlePanel_list_first"]
        )
        let first = try PinduoduoV2RequestBuilder(rootDirectory: root)
            .freeze(localJobID: UUID(), capture: original)
        try PinduoduoV2HistoryLedger(rootDirectory: root, customerUID: "GZC-LEGACY")
            .markAccepted(messages: first.messageFingerprints, media: first.mediaFingerprints)

        let truncated = PDDChatMessage(
            id: firstMessage.id, sender: firstMessage.sender, content: firstMessage.content,
            displayTime: firstMessage.displayTime, kind: firstMessage.kind,
            capturedAt: Date(timeIntervalSince1970: floor(originalDate.timeIntervalSince1970))
        )
        let next = message("middlePanel_list_next", .customer, "next", seconds: 0)
        let recovered = try makeCapture(
            uid: "GZC-LEGACY", messages: [truncated, next], targets: [next.id]
        )

        let second = try PinduoduoV2RequestBuilder(rootDirectory: root)
            .freeze(localJobID: UUID(), capture: recovered)
        let request = try JSONDecoder().decode(PinduoduoV2ReplyRequest.self, from: second.requestJSON)
        XCTAssertEqual(request.messages.map(\.id), [next.id])
    }

    func testStatusUsesExactOriginHeaderAndReadinessFields() async throws {
        let transport = RecordingV2Transport(responses: [
            .success(response(status: 200, body: readyStatusJSON()))
        ])
        let client = PinduoduoV2APIClient(transport: transport)
        let status = try await client.status(apiKey: "pdd-private", cacheLifetime: 0)
        XCTAssertTrue(status.contextEnabled)
        let request = try XCTUnwrap(transport.requests.first?.request)
        XCTAssertEqual(request.url?.absoluteString,
            "https://grozziie.zjweiting.com:8035/api/codex/pinduoduo/v2/status?storeId=pinduoduo-default")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Pinduoduo-Key"), "pdd-private")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testSubmitAndCompletedPollValidateAllBindingsAndSevenFields() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let localID = UUID()
        let capture = try makeCapture(uid: "GZC-400", messages: [
            message("middlePanel_list_q", .customer, "How?", seconds: 0)
        ], targets: ["middlePanel_list_q"])
        let record = try PinduoduoV2RequestBuilder(rootDirectory: root).freeze(localJobID: localID, capture: capture)
        let hostedID = "hosted-job-1"
        let pollURL = "https://grozziie.zjweiting.com:8035/api/codex/pinduoduo/v2/replies/\(hostedID)?storeId=pinduoduo-default"
        let acceptance = json([
            "jobId": hostedID, "status": "queued", "createdAt": "2026-11-14T00:00:00Z",
            "updatedAt": "2026-11-14T00:00:00Z", "platform": "pinduoduo",
            "storeId": "pinduoduo-default", "customerUid": "GZC-400",
            "historyVersion": record.historyVersion, "pollUrl": pollURL
        ])
        let completed = completedJSON(jobID: hostedID, uid: "GZC-400", historyVersion: record.historyVersion)
        let transport = RecordingV2Transport(responses: [
            .success(response(status: 202, body: acceptance)),
            .success(response(status: 200, body: completed))
        ])
        let client = PinduoduoV2APIClient(transport: transport)
        let accepted = try await client.submit(record, apiKey: "key")
        let result = try await client.poll(
            url: URL(string: accepted.pollUrl)!, expectedJobID: hostedID,
            customerUID: "GZC-400", historyVersion: record.historyVersion, apiKey: "key"
        )
        XCTAssertEqual(result.reply?.replyText, "Follow this step.")
        XCTAssertEqual(result.resultDigest, String(repeating: "a", count: 64))
    }

    func testRelativePollURLWithTrailingSlashAndExtraQueryIsCanonicalizedLocally() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = try makeCapture(uid: "GZC-401", messages: [
            message("middlePanel_list_q", .customer, "How?", seconds: 0)
        ], targets: ["middlePanel_list_q"])
        let record = try PinduoduoV2RequestBuilder(rootDirectory: root)
            .freeze(localJobID: UUID(), capture: capture)
        let hostedID = "hosted-equivalent-url"
        let relativePoll = "/api/codex/pinduoduo/v2/replies/\(hostedID)/?storeId=pinduoduo-default&observation=accepted"
        let acceptance = json([
            "jobId": hostedID, "status": "queued", "createdAt": "2026-11-14T00:00:00Z",
            "updatedAt": "2026-11-14T00:00:00Z", "platform": "pinduoduo",
            "storeId": "pinduoduo-default", "customerUid": "GZC-401",
            "historyVersion": record.historyVersion, "pollUrl": relativePoll
        ])
        let transport = RecordingV2Transport(responses: [
            .success(response(status: 202, body: acceptance)),
            .success(response(status: 200, body: completedJSON(
                jobID: hostedID, uid: "GZC-401", historyVersion: record.historyVersion
            )))
        ])
        let client = PinduoduoV2APIClient(transport: transport)
        let accepted = try await client.submit(record, apiKey: "key")
        _ = try await client.poll(
            url: try XCTUnwrap(URL(string: accepted.pollUrl)), expectedJobID: hostedID,
            customerUID: "GZC-401", historyVersion: record.historyVersion, apiKey: "key"
        )
        XCTAssertEqual(transport.requests.last?.request.url?.absoluteString,
            "https://grozziie.zjweiting.com:8035/api/codex/pinduoduo/v2/replies/\(hostedID)?storeId=pinduoduo-default")
    }

    func testPollURLStillRejectsDifferentOriginAndConflictingStore() async {
        let client = PinduoduoV2APIClient(transport: RecordingV2Transport(responses: []))
        await XCTAssertThrowsErrorAsync {
            _ = try await client.poll(
                url: URL(string: "https://evil.example/api/codex/pinduoduo/v2/replies/job?storeId=pinduoduo-default")!,
                expectedJobID: "job", customerUID: "uid", historyVersion: "v1", apiKey: "key"
            )
        }
        await XCTAssertThrowsErrorAsync {
            _ = try await client.poll(
                url: URL(string: "https://grozziie.zjweiting.com:8035/api/codex/pinduoduo/v2/replies/job?storeId=other")!,
                expectedJobID: "job", customerUID: "uid", historyVersion: "v1", apiKey: "key"
            )
        }
    }

    func testCompletedPollRejectsExtraReplyProperty() async throws {
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: completedJSON(jobID: "job", uid: "GZC-500", historyVersion: "v1")
        ) as? [String: Any])
        var reply = object["reply"] as! [String: Any]
        reply["confidence"] = "high"
        object["reply"] = reply
        let transport = RecordingV2Transport(responses: [
            .success(response(status: 200, body: try JSONSerialization.data(withJSONObject: object)))
        ])
        let client = PinduoduoV2APIClient(transport: transport)
        await XCTAssertThrowsErrorAsync {
            _ = try await client.poll(
                url: URL(string: "https://grozziie.zjweiting.com:8035/api/codex/pinduoduo/v2/replies/job?storeId=pinduoduo-default")!,
                expectedJobID: "job", customerUID: "GZC-500", historyVersion: "v1", apiKey: "key"
            )
        }
    }

    func testDeliveryRecorderRetriesIdenticalPersistedEventWithoutChangingID() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let digest = String(repeating: "b", count: 64)
        let receipt = PinduoduoV2GenerationReceipt(
            jobId: "job-delivery", platform: "pinduoduo", storeId: "pinduoduo-default",
            customerUid: "GZC-600", historyVersion: "v1", resultDigest: digest
        )
        let transport = RecordingV2Transport(responses: [
            .failure(PinduoduoV2ClientError.transport("lost response")),
            .success(response(status: 200, body: json([
                "jobId": "job-delivery", "storeId": "pinduoduo-default", "eventId": "placeholder",
                "status": "sent", "occurredAt": "placeholder", "resultDigest": digest,
                "actualSentText": "sent text", "recorded": true
            ]), mutateFromRequest: true))
        ])
        let client = PinduoduoV2APIClient(transport: transport)
        let credential = FixedV2Credential(value: "key")
        let recorder = PinduoduoV2DeliveryRecorder(rootDirectory: root, client: client, credentials: credential)
        try recorder.enqueueVerifiedSend(
            receipt: receipt, actualSentText: "sent text", serviceMessageID: "service-native-1", occurredAt: Date()
        )
        await recorder.flushPending()
        await recorder.flushPending()
        let bodies = transport.requests.compactMap { $0.request.httpBody }
        XCTAssertEqual(bodies.count, 2)
        let first = try JSONDecoder().decode(PinduoduoV2DeliveryRequest.self, from: bodies[0])
        let second = try JSONDecoder().decode(PinduoduoV2DeliveryRequest.self, from: bodies[1])
        XCTAssertEqual(first, second)
    }

    func testUnknownThenSentUsesNewDeliveryEventAndNeverMutatesUnknownBody() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let digest = String(repeating: "c", count: 64)
        let receipt = PinduoduoV2GenerationReceipt(
            jobId: "job-transition", platform: "pinduoduo", storeId: "pinduoduo-default",
            customerUid: "GZC-601", historyVersion: "v1", resultDigest: digest
        )
        let transport = RecordingV2Transport(responses: [
            .success(response(status: 200, body: json([
                "jobId": "job-transition", "storeId": "pinduoduo-default", "eventId": "placeholder",
                "status": "unknown", "occurredAt": "placeholder", "resultDigest": digest,
                "recorded": true
            ]), mutateFromRequest: true)),
            .success(response(status: 200, body: json([
                "jobId": "job-transition", "storeId": "pinduoduo-default", "eventId": "placeholder",
                "status": "sent", "occurredAt": "placeholder", "resultDigest": digest,
                "actualSentText": "confirmed text", "recorded": true
            ]), mutateFromRequest: true))
        ])
        let recorder = PinduoduoV2DeliveryRecorder(
            rootDirectory: root, client: PinduoduoV2APIClient(transport: transport),
            credentials: FixedV2Credential(value: "key")
        )
        try recorder.enqueueUnknown(receipt: receipt, occurredAt: Date())
        await recorder.flushPending()
        try recorder.enqueueVerifiedSend(receipt: receipt, actualSentText: "confirmed text",
            serviceMessageID: "middlePanel_list_service", occurredAt: Date())
        await recorder.flushPending()

        let bodies = try transport.requests.compactMap(\.request.httpBody).map {
            try JSONDecoder().decode(PinduoduoV2DeliveryRequest.self, from: $0)
        }
        XCTAssertEqual(bodies.map(\.status), [.unknown, .sent])
        XCTAssertNil(bodies[0].actualSentText)
        XCTAssertEqual(bodies[1].actualSentText, "confirmed text")
        XCTAssertNotEqual(bodies[0].eventId, bodies[1].eventId)
    }

    func testLostAcceptanceReplaysIdenticalFrozenRequestAndKey() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let localID = UUID()
        let capture = try makeCapture(uid: "GZC-700", messages: [
            message("middlePanel_list_q", .customer, "How?", seconds: 0)
        ], targets: ["middlePanel_list_q"])
        let preview = try PinduoduoV2RequestBuilder(rootDirectory: root)
            .freeze(localJobID: localID, capture: capture)
        let hostedID = "hosted-replayed"
        let pollURL = "https://grozziie.zjweiting.com:8035/api/codex/pinduoduo/v2/replies/\(hostedID)?storeId=pinduoduo-default"
        let acceptance = json([
            "jobId": hostedID, "status": "queued", "createdAt": "2026-11-14T00:00:00Z",
            "updatedAt": "2026-11-14T00:00:00Z", "platform": "pinduoduo",
            "storeId": "pinduoduo-default", "customerUid": "GZC-700",
            "historyVersion": preview.historyVersion, "pollUrl": pollURL
        ])
        let transport = RecordingV2Transport(responses: [
            .success(response(status: 200, body: readyStatusJSON())),
            .failure(PinduoduoV2ClientError.transport("acceptance response lost")),
            .success(response(status: 202, body: acceptance)),
            .success(response(status: 200, body: completedJSON(
                jobID: hostedID, uid: "GZC-700", historyVersion: preview.historyVersion
            )))
        ])
        let generator = PinduoduoV2ReplyGenerator(
            rootDirectory: root, client: PinduoduoV2APIClient(transport: transport),
            credentials: FixedV2Credential(value: "key"), sleep: { _ in }
        )
        _ = try await generator.generate(jobID: localID, capture: capture)
        let posts = transport.requests.filter { $0.request.httpMethod == "POST" }
        XCTAssertEqual(posts.count, 2)
        XCTAssertEqual(posts[0].request.httpBody, posts[1].request.httpBody)
        XCTAssertEqual(posts[0].request.httpBody, preview.requestJSON)
    }

    func testUndecodableAcceptanceRetriesSameRequestAndLogsOnlyFieldPath() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let localID = UUID()
        let capture = try makeCapture(uid: "GZC-700", messages: [
            message("middlePanel_list_q", .customer, "How?", seconds: 0)
        ], targets: ["middlePanel_list_q"])
        let preview = try PinduoduoV2RequestBuilder(rootDirectory: root).freeze(localJobID: localID, capture: capture)
        let hostedID = "hosted-replayed"
        var acceptance = [
            "jobId": hostedID, "status": "queued", "createdAt": "2026-11-14T00:00:00Z",
            "updatedAt": "2026-11-14T00:00:00Z", "platform": "pinduoduo",
            "storeId": "pinduoduo-default", "customerUid": "GZC-700",
            "historyVersion": preview.historyVersion,
            "pollUrl": "/api/codex/pinduoduo/v2/replies/hosted-replayed"
        ]
        let accepted = json(acceptance)
        acceptance.removeValue(forKey: "pollUrl")
        acceptance["extra"] = "sensitive-response-value"
        let transport = RecordingV2Transport(responses: [
            .success(response(status: 200, body: readyStatusJSON())),
            .success(response(status: 202, body: json(acceptance))),
            .success(response(status: 202, body: accepted)),
            .success(response(status: 200, body: completedJSON(
                jobID: hostedID, uid: "GZC-700", historyVersion: preview.historyVersion)))
        ])
        let generator = PinduoduoV2ReplyGenerator(rootDirectory: root,
            client: PinduoduoV2APIClient(transport: transport),
            credentials: FixedV2Credential(value: "key"), sleep: { _ in })

        _ = try await generator.generate(jobID: localID, capture: capture)

        let posts = transport.requests.filter { $0.request.httpMethod == "POST" }
        XCTAssertEqual(posts.map { $0.request.httpBody }, [preview.requestJSON, preview.requestJSON])
        let log = try String(contentsOf: root.appendingPathComponent("logs/automation-steps.jsonl"))
        XCTAssertTrue(log.contains("submit"))
        XCTAssertTrue(log.contains("pollUrl"))
        XCTAssertFalse(log.contains("sensitive-response-value"))
    }

    func testKnownJobRestartPollsOriginalWithoutStatusOrNewPost() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let localID = UUID()
        let capture = try makeCapture(uid: "GZC-701", messages: [
            message("middlePanel_list_q", .customer, "How?", seconds: 0)
        ], targets: ["middlePanel_list_q"])
        let outbox = PinduoduoV2GenerationOutboxStore(rootDirectory: root)
        var record = try PinduoduoV2RequestBuilder(rootDirectory: root)
            .freeze(localJobID: localID, capture: capture)
        record.hostedJobID = "hosted-existing"
        record.pollURL = "https://grozziie.zjweiting.com:8035/api/codex/pinduoduo/v2/replies/hosted-existing?storeId=pinduoduo-default"
        record.phase = .accepted
        try outbox.save(record)
        let transport = RecordingV2Transport(responses: [
            .success(response(status: 200, body: completedJSON(
                jobID: "hosted-existing", uid: "GZC-701", historyVersion: record.historyVersion
            )))
        ])
        let generator = PinduoduoV2ReplyGenerator(
            rootDirectory: root, client: PinduoduoV2APIClient(transport: transport),
            credentials: FixedV2Credential(value: "key"), sleep: { _ in }
        )
        _ = try await generator.generate(jobID: localID, capture: capture)
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(transport.requests[0].request.httpMethod, "GET")
        XCTAssertTrue(transport.requests[0].request.url!.path.hasSuffix("/replies/hosted-existing"))
    }

    func testHostedRecoveryYieldsAfterOnePollWithoutResubmitting() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let localID = UUID()
        let question = message("middlePanel_list_q", .customer, "How?", seconds: 0)
        let capture = try makeCapture(uid: "GZC-701", messages: [question], targets: [question.id])
        let store = PinduoduoV2GenerationOutboxStore(rootDirectory: root)
        var record = try PinduoduoV2RequestBuilder(rootDirectory: root).freeze(localJobID: localID, capture: capture)
        record.hostedJobID = "hosted-existing"
        record.pollURL = "/api/codex/pinduoduo/v2/replies/hosted-existing"
        record.phase = .accepted
        try store.save(record)
        let transport = RecordingV2Transport(responses: [
            .success(response(status: 200, body: json(["jobId": "hosted-existing", "status": "recovery_required"]))),
            .success(response(status: 200, body: completedJSON(jobID: "hosted-existing", uid: capture.uid, historyVersion: record.historyVersion)))
        ])
        let generator = PinduoduoV2ReplyGenerator(rootDirectory: root, client: PinduoduoV2APIClient(transport: transport),
            credentials: FixedV2Credential(value: "key"), sleep: { _ in })
        do {
            _ = try await generator.generate(jobID: localID, capture: capture)
            XCTFail("The recovering job should release its active generation slot")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Hosted recovery required"))
        }
        XCTAssertEqual(transport.requests.map { $0.request.httpMethod }, ["GET"])
        XCTAssertEqual(try store.load(localID)?.phase, .recoveryRequired)
        _ = try await generator.generate(jobID: localID, capture: capture)
        XCTAssertEqual(transport.requests.map { $0.request.httpMethod }, ["GET", "GET"])
        XCTAssertEqual(try store.load(localID)?.phase, .completed)
    }

    func testExpiredPollPersistsTerminalPhaseAndDoesNotResubmit() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let localID = UUID()
        let capture = try makeCapture(uid: "GZC-701", messages: [
            message("middlePanel_list_q", .customer, "How?", seconds: 0)
        ], targets: ["middlePanel_list_q"])
        let store = PinduoduoV2GenerationOutboxStore(rootDirectory: root)
        var record = try PinduoduoV2RequestBuilder(rootDirectory: root).freeze(localJobID: localID, capture: capture)
        record.hostedJobID = "hosted-existing"
        record.pollURL = "/api/codex/pinduoduo/v2/replies/hosted-existing"
        record.phase = .accepted
        try store.save(record)
        let transport = RecordingV2Transport(responses: [.success(response(status: 410, body: Data()))])
        let generator = PinduoduoV2ReplyGenerator(rootDirectory: root, client: PinduoduoV2APIClient(transport: transport),
            credentials: FixedV2Credential(value: "key"), sleep: { _ in })
        for _ in 0..<2 {
            do {
                _ = try await generator.generate(jobID: localID, capture: capture)
                XCTFail("Expected expired job")
            } catch {
                XCTAssertEqual(error as? PinduoduoV2ClientError, .expired)
            }
        }
        XCTAssertEqual(try store.load(localID)?.phase, .expired)
        XCTAssertEqual(transport.requests.map { $0.request.httpMethod }, ["GET"])
    }

    private func makeCapture(uid: String, messages: [PDDChatMessage], targets: [String]) throws -> AutoReplyCapture {
        let timeline = try AutoReplyTimeline.make(messages: messages)
        let events = timeline.events.filter { targets.contains($0.messageID) }
        let batch = FrozenCustomerBatch(
            startCursor: .empty, endCursor: timeline.cursor, events: events,
            targetCustomerJSONL: ""
        )
        return .init(uid: uid, fullHistory: messages, batch: batch,
                     customerCursor: timeline.cursor, unexpectedServiceMessageIDs: [])
    }

    private func message(_ id: String, _ sender: ChatSender, _ text: String, seconds: TimeInterval) -> PDDChatMessage {
        .init(id: id, sender: sender, content: text, displayTime: nil, kind: .text,
              capturedAt: Date().addingTimeInterval(seconds))
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func readyStatusJSON() -> Data {
        json([
            "contextEnabled": true, "platform": "pinduoduo", "storeId": "pinduoduo-default",
            "agent": ["connected": true, "contextV2Supported": true],
            "local": ["enabled": true, "library": ["ready": true, "demo": false]],
            "capabilities": ["orderContext": "v1"]
        ])
    }

    private func completedJSON(jobID: String, uid: String, historyVersion: String) -> Data {
        json([
            "jobId": jobID, "status": "completed", "platform": "pinduoduo",
            "storeId": "pinduoduo-default", "customerUid": uid, "historyVersion": historyVersion,
            "binding": ["jobId": jobID, "platform": "pinduoduo", "storeId": "pinduoduo-default",
                        "customerUid": uid, "historyVersion": historyVersion],
            "resultDigest": String(repeating: "a", count: 64),
            "reply": ["action": "reply", "reply_text": "Follow this step.", "transfer_reason": "none",
                      "product_id": "", "product_query": "", "sku_label": "", "reason": "technical answer"]
        ])
    }

    private func json(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func response(status: Int, body: Data, mutateFromRequest: Bool = false) -> RecordingV2Transport.Response {
        .init(status: status, body: body, headers: [:], mutateDeliveryBindingFromRequest: mutateFromRequest)
    }
}

@MainActor
private final class TimestampRepairDriver: AutoReplyAutomationDriver {
    func discover() async throws -> [AutoReplyDiscovery] { [] }
    func preflight(uid: String, after cursor: AutoReplyCursor) async throws -> AutoReplyCapture? { nil }
    func capture(uid: String, after cursor: AutoReplyCursor) async throws -> AutoReplyCapture { throw CocoaError(.fileReadUnknown) }
    func send(uid: String, text: String, expectedCustomerCursor: AutoReplyCursor) async throws -> AutoReplyDeliveryResult { throw CocoaError(.fileWriteUnknown) }
}

private struct FixedV2Credential: PinduoduoV2CredentialProviding {
    let value: String
    func apiKey() throws -> String { value }
}

private final class RecordingV2Transport: PinduoduoV2Transporting, @unchecked Sendable {
    struct Captured {
        let request: URLRequest
        let uploadBody: Data?
    }
    struct Response {
        let status: Int
        var body: Data
        let headers: [String: String]
        let mutateDeliveryBindingFromRequest: Bool
    }
    private let lock = NSLock()
    private var responses: [Result<Response, Error>]
    private(set) var requests: [Captured] = []

    init(responses: [Result<Response, Error>]) { self.responses = responses }

    func execute(_ request: URLRequest, uploadFile: URL?) async throws -> (Data, HTTPURLResponse) {
        let next: Result<Response, Error> = lock.withLock {
            let uploadBody = uploadFile.flatMap { try? Data(contentsOf: $0) }
            requests.append(.init(request: request, uploadBody: uploadBody))
            return responses.removeFirst()
        }
        var value = try next.get()
        if value.mutateDeliveryBindingFromRequest,
           let body = request.httpBody,
           let delivery = try? JSONDecoder().decode(PinduoduoV2DeliveryRequest.self, from: body) {
            var object = try! JSONSerialization.jsonObject(with: value.body) as! [String: Any]
            object["eventId"] = delivery.eventId
            object["occurredAt"] = delivery.occurredAt
            value.body = try! JSONSerialization.data(withJSONObject: object)
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: value.status, httpVersion: "HTTP/1.1", headerFields: value.headers
        )!
        return (value.body, response)
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {}
}
