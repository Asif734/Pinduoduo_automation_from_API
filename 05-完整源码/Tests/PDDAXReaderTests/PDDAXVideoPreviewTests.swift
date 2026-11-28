import XCTest
@testable import PDDAXReader

final class PDDAXVideoPreviewTests: XCTestCase {
    func testRecognizesOnlyExplicitVideoPreviewMarkers() {
        XCTAssertTrue(PDDVideoPreviewElementPolicy.isPreviewMarker("视频预览"))
        XCTAssertTrue(PDDVideoPreviewElementPolicy.isPreviewMarker("客户视频播放"))
        XCTAssertFalse(PDDVideoPreviewElementPolicy.isPreviewMarker("拼多多商家工作台"))
        XCTAssertFalse(PDDVideoPreviewElementPolicy.isPreviewMarker("消息"))
        XCTAssertFalse(PDDVideoPreviewElementPolicy.isPreviewMarker("预览"))
    }

    func testRecognizesCloseButtonOnlyInsidePreviewSubtree() {
        XCTAssertTrue(PDDVideoPreviewElementPolicy.isCloseButton(role: "AXButton", labels: ["Close"]))
        XCTAssertTrue(PDDVideoPreviewElementPolicy.isCloseButton(role: "AXButton", labels: ["关闭"]))
        XCTAssertFalse(PDDVideoPreviewElementPolicy.isCloseButton(role: "AXButton", labels: ["Fullscreen"]))
        XCTAssertFalse(PDDVideoPreviewElementPolicy.isCloseButton(role: "AXWindow", labels: ["Close"]))
    }

    @MainActor
    func testDismissesPreviewByClickingItsOwnCloseButtonBeforeOpeningNextVideo() async throws {
        let messageID = "middlePanel_list_123"
        let videoFrame = CGRect(x: 310, y: 220, width: 120, height: 90)
        let chat = previewVideoTree(messageID: messageID, frame: videoFrame)
        let closeFrame = CGRect(x: 218, y: 118, width: 11, height: 11)
        let previewTitle = PDDAXSemanticNode(
            id: AXElementToken(rawValue: 5), parentID: AXElementToken(rawValue: 4), role: "AXStaticText",
            value: "视频预览", title: nil, domIdentifier: nil, domClasses: [], actionNames: [], isSettable: false
        )
        let previewClose = PDDAXSemanticNode(
            id: AXElementToken(rawValue: 6), parentID: previewTitle.parentID, role: "AXButton",
            value: nil, title: nil, domIdentifier: nil, domClasses: [], actionNames: ["AXPress"],
            isSettable: false, frame: closeFrame, accessibilityDescription: "Close"
        )
        let unrelatedClose = PDDAXSemanticNode(
            id: AXElementToken(rawValue: 7), parentID: AXElementToken(rawValue: 1), role: "AXButton",
            value: nil, title: "Close", domIdentifier: nil, domClasses: [], actionNames: ["AXPress"],
            isSettable: false, frame: CGRect(x: 5, y: 5, width: 11, height: 11)
        )
        let overlay = PDDAXSemanticTree(rootSnapshot: chat.rootSnapshot,
            nodes: chat.nodes + [unrelatedClose, previewTitle, previewClose])
        let backend = PreviewBackendStub(tree: overlay)
        var actions: [String] = []
        var dismisses = true
        let opener = PDDAXVideoPreviewOpener(
            backend: backend,
            clickOverride: { _ in actions.append("open") },
            previewCloseClick: { point in
                XCTAssertEqual(point, CGPoint(x: closeFrame.midX, y: closeFrame.midY))
                actions.append("close")
                if dismisses { backend.tree = chat }
            }
        )

        await opener.close()
        XCTAssertEqual(actions, ["close"])

        backend.tree = overlay
        let candidate = PDDCustomerVideoCandidate(messageID: messageID, frame: videoFrame)
        let lease = UIOperationLeaseRegistry().acquire(uid: "PDD-one")
        try await opener.open(candidate, lease: lease)
        XCTAssertEqual(actions, ["close", "close", "open"])

        dismisses = false
        backend.tree = overlay
        do {
            try await opener.open(candidate, lease: lease)
            XCTFail("The next video click must wait until the previous preview is gone")
        } catch PDDCustomerVideoError.clickFailed {
            XCTAssertEqual(actions, ["close", "close", "open", "close"])
        }
    }

