import XCTest
@testable import PDDAXReader

@MainActor
final class AutoReplyJobDeletionTests: XCTestCase {
    func testDeleteArchivesTaskPreservesHistoryAndReceiptsAndSurvivesRestart() throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let selected = try job("GZC-10", sequence: 50, ids: ["old"])
        let other = try job("GZC-11", sequence: 51, ids: ["other"])
        let store = try store(root, jobs: [selected, other])
        let history = PerUserChatStore(rootDirectory: root)
        _ = try history.mergeAXFirst(uid: selected.uid, messages: selected.capture.fullHistory)
        let receipts = CustomerMessageReceipts(root: root); try receipts.capture(selected.capture)
        let beforeReceipts = try Data(contentsOf: root.appendingPathComponent("message-receipts.json"))
        let scheduler = try AutoReplyScheduler(driver: Driver(), generator: Generator(), store: store)
        XCTAssertTrue(scheduler.canDeleteJob(selected.id))
        try scheduler.deleteJob(selected.id)
        XCTAssertEqual(scheduler.jobs, [other])
        XCTAssertEqual(try store.load().manuallyDeletedMessageIDsByUID[selected.uid], ["old"])
        XCTAssertEqual(try history.loadAXFirst(uid: selected.uid), selected.capture.fullHistory)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("message-receipts.json")), beforeReceipts)
        let archived = root.appendingPathComponent("archive/manual-deletions/\(selected.id.uuidString).json")
        XCTAssertEqual(try JSONDecoder().decode(AutoReplyJob.self, from: Data(contentsOf: archived)), selected)
        let restarted = try AutoReplyScheduler(driver: Driver(), generator: Generator(), store: store)
        XCTAssertEqual(restarted.jobs, [other])
    }

    func testDeletedMessageIsNotRequeuedButLaterMessageStillGeneratesAndSends() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let selected = try job("customer", sequence: 50, ids: ["old"])
        let store = try store(root, jobs: [selected])
        try CustomerMessageReceipts(root: root).capture(selected.capture)
        let first = try AutoReplyScheduler(driver: Driver(), generator: Generator(), store: store)
        try first.deleteJob(selected.id)
        let driver = Driver(); driver.nextCapture = try capture("customer", ids: ["old", "new"])
        let generator = Generator()
        let restarted = try AutoReplyScheduler(driver: driver, generator: generator, store: store)
        restarted.start()
        for _ in 0..<20 { await restarted.tick(); try await Task.sleep(for: .milliseconds(2)) }
        restarted.stop()
        XCTAssertEqual(generator.targets, [["new"]])
        XCTAssertEqual(driver.sentTexts, ["fresh reply"])
        XCTAssertFalse(restarted.jobs.contains { $0.id == selected.id })
        XCTAssertNil(try CustomerMessageReceipts(root: root).receipts(uid: "customer")["old"]?.replySentAt)
    }

    func testDeletingOneOverlappingAliasTaskPreservesOtherTaskUntilLastDelete() throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let canonical = PDDConversationKey.make(locator: .init(nickname: "A***"))
        let alias = PDDConversationKey.make(locator: .init(nickname: "A**"))
        let registry = PDDConversationIdentityStore(root: root)
        try registry.remember(uid: canonical, messageIDs: ["anchor", "context"], stableID: nil, boundary: nil)
        try registry.remember(uid: alias, messageIDs: ["shared"], stableID: nil, boundary: nil)
        _ = try registry.reconcileVerifiedThread(messageIDs: ["anchor", "shared"], stableID: nil, boundary: nil)
        let one = try job(alias, sequence: 50, ids: ["shared"])
        let two = try job(canonical, sequence: 51, ids: ["shared", "later"])
        let store = try store(root, jobs: [one, two])
        let scheduler = try AutoReplyScheduler(driver: Driver(), generator: Generator(), store: store)
        try scheduler.deleteJob(one.id)
        XCTAssertEqual(scheduler.jobs, [two])
        XCTAssertTrue(try store.load().manuallyDeletedMessageIDsByUID.values.allSatisfy(\.isEmpty))
        try scheduler.deleteJob(two.id)
        XCTAssertTrue(scheduler.jobs.isEmpty)
        XCTAssertEqual(try store.load().manuallyDeletedMessageIDsByUID[canonical], ["shared", "later"])
    }

    func testDeleteRefusesSendingUncertainAndDurableCommitIntentWithoutChangingState() throws {
        for mode in 0..<3 {
            let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
            var selected = try job("customer", sequence: 50, ids: ["target"])
            if mode == 0 { selected.state = .sending; selected.sendWasInvoked = true }
            if mode == 1 { selected.state = .completed; selected.deliveryOutcome = .uncertain; selected.sendWasInvoked = true }
            let store = try store(root, jobs: [selected])
            if mode == 2 {
                try PDDTextDeliveryAttemptStore(root: root).save(.init(uid: selected.uid,
                    replySHA256: PDDTextDeliveryAttempt.hash("draft"), stage: .commitIntent, updatedAt: Date()), id: selected.id)
            }
            let scheduler = try AutoReplyScheduler(driver: Driver(), generator: Generator(), store: store)
            let before = try store.load()
            XCTAssertFalse(scheduler.canDeleteJob(selected.id))
            XCTAssertThrowsError(try scheduler.deleteJob(selected.id))
            XCTAssertEqual(try store.load(), before)
        }
    }

    func testDeleteCancelsGenerationAndLateCompletionCannotRestoreTask() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        var selected = try job("customer", sequence: 50, ids: ["target"])
        selected.state = .queued; selected.reply = nil
        let store = try store(root, jobs: [selected])
        let driver = Driver(); let generator = Generator(); generator.delay = true
        let scheduler = try AutoReplyScheduler(driver: driver, generator: generator, store: store)
        scheduler.start()
        await scheduler.tick()
        for _ in 0..<100 where scheduler.liveGenerationCount == 0 { await Task.yield() }
        XCTAssertEqual(scheduler.jobs.first?.state, .generating)
        try scheduler.deleteJob(selected.id)
        for _ in 0..<12 { await scheduler.tick(); try await Task.sleep(for: .milliseconds(2)) }
        scheduler.stop()
        XCTAssertTrue(scheduler.jobs.isEmpty)
        XCTAssertEqual(scheduler.liveGenerationCount, 0)
        XCTAssertTrue(driver.sentTexts.isEmpty)
    }

    func testDeleteRejectsExternalCheckpointChange() throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let selected = try job("customer", sequence: 50, ids: ["target"])
        let store = try store(root, jobs: [selected])
        let scheduler = try AutoReplyScheduler(driver: Driver(), generator: Generator(), store: store)
        var external = try store.load(); external.nextSequence += 1; try store.save(external)
        XCTAssertThrowsError(try scheduler.deleteJob(selected.id))
        XCTAssertEqual(try store.load(), external)
        XCTAssertEqual(scheduler.jobs, [selected])
    }

    func testDeleteWaitsWhileAnotherTaskOwnsUI() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        var selected = try job("customer", sequence: 49, ids: ["pending"])
        selected.state = .queued; selected.reply = nil
        let sending = try job("another", sequence: 50, ids: ["send"])
        let store = try store(root, jobs: [selected, sending])
        let driver = Driver(); driver.blockSend = true
        let scheduler = try AutoReplyScheduler(driver: driver, generator: Generator(), store: store)
        scheduler.start()
        let turn = Task { await scheduler.tick() }
        for _ in 0..<100 where scheduler.currentUIOwner == nil { await Task.yield() }
        XCTAssertNotNil(scheduler.currentUIOwner)
        XCTAssertFalse(scheduler.canDeleteJob(selected.id))
        XCTAssertThrowsError(try scheduler.deleteJob(selected.id))
        XCTAssertEqual(scheduler.jobs.first?.id, selected.id)
        turn.cancel(); await turn.value; scheduler.stop()
    }

    func testDeletePrunesOnlySelectedMessagesFromMixedPendingVideoBatch() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let selected = try job("customer", sequence: 50, ids: ["deleted-video"])
        let store = try store(root, jobs: [selected])
        var state = try store.load()
        let mixed = try capture("customer", ids: ["deleted-video", "keep-video"])
        state.pendingVideoBatches = [.init(uid: "customer", capture: mixed, expectedMessageIDs: ["deleted-video", "keep-video"])]
        state.videoHoldingNotices = [.init(uid: "customer", messageIDs: ["deleted-video", "keep-video"], capturedAt: Date())]
        try store.save(state)
        let scheduler = try AutoReplyScheduler(driver: Driver(), generator: Generator(), store: store)
        try scheduler.deleteJob(selected.id)
        let after = try store.load()
        XCTAssertEqual(after.pendingVideoBatches.first?.expectedMessageIDs, ["keep-video"])
        XCTAssertEqual(after.pendingVideoBatches.first?.capture.batch?.customerMessageIDs, ["keep-video"])
        XCTAssertEqual(after.videoHoldingNotices.first?.messageIDs, ["keep-video"])
    }

    func testDeletedIncomingHandoffIsNotRediscoveredAsNewWork() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        var selected = try job("customer", sequence: 50, ids: ["placeholder"])
        selected.capture = .init(uid: "customer", fullHistory: [], batch: .incomingHandoff(key: "boundary", cursor: .empty),
            customerCursor: .empty, unexpectedServiceMessageIDs: [])
        let store = try store(root, jobs: [selected])
        let first = try AutoReplyScheduler(driver: Driver(), generator: Generator(), store: store)
        try first.deleteJob(selected.id)
        let driver = Driver(); driver.nextCapture = selected.capture
        let generator = Generator()
        let restarted = try AutoReplyScheduler(driver: driver, generator: generator, store: store)
        restarted.start()
        for _ in 0..<12 { await restarted.tick(); try await Task.sleep(for: .milliseconds(2)) }
        restarted.stop()
        XCTAssertTrue(restarted.jobs.isEmpty)
        XCTAssertTrue(generator.targets.isEmpty)
        XCTAssertTrue(driver.sentTexts.isEmpty)
    }

    func testViewModelDeletesSelectedTaskWhileStopped() throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let selected = try job("customer", sequence: 50, ids: ["target"])
        let scheduler = try AutoReplyScheduler(driver: Driver(), generator: Generator(), store: store(root, jobs: [selected]))
        let model = AutoReplyViewModel(runtime: scheduler)
        XCTAssertTrue(model.canDeleteJob(selected.id))
        model.deleteJob(selected.id)
        XCTAssertTrue(model.jobs.isEmpty)
        XCTAssertFalse(model.isRunning)
        XCTAssertTrue(model.status.contains("Deleted"))
    }

    func testDeletingRecoveredVideoSuppressesOriginalTransferAndSyntheticJobIDs() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try store(root, jobs: [])
        let scheduler = try AutoReplyScheduler(driver: Driver(), generator: Generator(), store: store)
        let attachment = AutoReplyVideoAttachment(messageID: "original-video", localURL: URL(fileURLWithPath: "/tmp/unused.mp4"),
            sha256: "test", byteCount: 1, durationSeconds: 1, width: 1, height: 1,
            videoCodec: "h264", audioCodec: nil, frames: [], transcript: nil, diagnostic: nil)
        let event = PDDVideoTransferEvent(uid: "customer", messageID: "original-video", phase: .readyForGeneration,
            attachment: attachment, recovered: true)
        await scheduler.receiveVideoTransferEvent(event)
        let selected = try XCTUnwrap(scheduler.jobs.first)
        XCTAssertEqual(selected.capture.batch?.customerMessageIDs, ["video-analysis:original-video"])
        try scheduler.deleteJob(selected.id)
        await scheduler.receiveVideoTransferEvent(event)
        scheduler.requestVideoRecovery(uid: "customer", messageID: "original-video")
        XCTAssertTrue(scheduler.jobs.isEmpty)
        XCTAssertEqual(try store.load().manuallyDeletedMessageIDsByUID["customer"], ["original-video", "video-analysis:original-video"])
        XCTAssertTrue(try store.load().pendingCaptureRequests.isEmpty)
    }

    func testSupplementToAnotherTaskCannotRequeueDeletedMessageButRetainsNewMessage() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        var earlier = try job("customer", sequence: 50, ids: ["A"])
        earlier.nextAttemptAt = .distantFuture
        let selected = try job("customer", sequence: 51, ids: ["B"])
        let store = try store(root, jobs: [earlier, selected])
        var state = try store.load()
        state.pendingCaptureRequests = [.init(uid: "customer", kind: .supplement,
            baseCursor: earlier.capture.customerCursor, sourceJobID: earlier.id)]
        try store.save(state)
        let driver = Driver()
        driver.discoveryEnabled = false
        let history = try capture("customer", ids: ["A", "B", "C"]).fullHistory
        let timeline = try AutoReplyTimeline.make(messages: history)
        driver.nextCapture = .init(uid: "customer", fullHistory: history,
            batch: try timeline.freeze(after: XCTUnwrap(timeline.prefixCursor(at: 1))),
            customerCursor: timeline.cursor, unexpectedServiceMessageIDs: [])
        let generator = Generator()
        let scheduler = try AutoReplyScheduler(driver: driver, generator: generator, store: store)
        try scheduler.deleteJob(selected.id)
        scheduler.start()
        for _ in 0..<24 { await scheduler.tick(); try await Task.sleep(for: .milliseconds(2)) }
        scheduler.stop()
        XCTAssertEqual(generator.targets, [["C"]])
        XCTAssertEqual(driver.capturedAfter.first, earlier.capture.customerCursor)
        XCTAssertFalse(scheduler.jobs.contains { $0.capture.batch?.customerMessageIDs.contains("B") == true })
        XCTAssertTrue(driver.sentTexts.isEmpty)
    }

    private func temporary() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private func capture(_ uid: String, ids: [String]) throws -> AutoReplyCapture {
        let history = ids.map { PDDChatMessage(id: $0, sender: .customer, content: $0, displayTime: nil, kind: .text, capturedAt: Date(timeIntervalSince1970: 100)) }
        let timeline = try AutoReplyTimeline.make(messages: history)
        return .init(uid: uid, fullHistory: history, batch: try timeline.freeze(after: .empty), customerCursor: timeline.cursor, unexpectedServiceMessageIDs: [])
    }
    private func job(_ uid: String, sequence: Int, ids: [String]) throws -> AutoReplyJob {
        .init(id: UUID(), uid: uid, sequence: sequence, state: .ready, capture: try capture(uid, ids: ids),
            reply: "draft", deliveryOutcome: .notSent, confirmedServiceMessageID: nil, retries: 0, nextAttemptAt: nil, lastError: nil)
    }
    private func store(_ root: URL, jobs: [AutoReplyJob]) throws -> AutoReplyStore {
        var state = AutoReplyPersistentState(); state.jobs = jobs; state.nextSequence = jobs.map(\.sequence).max() ?? 0
        let store = AutoReplyStore(rootDirectory: root); try store.save(state); return store
    }
    private final class Driver: AutoReplyAutomationDriver {
        var nextCapture: AutoReplyCapture?
        var sentTexts: [String] = []
        var blockSend = false
        var discoveryEnabled = true
        var capturedAfter: [AutoReplyCursor] = []
        func discover() async throws -> [AutoReplyDiscovery] {
            guard discoveryEnabled else { return [] }
            return nextCapture.map { [.init(uid: $0.uid, hasUnreadEvidence: true)] } ?? []
        }
        func capture(uid: String, after cursor: AutoReplyCursor) async throws -> AutoReplyCapture {
            capturedAfter.append(cursor)
            if let value = nextCapture { nextCapture = nil; return value }
            return .init(uid: uid, fullHistory: [], batch: nil, customerCursor: cursor, unexpectedServiceMessageIDs: [])
        }
        func preflight(uid: String, after cursor: AutoReplyCursor) async throws -> AutoReplyCapture? { nil }
        func send(uid: String, text: String, expectedCustomerCursor: AutoReplyCursor) async throws -> AutoReplyDeliveryResult {
            if blockSend { try await Task.sleep(for: .seconds(10)) }
            sentTexts.append(text); return .sent(serviceMessageID: "sent")
        }
    }
    private final class Generator: AutoReplyGenerating, @unchecked Sendable {
        var targets: [Set<String>] = []
        var delay = false
        func generate(_ capture: AutoReplyCapture) async throws -> CodexReplyResult {
            targets.append(capture.batch?.customerMessageIDs ?? [])
            if delay { try await Task.sleep(for: .seconds(10)) }
            return .init(reply: "fresh reply", threadID: "test")
        }
    }
}
