import Foundation
@testable import HermesMobile

enum ChatPerformanceContentKind: String, CaseIterable, Codable {
    case plain
    case markdown
    case code
    case math
    case reasoning
    case tool
}

enum ChatPerformanceToolState: String, CaseIterable, Codable {
    case none
    case collapsed
    case expanded
}

struct ChatPerformanceScenario: Hashable, Codable {
    let rowCount: Int
    let responseBytes: Int
    let contentKind: ChatPerformanceContentKind
    let toolState: ChatPerformanceToolState
    let followsScroll: Bool
    let animationEnabled: Bool

    var id: String {
        [
            "rows-\(rowCount)",
            "response-\(responseBytes)",
            contentKind.rawValue,
            toolState.rawValue,
            followsScroll ? "follow" : "free",
            animationEnabled ? "animated" : "static"
        ].joined(separator: "-")
    }
}

struct ChatPerformanceFixture {
    static let rowCounts = [50, 200, 500]
    static let responseByteLengths = [4_096, 16_384, 65_536]
    static let catalog: [ChatPerformanceScenario] = rowCounts.flatMap { rowCount in
        responseByteLengths.flatMap { responseBytes in
            ChatPerformanceContentKind.allCases.flatMap { contentKind in
                ChatPerformanceToolState.allCases.flatMap { toolState in
                    [false, true].flatMap { followsScroll in
                        [false, true].map { animationEnabled in
                            ChatPerformanceScenario(
                                rowCount: rowCount,
                                responseBytes: responseBytes,
                                contentKind: contentKind,
                                toolState: toolState,
                                followsScroll: followsScroll,
                                animationEnabled: animationEnabled
                            )
                        }
                    }
                }
            }
        }
    }

    let scenario: ChatPerformanceScenario
    let messages: [ChatMessage]
    let response: Data

    static func make(
        rowCount: Int,
        responseBytes: Int,
        contentKind: ChatPerformanceContentKind,
        toolState: ChatPerformanceToolState = .none,
        followsScroll: Bool = true,
        animationEnabled: Bool = false
    ) -> ChatPerformanceFixture {
        precondition(rowCount > 0)
        precondition(responseBytes > 0)
        let scenario = ChatPerformanceScenario(
            rowCount: rowCount,
            responseBytes: responseBytes,
            contentKind: contentKind,
            toolState: toolState,
            followsScroll: followsScroll,
            animationEnabled: animationEnabled
        )
        let messages = (0..<rowCount).map { index in
            ChatMessage(
                role: role(for: index, contentKind: contentKind),
                content: content(for: index, contentKind: contentKind, toolState: toolState),
                timestamp: Double(index),
                messageId: "performance-\(scenario.id)-message-\(index)",
                name: contentKind == .tool ? "read_file" : nil,
                reasoning: contentKind == .reasoning ? "Inspecting deterministic row \(index)." : nil
            )
        }
        let seed = "Hermex deterministic response baseline\n"
        var response = Data(seed.utf8)
        while response.count < responseBytes {
            response.append(contentsOf: Data(seed.utf8))
        }
        response = Data(response.prefix(responseBytes))
        return ChatPerformanceFixture(scenario: scenario, messages: messages, response: response)
    }

    private static func role(for index: Int, contentKind: ChatPerformanceContentKind) -> String {
        if contentKind == .tool { return "tool" }
        return index.isMultiple(of: 2) ? "user" : "assistant"
    }

    private static func content(
        for index: Int,
        contentKind: ChatPerformanceContentKind,
        toolState: ChatPerformanceToolState
    ) -> String {
        switch contentKind {
        case .plain:
            return "Deterministic plain response row \(index)."
        case .markdown:
            return "## Row \(index)\n\n**Stable** paragraph with `inline code`."
        case .code:
            return "```swift\nlet row = \(index)\n```"
        case .math:
            return "Equation \(index): $x_{\(index)} = \(index + 1)$"
        case .reasoning:
            return "Reasoning row \(index)"
        case .tool:
            let suffix = toolState == .expanded ? " output" : ""
            return "read_file row \(index)\(suffix)"
        }
    }
}
