import SwiftUI
import UIKit
@testable import HermesMobile

enum HostedLayoutResult: Equatable {
    case hosted
    case unavailable(String)
}

@MainActor
enum ChatTranscriptHostingSupport {
    static let bottomAnchorID = "chat-bottom-anchor"

    static func transcriptView(
        from viewModel: ChatViewModel,
        followScroll: Bool = true,
        onLoadOlderMessages: (() async -> Bool)? = nil
    ) -> ChatTranscriptView {
        ChatTranscriptView(
            isLoading: viewModel.isLoading,
            errorMessage: viewModel.errorMessage,
            messages: viewModel.messages,
            displayedTranscriptMessages: viewModel.displayedTranscriptMessages,
            compressionReferenceCard: viewModel.compressionReferenceCard,
            reasoningGroups: viewModel.displayedReasoningGroups,
            completedToolCallGroupsForAnchor: { anchorMessageID in
                viewModel.completedToolCallGroupsForAnchor(anchorMessageID)
            },
            liveReasoningText: viewModel.liveReasoningText,
            reasoningAnchorMessageID: viewModel.reasoningAnchorMessageID,
            liveToolCalls: viewModel.liveToolCalls,
            toolCallAnchorMessageID: viewModel.toolCallAnchorMessageID,
            streamingAssistantMessageID: viewModel.streamingAssistantMessageID,
            liveTokensPerSecond: viewModel.liveTokensPerSecond,
            activeStreamRecoveryState: viewModel.activeStreamRecoveryState,
            clarificationPrompt: viewModel.clarificationPrompt,
            isRespondingToClarification: viewModel.isRespondingToClarification,
            clarificationErrorMessage: viewModel.clarificationErrorMessage,
            hidesRunStatusAccessibility: false,
            showsThinkingAndToolCards: true,
            showsAssistantTypingIndicator: ChatTranscriptDisplaySettings.shouldShowAssistantTypingIndicator(
                hasActiveStream: viewModel.activeStreamID != nil,
                isCancellingStream: viewModel.isCancellingStream,
                hasStreamingAssistantMessage: viewModel.hasStreamingAssistantMessageContent,
                hasPendingClarificationPrompt: viewModel.clarificationPrompt != nil,
                liveReasoningText: viewModel.liveReasoningText,
                hasLiveToolCalls: !viewModel.liveToolCalls.isEmpty,
                showsThinkingAndToolCards: true
            ),
            showsScrollToBottomButton: false,
            shouldFollowLatestMessage: followScroll,
            latestTranscriptMessageRole: viewModel.displayedTranscriptMessages.last?.message.role,
            isScrolledNearBottom: true,
            activeStreamID: viewModel.activeStreamID,
            streamingScrollTrigger: viewModel.streamingScrollTrigger,
            cacheFirstReconcileScrollToken: viewModel.cacheFirstReconcileScrollToken,
            bottomAnchorID: bottomAnchorID,
            transcriptMessageSpacing: 10,
            transcriptBlockSpacing: 6,
            transcriptBottomInsetHeight: 96,
            scrollToBottomButtonBottomPadding: 12,
            localAttachmentPreviews: viewModel.localAttachmentPreviews,
            listeningMessageID: viewModel.listeningMessageID,
            isViewingCachedData: viewModel.isViewingCachedData,
            hasOlderMessages: viewModel.hasOlderMessages,
            isLoadingOlderMessages: viewModel.isLoadingOlderMessages,
            isRegeneratingMessage: viewModel.isRegeneratingMessage,
            isEditingMessage: viewModel.isEditingMessage,
            isForkingMessage: viewModel.isForkingMessage,
            loadAttachmentImage: { _ in nil },
            loadAttachmentData: { _ in nil },
            loadTranscriptMediaImage: { _ in nil },
            loadTranscriptMediaData: { _ in nil },
            transcriptMediaCacheNamespace: "https://example.test|performance-session",
            actionContext: { _, _ in nil },
            shouldRenderMessageRow: { message in
                if message.content?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                    return true
                }
                return message.role == "user" && message.attachments?.isEmpty == false
            },
            onLoadMessages: {},
            onLoadOlderMessages: onLoadOlderMessages ?? { false },
            onUpdateScrollMetrics: { _ in },
            onDismissKeyboard: {},
            onScrollToBottom: { proxy in
                scrollWithoutAnimation(proxy, id: bottomAnchorID)
            },
            onScrollToLatestTranscriptMessage: { proxy in
                if let id = viewModel.displayedTranscriptMessages.last?.id {
                    scrollWithoutAnimation(proxy, id: id)
                } else {
                    scrollWithoutAnimation(proxy, id: bottomAnchorID)
                }
            },
            onScrollToLatestContent: { proxy, _ in
                scrollWithoutAnimation(proxy, id: bottomAnchorID)
            },
            onPreviewAttachment: { _, _ in },
            onPreviewTranscriptMedia: { _ in },
            onToggleListening: { _ in },
            onSubmitClarification: { _ in },
            onSelectText: { _ in },
            onRegenerate: { _ in },
            onEdit: { _ in },
            onFork: { _ in },
            onCopy: { _ in }
        )
    }

    static func host(
        _ view: ChatTranscriptView,
        animationsEnabled: Bool = false
    ) -> (UIWindow, UIHostingController<ChatTranscriptView>) {
        if !animationsEnabled {
            UIView.setAnimationsEnabled(false)
        }
        let host = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window.windowScene = scene
        }
        host.view.frame = window.bounds
        window.rootViewController = host
        if animationsEnabled {
            window.makeKeyAndVisible()
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                window.makeKeyAndVisible()
            }
        }
        return (window, host)
    }

    static func applySnapshot(
        _ view: ChatTranscriptView,
        to host: UIHostingController<ChatTranscriptView>,
        animationsEnabled: Bool = false
    ) {
        if animationsEnabled {
            host.rootView = view
            return
        }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            host.rootView = view
        }
    }

    /// Returns `.hosted` after a successful layout, or `.unavailable(reason)` on timeout / empty bounds / layout-loop cap.
    static func layoutPass(
        window: UIWindow,
        host: UIHostingController<ChatTranscriptView>,
        timeout: TimeInterval
    ) -> HostedLayoutResult {
        if timeout <= 0 {
            return .unavailable("timeout")
        }

        let deadline = Date().addingTimeInterval(timeout)
        var iterations = 0

        while Date() < deadline {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            window.setNeedsLayout()
            window.layoutIfNeeded()
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))

            iterations += 1
            if iterations > 10_000 {
                return .unavailable("layout-loop")
            }

            let hasBounds = host.view.bounds.width > 0 && host.view.bounds.height > 0
            if host.view.window != nil, hasBounds {
                return .hosted
            }
        }

        if host.view.window == nil {
            return .unavailable("hosting-exception")
        }
        if host.view.bounds.width <= 0 || host.view.bounds.height <= 0 {
            return .unavailable("empty-bounds")
        }
        return .hosted
    }

    static func scrollView(in root: UIView) -> UIScrollView? {
        if let scrollView = root as? UIScrollView {
            return scrollView
        }
        for subview in root.subviews {
            if let found = scrollView(in: subview) {
                return found
            }
        }
        return nil
    }

    static func view(withIdentifier identifier: String, in root: UIView) -> UIView? {
        if root.accessibilityIdentifier == identifier {
            return root
        }
        if let elements = root.accessibilityElements {
            for element in elements {
                if let view = element as? UIView,
                   let found = self.view(withIdentifier: identifier, in: view) {
                    return found
                }
            }
        }
        for subview in root.subviews {
            if let found = view(withIdentifier: identifier, in: subview) {
                return found
            }
        }
        return nil
    }

    static func firstControl(matchingLabel label: String, in root: UIView) -> UIControl? {
        if let button = root as? UIButton,
           button.accessibilityLabel == label
            || button.title(for: .normal) == label
            || button.accessibilityHint == label {
            return button
        }
        if let control = root as? UIControl,
           control.accessibilityLabel == label || control.accessibilityHint == label {
            return control
        }
        for subview in root.subviews {
            if let found = firstControl(matchingLabel: label, in: subview) {
                return found
            }
        }
        return nil
    }

    static func firstView(matchingLabel label: String, in root: UIView) -> UIView? {
        if root.accessibilityLabel == label || root.accessibilityHint == label {
            return root
        }
        for subview in root.subviews {
            if let found = firstView(matchingLabel: label, in: subview) {
                return found
            }
        }
        return nil
    }

    @discardableResult
    static func activateIdentifier(_ identifier: String, in root: UIView) -> Bool {
        guard let probe = view(withIdentifier: identifier, in: root) as? TranscriptIdentifierProbeView,
              let onActivate = probe.onActivate
        else { return false }
        onActivate()
        return true
    }

    static func identifierIsExpanded(_ identifier: String, in root: UIView) -> Bool? {
        (view(withIdentifier: identifier, in: root) as? TranscriptIdentifierProbeView)?.isExpanded
    }

    @discardableResult
    static func activateControl(matchingLabel label: String, in root: UIView) -> Bool {
        if let control = firstControl(matchingLabel: label, in: root) {
            control.sendActions(for: .touchUpInside)
            return true
        }
        if let view = firstView(matchingLabel: label, in: root) {
            return view.accessibilityActivate()
        }
        return false
    }

    static func rowMinY(renderID: String, in root: UIView) -> CGFloat? {
        guard let scrollView = scrollView(in: root),
              let row = view(
                withIdentifier: ChatPrependScrollPositionController.accessibilityIdentifier(
                    forRenderID: renderID
                ),
                in: root
              )
        else { return nil }
        return row.convert(row.bounds, to: scrollView).minY
    }

    static func rowScreenY(renderID: String, in root: UIView) -> CGFloat? {
        guard let row = view(
            withIdentifier: ChatPrependScrollPositionController.accessibilityIdentifier(
                forRenderID: renderID
            ),
            in: root
        ) else { return nil }
        return row.convert(row.bounds.origin, to: nil).y
    }

    /// Render IDs currently in the UIKit tree, topmost first.
    static func realizedRowRenderIDs(in root: UIView) -> [String] {
        guard let scrollView = scrollView(in: root) else { return [] }
        var rows: [(id: String, minY: CGFloat)] = []
        collectRowIdentifiers(in: root, scrollView: scrollView, into: &rows)
        return rows.sorted { $0.minY < $1.minY }.map(\.id)
    }

    static func prependController(in root: UIView) -> ChatPrependScrollPositionController? {
        if let observer = root as? ChatScrollObserver.ObserverView {
            return observer.coordinator?.prependScrollPositionController
        }
        for subview in root.subviews {
            if let found = prependController(in: subview) {
                return found
            }
        }
        return nil
    }

    /// Layout ticks at the current offset until `identifier` exists. Does not jump
    /// `contentOffset`; LazyVStack would otherwise drop the currently realized rows.
    @discardableResult
    static func realizeIdentifier(
        _ identifier: String,
        in root: UIView,
        window: UIWindow,
        host: UIHostingController<ChatTranscriptView>
    ) -> UIView? {
        realize(in: root, window: window, host: host) {
            view(withIdentifier: identifier, in: root)
        }
    }

    @discardableResult
    static func realizeView(
        matchingLabel label: String,
        in root: UIView,
        window: UIWindow,
        host: UIHostingController<ChatTranscriptView>
    ) -> UIView? {
        realize(in: root, window: window, host: host) {
            firstView(matchingLabel: label, in: root) ?? firstControl(matchingLabel: label, in: root)
        }
    }

    private static func realize(
        in root: UIView,
        window: UIWindow,
        host: UIHostingController<ChatTranscriptView>,
        find: () -> UIView?
    ) -> UIView? {
        if let existing = find() {
            return existing
        }
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            window.setNeedsLayout()
            window.layoutIfNeeded()
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
            if let found = find() {
                return found
            }
        }
        return find()
    }

    private static func collectRowIdentifiers(
        in root: UIView,
        scrollView: UIScrollView,
        into rows: inout [(id: String, minY: CGFloat)]
    ) {
        if let identifier = root.accessibilityIdentifier {
            let prefix = ChatPrependScrollPositionController.rowAccessibilityPrefix
            if identifier.hasPrefix(prefix) {
                let renderID = String(identifier.dropFirst(prefix.count))
                if !renderID.isEmpty {
                    rows.append((renderID, root.convert(root.bounds, to: scrollView).minY))
                }
            }
        }
        if let elements = root.accessibilityElements {
            for element in elements {
                if let view = element as? UIView {
                    collectRowIdentifiers(in: view, scrollView: scrollView, into: &rows)
                }
            }
        }
        for subview in root.subviews {
            collectRowIdentifiers(in: subview, scrollView: scrollView, into: &rows)
        }
    }

    private static func scrollWithoutAnimation(_ proxy: ScrollViewProxy, id: String) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            proxy.scrollTo(id, anchor: .bottom)
        }
    }
}
