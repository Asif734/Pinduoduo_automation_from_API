import CryptoKit
import XCTest
@testable import PDDAXReader

@MainActor
final class PDDImageTextInputTests: XCTestCase {
    func testAcceptedServiceHistoryDoesNotBlockOnUIOrderFragmentsOrRenderingKind() throws {
        for (body, kind) in [("后续说明\n操作说明", ChatContentKind.text), ("仅剩一个可见片段", .link), ("显示内容已被页面重建", .image)] {
            let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
            let fixture = try prepare(root)
            let history = fixture.capture.fullHistory.map { $0.id == "service" ? message("service", sender: .service, text: body, kind: kind) : $0 }
            var changed = try capture(history, targets: ["photo", "caption"])
            changed.imageAttachments = fixture.capture.imageAttachments
            let original = changed
            let ledger = PinduoduoV2HistoryLedger(rootDirectory: root, customerUID: "GZC-IMAGE")
            let before = try ledger.snapshot()
            let record = try builder(root).freeze(localJobID: UUID(), capture: changed)
            let request = try JSONDecoder().decode(PinduoduoV2ReplyRequest.self, from: record.requestJSON)
            XCTAssertEqual(request.messages.map(\.id), ["photo", "caption"])
            XCTAssertEqual(Set(request.targetMessageIds), ["photo", "caption"])
            XCTAssertEqual(request.messages.last?.text, "这个怎样设置时间？")
            XCTAssertEqual(request.media.map(\.messageId), ["photo"])
            XCTAssertEqual(try ledger.snapshot().messages, before.messages)
            XCTAssertEqual(changed, original)
        }
    }

