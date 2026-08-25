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
                let before = query["msg_before"].flatMap(Int.init)
                let limit = query["msg_limit"].flatMap(Int.init)
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
            XCTAssertEqual(Set(viewModel.messages.map(\.id)).count, total)
            XCTAssertEqual(viewModel.messages.map(\.id), viewModel.messages.map(\.id).sorted { lhs, rhs in
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

    private static func messageJSON(index: Int) -> [String: Any] {
        [
            "role": index.isMultiple(of: 2) ? "user" : "assistant",
            "content": "Deterministic pagination row \(index)",
            "_ts": Double(index),
            "message_id": "performance-message-\(index)"
        ]
    }
}
