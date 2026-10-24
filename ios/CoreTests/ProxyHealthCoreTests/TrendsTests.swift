import XCTest
@testable import ProxyHealthCore

final class TrendsTests: XCTestCase {
    func testChangeIgnoresGaps() {
        // Weight is recorded every week or two; the days in between are nil.
        let result = Trends.change([77.2, nil, nil, 76.6, nil, 75.3])
        XCTAssertEqual(result?.delta ?? 0, -1.9, accuracy: 0.0001)
        XCTAssertEqual(result?.points, 3)
    }

    func testChangeNeedsTwoPoints() {
        XCTAssertNil(Trends.change([75.3]))
        XCTAssertNil(Trends.change([nil, nil]))
        XCTAssertNil(Trends.change([]))
    }

    func testAverageUsesOnlyPresentValues() {
        XCTAssertEqual(Trends.average([10, nil, 20], window: 7) ?? 0, 15, accuracy: 0.0001)
    }

    func testAverageWindowTakesTheMostRecent() {
        XCTAssertEqual(Trends.average([100, 100, 1, 3], window: 2) ?? 0, 2, accuracy: 0.0001)
    }

    func testAverageOfNothingIsNil() {
        XCTAssertNil(Trends.average([nil, nil], window: 7))
    }

    func testRingFractionClampsAnOverAchievedGoal() {
        XCTAssertEqual(Trends.fraction(value: 594, goal: 320), 1, accuracy: 0.0001)
        XCTAssertEqual(Trends.fraction(value: 160, goal: 320), 0.5, accuracy: 0.0001)
    }

    func testRingPercentIsNotClamped() {
        // The ring fills up, but the label still reports the real number.
        XCTAssertEqual(Trends.percent(value: 594, goal: 320), 186)
        XCTAssertEqual(Trends.percent(value: 6, goal: 10), 60)
    }

    func testMissingGoalDoesNotDivideByZero() {
        XCTAssertEqual(Trends.fraction(value: 10, goal: 0), 0)
        XCTAssertEqual(Trends.percent(value: 10, goal: 0), 0)
    }
}

final class SpanDaysTests: XCTestCase {
    func testSpanAcrossMonths() {
        // Eight weigh-ins between these two dates: the trend covers 83 days, not 8.
        XCTAssertEqual(Trends.spanDays(from: "2026-08-02", to: "2026-10-24"), 83)
    }

    func testSameDayIsZero() {
        XCTAssertEqual(Trends.spanDays(from: "2026-10-24", to: "2026-10-24"), 0)
    }

    func testCrossesALeapDay() {
        XCTAssertEqual(Trends.spanDays(from: "2024-02-28", to: "2024-03-01"), 2)
    }

    func testRejectsMalformedKeys() {
        XCTAssertNil(Trends.spanDays(from: "nope", to: "2026-10-24"))
    }
}
