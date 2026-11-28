import XCTest
@testable import PDDAXReader

@MainActor
final class PDDVideoHoldingNoticeTests: XCTestCase {
    func testVideoFailureBeforeCaptureIsRecordedStillAsksAboutProblem() async throws {
        let f = try Fixture(pending: true); defer { f.clean() }
        for phase in [PDDVideoTransferPhase.failed, .fallbackRequired] {
            await f.scheduler.receiveVideoTransferEvent(.init(uid: "customer", messageID: "video", phase: phase))
        }
        await f.capture()
        await f.ticks(10)
        XCTAssertEqual(f.driver.sent.count, 1)
        XCTAssertTrue(CustomerFacingFallback.productProblemQuestions.contains(try XCTUnwrap(f.driver.sent.first)))
        XCTAssertTrue(f.scheduler.pendingVideoBatchesSnapshot.isEmpty)
    }

    func testVideoWithoutClickablePreviewAsksAboutProblemWithoutGeneration() async throws {
        let f = try Fixture(pending: true); defer { f.clean() }
        f.driver.captures["customer"] = try holdCapture(messages: [holdMessage("video", .video, "[视频]")])
        await f.capture()
        await f.ticks(10)
        let captures = await f.generator.captures
        XCTAssertTrue(captures.isEmpty)
        XCTAssertEqual(f.driver.sent.count, 1)
        XCTAssertTrue(CustomerFacingFallback.productProblemQuestions.contains(try XCTUnwrap(f.driver.sent.first)))
    }

