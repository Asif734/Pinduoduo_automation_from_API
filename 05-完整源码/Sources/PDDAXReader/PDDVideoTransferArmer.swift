import Foundation

typealias PDDVideoPreviewVerification = @MainActor @Sendable () async throws -> Bool

final class ArmedPDDVideoTransfer: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private let networkLogURL: URL?
    private var networkCapture: PDDVideoNetworkCapture?
    private let onStart: @Sendable (PDDVideoNetworkCapture?) -> Void
    private let operation: @Sendable () async -> Void

    init(
        networkLogURL: URL? = nil,
        onStart: @escaping @Sendable (PDDVideoNetworkCapture?) -> Void = { _ in },
        operation: @escaping @Sendable () async -> Void
    ) {
        self.networkLogURL = networkLogURL
        self.onStart = onStart
        self.operation = operation
    }

    func checkpointNetworkBeforeClick() {
        guard let networkLogURL else { return }
        let capture = try? PDDVideoNetworkCapture(file: networkLogURL)
        lock.withLock { networkCapture = capture }
    }

    func start() {
        _ = startTask()
    }

    func startAndWaitUntilAddressCaptured() async {
        await startTask().value
    }

    private func startTask() -> Task<Void, Never> {
        lock.lock()
        if let task {
            lock.unlock()
            return task
        }
        let onStart = self.onStart
        let networkCapture = self.networkCapture
        let operation = self.operation
        let task = Task.detached(priority: .utility) {
            onStart(networkCapture)
            await operation()
        }
        self.task = task
        lock.unlock()
        return task
    }
}

