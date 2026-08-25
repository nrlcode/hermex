import XCTest
@testable import HermesMobile

@MainActor
final class ChatPerformanceInstrumentationTests: XCTestCase {
    func testResetStartsWithZeroAndSummaryIsStableAndPayloadFree() throws {
        let instrumentation = ChatPerformanceInstrumentation.shared
        instrumentation.reset()

        XCTAssertTrue(instrumentation.summary.counters.isEmpty)
        XCTAssertTrue(instrumentation.summary.closedIntervals.isEmpty)
        let data = try JSONEncoder().encode(instrumentation.summary)
        let encoded = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(encoded.contains("prompt"))
        XCTAssertFalse(encoded.contains("http"))
        XCTAssertFalse(encoded.contains("tool_args"))
    }

    func testNamedPhasesCountUnitsAndCloseIntervals() {
        let instrumentation = ChatPerformanceInstrumentation.shared
        instrumentation.reset()

        instrumentation.record(.eventHandling, units: 3)
        instrumentation.record(.drainedUnits, units: 12)
        instrumentation.begin(.streamIntervals)
        instrumentation.end(.streamIntervals)

        XCTAssertEqual(instrumentation.summary.counters[ChatPerformancePhase.eventHandling.rawValue], 3)
        XCTAssertEqual(instrumentation.summary.counters[ChatPerformancePhase.drainedUnits.rawValue], 12)
        XCTAssertEqual(instrumentation.summary.closedIntervals[ChatPerformancePhase.streamIntervals.rawValue], 1)
        XCTAssertGreaterThan(instrumentation.summary.intervalDurationsNanoseconds[ChatPerformancePhase.streamIntervals.rawValue] ?? 0, 0)
    }

    func testCountersDoNotRecordNonPositiveUnits() {
        let instrumentation = ChatPerformanceInstrumentation.shared
        instrumentation.reset()

        instrumentation.record(.eventHandling, units: 0)
        instrumentation.record(.eventHandling, units: -1)

        XCTAssertNil(instrumentation.summary.counters[ChatPerformancePhase.eventHandling.rawValue])
    }
}
