import XCTest
@testable import PDDAXReader

@MainActor
final class PDDVideoTransferArmerTests: XCTestCase {
    func testLiveCaptureDownloadsTargetVideoWithoutGeneratingOrSendingReply() async throws {
        guard let messageID = ProcessInfo.processInfo.environment["PDD_LIVE_VIDEO_CAPTURE_MESSAGE_ID"] else {
            throw XCTSkip("Set PDD_LIVE_VIDEO_CAPTURE_MESSAGE_ID for a capture-only local video check")
        }
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let root = sandbox.appendingPathComponent("videos")
        let backend = LivePDDAXBackend()
        let tree = try backend.readSemanticTree()
        let candidate = try XCTUnwrap(PDDAXVideoSelection.customerVideos(in: tree.nodes, messageIDs: [messageID]).first)
        let finished = expectation(description: "video capture reached evidence or retry")
        let events = LiveVideoCaptureEvents()
        let registry = PDDVideoTransferRegistry()
        let armer = PDDVideoTransferArmer(destinationRoot: root, registry: registry,
            analysisInbox: PDDVideoAnalysisInbox(stateURL: root.appendingPathComponent("hashes.json")),
            speechTranscriber: PDDNoVideoSpeechTranscriber(),
            eventHandler: { event in
                await events.append(event)
                print("CAPTURE-ONLY phase=\(event.phase.rawValue) \(event.diagnostic ?? "")")
                if [.readyForGeneration, .waitingForRetry, .failed].contains(event.phase) { finished.fulfill() }
            })
        let coordinator = PDDVideoForegroundCoordinator(armer: armer,
            opener: PDDAXVideoPreviewOpener(backend: backend))
        _ = try await coordinator.begin(uid: "capture-only", candidates: [candidate],
            lease: UIOperationLeaseRegistry().acquire(uid: "capture-only"))
        await fulfillment(of: [finished], timeout: 120)
        await registry.cancelAll()
        let captured = await events.values
        let attachment = try XCTUnwrap(captured.first { $0.phase == .readyForGeneration }?.attachment)
        XCTAssertEqual(attachment.messageID, messageID)
        XCTAssertFalse(attachment.frames.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: attachment.localURL.path))
        let log = try String(contentsOf: sandbox.appendingPathComponent("logs/automation-steps.jsonl"))
        let source = log.contains("source=network") ? "network" : "cache"
        print("CAPTURE-ONLY source=\(source); audio=\(attachment.audioCodec ?? "none"); frames=\(attachment.frames.count)")
    }

    func testFailedVideoAsksProductProblemImmediatelyAndOnlyOnceAcrossRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = VideoOrderRecorder()
        let url = root.appendingPathComponent("transfer-state.json")
        let key = PDDVideoTransferKey(uid: "customer", messageID: "video")
        // Recreate the armer and store on each failure to exercise restart durability.
        for _ in 0..<2 {
            let armer = PDDVideoTransferArmer(destinationRoot: root,
                registry: PDDVideoTransferRegistry(),
                analysisInbox: PDDVideoAnalysisInbox(stateURL: root.appendingPathComponent("hashes.json")),
                stateStore: PDDDurableVideoTransferStore(url: url),
                eventHandler: { recorder.append($0.phase.rawValue) })
            await armer.reportFailure(uid: "customer", messageID: "video", error: OperationTimeout(stage: "video-download"))
            let store = PDDDurableVideoTransferStore(url: url)
            let record = try await store.record(key)
            XCTAssertEqual(record?.phase, .terminalFailure)
            XCTAssertEqual(record?.failure, .responseTimeout)
            XCTAssertEqual(record?.retryIndex, 0)
            XCTAssertNil(record?.nextAttemptAt)
            let due = try await store.claimDueRecords()
            XCTAssertTrue(due.isEmpty)
        }
        XCTAssertEqual(recorder.values, ["failed", "fallbackRequired"])
    }

    func testCancellationDoesNotCreateVideoFailureOrContinueToAnotherVideo() async throws {
        let recorder = VideoOrderRecorder()
        let armer = VideoArmerSpy(recorder: recorder)
        let coordinator = PDDVideoForegroundCoordinator(armer: armer, opener: CancellingVideoPreviewOpener())
        let candidates = ["v1", "v2"].map {
            PDDCustomerVideoCandidate(messageID: $0, frame: CGRect(x: 10, y: 10, width: 30, height: 30))
        }
        do {
            _ = try await coordinator.begin(uid: "PDD-one", candidates: candidates,
                                           lease: UIOperationLeaseRegistry().acquire(uid: "PDD-one"))
            XCTFail("Cancellation must propagate to the UI operation")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertTrue(armer.failedMessageIDs.isEmpty)
        XCTAssertEqual(recorder.values, ["arm"])
    }

    func testForegroundOrderIsArmOpenStartClose() async throws {
        let recorder = VideoOrderRecorder()
        let armer = VideoArmerSpy(recorder: recorder)
        let opener = VideoPreviewOpenerSpy(recorder: recorder)
        let coordinator = PDDVideoForegroundCoordinator(armer: armer, opener: opener)
        let candidate = PDDCustomerVideoCandidate(
            messageID: "v1", frame: CGRect(x: 10, y: 10, width: 80, height: 60)
        )

        let pending = try await coordinator.begin(
            uid: "PDD-one",
            candidates: [candidate],
            lease: UIOperationLeaseRegistry().acquire(uid: "PDD-one")
        )

        XCTAssertEqual(pending, ["v1"])
        XCTAssertEqual(recorder.values, ["arm", "open", "start", "close"])
    }

    func testPreviewRemainsOpenUntilAddressCaptureFinishesThenClosesOnce() async throws {
        let recorder = VideoOrderRecorder()
        let started = expectation(description: "download started")
        let release = AsyncReleaseGate()
        let armer = WaitingVideoArmerSpy(
            recorder: recorder, started: started, release: release
        )
        let opener = VideoPreviewOpenerSpy(recorder: recorder)
        let coordinator = PDDVideoForegroundCoordinator(armer: armer, opener: opener)
        let candidate = PDDCustomerVideoCandidate(
            messageID: "v1", frame: CGRect(x: 10, y: 10, width: 80, height: 60)
        )

        let operation = Task { @MainActor in
            try await coordinator.begin(
                uid: "PDD-one", candidates: [candidate],
                lease: UIOperationLeaseRegistry().acquire(uid: "PDD-one")
            )
        }
        await fulfillment(of: [started], timeout: 1)
        XCTAssertEqual(recorder.values, ["arm", "open", "start"])

        await release.open()
        _ = try await operation.value
        XCTAssertEqual(recorder.values, ["arm", "open", "start", "close"])
    }

    func testStartReturnsWhileBackgroundOperationWaits() async throws {
        let started = expectation(description: "background started")
        let release = AsyncReleaseGate()
        let transfer = ArmedPDDVideoTransfer {
            started.fulfill()
            await release.wait()
        }

        transfer.start()
        await fulfillment(of: [started], timeout: 1)
        await release.open()
    }

    func testStartIsIdempotent() async throws {
        let counter = AsyncCounter()
        let transfer = ArmedPDDVideoTransfer { await counter.increment() }

        transfer.start()
        transfer.start()
        try await Task.sleep(for: .milliseconds(30))

        let value = await counter.currentValue()
        XCTAssertEqual(value, 1)
    }

    func testLaterOpenFailureKeepsEveryVideoPendingAndReportsOnlyFailedVideo() async throws {
        let recorder = VideoOrderRecorder()
        let armer = VideoArmerSpy(recorder: recorder)
        let opener = VideoPreviewOpenerSpy(recorder: recorder, failingMessageID: "v2")
        let coordinator = PDDVideoForegroundCoordinator(armer: armer, opener: opener)
        let candidates = ["v1", "v2"].map {
            PDDCustomerVideoCandidate(messageID: $0, frame: CGRect(x: 0, y: 0, width: 20, height: 20))
        }

        let pending = try await coordinator.begin(
            uid: "PDD-one", candidates: candidates,
            lease: UIOperationLeaseRegistry().acquire(uid: "PDD-one")
        )

        XCTAssertEqual(pending, ["v1", "v2"])
        XCTAssertEqual(armer.failedMessageIDs, ["v2"])
    }

    func testMissingPreviewLabelsDoNotPreventAddressCapture() async throws {
        let recorder = VideoOrderRecorder()
        let armer = VideoArmerSpy(recorder: recorder)
        let opener = ConfirmingVideoPreviewOpenerSpy(
            recorder: recorder, confirmations: [false, false, true]
        )
        let coordinator = PDDVideoForegroundCoordinator(armer: armer, opener: opener)
        let candidate = PDDCustomerVideoCandidate(
            messageID: "v1", frame: CGRect(x: 10, y: 10, width: 80, height: 60)
        )

        _ = try await coordinator.begin(
            uid: "PDD-one", candidates: [candidate],
            lease: UIOperationLeaseRegistry().acquire(uid: "PDD-one")
        )

        XCTAssertEqual(opener.openCount, 1)
        XCTAssertEqual(recorder.values, ["arm", "open", "start", "close"])
        XCTAssertTrue(armer.failedMessageIDs.isEmpty)
    }

    func testConfirmedPreviewIsNeverClickedASecondTime() async throws {
        let recorder = VideoOrderRecorder()
        let armer = VideoArmerSpy(recorder: recorder)
        let opener = ConfirmingVideoPreviewOpenerSpy(
            recorder: recorder, confirmations: [true, false, false]
        )
        let coordinator = PDDVideoForegroundCoordinator(armer: armer, opener: opener)
        let candidate = PDDCustomerVideoCandidate(
            messageID: "v1", frame: CGRect(x: 10, y: 10, width: 80, height: 60)
        )

        _ = try await coordinator.begin(
            uid: "PDD-one", candidates: [candidate],
            lease: UIOperationLeaseRegistry().acquire(uid: "PDD-one")
        )

        XCTAssertEqual(opener.openCount, 1)
        XCTAssertEqual(recorder.values, ["arm", "open", "start", "close"])
    }

    func testAllPreviewProbesFalseStillWaitsForLinkWithoutFallback() async throws {
        let recorder = VideoOrderRecorder()
        let armer = VideoArmerSpy(recorder: recorder)
        let opener = ConfirmingVideoPreviewOpenerSpy(
            recorder: recorder, confirmations: [false, false, false]
        )
        let coordinator = PDDVideoForegroundCoordinator(armer: armer, opener: opener)
        let candidate = PDDCustomerVideoCandidate(
            messageID: "v1", frame: CGRect(x: 10, y: 10, width: 80, height: 60)
        )

        let pending = try await coordinator.begin(
            uid: "PDD-one", candidates: [candidate],
            lease: UIOperationLeaseRegistry().acquire(uid: "PDD-one")
        )

        XCTAssertEqual(pending, ["v1"])
        XCTAssertEqual(opener.openCount, 1)
        XCTAssertTrue(recorder.values.contains("start"))
        XCTAssertTrue(armer.failedMessageIDs.isEmpty)
    }
}