private actor PDDVideoForegroundCompletion {
    private var completed = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if completed { return }
        await withCheckedContinuation { continuation in
            if completed { continuation.resume() }
            else { waiters.append(continuation) }
        }
    }

    func finish() {
        guard !completed else { return }
        completed = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

@MainActor
protocol PDDVideoTransferArming: AnyObject {
    func arm(
        uid: String,
        messageID: String,
        candidate: PDDCustomerVideoCandidate,
        verifyNetworkPreview: @escaping PDDVideoPreviewVerification
    ) async throws -> ArmedPDDVideoTransfer?
    func reportFailure(uid: String, messageID: String, error: Error) async
}

extension PDDVideoTransferArming {
    func reportFailure(uid: String, messageID: String, error: Error) async {}
}

@MainActor
protocol PDDVideoPreviewOpening: AnyObject {
    func open(_ candidate: PDDCustomerVideoCandidate, lease: UIOperationLease) async throws
    func open(_ candidate: PDDCustomerVideoCandidate, lease: UIOperationLease,
              beforeClick: @MainActor () -> Void) async throws
    func waitUntilOpen() async throws -> Bool
    func confirmsNetworkCapture(_ candidate: PDDCustomerVideoCandidate, lease: UIOperationLease) async throws -> Bool
    func close() async
}

extension PDDVideoPreviewOpening {
    func open(_ candidate: PDDCustomerVideoCandidate, lease: UIOperationLease,
              beforeClick: @MainActor () -> Void) async throws {
        beforeClick()
        try await open(candidate, lease: lease)
    }

    func waitUntilOpen() async throws -> Bool { true }
    func confirmsNetworkCapture(_ candidate: PDDCustomerVideoCandidate, lease: UIOperationLease) async throws -> Bool {
        try lease.validate()
        return try await waitUntilOpen()
    }
}

@MainActor
struct PDDVideoForegroundCoordinator {
    let armer: any PDDVideoTransferArming
    let opener: any PDDVideoPreviewOpening

    func begin(
        uid: String,
        candidates: [PDDCustomerVideoCandidate],
        lease: UIOperationLease
    ) async throws -> [String] {
        var pending: [String] = []
        for candidate in candidates {
            pending.append(candidate.messageID)
            do {
                try await beginOne(uid: uid, candidate: candidate, lease: lease)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                await armer.reportFailure(uid: uid, messageID: candidate.messageID, error: error)
            }
        }
        return pending
    }

    private func beginOne(
        uid: String,
        candidate: PDDCustomerVideoCandidate,
        lease: UIOperationLease
    ) async throws {
        try lease.validate()
        guard let armed = try await armer.arm(
            uid: uid, messageID: candidate.messageID, candidate: candidate,
            verifyNetworkPreview: {
                try await PDDUIOperationContext.$lease.withValue(lease) {
                    try await opener.confirmsNetworkCapture(candidate, lease: lease)
                }
            }
        ) else { return }
        var clicked = false
        var lastOpenError: Error?
        for _ in 0..<3 {
            do {
                try lease.validate()
                try await opener.open(candidate, lease: lease) { armed.checkpointNetworkBeforeClick() }
                clicked = true
                break
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastOpenError = error
            }
        }
        guard clicked else {
            throw lastOpenError ?? PDDCustomerVideoError.clickFailed
        }
        // A posted click can load the video without exposing the expected AX
        // preview labels. The matching cache URL is the capture evidence; do not
        // block the watcher or toggle an already-open preview by clicking again.
        await armed.startAndWaitUntilAddressCaptured()
        do {
            try lease.validate()
        } catch {
            await opener.close()
            throw error
        }
        await opener.close()
    }
}

@MainActor
final class PDDVideoTransferArmer: PDDVideoTransferArming {
    typealias EventHandler = @Sendable (PDDVideoTransferEvent) async -> Void

    private let cefRoot: URL
    private let networkLogURL: URL
    private let destinationRoot: URL
    private let watcher: PDDVideoCacheWatcher
    private let downloader: PDDUnlimitedVideoDownloadClient
    private let alternateDownloader: PDDAlternateVideoDownloadClient
    private let registry: PDDVideoTransferRegistry
    private let analysisInbox: PDDVideoAnalysisInbox
    private let stateStore: PDDDurableVideoTransferStore
    private let speechTranscriber: any PDDVideoSpeechTranscribing
    private let eventHandler: EventHandler

    init(
        cefRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.pinduoduo.merchantMac/PMDataRelease/Caches/cef"),
        destinationRoot: URL,
        networkLogURL: URL = PDDVideoNetworkCapture.sessionLogURL,
        watcher: PDDVideoCacheWatcher = PDDVideoCacheWatcher(),
        downloader: PDDUnlimitedVideoDownloadClient = PDDUnlimitedVideoDownloadClient(),
        alternateDownloader: PDDAlternateVideoDownloadClient = PDDAlternateVideoDownloadClient(),
        registry: PDDVideoTransferRegistry,
        analysisInbox: PDDVideoAnalysisInbox,
        stateStore: PDDDurableVideoTransferStore? = nil,
        speechTranscriber: any PDDVideoSpeechTranscribing = PDDAppleVideoSpeechTranscriber(),
        eventHandler: @escaping EventHandler
    ) {
        self.cefRoot = cefRoot
        self.networkLogURL = networkLogURL
        self.destinationRoot = destinationRoot
        self.watcher = watcher
        self.downloader = downloader
        self.alternateDownloader = alternateDownloader
        self.registry = registry
        self.analysisInbox = analysisInbox
        self.stateStore = stateStore ?? PDDDurableVideoTransferStore(
            url: destinationRoot.appendingPathComponent("transfer-state.json")
        )
        self.speechTranscriber = speechTranscriber
        self.eventHandler = eventHandler
    }

    func arm(
        uid: String,
        messageID: String,
        candidate: PDDCustomerVideoCandidate,
        verifyNetworkPreview: @escaping PDDVideoPreviewVerification
    ) async throws -> ArmedPDDVideoTransfer? {
        let key = PDDVideoTransferKey(uid: uid, messageID: messageID)
        guard !(await registry.contains(key)) else { return nil }
        let record = try await stateStore.begin(key: key, uid: uid, messageID: messageID)
        let isRecovery = record.retryIndex > 0
        switch record.phase {
        case .downloaded, .preparingEvidence, .readyForGeneration,
             .completed, .terminalFailure, .admitted:
            return nil
        case .waitingForRetry where (record.nextAttemptAt ?? .distantPast) > Date():
            return nil
        default:
            break
        }
        try await stateStore.transition(key: key, to: .opening)
        let directories = (try? PDDVideoCacheLocator.findCacheDataDirectories(inCEFRoot: cefRoot)) ?? []
        let baselines = (try? PDDVideoCacheBaseline.capture(directories: directories)) ?? []
        let transferDirectory = destinationRoot
            .appendingPathComponent("transfers", isDirectory: true)
            .appendingPathComponent(key.customerHash, isDirectory: true)
            .appendingPathComponent(key.messageHash, isDirectory: true)
        let partialURL = transferDirectory.appendingPathComponent("video.partial.mp4")
        let evidenceRoot = destinationRoot
            .appendingPathComponent("evidence", isDirectory: true)
            .appendingPathComponent(key.customerHash, isDirectory: true)
        let saveRoot = destinationRoot
        let watcher = self.watcher
        let downloader = self.downloader
        let alternateDownloader = self.alternateDownloader
        let eventHandler = self.eventHandler
        let registry = self.registry
        let analysisInbox = self.analysisInbox
        let stateStore = self.stateStore
        let speechTranscriber = self.speechTranscriber
        let foregroundCompletion = PDDVideoForegroundCompletion()
        let transferOperation: @Sendable (PDDVideoNetworkCapture?) async -> Void = { networkCapture in
            await eventHandler(.init(
                uid: uid, messageID: messageID, phase: .waitingForAddress
            ))
            do {
                let networkLookup: (@MainActor @Sendable () async throws -> URL)?
                if let networkCapture {
                    networkLookup = {
                        AutomationStepLog.record(root: saveRoot.deletingLastPathComponent(), uid: uid,
                            step: "video-network-waiting", detail: "message_id=\(messageID)")
                        let url: URL
                        do {
                            url = try await networkCapture.wait()
                        } catch PDDVideoNetworkCapture.Failure.ambiguous {
                            AutomationStepLog.record(root: saveRoot.deletingLastPathComponent(), uid: uid,
                                step: "video-network-ambiguous", detail: "message_id=\(messageID)")
                            throw PDDVideoNetworkCapture.Failure.ambiguous
                        }
                        try Task.checkCancellation()
                        guard try await verifyNetworkPreview() else {
                            AutomationStepLog.record(root: saveRoot.deletingLastPathComponent(), uid: uid,
                                step: "video-network-chat-unverified", detail: "message_id=\(messageID)")
                            throw PDDVideoNetworkCapture.Failure.unavailable
                        }
                        try Task.checkCancellation()
                        guard await registry.claimSource(url, for: key) else {
                            throw PDDVideoNetworkCapture.Failure.ambiguous
                        }
                        return url
                    }
                } else {
                    networkLookup = nil
                    AutomationStepLog.record(root: saveRoot.deletingLastPathComponent(), uid: uid,
                        step: "video-network-log-unavailable", detail: "message_id=\(messageID)")
                }
                let match = try await PDDVideoAddressResolver.resolve(cache: {
                    AutomationStepLog.record(root: saveRoot.deletingLastPathComponent(), uid: uid,
                        step: "video-cache-waiting", detail: "message_id=\(messageID)")
                    let preloadedWindow = PDDAXSnapshotOrder.messageOrdinal(from: messageID)
                        .map { ordinal -> ClosedRange<Date> in
                            let messageDate = Date(
                                timeIntervalSince1970: TimeInterval(ordinal) / 1_000
                            )
                            return messageDate...messageDate.addingTimeInterval(20)
                        }
                    return try await watcher.wait(
                        in: baselines, preloadedWindow: preloadedWindow
                    ) { url in
                        guard (try? await verifyNetworkPreview()) == true, !Task.isCancelled else { return false }
                        return await registry.claimSource(url, for: key)
                    }
                }, network: networkLookup)
                try Task.checkCancellation()
                let sourceURL = match.url
                AutomationStepLog.record(root: saveRoot.deletingLastPathComponent(), uid: uid,
                    step: "video-address-captured", detail: "message_id=\(messageID); source=\(match.source.rawValue)")
                // Only address capture needs the foreground preview. Download,
                // validation and evidence processing continue independently.
                await foregroundCompletion.finish()
                try await stateStore.transition(key: key, to: .addressCaptured)
                try await stateStore.recordAttempt(key: key)
                await eventHandler(.init(uid: uid, messageID: messageID, phase: .downloading))
                try await stateStore.transition(key: key, to: .downloading)
                _ = try await withOperationDeadline(
                    .seconds(PDDUnlimitedVideoDownloadSessionPolicy.transferTimeoutSeconds), stage: "video-download"
                ) {
                    do {
                        return try await downloader.download(from: sourceURL, to: partialURL)
                    } catch {
                        try Task.checkCancellation()
                        return try await alternateDownloader.download(from: sourceURL, to: partialURL)
                    }
                }
                try await stateStore.transition(key: key, to: .validating)
                let summary = try await PDDVideoFileInspector.inspect(partialURL)
                let stableURL = PDDBackgroundVideoRecovery.savedVideoURL(root: saveRoot, key: key)
                try FileManager.default.createDirectory(
                    at: transferDirectory, withIntermediateDirectories: true
                )
                if FileManager.default.fileExists(atPath: stableURL.path) {
                    try? FileManager.default.removeItem(at: partialURL)
                } else {
                    try FileManager.default.moveItem(at: partialURL, to: stableURL)
                }
                let receipt = PDDDownloadedCustomerVideo(
                    uid: uid, messageID: messageID, key: key,
                    fileURL: stableURL, summary: summary
                )
                try await stateStore.transition(
                    key: key, to: .downloaded, fileName: stableURL.lastPathComponent
                )
                await eventHandler(.init(uid: uid, messageID: messageID, phase: .downloaded,
                    diagnostic: "saved_file=\(stableURL.lastPathComponent); identity=customer-message"))
                await foregroundCompletion.finish()
                _ = try await analysisInbox.claim(receipt)
                await eventHandler(.init(
                    uid: uid, messageID: messageID, phase: .preparingEvidence
                ))
                try await stateStore.transition(key: key, to: .preparingEvidence)
                let preparer = PDDCustomerVideoEvidencePreparer(
                    rootURL: evidenceRoot,
                    transcriber: speechTranscriber
                )
                let attachment = try await withOperationDeadline(
                    .seconds(90), stage: "video-evidence"
                ) {
                    try await preparer.prepare(download: receipt)
                }
                await eventHandler(.init(
                    uid: uid, messageID: messageID, phase: .readyForGeneration,
                    attachment: attachment, diagnostic: attachment.diagnostic, recovered: isRecovery
                ))
                try await stateStore.transition(key: key, to: .readyForGeneration)
            } catch is CancellationError {
                await foregroundCompletion.finish()
                return
            } catch {
                try? FileManager.default.removeItem(at: partialURL)
                await Self.handleFailure(
                    uid: uid, messageID: messageID, key: key, error: error,
                    stateStore: stateStore, eventHandler: eventHandler
                )
                await foregroundCompletion.finish()
            }
        }
        return ArmedPDDVideoTransfer(
            networkLogURL: networkLogURL,
            onStart: { networkCapture in
                Task {
                    let started = await registry.start(key: key) { await transferOperation(networkCapture) }
                    if !started { await foregroundCompletion.finish() }
                }
            },
            operation: { await foregroundCompletion.wait() }
        )
    }

    func reportFailure(uid: String, messageID: String, error: Error) async {
        let key = PDDVideoTransferKey(uid: uid, messageID: messageID)
        _ = try? await stateStore.begin(key: key, uid: uid, messageID: messageID)
        await Self.handleFailure(
            uid: uid, messageID: messageID, key: key, error: error,
            stateStore: stateStore, eventHandler: eventHandler
        )
    }

    private static func handleFailure(
        uid: String, messageID: String, key: PDDVideoTransferKey, error: Error,
        stateStore: PDDDurableVideoTransferStore, eventHandler: EventHandler
    ) async {
        let category = PDDVideoTransferFailureCategory.classify(error)
        let detail = PDDVideoTransferFailureCategory.diagnostic(error)
        let record = try? await stateStore.record(key)
        guard record?.phase != .terminalFailure else { return }
        try? await stateStore.transition(
            key: key, to: .terminalFailure, failure: category, failureDetail: detail
        )
        await eventHandler(.init(
            uid: uid, messageID: messageID, phase: .failed,
            diagnostic: "category=\(category.rawValue) cause=\(detail); proceed without video"
        ))
        if (try? await stateStore.markFallbackEmitted(key: key)) == true {
            await eventHandler(.init(
                uid: uid, messageID: messageID, phase: .fallbackRequired,
                diagnostic: "请问您的产品遇到了什么问题？麻烦您描述一下具体表现，我来帮您排查。"
            ))
        }
    }
}