    func testFailedVideoAsksProductProblemOnceThenWaitsForCustomerAcrossRestart() async throws {
        let f = try Fixture(pending: true); defer { f.clean() }
        await f.capture()
        for phase in [PDDVideoTransferPhase.failed, .fallbackRequired, .failed] {
            await f.scheduler.receiveVideoTransferEvent(.init(uid: "customer", messageID: "video", phase: phase))
        }
        await f.ticks(8)
        XCTAssertEqual(f.driver.sent.count, 1)
        XCTAssertTrue(CustomerFacingFallback.productProblemQuestions.contains(try XCTUnwrap(f.driver.sent.first)))
        XCTAssertEqual(f.scheduler.jobs.first?.state, .completed)
        XCTAssertTrue(f.scheduler.pendingVideoBatchesSnapshot.isEmpty)
        XCTAssertNotNil(try CustomerMessageReceipts(root: f.root).receipts(uid: "customer")["video"]?.replySentAt)
        f.scheduler.stop()
        let restored = try AutoReplyScheduler(driver: f.driver, generator: f.generator,
            store: AutoReplyStore(rootDirectory: f.root), now: { f.clock.value })
        XCTAssertTrue(restored.pendingVideoBatchesSnapshot.isEmpty)
        restored.start(); defer { restored.stop() }
        f.clock.value += 1800
        for _ in 0..<8 { await restored.tick() }
        XCTAssertEqual(f.driver.sent.count, 1, "No repeated product question or video retry after restart")
        XCTAssertTrue(restored.pendingVideoBatchesSnapshot.isEmpty)
        f.driver.captures["customer"] = try holdCapture(messages: [
            holdMessage("video", .video, "[视频]"),
            holdMessage("problem", .text, "The printer does not print")
        ], targetIDs: ["problem"])
        f.driver.discoveries = [.init(uid: "customer", hasUnreadEvidence: true)]
        restored.requestAXRefresh()
        for _ in 0..<20 { await restored.tick(); try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertEqual(f.driver.sent.count, 2)
        XCTAssertEqual(f.driver.sent.last, "实际答复")
        let captures = await f.generator.captures
        XCTAssertEqual(captures.map { $0.batch?.customerMessageIDs }, [["problem"]])
    }

    func testHistoricalVideoInRecoveredBatchDoesNotStartCourtesyTimer() async throws {
        let f = try Fixture(pending: true); defer { f.clean() }
        let stale = PDDChatMessage(
            id: "old-video", sender: .customer, content: "[视频]", displayTime: nil,
            kind: .video, capturedAt: f.clock.value.addingTimeInterval(-3 * 60 * 60)
        )
        f.driver.captures["customer"] = try holdCapture(
            messages: [stale], pending: true
        )

        await f.capture()
        f.clock.value += 20
        await f.ticks(5)

        XCTAssertTrue(f.driver.sent.isEmpty)
        XCTAssertTrue(
            try AutoReplyStore(rootDirectory: f.root).load().videoHoldingNotices.isEmpty
        )
    }

    func testVideoGenerationSendsNoCourtesyMessageAfterTenSeconds() async throws {
        let f = try Fixture(pending: false); defer { f.clean() }
        await f.generator.setSlow()
        await f.capture(); await f.ticks(2)
        XCTAssertEqual(f.scheduler.jobs.first?.state, .generating)
        f.clock.value += 10; await f.ticks(2)
        XCTAssertTrue(f.driver.sent.isEmpty)
        XCTAssertEqual(f.scheduler.jobs.first?.state, .generating)
        XCTAssertNil(try CustomerMessageReceipts(root: f.root).receipts(uid: "customer")["video"]?.replySentAt)
    }
    func testVideoAwaitingEvidenceSendsOnlyTheFinalReply() async throws {
        let f = try Fixture(pending: true); defer { f.clean() }
        await f.capture()
        f.clock.value += 9.99; await f.ticks(3)
        XCTAssertTrue(f.driver.sent.isEmpty)
        f.clock.value += 0.01; await f.ticks(3)
        XCTAssertTrue(f.driver.sent.isEmpty)
        let receipt = try CustomerMessageReceipts(root: f.root).receipts(uid: "customer")["video"]
        XCTAssertNil(receipt?.replySentAt); XCTAssertNil(receipt?.submittedAt)
        XCTAssertEqual(f.scheduler.pendingVideoBatchesSnapshot.count, 1)
        f.clock.value += 20; await f.ticks(5)
        XCTAssertTrue(f.driver.sent.isEmpty)
        await f.scheduler.receiveVideoTransferEvent(.init(uid: "customer", messageID: "video", phase: .readyForGeneration, attachment: holdAttachment()))
        await f.ticks(15)
        XCTAssertEqual(f.driver.sent, ["实际答复"])
        XCTAssertNotNil(try CustomerMessageReceipts(root: f.root).receipts(uid: "customer")["video"]?.replySentAt)
    }

    func testFastFinalReplySendsOnceAndDryRunDoesNotSend() async throws {
        let f = try Fixture(pending: false); defer { f.clean() }
        await f.capture(); await f.ticks(15)
        XCTAssertEqual(f.driver.sent, ["实际答复"])
        f.clock.value += 20; await f.ticks(5)
        XCTAssertEqual(f.driver.sent, ["实际答复"])
        let dry = try Fixture(pending: false); defer { dry.clean() }
        dry.scheduler.setDeliveryEnabled(false)
        await dry.capture()
        dry.clock.value += 11; await dry.ticks(5)
        XCTAssertTrue(dry.driver.sent.isEmpty)
        dry.scheduler.stop(); dry.scheduler.setDeliveryEnabled(true); await dry.ticks(3)
        XCTAssertTrue(dry.driver.sent.isEmpty)
    }

    func testLegacyCourtesyDoesNotSendOrBlockAnotherCustomerAfterRestart() async throws {
        let f = try Fixture(pending: true); defer { f.clean() }
        await f.capture()
        f.scheduler.stop()
        let store = AutoReplyStore(rootDirectory: f.root)
        var checkpoint = try store.load()
        checkpoint.videoHoldingNotices = [.init(uid: "customer", messageIDs: ["video"], capturedAt: f.clock.value)]
        try store.save(checkpoint)
        let restored = try AutoReplyScheduler(driver: f.driver, generator: f.generator, store: store, now: { f.clock.value })
        restored.start(); f.clock.value += 20
        defer { restored.stop() }
        await restored.tick(); await restored.tick()
        XCTAssertTrue(f.driver.sent.isEmpty)
        f.driver.captures["other"] = try holdCapture(uid: "other", messages: [holdMessage("other-text", .text, "hello")])
        f.driver.discoveries = [.init(uid: "other", hasUnreadEvidence: true)]
        restored.requestAXRefresh()
        for _ in 0..<20 { await restored.tick(); try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertEqual(f.driver.sentUIDs, ["other"])
    }

    func testVideoRetryReleasesCapturedTextAndDoesNotAbsorbLaterText() async throws {
        let f = try Fixture(pending: true); defer { f.clean() }
        let video = holdMessage("video", .video, "[视频]")
        let text = holdMessage("text", .text, "It connects but prints blank pages")
        f.driver.captures["customer"] = try holdCapture(messages: [video, text], pending: true)
        await f.capture()
        await f.scheduler.receiveVideoTransferEvent(.init(uid: "customer", messageID: video.id, phase: .waitingForRetry))
        await f.ticks(15)
        let first = await f.generator.captures
        XCTAssertEqual(first.map { $0.batch?.customerMessageIDs }, [[text.id]])
        XCTAssertEqual(f.driver.sent, ["实际答复"])
        XCTAssertEqual(f.scheduler.pendingVideoBatchesSnapshot.first?.capture.batch?.customerMessageIDs, [video.id])

        let followup = holdMessage("text-2", .text, "Can I try another roll?")
        f.driver.captures["customer"] = try holdCapture(messages: [video, text, followup], targetIDs: [followup.id])
        f.driver.discoveries = [.init(uid: "customer", hasUnreadEvidence: true)]
        f.scheduler.requestAXRefresh()
        await f.ticks(15)
        let captures = await f.generator.captures
        XCTAssertEqual(captures.map { $0.batch?.customerMessageIDs }, [[text.id], [followup.id]])
        XCTAssertEqual(f.scheduler.pendingVideoBatchesSnapshot.first?.capture.batch?.customerMessageIDs, [video.id])
    }

    func testTextFollowingVideoWaitsAndJoinsOneActualReply() async throws {
        let f = try Fixture(pending: true); defer { f.clean() }
        await f.capture()
        f.driver.captures["customer"] = try holdCapture(messages: [holdMessage("video", .video, "[视频]"), holdMessage("text", .text, "check this")], targetIDs: ["text"])
        f.driver.discoveries = [.init(uid: "customer", hasUnreadEvidence: true)]
        f.scheduler.requestAXRefresh()
        await f.ticks(6)
        let before = await f.generator.captures
        XCTAssertTrue(before.isEmpty, "Text must not generate an unavailable-video reply while evidence is pending")
        await f.scheduler.receiveVideoTransferEvent(.init(uid: "customer", messageID: "video", phase: .readyForGeneration, attachment: holdAttachment()))
        await f.ticks(15)
        let captures = await f.generator.captures
        XCTAssertEqual(captures.count, 1)
        XCTAssertEqual(captures.first?.batch?.events.map(\.messageID), ["video", "text"])
        XCTAssertEqual(captures.first?.videoAttachments.count, 1)
        XCTAssertEqual(f.driver.sent, ["实际答复"])
    }

    func testQueuedVideoAndTextCoalesceWithoutDroppingReceipts() async throws {
        let f = try Fixture(pending: false); defer { f.clean() }
        var state = AutoReplyPersistentState()
        let video = try holdCapture(messages: [holdMessage("video", .video, "[视频]")], ready: true)
        let text = try holdCapture(messages: [holdMessage("video", .video, "[视频]"), holdMessage("text", .text, "check this")], targetIDs: ["text"])
        state.jobs = [video, text].enumerated().map { offset, capture in
            AutoReplyJob(id: UUID(), uid: "customer", sequence: offset + 1, state: .queued, capture: capture,
                reply: nil, deliveryOutcome: nil, confirmedServiceMessageID: nil, retries: 0, nextAttemptAt: nil, lastError: nil)
        }
        state.nextSequence = 2; f.scheduler.stop()
        try AutoReplyStore(rootDirectory: f.root).save(state)
        let restored = try AutoReplyScheduler(driver: f.driver, generator: f.generator, store: AutoReplyStore(rootDirectory: f.root))
        restored.start()
        for _ in 0..<12 { await restored.tick(); try await Task.sleep(for: .milliseconds(2)) }
        let captures = await f.generator.captures
        XCTAssertEqual(captures.count, 1)
        XCTAssertEqual(captures.first?.batch?.customerMessageIDs, ["video", "text"])
        XCTAssertEqual(f.driver.sent, ["实际答复"])
        restored.stop()
    }

    private final class Clock: @unchecked Sendable { var value = Date(timeIntervalSince1970: 100) }
    @MainActor private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let clock = Clock(); let driver = Driver(); let generator = Generator()
        let scheduler: AutoReplyScheduler
        init(pending: Bool) throws {
            driver.captures["customer"] = try holdCapture(messages: [holdMessage("video", .video, "[视频]")], pending: pending, ready: !pending)
            driver.discoveries = [.init(uid: "customer", hasUnreadEvidence: true)]
            let clock = clock
            scheduler = try AutoReplyScheduler(driver: driver, generator: generator, store: AutoReplyStore(rootDirectory: root), now: { clock.value })
            scheduler.start()
        }
        func capture() async { await ticks(2) }
        func ticks(_ count: Int) async { for _ in 0..<count { await scheduler.tick(); try? await Task.sleep(for: .milliseconds(2)) } }
        func clean() { scheduler.stop(); try? FileManager.default.removeItem(at: root) }
    }
    private final class Driver: AutoReplyAutomationDriver {
        var captures: [String: AutoReplyCapture] = [:]; var discoveries: [AutoReplyDiscovery] = []
        var sent: [String] = []; var sentUIDs: [String] = []
        func discover() async throws -> [AutoReplyDiscovery] { defer { discoveries = [] }; return discoveries }
        func capture(uid: String, after cursor: AutoReplyCursor) async throws -> AutoReplyCapture {
            guard let capture = captures.removeValue(forKey: uid) else { return .init(uid: uid, fullHistory: [], batch: nil, customerCursor: cursor, unexpectedServiceMessageIDs: []) }
            return capture
        }
        func preflight(uid: String, after cursor: AutoReplyCursor) async throws -> AutoReplyCapture? { nil }
        func send(uid: String, text: String, expectedCustomerCursor: AutoReplyCursor) async throws -> AutoReplyDeliveryResult {
            sent.append(text); sentUIDs.append(uid); return .sent(serviceMessageID: "service-\(sent.count)")
        }
    }
    private actor Generator: AutoReplyGenerating {
        var captures: [AutoReplyCapture] = []
        var slow = false
        func setSlow() { slow = true }
        func generate(_ capture: AutoReplyCapture) async throws -> CodexReplyResult {
            captures.append(capture)
            if slow { try await Task.sleep(for: .seconds(30)) }
            return .init(reply: "实际答复", threadID: "test")
        }
    }
}

private func holdMessage(_ id: String, _ kind: ChatContentKind, _ content: String) -> PDDChatMessage {
        .init(id: id, sender: .customer, content: content, displayTime: nil, kind: kind, capturedAt: Date())
    }
private func holdAttachment() -> AutoReplyVideoAttachment {
        .init(messageID: "video", localURL: URL(fileURLWithPath: "/tmp/video.mp4"), sha256: "hash", byteCount: 1,
              durationSeconds: 5, width: 1, height: 1, videoCodec: "H.264", audioCodec: nil, frames: [], transcript: nil, diagnostic: nil)
    }
private func holdCapture(uid: String = "customer", messages: [PDDChatMessage], targetIDs: Set<String>? = nil, pending: Bool = false, ready: Bool = false) throws -> AutoReplyCapture {
        let timeline = try AutoReplyTimeline.make(messages: messages)
        let whole = try XCTUnwrap(timeline.freeze(after: .empty))
        let events = whole.events.filter { targetIDs?.contains($0.messageID) ?? true }
        let jsonl = try events.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }.joined(separator: "\n")
        return .init(uid: uid, fullHistory: messages, batch: .init(startCursor: .empty, endCursor: timeline.cursor, events: events, targetCustomerJSONL: jsonl),
                     customerCursor: timeline.cursor, unexpectedServiceMessageIDs: [], videoAttachments: ready ? [holdAttachment()] : [], pendingVideoMessageIDs: pending ? ["video"] : [])
    }

