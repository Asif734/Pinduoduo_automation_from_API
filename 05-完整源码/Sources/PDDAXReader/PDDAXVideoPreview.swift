import AppKit
import ApplicationServices
import Foundation

enum PDDVideoPreviewElementPolicy {
    static func isPreviewMarker(_ rawLabel: String) -> Bool {
        let label = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        return label.contains("视频")
            && (label.contains("预览") || label.contains("播放"))
    }

    static func isCloseButton(role: String, labels: [String]) -> Bool {
        guard role == kAXButtonRole as String else { return false }
        return labels.contains { rawLabel in
            let label = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return label == "close" || label == "关闭" || label == "关闭视频预览"
        }
    }

    static func closeButton(in nodes: [PDDAXSemanticNode<AXElementToken>]) -> PDDAXSemanticNode<AXElementToken>? {
        let previewParents = Set(nodes.compactMap { node -> AXElementToken? in
            guard node.role == "AXStaticText", [node.value, node.title, node.accessibilityDescription]
                .contains("视频预览") else { return nil }
            return node.parentID
        })
        let buttons = nodes.filter { node in
            guard let parent = node.parentID, previewParents.contains(parent) else { return false }
            return isCloseButton(role: node.role, labels: [node.value, node.title, node.accessibilityDescription]
                .compactMap { $0 })
        }
        return buttons.count == 1 ? buttons.first : nil
    }
}

@MainActor
final class PDDAXVideoPreviewOpener: PDDVideoPreviewOpening {
    typealias ClickOverride = @MainActor (PDDCustomerVideoCandidate) async throws -> Void
    typealias PreviewProbeOverride = @MainActor () -> Bool
    typealias ConfirmationPause = @MainActor () async throws -> Void

    private let backend: any PDDAXBackend
    private let logRoot: URL?
    private let clickOverride: ClickOverride?
    private let previewProbeOverride: PreviewProbeOverride?
    private let previewCloseClick: (@MainActor (CGPoint) throws -> Void)?
    private let confirmationPause: ConfirmationPause
    private var verifiedClick: (messageID: String, lease: UIOperationLease, conversation: PDDConversationLocator?)?

    convenience init() {
        self.init(backend: LivePDDAXBackend())
    }

    init(
        backend: any PDDAXBackend,
        logRoot: URL? = nil,
        clickOverride: ClickOverride? = nil,
        previewProbeOverride: PreviewProbeOverride? = nil,
        previewCloseClick: (@MainActor (CGPoint) throws -> Void)? = nil,
        confirmationPause: @escaping ConfirmationPause = {
            try await Task.sleep(for: .milliseconds(250))
        }
    ) {
        self.backend = backend
        self.logRoot = logRoot
        self.clickOverride = clickOverride
        self.previewProbeOverride = previewProbeOverride
        self.previewCloseClick = previewCloseClick
        self.confirmationPause = confirmationPause
    }

    func open(_ candidate: PDDCustomerVideoCandidate, lease: UIOperationLease) async throws {
        try await open(candidate, lease: lease, beforeClick: {})
    }

    func open(_ candidate: PDDCustomerVideoCandidate, lease: UIOperationLease,
              beforeClick: @MainActor () -> Void) async throws {
        try Task.checkCancellation()
        try lease.validate()
        verifiedClick = nil
        if clickOverride == nil { try await activateWorkbench() }
        try lease.validate()
        let initialTree = try backend.readSemanticTreeForObservation()
        let tree = try await dismissPreview(in: initialTree, lease: lease) ?? initialTree
        let conversation = try activeConversation(in: tree)
        guard let clickTarget = PDDAXVideoSelection.customerVideos(
            in: tree.nodes, messageIDs: [candidate.messageID]
        ).first, PDDAXRecipientVerification.reason(uid: lease.uid,
            locator: lease.uid.hasPrefix("PDD-ID-") ? nil : conversation,
            expectedAXMessageIDs: [candidate.messageID], tree: tree) != nil else {
            throw PDDCustomerVideoError.clickFailed
        }
        if let logRoot {
            AutomationStepLog.record(root: logRoot, uid: lease.uid, step: "video-preview-click-target",
                detail: "message_id=\(candidate.messageID) frame=\(clickTarget.frame); refreshed=\(clickTarget != candidate)")
        }
        try Task.checkCancellation()
        try lease.validate()
        beforeClick()
        try lease.validate()
        if let clickOverride {
            try await clickOverride(clickTarget)
        } else {
            guard let application = NSWorkspace.shared.frontmostApplication,
                  application.bundleIdentifier == "com.pinduoduo.merchantMac",
                  isWorkbenchFocused(in: AXUIElementCreateApplication(application.processIdentifier)) else {
                throw PDDCustomerVideoError.clickFailed
            }
            try postClick(at: CGPoint(x: clickTarget.frame.midX, y: clickTarget.frame.midY))
        }
        try Task.checkCancellation()
        try lease.validate()
        verifiedClick = (candidate.messageID, lease, conversation)
        if let logRoot {
            AutomationStepLog.record(root: logRoot, uid: lease.uid, step: "video-preview-click-posted",
                detail: "message_id=\(candidate.messageID); waiting for matching video URL")
        }
    }