    func testCustomerRowCannotBecomeServiceToBypassAcceptedHistoryValidation() throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try prepare(root)
        let history = fixture.capture.fullHistory.map { $0.id == "old" ? message("old", sender: .service, text: "changed role") : $0 }
        var changed = try capture(history, targets: ["photo", "caption"]); changed.imageAttachments = fixture.capture.imageAttachments
        XCTAssertThrowsError(try builder(root).freeze(localJobID: UUID(), capture: changed))
    }

    func testForeignCustomerArchiveCannotAuthorizeHistoryRecovery() throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try prepare(root)
        let folder = root.appendingPathComponent("pinduoduo-v2-generation-outbox")
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first { $0.pathExtension == "json" })
        var record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        record["customerUid"] = "ANOTHER-CUSTOMER"
        var request = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture.accepted.requestJSON) as? [String: Any])
        request["customerUid"] = "ANOTHER-CUSTOMER"
        record["requestJSON"] = try JSONSerialization.data(withJSONObject: request).base64EncodedString()
        try JSONSerialization.data(withJSONObject: record).write(to: file)
        XCTAssertThrowsError(try builder(root).freeze(localJobID: UUID(), capture: fixture.capture))
    }

    func testAlreadyAnsweredHistoryConflictRetiresOnlyWithCompleteVerifiedCoverage() throws {
        for scenario in ["complete", "partial", "uncertain", "foreign"] {
            let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
            let fixture = try prepare(root)
            let source = parked(fixture.capture, sequence: 94)
            var sent = AutoReplyJob(id: UUID(), uid: scenario == "foreign" ? "ANOTHER-CUSTOMER" : source.uid,
                sequence: 95, state: .completed, capture: fixture.capture, reply: "already answered",
                deliveryOutcome: scenario == "uncertain" ? .uncertain : .sent,
                confirmedServiceMessageID: "posted", retries: 0, nextAttemptAt: nil, lastError: nil)
            sent.sendWasInvoked = true
            let receipts = CustomerMessageReceipts(root: root)
            try receipts.capture(fixture.capture)
            let handled = scenario == "partial" ? try capture(fixture.capture.fullHistory, targets: ["photo"]) : fixture.capture
            try receipts.replied(handled)
            let before = try Data(contentsOf: root.appendingPathComponent("message-receipts.json"))
            var state = AutoReplyPersistentState(); state.jobs = [source, sent]; state.nextSequence = 95
            let store = AutoReplyStore(rootDirectory: root); try store.save(state)
            let driver = Driver()
            let scheduler = try AutoReplyScheduler(driver: driver, generator: Generator(), store: store)
            XCTAssertEqual(scheduler.jobs.count, 2)
            XCTAssertEqual(scheduler.jobs.first?.state, scenario == "complete" ? .failed : .quarantined)
            XCTAssertEqual(scheduler.jobs.first?.supersededByJobID, scenario == "complete" ? sent.id : nil)
            XCTAssertEqual(scheduler.jobs.first?.deliveryOutcome, .notSent)
            XCTAssertEqual(try store.load().answeredCursors[source.uid] ?? .empty, .empty)
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("message-receipts.json")), before)
            XCTAssertTrue(driver.sent.isEmpty)
        }
    }

    func testImageAndInlineCaptionAreSeparateStableCustomerEvents() throws {
        let image = node("AXImage", value: nil, classes: [], children: [])
        let caption = node("AXStaticText", value: "这个怎样设置时间？")
        let status = node("AXStaticText", value: "已读", classes: ["read-status"])
        func tree(_ children: [AXNodeSnapshot]) -> AXNodeSnapshot {
            .init(role: "AXGroup", attributes: [("AXDOMClassList", "[onemsg]"), ("AXDOMIdentifier", "middlePanel_list_photo")], children: [
                node("AXGroup", value: nil, classes: ["buyer-item"]),
                node("AXGroup", value: nil, classes: ["msg-content", "image-msg"], children: children)
            ])
        }
        let first = PDDChatParser.parse(root: tree([image, caption, status]), capturedAt: Date(timeIntervalSince1970: 100)).messages
        let second = PDDChatParser.parse(root: tree([status, image, caption]), capturedAt: Date(timeIntervalSince1970: 101)).messages
        XCTAssertEqual(first.count, 2)
        XCTAssertEqual(first.first?.kind, .image)
        XCTAssertEqual(first.first?.content, "[图片]")
        XCTAssertEqual(first.last?.kind, .text)
        XCTAssertEqual(first.last?.content, "这个怎样设置时间？")
        XCTAssertEqual(first.map(\.id), second.map(\.id))
        XCTAssertEqual(Set(first.map(\.id)).count, 2)
    }

    func testServiceReadStatusMovesWithoutChangingBodyAndCustomerWordsArePreserved() {
        func tree(_ sender: String, _ values: [String]) -> AXNodeSnapshot {
            .init(role: "AXGroup", attributes: [("AXDOMClassList", "[onemsg]"), ("AXDOMIdentifier", "middlePanel_list_message")], children: [
                node("AXGroup", value: nil, classes: [sender]),
                node("AXGroup", value: nil, classes: ["msg-content-box"], children: values.map { node("AXStaticText", value: $0) })
            ])
        }
        let first = PDDChatParser.parse(root: tree("cs-item", ["操作说明", "已读", "后续说明"])).messages
        let second = PDDChatParser.parse(root: tree("cs-item", ["已读", "操作说明", "后续说明"])).messages
        XCTAssertEqual(first.first?.content, "操作说明\n后续说明")
        XCTAssertEqual(first.first?.content, second.first?.content)
        XCTAssertEqual(PDDChatParser.parse(root: tree("buyer-item", ["已读"])).messages.first?.content, "已读")
        XCTAssertEqual(PDDChatParser.parse(root: tree("cs-item", ["显示已读但没有回复"])).messages.first?.content, "显示已读但没有回复")
    }

    func testPhotoAndRelatedTextShareRequestDespiteLegacyServiceStatusDrift() throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try prepare(root)
        let record = try builder(root).freeze(localJobID: UUID(), capture: fixture.capture)
        let request = try JSONDecoder().decode(PinduoduoV2ReplyRequest.self, from: record.requestJSON)
        XCTAssertEqual(Set(request.targetMessageIds), ["photo", "caption"])
        XCTAssertEqual(request.messages.map(\.id), ["photo", "caption"])
        XCTAssertEqual(request.messages.last?.text, "这个怎样设置时间？")
        XCTAssertEqual(request.messages.first?.mediaIds, request.media.map(\.id))
        XCTAssertEqual(request.media.map(\.messageId), ["photo"])
        XCTAssertEqual(record.files.count, 1)
        XCTAssertEqual(try PinduoduoV2HistoryLedger(rootDirectory: root, customerUID: "GZC-IMAGE").snapshot().messages["service"], fixture.accepted.messageFingerprints["service"])
        var changed = fixture.capture
        changed = replacingCustomer(in: changed, text: "不同的客户正文")
        XCTAssertThrowsError(try builder(root).freeze(localJobID: UUID(), capture: changed))
    }

    func testParkedPhotoAndTextCopiesRecoverIntoOneUnsentRequestAndDoNotRepeatAfterRestart() throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try prepare(root)
        let source = parked(fixture.capture, sequence: 73)
        var duplicate = parked(fixture.capture, sequence: 74)
        duplicate.retries = 1
        var state = AutoReplyPersistentState(); state.jobs = [source, duplicate]; state.nextSequence = 74
        let store = AutoReplyStore(rootDirectory: root); try store.save(state)
        let driver = Driver()
        let scheduler = try AutoReplyScheduler(driver: driver, generator: Generator(), store: store)
        let recovered = try XCTUnwrap(scheduler.jobs.last)
        XCTAssertEqual(recovered.sequence, 75)
        XCTAssertEqual(recovered.state, .queued)
        XCTAssertEqual(recovered.capture.batch?.customerMessageIDs, ["photo", "caption"])
        XCTAssertEqual(recovered.capture.imageAttachments.count, 1)
        XCTAssertEqual(scheduler.jobs.prefix(2).map(\.state), [.failed, .failed])
        XCTAssertEqual(scheduler.jobs.prefix(2).map(\.deliveryOutcome), [.notSent, .notSent])
        XCTAssertTrue(driver.sent.isEmpty)
        let restarted = try AutoReplyScheduler(driver: driver, generator: Generator(), store: store)
        XCTAssertEqual(restarted.jobs.count, 3)
        XCTAssertTrue(driver.sent.isEmpty)
    }

    func testRecoveryDoesNotBypassChangedCustomerBodyOrUncertainDelivery() throws {
        for uncertain in [false, true] {
            let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
            let fixture = try prepare(root)
            var source = parked(uncertain ? fixture.capture : replacingCustomer(in: fixture.capture, text: "不同的正文"), sequence: 73)
            source.sendWasInvoked = uncertain
            source.deliveryOutcome = uncertain ? .uncertain : .notSent
            var state = AutoReplyPersistentState(); state.jobs = [source]; state.nextSequence = 73
            let store = AutoReplyStore(rootDirectory: root); try store.save(state)
            let scheduler = try AutoReplyScheduler(driver: Driver(), generator: Generator(), store: store)
            XCTAssertEqual(scheduler.jobs.count, 1)
            XCTAssertEqual(scheduler.jobs.first?.state, .quarantined)
        }
    }

    func testIdenticalParkedBatchIsNotDuplicatedButAdditionalRelatedTextIsAdmitted() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try prepare(root)
        let source = parked(fixture.capture, sequence: 73)
        var record = try builder(root).freeze(localJobID: source.id, capture: fixture.capture)
        record.phase = .failed; record.lastErrorCode = "SERVER_REJECTED"
        try PinduoduoV2GenerationOutboxStore(rootDirectory: root).save(record)
        var state = AutoReplyPersistentState(); state.jobs = [source]; state.nextSequence = 73
        let store = AutoReplyStore(rootDirectory: root); try store.save(state)
        let driver = Driver()
        var recaptured = fixture.capture
        let image = try XCTUnwrap(fixture.capture.imageAttachments.first)
        recaptured.imageAttachments = [.init(messageID: image.messageID,
            sourceURL: URL(string: "https://example.test/fresh-preview")!, localURL: image.localURL,
            mimeType: image.mimeType, byteCount: image.byteCount, sha256: image.sha256)]
        driver.nextCapture = recaptured
        let generator = Generator()
        let scheduler = try AutoReplyScheduler(driver: driver, generator: generator, store: store)
        scheduler.start()
        for _ in 0..<16 { await scheduler.tick(); try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertEqual(scheduler.jobs.count, 1)
        let before = await generator.recorded(); XCTAssertTrue(before.isEmpty)
        var newer = try capture(fixture.capture.fullHistory + [message("new-caption", text: "再帮我看这个")],
            targets: ["photo", "caption", "new-caption"])
        newer.imageAttachments = fixture.capture.imageAttachments
        driver.nextCapture = newer
        scheduler.requestAXRefresh()
        for _ in 0..<20 { await scheduler.tick(); try await Task.sleep(for: .milliseconds(2)) }
        scheduler.stop()
        let after = await generator.recorded()
        XCTAssertEqual(after, [["photo", "caption", "new-caption"]])
    }

    func testRecoveryIncludesTextAlreadyCapturedAsPendingSupplement() throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try prepare(root)
        var photo = try capture(fixture.capture.fullHistory.filter { $0.id != "caption" }, targets: ["photo"])
        photo.imageAttachments = fixture.capture.imageAttachments
        var source = parked(photo, sequence: 73)
        source.pendingSupplement = try capture(fixture.capture.fullHistory, targets: ["caption"])
        var state = AutoReplyPersistentState(); state.jobs = [source]; state.nextSequence = 73
        let store = AutoReplyStore(rootDirectory: root); try store.save(state)
        let scheduler = try AutoReplyScheduler(driver: Driver(), generator: Generator(), store: store)
        XCTAssertEqual(scheduler.jobs.last?.capture.batch?.customerMessageIDs, ["photo", "caption"])
        XCTAssertEqual(scheduler.jobs.last?.capture.imageAttachments.count, 1)
        XCTAssertNil(scheduler.jobs.first?.pendingSupplement)
    }

    func testRecoveryWaitsForRequestedRelatedTextAndCombinesItBeforePromotion() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try prepare(root)
        var photo = try capture(fixture.capture.fullHistory.filter { $0.id != "caption" }, targets: ["photo"])
        photo.imageAttachments = fixture.capture.imageAttachments
        var source = parked(photo, sequence: 73); source.supplementCapturePending = true
        var state = AutoReplyPersistentState(); state.jobs = [source]; state.nextSequence = 73
        state.pendingCaptureRequests = [.init(uid: source.uid, kind: .supplement,
            baseCursor: source.capture.customerCursor, sourceJobID: source.id)]
        let store = AutoReplyStore(rootDirectory: root); try store.save(state)
        let driver = Driver(); driver.discoveryEnabled = false
        driver.nextCapture = try capture(fixture.capture.fullHistory, targets: ["caption"])
        let generator = Generator()
        let scheduler = try AutoReplyScheduler(driver: driver, generator: generator, store: store)
        XCTAssertEqual(scheduler.jobs.count, 1)
        XCTAssertEqual(scheduler.jobs.first?.state, .quarantined)
        scheduler.start()
        for _ in 0..<24 { await scheduler.tick(); try await Task.sleep(for: .milliseconds(2)) }
        scheduler.stop()
        let targets = await generator.recorded()
        XCTAssertEqual(targets, [["photo", "caption"]])
    }

    func testUnvalidatedPhotoAndArrivingTextStayParkedWithoutAdvancingCursor() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try prepare(root)
        let changed = replacingCustomer(in: fixture.capture, text: "不能证明的不同正文")
        var photo = try capture(changed.fullHistory.filter { $0.id != "caption" }, targets: ["photo"])
        photo.imageAttachments = changed.imageAttachments
        var source = parked(photo, sequence: 73); source.supplementCapturePending = true
        var state = AutoReplyPersistentState(); state.jobs = [source]; state.nextSequence = 73
        state.pendingCaptureRequests = [.init(uid: source.uid, kind: .supplement, baseCursor: source.capture.customerCursor, sourceJobID: source.id)]
        let store = AutoReplyStore(rootDirectory: root); try store.save(state)
        let driver = Driver(); driver.discoveryEnabled = false
        driver.nextCapture = try capture(changed.fullHistory, targets: ["caption"])
        let generator = Generator()
        let scheduler = try AutoReplyScheduler(driver: driver, generator: generator, store: store)
        scheduler.start()
        for _ in 0..<20 { await scheduler.tick(); try await Task.sleep(for: .milliseconds(2)) }
        scheduler.stop()
        XCTAssertEqual(scheduler.jobs.count, 1)
        XCTAssertEqual(scheduler.jobs.first?.state, .quarantined)
        XCTAssertEqual(scheduler.jobs.first?.pendingSupplement?.batch?.customerMessageIDs, ["caption"])
        XCTAssertEqual(try store.load().answeredCursors[source.uid] ?? .empty, .empty)
        let generated = await generator.recorded(); XCTAssertTrue(generated.isEmpty)
    }

    func testEmptySupplementScanEventuallyResumesValidatedPhotoWithoutRestart() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try prepare(root)
        var photo = try capture(fixture.capture.fullHistory.filter { $0.id != "caption" }, targets: ["photo"])
        photo.imageAttachments = fixture.capture.imageAttachments
        var source = parked(photo, sequence: 73); source.supplementCapturePending = true
        var state = AutoReplyPersistentState(); state.jobs = [source]; state.nextSequence = 73
        state.pendingCaptureRequests = [.init(uid: source.uid, kind: .supplement, baseCursor: source.capture.customerCursor, sourceJobID: source.id)]
        let store = AutoReplyStore(rootDirectory: root); try store.save(state)
        let driver = Driver(); driver.discoveryEnabled = false
        let generator = Generator()
        let scheduler = try AutoReplyScheduler(driver: driver, generator: generator, store: store)
        scheduler.start()
        for _ in 0..<28 { await scheduler.tick(); try await Task.sleep(for: .milliseconds(2)) }
        scheduler.stop()
        let generated = await generator.recorded(); XCTAssertEqual(generated, [["photo"]])
    }

    private func builder(_ root: URL) -> PinduoduoV2RequestBuilder {
        .init(rootDirectory: root, now: { Date(timeIntervalSince1970: 1_000) })
    }
    private func temporary() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); return root
    }
    private func prepare(_ root: URL) throws -> (capture: AutoReplyCapture, accepted: PinduoduoV2GenerationOutboxRecord) {
        let service = message("service", sender: .service, text: "操作说明\n已读\n后续说明")
        let old = message("old", text: "你好")
        let initial = try capture([service, old], targets: ["old"])
        let accepted = try builder(root).freeze(localJobID: UUID(), capture: initial)
        try PinduoduoV2HistoryLedger(rootDirectory: root, customerUID: initial.uid)
            .markAccepted(messages: accepted.messageFingerprints, media: [:])
        let changed = message("service", sender: .service, text: "已读\n操作说明\n后续说明")
        var value = try capture([changed, old, message("photo", text: "[图片]", kind: .image), message("caption", text: "这个怎样设置时间？")], targets: ["photo", "caption"])
        let data = Data([0x89,0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a,1,2,3])
        let photo = root.appendingPathComponent("photo.png"); try data.write(to: photo)
        value.imageAttachments = [.init(messageID: "photo", sourceURL: photo, localURL: photo,
            mimeType: "image/png", byteCount: data.count, sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())]
        return (value, accepted)
    }
    private func replacingService(in capture: AutoReplyCapture, text: String) -> AutoReplyCapture {
        var value = capture
        let history = capture.fullHistory.map { $0.id == "service" ? message("service", sender: .service, text: text) : $0 }
        value = .init(uid: capture.uid, fullHistory: history, batch: capture.batch, customerCursor: capture.customerCursor,
            unexpectedServiceMessageIDs: [], imageAttachments: capture.imageAttachments)
        return value
    }
    private func replacingCustomer(in capture: AutoReplyCapture, text: String) -> AutoReplyCapture {
        .init(uid: capture.uid, fullHistory: capture.fullHistory.map { $0.id == "old" ? message("old", text: text) : $0 },
            batch: capture.batch, customerCursor: capture.customerCursor, unexpectedServiceMessageIDs: [], imageAttachments: capture.imageAttachments)
    }
    private func message(_ id: String, sender: ChatSender = .customer, text: String, kind: ChatContentKind = .text) -> PDDChatMessage {
        .init(id: id, sender: sender, content: text, displayTime: nil, kind: kind, capturedAt: Date(timeIntervalSince1970: 100))
    }
    private func capture(_ history: [PDDChatMessage], targets: Set<String>) throws -> AutoReplyCapture {
        let timeline = try AutoReplyTimeline.make(messages: history)
        let all = try XCTUnwrap(timeline.freeze(after: .empty)); let events = all.events.filter { targets.contains($0.messageID) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return .init(uid: "GZC-IMAGE", fullHistory: history,
            batch: .init(startCursor: .empty, endCursor: timeline.cursor, events: events,
                targetCustomerJSONL: try events.map { String(decoding: try encoder.encode($0), as: UTF8.self) }.joined(separator: "\n")),
            customerCursor: timeline.cursor, unexpectedServiceMessageIDs: [])
    }
    private func parked(_ capture: AutoReplyCapture, sequence: Int) -> AutoReplyJob {
        .init(id: UUID(), uid: capture.uid, sequence: sequence, state: .quarantined, capture: capture,
            reply: nil, deliveryOutcome: .notSent, confirmedServiceMessageID: nil, retries: 1,
            nextAttemptAt: nil, lastError: "Message ID service changed after synchronization", imageAttachments: capture.imageAttachments)
    }
    private func node(_ role: String, value: String?, classes: [String] = [], children: [AXNodeSnapshot] = []) -> AXNodeSnapshot {
        .init(role: role, attributes: (value.map { [("AXValue", $0)] } ?? []) + [("AXDOMClassList", "[" + classes.joined(separator: ", ") + "]")], children: children)
    }
    private final class Driver: AutoReplyAutomationDriver {
        var sent: [String] = []
        var nextCapture: AutoReplyCapture?
        var discoveryEnabled = true
        func discover() async throws -> [AutoReplyDiscovery] {
            guard discoveryEnabled else { return [] }
            return nextCapture.map { [.init(uid: $0.uid, hasUnreadEvidence: true)] } ?? []
        }
        func capture(uid: String, after cursor: AutoReplyCursor) async throws -> AutoReplyCapture {
            if let value = nextCapture { nextCapture = nil; return value }
            return .init(uid: uid, fullHistory: [], batch: nil, customerCursor: cursor, unexpectedServiceMessageIDs: [])
        }
        func preflight(uid: String, after cursor: AutoReplyCursor) async throws -> AutoReplyCapture? { nil }
        func send(uid: String, text: String, expectedCustomerCursor: AutoReplyCursor) async throws -> AutoReplyDeliveryResult { sent.append(text); return .sent(serviceMessageID: "sent") }
    }
    private actor Generator: AutoReplyGenerating {
        var captures: [Set<String>] = []
        func generate(_ capture: AutoReplyCapture) async throws -> CodexReplyResult {
            captures.append(capture.batch?.customerMessageIDs ?? [])
            return .init(reply: "reply", threadID: "test")
        }
        func recorded() -> [Set<String>] { captures }
    }
}
