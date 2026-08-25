import Foundation
import XCTest
@testable import HermesMobile

final class ChatPerformanceMeasurementTests: APIClientTestCase {
    func testCheapBoundedMeasurementCapturesSamplesWithoutPacingSleeps() {
        let fixture = ChatPerformanceFixture.make(
            rowCount: 50,
            responseBytes: 4_096,
            contentKind: .markdown
        )
        var samples: [UInt64] = []

        for _ in 0..<2 {
            _ = ChatViewModel.transcriptMessages(from: fixture.messages, messageOffset: 0)
        }
        for _ in 0..<3 {
            let start = DispatchTime.now().uptimeNanoseconds
            let mapped = ChatViewModel.transcriptMessages(from: fixture.messages, messageOffset: 0)
            samples.append(DispatchTime.now().uptimeNanoseconds &- start)
            XCTAssertEqual(mapped.count, fixture.messages.count)
        }

        let sortedSamples = samples.sorted()
        XCTAssertEqual(sortedSamples.count, 3)
        XCTAssertGreaterThanOrEqual(sortedSamples[1], sortedSamples[0])
        XCTAssertGreaterThanOrEqual(sortedSamples[2], sortedSamples[1])
    }

    @MainActor
    func testRealPaginationSeamLoadsAllBoundedFixtureSizesWithoutDuplicates() async throws {
        for total in [50, 200, 500] {
            var requests: [(before: Int?, limit: Int?)] = []
            let client = makeClient { request in
                let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
                let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value) })
                let before = (query["msg_before"] ?? nil).flatMap { Int($0) }
                let limit = (query["msg_limit"] ?? nil).flatMap { Int($0) }
                requests.append((before, limit))