private actor LiveVideoCaptureEvents {
    var values: [PDDVideoTransferEvent] = []
    func append(_ event: PDDVideoTransferEvent) { values.append(event) }
}

@MainActor
private final class CancellingVideoPreviewOpener: PDDVideoPreviewOpening {
    func open(_ candidate: PDDCustomerVideoCandidate, lease: UIOperationLease) async throws {
        throw CancellationError()
    }
    func close() async {}
}

private final class VideoOrderRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var values: [String] { lock.withLock { storage } }
    func append(_ value: String) { lock.withLock { storage.append(value) } }
}

@MainActor
private final class VideoArmerSpy: PDDVideoTransferArming {
    let recorder: VideoOrderRecorder
    var failedMessageIDs: [String] = []
    init(recorder: VideoOrderRecorder) { self.recorder = recorder }
    func arm(
        uid: String, messageID: String, candidate: PDDCustomerVideoCandidate,
        verifyNetworkPreview: @escaping PDDVideoPreviewVerification
    ) async throws -> ArmedPDDVideoTransfer? {
        recorder.append("arm")
        return ArmedPDDVideoTransfer(
            onStart: { [recorder] _ in recorder.append("start") },
            operation: {}
        )
    }
    func reportFailure(uid: String, messageID: String, error: Error) async {
        failedMessageIDs.append(messageID)
    }
}