    @MainActor
    func testLiveCloseOnlyWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["PDD_LIVE_VIDEO_PREVIEW_CLOSE"] == "1" else {
            throw XCTSkip("set PDD_LIVE_VIDEO_PREVIEW_CLOSE=1 with a PDD video preview already open")
        }
        await PDDAXVideoPreviewOpener().close()
    }

    @MainActor
    func testLiveOpenCanConfirmAndCloseCurrentCustomerVideo() async throws {
        guard ProcessInfo.processInfo.environment["PDD_LIVE_VIDEO_PREVIEW_OPEN"] == "1" else {
            throw XCTSkip("set PDD_LIVE_VIDEO_PREVIEW_OPEN=1 with a customer video visible in PDD")
        }
        let backend = LivePDDAXBackend()
        let tree = try backend.readSemanticTree()
        let messageIDs = tree.nodes.compactMap(\.domIdentifier).filter {
            $0.hasPrefix("middlePanel_list_")
        }
        let candidate = try XCTUnwrap(PDDAXVideoSelection.customerVideos(
            in: tree.nodes, messageIDs: messageIDs
        ).last)
        let opener = PDDAXVideoPreviewOpener(backend: backend)

        try await opener.open(
            candidate,
            lease: UIOperationLeaseRegistry().acquire(uid: "PDD-live-video-test")
        )
        let confirmed = try await opener.waitUntilOpen()
        await opener.close()

        XCTAssertTrue(confirmed, "PDD accepted the click but preview-open evidence was not exposed")
    }

    @MainActor
    func testEveryOpenAttemptRefreshesTheVideoFrameByMessageID() async throws {
        let messageID = "middlePanel_list_123"
        let refreshedFrame = CGRect(x: 310, y: 220, width: 120, height: 90)
        let backend = PreviewBackendStub(tree: previewVideoTree(
            messageID: messageID, frame: refreshedFrame
        ))
        var clickedFrames: [CGRect] = []
        let opener = PDDAXVideoPreviewOpener(
            backend: backend,
            clickOverride: { clickedFrames.append($0.frame) },
            previewProbeOverride: { true },
            confirmationPause: {}
        )
        let staleCandidate = PDDCustomerVideoCandidate(
            messageID: messageID,
            frame: CGRect(x: 10, y: 20, width: 30, height: 30)
        )

        try await opener.open(
            staleCandidate,
            lease: UIOperationLeaseRegistry().acquire(uid: "PDD-one")
        )

        XCTAssertEqual(clickedFrames, [refreshedFrame])
        XCTAssertEqual(backend.readCount, 1)
    }

    @MainActor
    func testVerifiedVideoClickSurvivesMissingPreviewButRejectsAChangedChat() async throws {
        let messageID = "middlePanel_list_123"
        let frame = CGRect(x: 310, y: 220, width: 120, height: 90)
        let backend = PreviewBackendStub(tree: previewVideoTree(messageID: messageID, frame: frame))
        var checkpointed = false
        let opener = PDDAXVideoPreviewOpener(backend: backend,
            clickOverride: { _ in XCTAssertTrue(checkpointed) }, previewProbeOverride: { false })
        let lease = UIOperationLeaseRegistry().acquire(uid: "PDD-one")
        let candidate = PDDCustomerVideoCandidate(messageID: messageID, frame: frame)
        try await opener.open(candidate, lease: lease) {
            XCTAssertEqual(backend.readCount, 1, "Verify the message before recording the network checkpoint")
            checkpointed = true
        }

        let verified = try await opener.confirmsNetworkCapture(candidate, lease: lease)
        XCTAssertTrue(verified)

        backend.tree = previewVideoTree(messageID: messageID, frame: frame, activeID: "conversation-b")
        let changedChatVerified = try await opener.confirmsNetworkCapture(candidate, lease: lease)
        XCTAssertFalse(changedChatVerified, "A stale message pane cannot authorize capture after the active chat changes")
    }

    private func previewVideoTree(messageID: String, frame: CGRect, activeID: String = "conversation-a") -> PDDAXSemanticTree {
        let selectedChat = AXNodeSnapshot(role: "AXGroup", attributes: [
            ("AXDOMClassList", "[chat-item-box, active]"), ("AXDOMIdentifier", activeID)
        ], children: [AXNodeSnapshot(role: "AXStaticText", attributes: [
            ("AXDOMClassList", "[chat-nickname]"), ("AXValue", "A***")
        ])])
        return PDDAXSemanticTree(rootSnapshot: AXNodeSnapshot(role: "AXWindow", children: [selectedChat]), nodes: [
            PDDAXSemanticNode(
                id: AXElementToken(rawValue: 1), parentID: nil, role: "AXGroup",
                value: nil, title: nil, domIdentifier: "msgListContainer",
                domClasses: ["msg-list"], actionNames: [], isSettable: false,
                frame: CGRect(x: 0, y: 0, width: 800, height: 800)
            ),
            PDDAXSemanticNode(
                id: AXElementToken(rawValue: 2), parentID: AXElementToken(rawValue: 1),
                role: "AXGroup", value: nil, title: nil, domIdentifier: messageID,
                domClasses: ["onemsg", "buyer-item"], actionNames: [], isSettable: false
            ),
            PDDAXSemanticNode(
                id: AXElementToken(rawValue: 3), parentID: AXElementToken(rawValue: 2),
                role: "AXGroup", value: nil, title: nil, domIdentifier: nil,
                domClasses: ["video-msg"], actionNames: [], isSettable: false,
                frame: frame
            )
        ])
    }
}

@MainActor
private final class PreviewBackendStub: PDDAXBackend {
    var tree: PDDAXSemanticTree
    var readCount = 0

    init(tree: PDDAXSemanticTree) { self.tree = tree }

    func readSemanticTree() throws -> PDDAXSemanticTree {
        readCount += 1
        return tree
    }

    func performPress(_ id: AXElementToken) throws {}
    func setValue(_ text: String, on id: AXElementToken) throws {}
    func value(of id: AXElementToken) throws -> String { "" }
}