                let pageEnd = before ?? total
                let pageStart = max(0, pageEnd - 50)
                let rows = (pageStart..<pageEnd).map(Self.messageJSON)
                let payload: [String: Any] = [
                    "session": [
                        "session_id": "performance-session",
                        "messages": rows,
                        "_messages_truncated": pageStart > 0,
                        "_messages_offset": pageStart
                    ]
                ]
                let data = try JSONSerialization.data(withJSONObject: payload)
                return apiTestJSONResponse(String(decoding: data, as: UTF8.self), for: request)
            }
            let viewModel = ChatViewModel(
                session: SessionSummary(sessionId: "performance-session"),
                server: URL(string: "https://example.test")!,
                client: client
            )

            ChatPerformanceInstrumentation.shared.reset()
            await viewModel.loadMessages()
            while viewModel.hasOlderMessages {
                _ = await viewModel.loadOlderMessages()
            }

            XCTAssertEqual(viewModel.messages.count, total)
            XCTAssertEqual(Set(viewModel.messages.map { $0.id }).count, total)
            XCTAssertEqual(viewModel.messages.map { $0.id }, viewModel.messages.map { $0.id }.sorted { lhs, rhs in
                let left = Int(lhs.split(separator: "-").last!)!
                let right = Int(rhs.split(separator: "-").last!)!
                return left < right
            })
            XCTAssertEqual(viewModel.messagesOffset, 0)
            XCTAssertEqual(requests.first?.limit, 50)
            XCTAssertTrue(requests.dropFirst().allSatisfy { $0.limit == 50 && $0.before != nil })
            XCTAssertGreaterThanOrEqual(
                ChatPerformanceInstrumentation.shared.summary.counters[
                    ChatPerformancePhase.messagePageLoads.rawValue
                ] ?? 0,
                1
            )
        }
    }

    @MainActor
    func testFixtureDrivenReplayPreservesOrderingDeduplicationAndFinalFlush() async throws {
        let streamClient = ScriptedSSEStreamingClient(connectionScripts: [
            [
                .init(.token("Alpha "), lastEventID: "stream-123:1"),
                .init(.token("bravo "), lastEventID: "stream-123:2"),
                .init(.transportError("Connection lost"))
            ],
            [
                .init(.token("Alpha "), lastEventID: "stream-123:1"),
                .init(.token("bravo "), lastEventID: "stream-123:2"),
                .init(.token("charlie."), lastEventID: "stream-123:3"),
                .init(.done(DoneStreamEvent())),
                .init(.streamEnd)
            ]
        ])
        let viewModel = try makeStreamingViewModel(streamClient: streamClient) { request in
            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse(#"{"session_id":"performance-session","stream_id":"stream-123"}"#, for: request)
            case "/api/chat/stream/status":
                return apiTestJSONResponse(#"{"active":false,"stream_id":"stream-123","replay_available":true}"#, for: request)
            case "/api/session":
                return apiTestJSONResponse(#"{"session":{"session_id":"performance-session"}}"#, for: request)
            default:
                XCTFail("Unexpected request path")
                throw URLError(.badURL)
            }
        }

        ChatPerformanceInstrumentation.shared.reset()
        let didStart = await viewModel.sendMessage("Keep working")
        XCTAssertTrue(didStart)
        streamClient.playArmedConnectionScript()
        try await waitUntil { streamClient.startedURLs.count == 2 }
        streamClient.playArmedConnectionScript()

        XCTAssertEqual(viewModel.messages.compactMap { $0.content }, ["Keep working", "Alpha bravo charlie."])
        XCTAssertEqual(Set(viewModel.messages.map { $0.id }).count, viewModel.messages.count)
        XCTAssertEqual(viewModel.activeStreamID, nil)
        XCTAssertEqual(ChatPerformanceInstrumentation.shared.summary.closedIntervals[ChatPerformancePhase.streamIntervals.rawValue], 2)
    }

    @MainActor
    func testFixtureDrivenCancellationAndErrorCloseIntervalsAfterSynchronousFlush() async throws {
        let cancellationClient = ScriptedSSEStreamingClient(connectionScripts: [[
            .init(.token("Partial response"))
        ]])
        let cancellationViewModel = try makeStreamingViewModel(streamClient: cancellationClient) { request in
            switch request.url?.path {
            case "/api/chat/start":
                return apiTestJSONResponse(#"{"session_id":"performance-session","stream_id":"cancel-stream"}"#, for: request)
            case "/api/chat/cancel":
                return apiTestJSONResponse(#"{"ok":true,"cancelled":true}"#, for: request)
            default:
                throw URLError(.badURL)
            }
        }

        ChatPerformanceInstrumentation.shared.reset()
        let didStartCancellation = await cancellationViewModel.sendMessage("Cancel this")
        XCTAssertTrue(didStartCancellation)
        cancellationClient.playArmedConnectionScript()
        _ = try await cancellationViewModel.cancelActiveStream()
        let cancellationSummary = ChatPerformanceInstrumentation.shared.summary
        XCTAssertEqual(cancellationSummary.counters[ChatPerformancePhase.cancellations.rawValue], 1)
        XCTAssertEqual(cancellationSummary.closedIntervals[ChatPerformancePhase.streamIntervals.rawValue], 1)
        XCTAssertEqual(cancellationViewModel.messages.compactMap { $0.content }, ["Cancel this", "Partial response"])

        let errorClient = ScriptedSSEStreamingClient(connectionScripts: [[
            .init(.token("Before error")),
            .init(.error("Scripted stream error"))
        ]])
        let errorViewModel = try makeStreamingViewModel(streamClient: errorClient) { request in
            XCTAssertEqual(request.url?.path, "/api/chat/start")
            return apiTestJSONResponse(#"{"session_id":"performance-session","stream_id":"error-stream"}"#, for: request)
        }

        ChatPerformanceInstrumentation.shared.reset()
        let didStartError = await errorViewModel.sendMessage("Handle error")
        XCTAssertTrue(didStartError)
        errorClient.playArmedConnectionScript()
        let errorSummary = ChatPerformanceInstrumentation.shared.summary
        XCTAssertEqual(errorSummary.counters[ChatPerformancePhase.errors.rawValue], 1)
        XCTAssertGreaterThanOrEqual(errorSummary.counters[ChatPerformancePhase.finalFlushes.rawValue] ?? 0, 1)
        XCTAssertEqual(errorSummary.closedIntervals[ChatPerformancePhase.streamIntervals.rawValue], 1)
        XCTAssertEqual(errorViewModel.messages.compactMap { $0.content }, ["Handle error", "Before error"])
    }

    func testFixtureContentGroupingAndExpansionKeepAnchorsStable() {
        for contentKind in [ChatPerformanceContentKind.markdown, .math, .reasoning, .tool] {
            let fixture = ChatPerformanceFixture.make(
                rowCount: 4,
                responseBytes: 4_096,
                contentKind: contentKind,
                toolState: contentKind == .tool ? .expanded : .none
            )
            let transcript = ChatViewModel.transcriptMessages(from: fixture.messages)

            XCTAssertEqual(transcript.map { $0.anchorID }, fixture.messages.filter { $0.role != "tool" }.map { $0.id })
            XCTAssertEqual(transcript.map { $0.id }, transcript.map { $0.id }.sorted())
            XCTAssertEqual(transcript.count, contentKind == .tool ? 0 : fixture.messages.count)
            XCTAssertTrue(fixture.messages.allSatisfy { message in
                message.content?.isEmpty == false || message.reasoning?.isEmpty == false
            })
            switch contentKind {
            case .markdown:
                XCTAssertTrue(fixture.messages.allSatisfy { $0.content?.contains("**Stable**") == true })
            case .math:
                XCTAssertTrue(fixture.messages.allSatisfy { $0.content?.contains("$") == true })
            case .reasoning:
                XCTAssertEqual(
                    ChatViewModel.reasoningDisplayGroups(messages: fixture.messages, archivedGroups: []).count,
                    2
                )
            case .tool:
                XCTAssertTrue(transcript.isEmpty)
            default:
                XCTFail("Unexpected content kind in grouping fixture")
            }
        }

        var transcriptIDsByToolState: [[String]] = []
        var anchorIDsByToolState: [[String]] = []

        for toolState in [ChatPerformanceToolState.collapsed, .expanded] {
            let fixture = ChatPerformanceFixture.make(
                rowCount: 4,
                responseBytes: 4_096,
                contentKind: .tool,
                toolState: toolState
            )
            let messages = [
                ChatMessage(
                    role: "user",
                    content: "Run the tools",
                    timestamp: 0,
                    messageId: "tool-user"
                ),
                ChatMessage(
                    role: "assistant",
                    content: nil,
                    timestamp: 1,
                    messageId: "tool-assistant",
                    toolCalls: [
                        .object([
                            "id": .string("call-1"),
                            "function": .object([
                                "name": .string("read_file"),
                                "arguments": .string("{\"path\":\"notes.txt\"}")
                            ])
                        ]),
                        .object([
                            "id": .string("call-2"),
                            "function": .object([
                                "name": .string("search_files"),
                                "arguments": .string("{\"path\":\"Sources\"}")
                            ])
                        ])
                    ]
                ),
                ChatMessage(
                    role: "tool",
                    content: fixture.messages[0].content,
                    timestamp: 2,
                    messageId: "tool-result-1",
                    toolCallId: "call-1"
                ),
                ChatMessage(
                    role: "tool",
                    content: fixture.messages[1].content,
                    timestamp: 3,
                    messageId: "tool-result-2",
                    toolCallId: "call-2"
                )
            ]
            let groups = ToolCallGroup.groups(
                persistedToolCalls: [],
                messages: messages,
                messageOffset: nil
            )
            let transcript = ChatViewModel.transcriptMessages(from: messages)
            guard let group = groups.first else {
                XCTFail("Expected one grouped tool activity")
                continue
            }

            XCTAssertEqual(groups.count, 1)
            XCTAssertEqual(fixture.scenario.toolState, toolState)
            XCTAssertEqual(group.toolCalls.map { $0.id }, ["call-1", "call-2"])
            XCTAssertEqual(group.toolCalls.map { $0.name }, ["read_file", "search_files"])
            XCTAssertTrue(group.toolCalls.allSatisfy { toolCall in
                (toolCall.preview ?? "").hasSuffix(" output") == (toolState == .expanded)
            })
            XCTAssertEqual(
                group.toolCalls.map { $0.preview },
                [fixture.messages[0].content, fixture.messages[1].content]
            )
            XCTAssertEqual(group.anchorMessageID, "tool-assistant")
            XCTAssertEqual(group.anchorMessageID, transcript.last?.anchorID)
            XCTAssertEqual(transcript.map { $0.anchorID }, ["tool-user", "tool-assistant"])

            transcriptIDsByToolState.append(transcript.map { $0.id })
            anchorIDsByToolState.append(transcript.map { $0.anchorID })
        }

        XCTAssertEqual(transcriptIDsByToolState.count, 2)
        XCTAssertEqual(anchorIDsByToolState.count, 2)
        guard transcriptIDsByToolState.count == 2,
              anchorIDsByToolState.count == 2
        else {
            return
        }
        XCTAssertEqual(transcriptIDsByToolState[0], transcriptIDsByToolState[1])
        XCTAssertEqual(anchorIDsByToolState[0], anchorIDsByToolState[1])

        let streaming = [
            ChatMessage(role: "user", content: "Question", timestamp: 1, messageId: "user-1"),
            ChatMessage(role: "assistant", content: "Partial", timestamp: 2, messageId: "stream-1")
        ]
        let completed = [
            ChatMessage(role: "user", content: "Question", timestamp: 1, messageId: "user-1"),
            ChatMessage(role: "assistant", content: "Complete", timestamp: 2, messageId: "assistant-1")
        ]
        let streamingTranscript = ChatViewModel.transcriptMessages(from: streaming)
        let completedTranscript = ChatViewModel.transcriptMessages(from: completed)
        XCTAssertEqual(streamingTranscript.map { $0.id }, completedTranscript.map { $0.id })
        XCTAssertEqual(streamingTranscript.first?.anchorID, "user-1")
        XCTAssertEqual(streamingTranscript.last?.anchorID, "stream-1")
        XCTAssertEqual(completedTranscript.last?.anchorID, "assistant-1")
    }

    private static func messageJSON(index: Int) -> [String: Any] {
        [
            "role": index.isMultiple(of: 2) ? "user" : "assistant",
            "content": "Deterministic pagination row \(index)",
            "_ts": Double(index),
            "message_id": "performance-message-\(index)"
        ]
    }

    @MainActor
    private func makeStreamingViewModel(
        streamClient: ScriptedSSEStreamingClient,
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) throws -> ChatViewModel {
        let client = makeClient(handler: handler)
        let viewModel = ChatViewModel(
            session: SessionSummary(sessionId: "performance-session"),
            server: URL(string: "https://example.test")!,
            client: client,
            streamClient: streamClient,
            approvalStreamClient: ScriptedSSEStreamingClient(),
            clarifyStreamClient: ScriptedSSEStreamingClient(),
            btwStreamClient: ScriptedSSEStreamingClient()
        )
        streamClient.flushPendingStreamingContent = { [weak viewModel] in
            viewModel?.flushPendingStreamingContent()
        }
        return viewModel
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for scripted stream recovery")
    }
}
