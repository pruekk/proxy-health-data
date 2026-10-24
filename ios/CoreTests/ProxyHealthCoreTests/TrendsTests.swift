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

final class SyncMergeTests: XCTestCase {
    private struct Entry: Equatable {
        let at: Date
        let source: String
    }

    private func date(_ iso: String) -> Date { ISODate.parse(iso)! }

    func testNewestFirst() {
        let merged = SyncMerge.dedupedByTimestamp([
            Entry(at: date("2026-10-24T08:00:00Z"), source: "a"),
            Entry(at: date("2026-10-24T10:00:00Z"), source: "b"),
        ]) { $0.at }
        XCTAssertEqual(merged.map(\.source), ["b", "a"])
    }

    func testTheSameSyncFromBothSourcesAppearsOnce() {
        // The device records a sync and the server returns its own copy of it.
        let local = Entry(at: date("2026-10-24T10:00:00.120Z"), source: "local")
        let server = Entry(at: date("2026-10-24T10:00:00.000Z"), source: "server")
        let merged = SyncMerge.dedupedByTimestamp([local, server]) { $0.at }
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.source, "local", "the local entry is passed first and wins")
    }

    func testDistinctSyncsASecondApartAreKept() {
        let merged = SyncMerge.dedupedByTimestamp([
            Entry(at: date("2026-10-24T10:00:00Z"), source: "a"),
            Entry(at: date("2026-10-24T10:00:01Z"), source: "b"),
        ]) { $0.at }
        XCTAssertEqual(merged.count, 2)
    }

    func testEmptyInput() {
        XCTAssertTrue(SyncMerge.dedupedByTimestamp([Entry]()) { $0.at }.isEmpty)
    }
}
