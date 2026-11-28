import CryptoKit
import Foundation

@MainActor
final class PDDAXReplySender {
    var supportsTextDeliveryTracking: Bool { logRoot != nil }
    private let backend: any PDDAXBackend
    private let opener: any PDDConversationOpening
    private let confirmationTimeout: TimeInterval
    private let writeVerificationTimeout: TimeInterval
    private let pollIntervalNanoseconds: UInt64
    private let logRoot: URL?
    private let observeSnapshot: (@MainActor (String, AXNodeSnapshot) throws -> Void)?
    private let imageUploader: any PDDOutgoingImageUploading
    private let imageConfirmationTimeout: TimeInterval
    private let imagePreviewClicker: any PDDTransferClicking

    init(
        backend: any PDDAXBackend,
        opener: any PDDConversationOpening,
        confirmationTimeout: TimeInterval = 3.0,
        writeVerificationTimeout: TimeInterval = 1.0,
        pollIntervalNanoseconds: UInt64 = 85_000_000,
        logRoot: URL? = nil,
        observeSnapshot: (@MainActor (String, AXNodeSnapshot) throws -> Void)? = nil,
        imageUploader: (any PDDOutgoingImageUploading)? = nil,
        imageConfirmationTimeout: TimeInterval = 20,
        imagePreviewClicker: (any PDDTransferClicking)? = nil
    ) {
        self.backend = backend
        self.opener = opener
        self.confirmationTimeout = confirmationTimeout
        self.writeVerificationTimeout = writeVerificationTimeout
        self.pollIntervalNanoseconds = pollIntervalNanoseconds
        self.logRoot = logRoot
        self.observeSnapshot = observeSnapshot
        self.imageUploader = imageUploader ?? LivePDDOutgoingImageUploader(logRoot: logRoot)
        self.imageConfirmationTimeout = imageConfirmationTimeout
        self.imagePreviewClicker = imagePreviewClicker ?? CGEventPDDTransferClicker()
    }