    func waitUntilOpen() async throws -> Bool {
        for _ in 0..<6 {
            try Task.checkCancellation()
            if previewProbeOverride?() ?? isPreviewOpen() { return true }
            try await confirmationPause()
        }
        try Task.checkCancellation()
        return previewProbeOverride?() ?? isPreviewOpen()
    }

    func confirmsNetworkCapture(_ candidate: PDDCustomerVideoCandidate, lease: UIOperationLease) async throws -> Bool {
        try Task.checkCancellation()
        try lease.validate()
        guard let verifiedClick, verifiedClick.messageID == candidate.messageID,
              verifiedClick.lease == lease else { return false }
        let tree = try backend.readSemanticTreeForObservation()
        if let previous = verifiedClick.conversation, let current = try activeConversation(in: tree) {
            if let previousID = previous.normalizedIdentifier, let currentID = current.normalizedIdentifier {
                guard previousID == currentID else { return false }
            } else if !previous.normalizedNickname.isEmpty, !current.normalizedNickname.isEmpty {
                guard previous.normalizedNickname == current.normalizedNickname else { return false }
            }
        }
        let reason = PDDAXRecipientVerification.reason(uid: lease.uid, locator: verifiedClick.conversation,
            expectedAXMessageIDs: [candidate.messageID], tree: tree)
        try lease.validate()
        return reason == "ax-conversation-id" || reason == "ax-customer-message-id" || reason == "ax-customer-id"
    }

    private func activeConversation(in tree: PDDAXSemanticTree) throws -> PDDConversationLocator? {
        if let locator = PDDConversationSnapshotLocator.current(in: tree.rootSnapshot) { return locator }
        if let id = PDDConversationSnapshotLocator.activeIdentifier(in: tree.rootSnapshot) {
            return .init(domIdentifier: id, nickname: "")
        }
        return try PDDAXControlSelection.currentConversationRow(in: tree.nodes).map {
            .init(domIdentifier: $0.domIdentifier, nickname: $0.visibleLabel)
        }
    }

