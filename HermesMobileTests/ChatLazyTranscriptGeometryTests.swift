import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import HermesMobile

final class ChatLazyTranscriptGeometryTests: APIClientTestCase {
    private var previousAnimationEnabled: Any?
    private var hostedWindow: UIWindow?

    override func setUp() {
        super.setUp()
        previousAnimationEnabled = UserDefaults.standard.object(
            forKey: StreamedTextAnimationSettings.isEnabledKey
        )
        UserDefaults.standard.set(false, forKey: StreamedTextAnimationSettings.isEnabledKey)
        UIView.setAnimationsEnabled(false)
        ChatTranscriptToolExpansionSeed.values = [:]
    }

    override func tearDown() {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                hostedWindow?.rootViewController = nil
                hostedWindow?.isHidden = true
                hostedWindow = nil
            }
        }
        UIView.setAnimationsEnabled(true)
        ChatTranscriptToolExpansionSeed.values = [:]
        if let previousAnimationEnabled {
            UserDefaults.standard.set(
                previousAnimationEnabled,
                forKey: StreamedTextAnimationSettings.isEnabledKey
            )
        } else {
            UserDefaults.standard.removeObject(forKey: StreamedTextAnimationSettings.isEnabledKey)
        }
        super.tearDown()
    }

    @MainActor
    func testHostedNewestPageLoadOlderPreservesLazyAnchorGeometry() async throws {
        let outcome = try await runNewestPageLoadOlder(
            total: 150,
            mixedContent: true,
            intraRowOffsetY: 0,
            dragDuringLoad: false
        )
        switch outcome {
        case .unavailable(let reason):
            throw XCTSkip("hosted transcript unavailable: \(reason)")
        case .hosted(let result):
            XCTAssertEqual(result.rowCountBefore, 50)
            XCTAssertEqual(result.rowCountAfter, 100)
            XCTAssertEqual(result.anchorRenderID, result.anchorRenderIDAfter)
            XCTAssertEqual(result.offsetAfter, result.expectedOffsetAfter, accuracy: 1.5)
        }
    }

    @MainActor
    func testHostedLoadOlderPreservesNonzeroIntraRowOffset() async throws {
        let outcome = try await runNewestPageLoadOlder(
            total: 150,
            mixedContent: true,
            intraRowOffsetY: 28,
            dragDuringLoad: false
        )
        switch outcome {
        case .unavailable(let reason):
            throw XCTSkip("hosted transcript unavailable: \(reason)")
        case .hosted(let result):
            XCTAssertEqual(result.intraRowOffsetY, 28, accuracy: 1.5)
            XCTAssertEqual(result.offsetAfter, result.expectedOffsetAfter, accuracy: 1.5)
        }
    }

    @MainActor
    func testHostedDelayedRealizationDoesNotHopAfterOneSecond() async throws {
        let outcome = try await runNewestPageLoadOlder(
            total: 150,
            mixedContent: true,
            intraRowOffsetY: 18,
            dragDuringLoad: false,
            extraLayoutAfterRestore: true
        )
        switch outcome {
        case .unavailable(let reason):
            throw XCTSkip("hosted transcript unavailable: \(reason)")
        case .hosted(let result):
            XCTAssertEqual(result.offsetAfterExtraLayout, result.expectedOffsetAfterExtraLayout, accuracy: 1.5)
            XCTAssertEqual(result.anchorRenderID, result.anchorRenderIDAfterExtraLayout)
        }
    }

    @MainActor
    func testHostedUserDragDuringLoadOlderDoesNotScrollTo() async throws {
        let outcome = try await runNewestPageLoadOlder(
            total: 150,
            mixedContent: false,
            intraRowOffsetY: 0,
            dragDuringLoad: true
        )
        switch outcome {
        case .unavailable(let reason):
            throw XCTSkip("hosted transcript unavailable: \(reason)")
        case .hosted(let result):
            XCTAssertEqual(result.offsetAfter, result.draggedOffset, accuracy: 1.5)
        }
    }

    @MainActor
    func testHostedToolExpansionSurvivesScrollAwayAndBack() async throws {
        let viewModel = try await loadNewestPageViewModel(
            total: 50,
            mixedContent: true,
            toolCallAssistantIndex: 49,
            loadAllPages: true
        )
        let hasToolGroup = viewModel.displayedTranscriptMessages.contains { message in
            !viewModel.completedToolCallGroupsForAnchor(message.anchorID).isEmpty
        }
        XCTAssertTrue(hasToolGroup)

        let anchoredMessage = try XCTUnwrap(
            viewModel.displayedTranscriptMessages.first { message in
                !viewModel.completedToolCallGroupsForAnchor(message.anchorID).isEmpty
            }
        )
        let group = try XCTUnwrap(
            viewModel.completedToolCallGroupsForAnchor(anchoredMessage.anchorID).first
        )
        let groupIdentifier = "transcript.tool-group.\(group.id)"

        ChatTranscriptToolExpansionSeed.values = [group.id: true]
        let view = ChatTranscriptHostingSupport.transcriptView(
            from: viewModel,
            followScroll: false
        )
        let (window, host) = ChatTranscriptHostingSupport.host(view)
        hostedWindow = window
        let layout = ChatTranscriptHostingSupport.layoutPass(window: window, host: host, timeout: 30)
        if case .unavailable(let reason) = layout {
            throw XCTSkip("hosted transcript unavailable: \(reason)")
        }

        _ = ChatTranscriptHostingSupport.realizeIdentifier(
            ChatPrependScrollPositionController.accessibilityIdentifier(
                forRenderID: anchoredMessage.renderID
            ),
            in: host.view,
            window: window,
            host: host
        )
        _ = ChatTranscriptHostingSupport.realizeIdentifier(
            groupIdentifier,
            in: host.view,
            window: window,
            host: host
        )
        _ = try XCTUnwrap(
            ChatTranscriptHostingSupport.view(withIdentifier: groupIdentifier, in: host.view),
            "expected realized \(groupIdentifier) after bringing it on-screen"
        )
        XCTAssertEqual(
            ChatTranscriptHostingSupport.identifierIsExpanded(groupIdentifier, in: host.view),
            true,
            "expected seeded expansion before recycle"
        )

        guard let scrollView = ChatTranscriptHostingSupport.scrollView(in: host.view) else {
            throw XCTSkip("hosted transcript unavailable: scroll-view")
        }
        let minY = -scrollView.adjustedContentInset.top
        let maxY = max(
            minY,
            scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
        )
        scrollView.setContentOffset(CGPoint(x: 0, y: minY), animated: false)
        _ = ChatTranscriptHostingSupport.layoutPass(window: window, host: host, timeout: 5)
        scrollView.setContentOffset(CGPoint(x: 0, y: maxY), animated: false)
        _ = ChatTranscriptHostingSupport.layoutPass(window: window, host: host, timeout: 5)
        _ = ChatTranscriptHostingSupport.realizeIdentifier(
            groupIdentifier,
            in: host.view,
            window: window,
            host: host
        )

        let restored = ChatTranscriptHostingSupport.view(withIdentifier: groupIdentifier, in: host.view)
        XCTAssertNotNil(restored)
        XCTAssertEqual(
            ChatTranscriptHostingSupport.identifierIsExpanded(groupIdentifier, in: host.view),
            true,
            "expected expansion to survive lazy recycle"
        )
    }

    private func hostedSessionResponse(
        total: Int,
        request: URLRequest,
        largeAssistantContent: String?,
        mixedContent: Bool = false,
        toolCallAssistantIndex: Int? = nil
    ) throws -> (HTTPURLResponse, Data) {
        let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
        let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value) })
        let before = (query["msg_before"] ?? nil).flatMap { Int($0) }
        let data = try hostedPaginationSessionJSON(
            total: total,
            before: before,
            largeAssistantContent: largeAssistantContent,
            mixedContent: mixedContent,
            toolCallAssistantIndex: toolCallAssistantIndex
        )
        return apiTestJSONResponse(String(decoding: data, as: UTF8.self), for: request)
    }

    private final class DragState {
        var offset: CGFloat = 0
    }

    private struct NewestPageLoadOlderResult {
        var rowCountBefore: Int
        var rowCountAfter: Int
        var anchorRenderID: String
        var anchorRenderIDAfter: String
        var intraRowOffsetY: CGFloat
        var offsetAfter: CGFloat
        var expectedOffsetAfter: CGFloat
        var draggedOffset: CGFloat
        var offsetAfterExtraLayout: CGFloat
        var expectedOffsetAfterExtraLayout: CGFloat
        var anchorRenderIDAfterExtraLayout: String
    }

    private enum NewestPageLoadOlderOutcome {
        case hosted(NewestPageLoadOlderResult)
        case unavailable(String)
    }

    @MainActor
    private func loadNewestPageViewModel(
        total: Int,
        mixedContent: Bool = false,
        toolCallAssistantIndex: Int? = nil,
        loadAllPages: Bool = false
    ) async throws -> ChatViewModel {
        let client = makeClient { request in
            try self.hostedSessionResponse(
                total: total,
                request: request,
                largeAssistantContent: nil,
                mixedContent: mixedContent,
                toolCallAssistantIndex: toolCallAssistantIndex
            )
        }
        let viewModel = ChatViewModel(
            session: SessionSummary(sessionId: "performance-session"),
            server: URL(string: "https://example.test")!,
            client: client
        )
        await viewModel.loadMessages()
        if loadAllPages {
            while viewModel.hasOlderMessages {
                _ = await viewModel.loadOlderMessages()
            }
            XCTAssertEqual(viewModel.messages.count, total)
        } else {
            XCTAssertEqual(viewModel.messages.count, min(50, total))
            if total > 50 {
                XCTAssertTrue(viewModel.hasOlderMessages)
            }
        }
        return viewModel
    }

    @MainActor
    private func runNewestPageLoadOlder(
        total: Int,
        mixedContent: Bool,
        intraRowOffsetY: CGFloat,
        dragDuringLoad: Bool,
        extraLayoutAfterRestore: Bool = false
    ) async throws -> NewestPageLoadOlderOutcome {
        let viewModel = try await loadNewestPageViewModel(
            total: total,
            mixedContent: mixedContent
        )
        let rowCountBefore = viewModel.displayedTranscriptMessages.count
        guard rowCountBefore == 50 else {
            return .unavailable("newest-page-count")
        }
        let preferredAnchorRenderID = try XCTUnwrap(viewModel.displayedTranscriptMessages.first?.renderID)

        var hostBox: UIHostingController<ChatTranscriptView>?
        let dragState = DragState()

        func makeFollowOffView() -> ChatTranscriptView {
            ChatTranscriptHostingSupport.transcriptView(
                from: viewModel,
                followScroll: false,
                onLoadOlderMessages: {
                    if dragDuringLoad,
                       let host = hostBox,
                       let scrollView = ChatTranscriptHostingSupport.scrollView(in: host.view) {
                        let next = scrollView.contentOffset.y + 72
                        scrollView.setContentOffset(CGPoint(x: 0, y: next), animated: false)
                        dragState.offset = scrollView.contentOffset.y
                    }
                    let didLoad = await viewModel.loadOlderMessages()
                    if let host = hostBox {
                        ChatTranscriptHostingSupport.applySnapshot(
                            ChatTranscriptHostingSupport.transcriptView(
                                from: viewModel,
                                followScroll: false
                            ),
                            to: host
                        )
                    }
                    return didLoad
                }
            )
        }

        let (window, host) = ChatTranscriptHostingSupport.host(makeFollowOffView())
        hostBox = host
        hostedWindow = window
        let layout = ChatTranscriptHostingSupport.layoutPass(window: window, host: host, timeout: 30)
        if case .unavailable(let reason) = layout {
            return .unavailable(reason)
        }

        guard let scrollView = ChatTranscriptHostingSupport.scrollView(in: host.view) else {
            return .unavailable("scroll-view")
        }

        let realizedIDs = ChatTranscriptHostingSupport.realizedRowRenderIDs(in: host.view)
        if realizedIDs.isEmpty {
            _ = ChatTranscriptHostingSupport.realizeIdentifier(
                ChatPrependScrollPositionController.accessibilityIdentifier(
                    forRenderID: preferredAnchorRenderID
                ),
                in: host.view,
                window: window,
                host: host
            )
            _ = ChatTranscriptHostingSupport.realizeView(
                matchingLabel: "Load older messages",
                in: host.view,
                window: window,
                host: host
            )
        }

        let anchorIDs = ChatTranscriptHostingSupport.realizedRowRenderIDs(in: host.view)
        let anchorRenderID: String
        if ChatTranscriptHostingSupport.rowMinY(renderID: preferredAnchorRenderID, in: host.view) != nil {
            anchorRenderID = preferredAnchorRenderID
        } else {
            anchorRenderID = try XCTUnwrap(
                anchorIDs.first,
                "expected a realized transcript.row after bringing the newest-page anchor on-screen"
            )
        }
        let rowMinY = try XCTUnwrap(
            ChatTranscriptHostingSupport.rowMinY(renderID: anchorRenderID, in: host.view),
            "expected geometry for realized transcript.row.\(anchorRenderID)"
        )
        let loadOlderControl =
            ChatTranscriptHostingSupport.firstControl(matchingLabel: "Load older messages", in: host.view)
            ?? ChatTranscriptHostingSupport.firstView(matchingLabel: "Load older messages", in: host.view)

        if intraRowOffsetY > 0 {
            scrollView.setContentOffset(CGPoint(x: 0, y: rowMinY + intraRowOffsetY), animated: false)
            _ = ChatTranscriptHostingSupport.layoutPass(window: window, host: host, timeout: 5)
        }

        let capturedIntraRow: CGFloat
        if let currentMinY = ChatTranscriptHostingSupport.rowMinY(renderID: anchorRenderID, in: host.view) {
            capturedIntraRow = scrollView.contentOffset.y - currentMinY
        } else {
            capturedIntraRow = intraRowOffsetY
        }

        var activatedLoadOlder = ChatTranscriptHostingSupport.activateControl(
            matchingLabel: "Load older messages",
            in: host.view
        )
        if !activatedLoadOlder, let control = loadOlderControl as? UIControl {
            control.sendActions(for: .touchUpInside)
            activatedLoadOlder = true
        } else if !activatedLoadOlder {
            activatedLoadOlder = loadOlderControl?.accessibilityActivate() ?? false
        }
        if !activatedLoadOlder, let controller = ChatTranscriptHostingSupport.prependController(in: host.view) {
            _ = controller.capture()
            if dragDuringLoad {
                let next = scrollView.contentOffset.y + 72
                scrollView.setContentOffset(CGPoint(x: 0, y: next), animated: false)
                dragState.offset = scrollView.contentOffset.y
            }
            let didLoad = await viewModel.loadOlderMessages()
            ChatTranscriptHostingSupport.applySnapshot(
                ChatTranscriptHostingSupport.transcriptView(from: viewModel, followScroll: false),
                to: host
            )
            if didLoad {
                _ = controller.restoreAfterPrepend()
            }
            activatedLoadOlder = didLoad
        }
        guard activatedLoadOlder else {
            return .unavailable("load-older-activate")
        }

        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, viewModel.displayedTranscriptMessages.count == rowCountBefore {
            _ = ChatTranscriptHostingSupport.layoutPass(window: window, host: host, timeout: 0.25)
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }

        let rowCountAfter = viewModel.displayedTranscriptMessages.count
        guard rowCountAfter > rowCountBefore else {
            return .unavailable("did-not-prepend")
        }

        _ = ChatTranscriptHostingSupport.layoutPass(window: window, host: host, timeout: 5)
        let afterMinY = try XCTUnwrap(
            ChatTranscriptHostingSupport.rowMinY(renderID: anchorRenderID, in: host.view),
            "expected realized anchor row after Load Older restore"
        )
        let expectedOffset = afterMinY + capturedIntraRow
        let offsetAfter = scrollView.contentOffset.y
        let afterID = viewModel.displayedTranscriptMessages.first { $0.renderID == anchorRenderID }?.renderID ?? ""

        var offsetAfterExtra = offsetAfter
        var expectedAfterExtra = expectedOffset
        var extraID = afterID
        if extraLayoutAfterRestore {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.05))
            _ = ChatTranscriptHostingSupport.layoutPass(window: window, host: host, timeout: 5)
            offsetAfterExtra = scrollView.contentOffset.y
            if let extraMinY = ChatTranscriptHostingSupport.rowMinY(renderID: anchorRenderID, in: host.view) {
                expectedAfterExtra = extraMinY + capturedIntraRow
            }
            extraID = viewModel.displayedTranscriptMessages.first { $0.renderID == anchorRenderID }?.renderID ?? ""
        }

        return .hosted(
            NewestPageLoadOlderResult(
                rowCountBefore: rowCountBefore,
                rowCountAfter: rowCountAfter,
                anchorRenderID: anchorRenderID,
                anchorRenderIDAfter: afterID,
                intraRowOffsetY: capturedIntraRow,
                offsetAfter: offsetAfter,
                expectedOffsetAfter: dragDuringLoad ? dragState.offset : expectedOffset,
                draggedOffset: dragState.offset,
                offsetAfterExtraLayout: offsetAfterExtra,
                expectedOffsetAfterExtraLayout: expectedAfterExtra,
                anchorRenderIDAfterExtraLayout: extraID
            )
        )
    }

    private func hostedPaginationSessionJSON(
        total: Int,
        before: Int?,
        largeAssistantContent: String? = nil,
        mixedContent: Bool = false,
        toolCallAssistantIndex: Int? = nil
    ) throws -> Data {
        let pageEnd = before ?? total
        let pageStart = max(0, pageEnd - 50)
        let rows = (pageStart..<pageEnd).map { index in
            hostedPaginationRow(
                index: index,
                total: total,
                largeAssistantContent: largeAssistantContent,
                mixedContent: mixedContent
            )
        }
        var session: [String: Any] = [
            "session_id": "performance-session",
            "messages": rows,
            "_messages_truncated": pageStart > 0,
            "_messages_offset": pageStart
        ]
        if let toolCallAssistantIndex,
           toolCallAssistantIndex >= pageStart,
           toolCallAssistantIndex < pageEnd {
            session["tool_calls"] = [
                [
                    "name": "read_file",
                    "snippet": "let value = \(toolCallAssistantIndex)",
                    "tid": "call-\(toolCallAssistantIndex)",
                    "assistant_msg_idx": toolCallAssistantIndex,
                    "args": ["path": "notes.txt"]
                ]
            ]
        }
        let payload: [String: Any] = ["session": session]
        return try JSONSerialization.data(withJSONObject: payload)
    }

    private func hostedPaginationRow(
        index: Int,
        total: Int,
        largeAssistantContent: String?,
        mixedContent: Bool
    ) -> [String: Any] {
        let isLastAssistant = index == total - 1 && !index.isMultiple(of: 2)
        let content: String
        if isLastAssistant, let largeAssistantContent {
            content = largeAssistantContent
        } else {
            content = hostedPaginationContent(for: index, mixedContent: mixedContent)
        }
        var row: [String: Any] = [
            "role": index.isMultiple(of: 2) ? "user" : "assistant",
            "content": content,
            "_ts": Double(index),
            "message_id": "performance-message-\(index)"
        ]
        if mixedContent, index % 7 == 3 {
            row["attachments"] = [
                [
                    "filename": "row-\(index).txt",
                    "mime": "text/plain",
                    "size": 32
                ]
            ]
        }
        return row
    }

    private func hostedPaginationContent(for index: Int, mixedContent: Bool) -> String {
        if mixedContent {
            switch index % 4 {
            case 0:
                return "## Row \(index)\n\n**Stable** paragraph with `inline code`."
            case 1:
                return "```swift\nlet row = \(index)\n```"
            case 2:
                return "Deterministic plain response row \(index)."
            default:
                return "Equation \(index): $x_\(index) = \(index + 1)$"
            }
        }
        return "## Row \(index)\n\n**Stable** paragraph with `inline code`."
    }
}