    func send(uid: String, text: String, outgoingImages: [DatasetReplyImage], deliveryID: UUID,
              expectedCustomerCursor: AutoReplyCursor, expectedCustomerMessageIDs: Set<String>,
              lease: UIOperationLease? = nil) async throws -> AutoReplyDeliveryResult {
        guard !outgoingImages.isEmpty else {
            return try await send(uid: uid, text: text, expectedCustomerCursor: expectedCustomerCursor,
                expectedCustomerMessageIDs: expectedCustomerMessageIDs, deliveryID: deliveryID)
        }
        guard let logRoot, outgoingImages.count <= 3, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failedBeforeSend("图片发送缺少持久化目录或有效回复")
        }
        let receipts = PDDOutgoingImageReceiptStore(root: logRoot)
        let realIDs = expectedCustomerMessageIDs.filter { !$0.hasPrefix(FrozenCustomerBatch.incomingHandoffPrefix) }
        var anySubmitted = false
        var allImagesConfirmed = false
        defer {
            if anySubmitted && !allImagesConfirmed {
                dismissIdleImageConfirmation(uid: uid, lease: lease)
            }
            imageUploader.finish()
        }
        do {
            for image in outgoingImages { try image.verify(in: logRoot) }
            for image in outgoingImages {
                try lease?.validate()
                try Task.checkCancellation()
                let tree = try await opener.openAndResolve(uid: uid, expectedCustomerMessageIDs: realIDs)
                guard matches(uid: uid, tree: tree, expectedIDs: realIDs) else {
                    throw DatasetReplyImageError.invalid("图片发送前 UID 不匹配")
                }
                try observeSnapshot?(uid, tree.rootSnapshot)
                var receipt = try receipts.load(deliveryID: deliveryID, hash: image.sha256)
                var maySendPreview = false
                if let existing = receipt {
                    guard existing.uid == uid, existing.imageSHA256 == image.sha256 else {
                        return .uncertain("图片发送凭据不匹配，停止自动重发")
                    }
                    anySubmitted = true
                    if existing.confirmedMessageID != nil {
                        AutomationStepLog.record(root: logRoot, uid: uid, step: "reply-image-duplicate-skipped", detail: image.sha256)
                        continue
                    }
                    // A submitted receipt survives crashes. Observe only; never upload it again.
                } else {
                    if !anySubmitted, let marker = expectedCustomerMessageIDs.first(where: {
                        $0.hasPrefix(FrozenCustomerBatch.incomingHandoffPrefix)
                    }) {
                        let key = String(marker.dropFirst(FrozenCustomerBatch.incomingHandoffPrefix.count))
                        guard PDDAXIncomingTransfer.unansweredHandoff(in: tree.rootSnapshot)?.boundaryKey == key else {
                            return .discardedBeforeSend("转入会话已回复或边界变化")
                        }
                    }
                    let baseline = PDDOutgoingImageControls.imageMessageIDs(in: tree)
                    AutomationStepLog.record(root: logRoot, uid: uid, step: "reply-image-paste-started", detail: image.datasetRelativePath)
                    try await imageUploader.upload(file: image.localURL) {
                        try lease?.validate()
                        try Task.checkCancellation()
                        let current = try backend.readSemanticTree()
                        guard matches(uid: uid, tree: current, expectedIDs: realIDs) else {
                            throw DatasetReplyImageError.invalid("粘贴图片前 UID 变化")
                        }
                        try observeSnapshot?(uid, current.rootSnapshot)
                        try image.verify(in: logRoot)
                        if receipt == nil {
                            let submitted = PDDOutgoingImageReceipt(uid: uid, imageSHA256: image.sha256,
                                baselineMessageIDs: baseline, submittedAt: Date())
                            try receipts.save(submitted, deliveryID: deliveryID)
                            receipt = submitted
                            anySubmitted = true
                            AutomationStepLog.record(root: logRoot, uid: uid, step: "reply-image-submitted", detail: image.sha256)
                        }
                    }
                    guard receipt != nil else { throw DatasetReplyImageError.invalid("上传器未保存发送凭据") }
                    maySendPreview = true
                }
                guard var submitted = receipt else { return .uncertain("缺少图片发送凭据") }
                let deadline = Date().addingTimeInterval(imageConfirmationTimeout)
                repeat {
                    try lease?.validate()
                    try Task.checkCancellation()
                    let current = try backend.readSemanticTree()
                    guard matches(uid: uid, tree: current, expectedIDs: realIDs) else { return .uncertain("图片上传后 UID 变化") }
                    try observeSnapshot?(uid, current.rootSnapshot)
                    let newIDs = PDDOutgoingImageControls.confirmedImageMessageIDs(in: current)
                        .subtracting(submitted.baselineMessageIDs)
                    if newIDs.count == 1, let id = newIDs.first {
                        submitted.confirmedMessageID = id
                        try receipts.save(submitted, deliveryID: deliveryID)
                        AutomationStepLog.record(root: logRoot, uid: uid, step: "reply-image-confirmed", detail: "sha256=\(image.sha256) message=\(id)")
                        break
                    }
                    // Some versions show a separate image confirmation dialog after pasting.
                    if maySendPreview, submitted.previewSubmittedAt == nil,
                       let button = PDDOutgoingImageControls.previewSendControl(in: current.nodes) {
                        try lease?.validate()
                        submitted.previewSubmittedAt = Date()
                        try receipts.save(submitted, deliveryID: deliveryID)
                        AutomationStepLog.record(root: logRoot, uid: uid, step: "reply-image-preview-send",
                            detail: "sha256=\(image.sha256) control=\(button.sourceLabel) route=\(button.allowsAXPress ? "AXPress" : "AX-frame-click")")
                        if button.allowsAXPress {
                            try backend.performPress(button.id)
                        } else {
                            try imagePreviewClicker.click(at: button.point)
                        }
                    }
                    try await Task.sleep(nanoseconds: max(pollIntervalNanoseconds, 20_000_000))
                } while Date() < deadline
                guard submitted.confirmedMessageID != nil else {
                    AutomationStepLog.record(root: logRoot, uid: uid, step: "reply-image-uncertain", detail: image.sha256)
                    return .uncertain("图片已提交但未确认送达；为防止重复，不自动重发")
                }
            }
            allImagesConfirmed = true
            try lease?.validate()
            // The image itself acknowledges an incoming handoff; do not reject the accompanying text as an old handoff.
            let result = try await send(uid: uid, text: text, expectedCustomerCursor: expectedCustomerCursor,
                expectedCustomerMessageIDs: realIDs)
            if case .failedBeforeSend(let reason) = result {
                return .failedBeforeSend("图片已确认；文字待重试：\(reason)")
            }
            if case .wordingRejected = result {
                return .uncertain("图片已确认；拼多多拒绝文字用语，需检查草稿")
            }
            return result
        } catch {
            AutomationStepLog.record(root: logRoot, uid: uid, step: "reply-image-error", detail: error.localizedDescription)
            return anySubmitted ? .uncertain("图片提交后中断，不自动重发：\(error.localizedDescription)")
                : .failedBeforeSend(error.localizedDescription)
        }
    }

    private func dismissIdleImageConfirmation(uid: String, lease: UIOperationLease?) {
        do {
            try lease?.validate()
            let tree = try backend.readSemanticTree()
            guard matches(uid: uid, tree: tree),
                  let cancel = PDDOutgoingImageControls.previewCancelControl(in: tree.nodes) else { return }
            AutomationStepLog.record(root: logRoot, uid: uid, step: "reply-image-preview-dismissed",
                detail: "Unconfirmed idle preview cancelled; other conversations can continue")
            if cancel.allowsAXPress { try backend.performPress(cancel.id) }
            else { try imagePreviewClicker.click(at: cancel.point) }
        } catch {
            AutomationStepLog.record(root: logRoot, uid: uid, step: "reply-image-preview-cleanup-failed",
                detail: error.localizedDescription)
        }
    }

    func send(
        uid: String,
        text: String,
        expectedCustomerCursor: AutoReplyCursor
    ) async throws -> AutoReplyDeliveryResult {
        try await send(
            uid: uid,
            text: text,
            expectedCustomerCursor: expectedCustomerCursor,
            expectedCustomerMessageIDs: []
        )
    }

    func send(uid: String, text: String, expectedCustomerCursor: AutoReplyCursor,
              expectedCustomerMessageIDs: Set<String>) async throws -> AutoReplyDeliveryResult {
        try await send(uid: uid, text: text, expectedCustomerCursor: expectedCustomerCursor,
            expectedCustomerMessageIDs: expectedCustomerMessageIDs, deliveryID: nil)
    }

    func send(
        uid: String,
        text: String,
        expectedCustomerCursor: AutoReplyCursor,
        expectedCustomerMessageIDs: Set<String>,
        deliveryID: UUID? = nil
    ) async throws -> AutoReplyDeliveryResult {
        AutomationStepLog.record(root: logRoot, uid: uid, step: "reply-send-started")
        do {
            let result = try await sendReply(uid: uid, text: text,
                expectedCustomerCursor: expectedCustomerCursor,
                expectedCustomerMessageIDs: expectedCustomerMessageIDs, deliveryID: deliveryID)
            AutomationStepLog.record(root: logRoot, uid: uid, step: "reply-send-result",
                detail: String(describing: result))
            return result
        } catch {
            AutomationStepLog.record(root: logRoot, uid: uid, step: "reply-send-error", detail: error.localizedDescription)
            throw error
        }
    }

    private func sendReply(uid: String, text reply: String, expectedCustomerCursor: AutoReplyCursor,
                           expectedCustomerMessageIDs: Set<String>, deliveryID: UUID?) async throws -> AutoReplyDeliveryResult {
        guard !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failedBeforeSend("回复为空")
        }
        let attempts = logRoot.map { PDDTextDeliveryAttemptStore(root: $0) }
        if let deliveryID, let attempts, let previous = try attempts.load(deliveryID) {
            if previous.mayHaveSent {
                return try await reconcileTextDelivery(uid: uid, text: reply, deliveryID: deliveryID,
                    expectedCustomerMessageIDs: expectedCustomerMessageIDs)
            }
            if previous.stage == .wordingRejected, previous.uid == uid,
               previous.replySHA256 == PDDTextDeliveryAttempt.hash(reply) {
                return .wordingRejected
            }
        }
        let handoffKey = expectedCustomerMessageIDs.first {
            $0.hasPrefix(FrozenCustomerBatch.incomingHandoffPrefix)
        }.map { String($0.dropFirst(FrozenCustomerBatch.incomingHandoffPrefix.count)) }
        let realMessageIDs = expectedCustomerMessageIDs.filter {
            !$0.hasPrefix(FrozenCustomerBatch.incomingHandoffPrefix)
        }

        let initialTree: PDDAXSemanticTree
        do {
            initialTree = try await opener.openAndResolve(
                uid: uid,
                expectedCustomerMessageIDs: realMessageIDs
            )
        } catch let error as PDDAXConversationDriverError {
            return .failedBeforeSend(error.localizedDescription)
        } catch {
            return .failedBeforeSend(error.localizedDescription)
        }
        guard matches(uid: uid, tree: initialTree, expectedIDs: realMessageIDs) else {
            return .failedBeforeSend("写入前 UID 不匹配")
        }
        if let handoffKey,
           PDDAXIncomingTransfer.unansweredHandoff(in: initialTree.rootSnapshot)?.boundaryKey != handoffKey {
            return .discardedBeforeSend("转入会话已回复或转接边界已变化")
        }
        AutomationStepLog.record(root: logRoot, uid: uid, step: "reply-target-verified",
            detail: "route=\(opener.recipientVerificationReason(uid: uid, expectedCustomerMessageIDs: realMessageIDs, in: initialTree) ?? "unknown") ocr_required=false")
        do { try observeSnapshot?(uid, initialTree.rootSnapshot) }
        catch { return .failedBeforeSend("保存客户消息失败：\(error.localizedDescription)") }

        let initialComposer: AXElementToken
        do { initialComposer = try PDDAXControlSelection.composer(in: initialTree.nodes) }
        catch { return .failedBeforeSend(error.localizedDescription) }
        let existingDraft: String
        do { existingDraft = try backend.value(of: initialComposer) }
        catch { return .failedBeforeSend(error.localizedDescription) }
        if existingDraft != reply {
            do {
                AutomationStepLog.record(root: logRoot, uid: uid, step: "reply-composer-write-started")
                try backend.setValue(reply, on: initialComposer)
                guard await waitForComposerValue(reply, on: initialComposer) else {
                    return .failedBeforeSend("输入区 AX 回读与回复不一致")
                }
            } catch {
                return .failedBeforeSend(error.localizedDescription)
            }
        }

        let afterWrite: PDDAXSemanticTree
        do { afterWrite = try backend.readSemanticTree() }
        catch { return .failedBeforeSend(error.localizedDescription) }
        guard matches(uid: uid, tree: afterWrite, expectedIDs: realMessageIDs) else {
            return .failedBeforeSend("写入后 UID 变化")
        }
        do {
            let freshComposer = try PDDAXControlSelection.composer(in: afterWrite.nodes)
            guard await waitForComposerValue(reply, on: freshComposer) else {
                return .failedBeforeSend("写入后输入区回读不一致")
            }
        } catch {
            return .failedBeforeSend(error.localizedDescription)
        }

        let beforePress: PDDAXSemanticTree
        do { beforePress = try backend.readSemanticTree() }
        catch { return .failedBeforeSend(error.localizedDescription) }
        guard matches(uid: uid, tree: beforePress, expectedIDs: realMessageIDs) else {
            return .failedBeforeSend("发送前 UID 变化")
        }
        if let handoffKey,
           PDDAXIncomingTransfer.unansweredHandoff(in: beforePress.rootSnapshot)?.boundaryKey != handoffKey {
            return .discardedBeforeSend("转入会话已回复或转接边界已变化")
        }
        AutomationStepLog.record(root: logRoot, uid: uid, step: "reply-composer-verified")
        do { try observeSnapshot?(uid, beforePress.rootSnapshot) }
        catch { return .failedBeforeSend("保存客户消息失败：\(error.localizedDescription)") }
        let initialWarnings = wordingWarnings(in: initialTree.rootSnapshot)
        let beforePressWarnings = wordingWarnings(in: beforePress.rootSnapshot)
        if !beforePressWarnings.subtracting(initialWarnings).isEmpty { return .wordingRejected }
        let sendControl: AXElementToken
        do { sendControl = try PDDAXControlSelection.sendControl(in: beforePress.nodes) }
        catch { return .failedBeforeSend(error.localizedDescription) }

        try Task.checkCancellation()
        try PDDUIOperationContext.lease?.validate()
        let baselineServiceIDs = Set([initialTree, afterWrite, beforePress].flatMap { tree in
            PDDChatParser.parse(root: tree.rootSnapshot).messages.filter { $0.sender == .service }.map(\.id)
        })
        if let deliveryID, let attempts {
            var attempt = PDDTextDeliveryAttempt(uid: uid, replySHA256: PDDTextDeliveryAttempt.hash(reply),
                stage: .composerVerified, baselineServiceIDs: baselineServiceIDs, updatedAt: Date())
            try attempts.save(attempt, id: deliveryID)
            // Persist BEFORE the action. Anything after this point is observe-only on retry.
            attempt.stage = .commitIntent
            try attempts.save(attempt, id: deliveryID)
        }
        AutomationStepLog.record(root: logRoot, uid: uid, step: "reply-send-click-started")
        do { try backend.performPress(sendControl) }
        catch { return .uncertain("已执行发送动作，但按钮状态无法确认：\(error.localizedDescription)") }

        let started = Date()
        repeat {
            do {
                let confirmation = try backend.readSemanticTree()
                if matches(uid: uid, tree: confirmation, expectedIDs: realMessageIDs) {
                    do { try observeSnapshot?(uid, confirmation.rootSnapshot) }
                    catch { return .uncertain("已发送，但保存最新客户消息失败：\(error.localizedDescription)") }
                }
                let candidates = PDDChatParser.parse(root: confirmation.rootSnapshot).messages.filter {
                    matchesServiceReply($0, text: reply, excluding: baselineServiceIDs)
                }
                if matches(uid: uid, tree: confirmation, expectedIDs: realMessageIDs),
                   candidates.count == 1, let posted = candidates.first {
                    if let deliveryID, let attempts, var attempt = try attempts.load(deliveryID) {
                        attempt.stage = .confirmed; attempt.confirmedMessageID = posted.id; attempt.updatedAt = Date()
                        try attempts.save(attempt, id: deliveryID)
                    }
                    return .sent(serviceMessageID: posted.id)
                }
                if candidates.isEmpty,
                   matches(uid: uid, tree: confirmation, expectedIDs: realMessageIDs),
                   !wordingWarnings(in: confirmation.rootSnapshot).subtracting(beforePressWarnings).isEmpty,
                   let composer = try? PDDAXControlSelection.composer(in: confirmation.nodes),
                   (try? backend.value(of: composer)) == reply {
                    if let deliveryID, let attempts, var attempt = try attempts.load(deliveryID) {
                        attempt.stage = .wordingRejected
                        attempt.updatedAt = Date()
                        try attempts.save(attempt, id: deliveryID)
                    }
                    return .wordingRejected
                }
            } catch {
                // The send click already happened. Continue bounded read-only observation.
            }
            if Date().timeIntervalSince(started) >= confirmationTimeout { break }
            if pollIntervalNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
            } else {
                await Task.yield()
            }
        } while true
        return .uncertain("发送后尚未观察到可唯一绑定的新客服消息，发送结果待后续会话核对")
    }

    func reconcileTextDelivery(uid: String, text: String, deliveryID: UUID,
                               expectedCustomerMessageIDs: Set<String>) async throws -> AutoReplyDeliveryResult {
        guard let logRoot else { return .uncertain("缺少发送凭据目录；不自动重发") }
        let attempts = PDDTextDeliveryAttemptStore(root: logRoot)
        guard var attempt = try attempts.load(deliveryID),
              attempt.uid == uid, attempt.replySHA256 == PDDTextDeliveryAttempt.hash(text) else {
            return .uncertain("缺少匹配的发送凭据；不自动重发")
        }
        if attempt.stage == .confirmed, let id = attempt.confirmedMessageID { return .sent(serviceMessageID: id) }
        guard attempt.mayHaveSent else { return .failedBeforeSend("发送动作尚未执行") }
        // A proven alias changes which evidence we observe. Reconciliation
        // must not change the selected conversation or the send binding.
        let canonicalUID = try PDDConversationIdentityStore(root: logRoot).canonicalUID(uid)
        let realIDs = expectedCustomerMessageIDs.filter { !$0.hasPrefix(FrozenCustomerBatch.incomingHandoffPrefix) }
        try Task.checkCancellation()
        try PDDUIOperationContext.lease?.validate()
        if let history = try? PerUserChatStore(rootDirectory: logRoot).loadAXFirst(uid: canonicalUID),
           let target = history.lastIndex(where: { $0.sender == .customer && realIDs.contains($0.id) }) {
            // Previously verified AX observations can outlive the rendered
            // pane. Require exact target, text, and a platform message time
            // inside the commit window before relying on that history.
            let candidates = history.dropFirst(target + 1).filter { message in
                matchesServiceReply(message, text: text, excluding: attempt.baselineServiceIDs)
                    && isInCommitWindow(message.id, attempt: attempt) == true
            }
            if candidates.count > 1 { return .uncertain("历史中有多条匹配回复；待核对，不自动重发") }
            if let posted = candidates.first {
                guard try !attempts.isConfirmedByAnotherAttempt(posted.id, excluding: deliveryID) else {
                    return .uncertain("匹配回复已用于另一条发送凭据；不自动重发")
                }
                attempt.stage = .confirmed; attempt.confirmedMessageID = posted.id; attempt.updatedAt = Date()
                try attempts.save(attempt, id: deliveryID)
                AutomationStepLog.record(root: logRoot, uid: canonicalUID, step: "reply-delivery-verified-from-ax-history",
                    detail: "job=\(deliveryID); exact target and reply inside commit window")
                return .sent(serviceMessageID: posted.id)
            }
        }
        let tree = try backend.readSemanticTreeForObservation()
        guard matches(uid: canonicalUID, tree: tree, expectedIDs: realIDs) else {
            return .uncertain("等待打开对应客户会话后核对，不主动切换会话")
        }
        try observeSnapshot?(canonicalUID, tree.rootSnapshot)
        let messages = PDDChatParser.parse(root: tree.rootSnapshot).messages
        let lastTarget = messages.lastIndex { realIDs.contains($0.id) && $0.sender == .customer }
        let handoff = expectedCustomerMessageIDs.first { $0.hasPrefix(FrozenCustomerBatch.incomingHandoffPrefix) }
            .map { String($0.dropFirst(FrozenCustomerBatch.incomingHandoffPrefix.count)) }
        let record = PDDAXIncomingTransfer.incomingRecord(in: tree.rootSnapshot)
        let eligibleServiceIDs: Set<String>
        if let lastTarget {
            eligibleServiceIDs = Set(messages.dropFirst(lastTarget + 1).filter { $0.sender == .service }.map(\.id))
        } else if let handoff, record?.handoff.boundaryKey == handoff {
            eligibleServiceIDs = record?.serviceReplyIDs ?? []
        } else {
            return .uncertain("目标消息尚未出现在核对视图；不根据旧同文回复推断送达")
        }
        let candidates = messages.filter {
            $0.id.hasPrefix("middlePanel_list_") && eligibleServiceIDs.contains($0.id)
                && matchesServiceReply($0, text: text, excluding: attempt.baselineServiceIDs)
                && isInCommitWindow($0.id, attempt: attempt) != false
        }
        if candidates.count == 1, let posted = candidates.first,
           try !attempts.isConfirmedByAnotherAttempt(posted.id, excluding: deliveryID) {
            attempt.stage = .confirmed; attempt.confirmedMessageID = posted.id; attempt.updatedAt = Date()
            try attempts.save(attempt, id: deliveryID)
            return .sent(serviceMessageID: posted.id)
        }
        return .uncertain("尚未找到本次回复的发送证据；保留核对，不自动重发")
    }

    private func matchesServiceReply(_ message: PDDChatMessage, text: String, excluding baseline: Set<String>) -> Bool {
        message.sender == .service && [.text, .link].contains(message.kind) && !baseline.contains(message.id)
            && PDDOCRNormalizer.normalize(message.content) == PDDOCRNormalizer.normalize(text)
    }

    private func wordingWarnings(in root: AXNodeSnapshot) -> Set<String> {
        var stack = [root]
        var warnings = Set<String>()
        while let node = stack.popLast() {
            // Never use a chat message, draft value, or highlighted text alone
            // as evidence that the platform rejected a send.
            guard !node.domClasses.contains("onemsg") else { continue }
            if node.role == "AXAlert" || !node.domClasses.isDisjoint(with: ["el-message", "send-warning", "wording-warning"]) {
                var notification = [node]
                var text: [String] = []
                while let item = notification.popLast() {
                    text.append(contentsOf: ["AXValue", "AXTitle", "AXDescription"].compactMap(item.attribute(named:)))
                    notification.append(contentsOf: item.children.reversed())
                }
                let normalized = PDDOCRNormalizer.normalize(text.joined(separator: " "))
                if ["敏感词", "违禁词", "违规词"].contains(where: normalized.contains),
                   ["无法发送", "不能发送", "禁止发送", "不允许发送", "发送失败", "请修改后发送"].contains(where: normalized.contains) {
                    warnings.insert(normalized)
                }
                continue
            }
            stack.append(contentsOf: node.children)
        }
        return warnings
    }

    private func isInCommitWindow(_ id: String, attempt: PDDTextDeliveryAttempt) -> Bool? {
        let prefix = "middlePanel_list_"
        guard id.hasPrefix(prefix) else { return nil }
        let suffix = id.dropFirst(prefix.count)
        guard suffix.count == 13, let millis = Int64(suffix) else { return nil }
        let delta = Double(millis) / 1_000 - attempt.updatedAt.timeIntervalSince1970
        return (0...max(3, confirmationTimeout + 2)).contains(delta)
    }

    private func waitForComposerValue(_ expected: String, on composer: AXElementToken) async -> Bool {
        let started = Date()
        repeat {
            if (try? backend.value(of: composer)) == expected { return true }
            if Date().timeIntervalSince(started) >= writeVerificationTimeout { return false }
            if pollIntervalNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
            } else {
                await Task.yield()
            }
        } while true
    }

    private func matches(uid: String, tree: PDDAXSemanticTree, expectedIDs: Set<String> = []) -> Bool {
        opener.recipientVerificationReason(uid: uid, expectedCustomerMessageIDs: expectedIDs, in: tree) != nil
    }

    private func stableSendID(uid: String, reply: String, cursor: AutoReplyCursor, handoffKey: String?) -> String {
        let material = [uid, cursor.digest, handoffKey ?? "", PDDOCRNormalizer.normalize(reply)]
            .joined(separator: "\u{1f}")
        let digest = SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "ax-send-\(digest)"
    }
}