    private func activateWorkbench() async throws {
        guard let application = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.pinduoduo.merchantMac"
        ).first, let bundleURL = application.bundleURL else { throw PDDCustomerVideoError.clickFailed }
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.5)
        guard let workbench = copyElements(kAXWindowsAttribute as String, from: appElement).first(where: {
            copyString(kAXTitleAttribute as String, from: $0)?.contains("拼多多商家工作台") == true
        }) else { throw PDDCustomerVideoError.clickFailed }
        do {
            try await PDDWindowForegroundActivation.run(
                request: {
                    let configuration = NSWorkspace.OpenConfiguration()
                    configuration.activates = true
                    configuration.createsNewApplicationInstance = false
                    configuration.allowsRunningApplicationSubstitution = false
                    let opened = try await NSWorkspace.shared.openApplication(
                        at: bundleURL, configuration: configuration
                    )
                    return opened.processIdentifier == application.processIdentifier
                },
                raise: { AXUIElementPerformAction(workbench, kAXRaiseAction as CFString) == .success },
                isFrontmost: {
                    !application.isTerminated
                        && NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier
                },
                isTargetWindowFocused: { isWorkbenchFocused(in: appElement) }
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw PDDCustomerVideoError.clickFailed
        }
    }

    private func isWorkbenchFocused(in appElement: AXUIElement) -> Bool {
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
        let window = unsafeBitCast(focused, to: AXUIElement.self)
        return copyString(kAXTitleAttribute as String, from: window)?.contains("拼多多商家工作台") == true
    }

    private func postClick(at point: CGPoint) throws {
        try Task.checkCancellation()
        guard let down = CGEvent(
            mouseEventSource: nil, mouseType: .leftMouseDown,
            mouseCursorPosition: point, mouseButton: .left
        ), let up = CGEvent(
            mouseEventSource: nil, mouseType: .leftMouseUp,
            mouseCursorPosition: point, mouseButton: .left
        ) else { throw PDDCustomerVideoError.clickFailed }
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventClickState, value: 1)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        try Task.checkCancellation()
    }

    private func copyElements(_ name: String, from element: AXUIElement) -> [AXUIElement] {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success else { return [] }
        return raw as? [AXUIElement] ?? []
    }

    private func copyString(_ name: String, from element: AXUIElement) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success,
              let raw else { return nil }
        return AXValueFormatter.string(from: raw)
    }

    func close() async {
        let click = verifiedClick
        verifiedClick = nil
        let lease = click?.lease ?? PDDUIOperationContext.lease
        do {
            try lease?.validate()
            let tree = try backend.readSemanticTreeForObservation()
            guard try await dismissPreview(in: tree, lease: lease) != nil else { return }
            if let logRoot, let click {
                AutomationStepLog.record(root: logRoot, uid: click.lease.uid, step: "video-preview-closed",
                    detail: "message_id=\(click.messageID)")
            }
        } catch {
            if let logRoot, let click {
                AutomationStepLog.record(root: logRoot, uid: click.lease.uid, step: "video-preview-close-failed",
                    detail: "message_id=\(click.messageID); \(error.localizedDescription)")
            }
        }
    }

    private func dismissPreview(in tree: PDDAXSemanticTree, lease: UIOperationLease?) async throws -> PDDAXSemanticTree? {
        guard let button = PDDVideoPreviewElementPolicy.closeButton(in: tree.nodes) else { return nil }
        try lease?.validate()
        guard !button.frame.isEmpty, button.frame.midX.isFinite, button.frame.midY.isFinite else {
            throw PDDCustomerVideoError.clickFailed
        }
        let point = CGPoint(x: button.frame.midX, y: button.frame.midY)
        if let previewCloseClick {
            try previewCloseClick(point)
        } else {
            guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.pinduoduo.merchantMac" else {
                throw PDDCustomerVideoError.clickFailed
            }
            // PDD exposes AXPress for this button, but only the pointer click dismisses it.
            try postClick(at: point)
        }
        for _ in 0..<3 {
            try await Task.sleep(for: .milliseconds(50))
            try lease?.validate()
            let updated = try backend.readSemanticTreeForObservation()
            if PDDVideoPreviewElementPolicy.closeButton(in: updated.nodes) == nil { return updated }
        }
        throw PDDCustomerVideoError.clickFailed
    }

    private func isPreviewOpen() -> Bool {
        guard let application = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.pinduoduo.merchantMac"
        ).first else { return false }
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        for window in copyElements(kAXWindowsAttribute as String, from: appElement) {
            var visited = Set<CFHashCode>()
            var budget = 2_000
            if firstDescendant(
                from: window,
                visited: &visited,
                budget: &budget,
                where: { element in
                    if labels(of: element).contains(where: PDDVideoPreviewElementPolicy.isPreviewMarker) {
                        return true
                    }
                    let dom = [
                        copyString("AXDOMIdentifier", from: element),
                        copyString("AXDOMClassList", from: element)
                    ].compactMap { $0 }.joined(separator: " ").lowercased()
                    return dom.contains("video-preview")
                        || dom.contains("video-player")
                        || dom.contains("video-modal")
                }
            ) != nil { return true }
        }
        return false
    }

    private func firstDescendant(
        from element: AXUIElement,
        visited: inout Set<CFHashCode>,
        budget: inout Int,
        where matches: (AXUIElement) -> Bool
    ) -> AXUIElement? {
        guard budget > 0, visited.insert(CFHash(element)).inserted else { return nil }
        budget -= 1
        if matches(element) { return element }
        let children = copyElements("AXChildrenInNavigationOrder", from: element)
            + copyElements(kAXChildrenAttribute as String, from: element)
        for child in children {
            if let match = firstDescendant(
                from: child, visited: &visited, budget: &budget, where: matches
            ) {
                return match
            }
        }
        return nil
    }

    private func labels(of element: AXUIElement) -> [String] {
        [
            kAXTitleAttribute as String,
            kAXDescriptionAttribute as String,
            kAXValueAttribute as String,
            kAXHelpAttribute as String
        ].compactMap { copyString($0, from: element) }
    }
}