@MainActor
private final class WaitingVideoArmerSpy: PDDVideoTransferArming {
    let recorder: VideoOrderRecorder
    let started: XCTestExpectation
    let release: AsyncReleaseGate

    init(
        recorder: VideoOrderRecorder,
        started: XCTestExpectation,
        release: AsyncReleaseGate
    ) {
        self.recorder = recorder
        self.started = started
        self.release = release
    }

    func arm(
        uid: String, messageID: String, candidate: PDDCustomerVideoCandidate,
        verifyNetworkPreview: @escaping PDDVideoPreviewVerification
    ) async throws -> ArmedPDDVideoTransfer? {
        recorder.append("arm")
        return ArmedPDDVideoTransfer(
            onStart: { [recorder, started] _ in
                recorder.append("start")
                started.fulfill()
            },
            operation: { [release] in await release.wait() }
        )
    }
}

@MainActor
private final class VideoPreviewOpenerSpy: PDDVideoPreviewOpening {
    let recorder: VideoOrderRecorder
    let failingMessageID: String?
    init(recorder: VideoOrderRecorder, failingMessageID: String? = nil) {
        self.recorder = recorder
        self.failingMessageID = failingMessageID
    }
    func open(_ candidate: PDDCustomerVideoCandidate, lease: UIOperationLease) async throws {
        recorder.append("open")
        if candidate.messageID == failingMessageID { throw VideoFixtureError.openFailed }
    }
    func close() async { recorder.append("close") }
}

@MainActor
private final class ConfirmingVideoPreviewOpenerSpy: PDDVideoPreviewOpening {
    let recorder: VideoOrderRecorder
    var confirmations: [Bool]
    var openCount = 0

    init(recorder: VideoOrderRecorder, confirmations: [Bool]) {
        self.recorder = recorder
        self.confirmations = confirmations
    }

    func open(_ candidate: PDDCustomerVideoCandidate, lease: UIOperationLease) async throws {
        openCount += 1
        recorder.append("open")
    }

    func waitUntilOpen() async throws -> Bool {
        let result = confirmations.isEmpty ? false : confirmations.removeFirst()
        recorder.append("confirm-\(result)")
        return result
    }

    func close() async { recorder.append("close") }
}

private enum VideoFixtureError: Error { case openFailed }

private actor AsyncCounter {
    var value = 0
    func increment() { value += 1 }
    func currentValue() -> Int { value }
}

private actor AsyncReleaseGate {
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func open() { continuation?.resume(); continuation = nil }
}
