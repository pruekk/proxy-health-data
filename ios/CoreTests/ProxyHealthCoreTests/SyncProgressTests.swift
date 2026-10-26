import XCTest
@testable import ProxyHealthCore

final class SyncProgressTests: XCTestCase {
    func testPhaseWeightsCoverTheWholeBar() {
        let total = SyncProgress.Phase.allCases.reduce(0) { $0 + $1.weight }
        XCTAssertEqual(total, 1, accuracy: 0.0001)
    }

    func testTheBarOnlyMovesForward() {
        var last = -1.0
        for phase in SyncProgress.Phase.allCases {
            for done in 0...4 {
                let fraction = SyncProgress(phase: phase, done: done, total: 4).fraction
                XCTAssertGreaterThanOrEqual(fraction, last)
                last = fraction
            }
        }
        XCTAssertEqual(last, 1, accuracy: 0.0001)
    }

    func testAPhaseWithoutStepsSitsAtItsStart() {
        XCTAssertEqual(SyncProgress(phase: .hourly).fraction, 0.48, accuracy: 0.0001)
    }

    func testPercentIsWholeNumbers() {
        XCTAssertEqual(SyncProgress(phase: .samples, done: 18, total: 36).percent, 24)
    }

    func testEstimateComesFromTheRateSoFar() {
        // Daily is the last long phase: one metric of twelve in, with everything before it done.
        let progress = SyncProgress(phase: .daily, done: 1, total: 12, elapsed: 30)
        XCTAssertEqual(progress.fraction, 0.608, accuracy: 0.01)
        XCTAssertEqual(progress.remaining!, 19.3, accuracy: 0.5)
    }

    func testNoEstimateBeforeThereIsSignal() {
        XCTAssertNil(SyncProgress(phase: .catalog, elapsed: 30).remaining)
        XCTAssertNil(SyncProgress(phase: .samples, done: 1, total: 36, elapsed: 2).remaining)
        XCTAssertNil(SyncProgress(phase: .samples, done: 18, total: 36, elapsed: 0.5).remaining)
    }

    func testEstimateIsRoundedToSomethingBelievable() {
        XCTAssertEqual(SyncProgress(phase: .daily, done: 11, total: 12, elapsed: 60).remainingText, "อีกไม่กี่วินาที")
        XCTAssertEqual(SyncProgress(phase: .daily, done: 6, total: 12, elapsed: 90).remainingText, "เหลืออีกประมาณ 30 วิ")
        XCTAssertEqual(SyncProgress(phase: .samples, done: 4, total: 36, elapsed: 60).remainingText, "เหลืออีกประมาณ 12 นาที")
    }

    func testTheLineNamesThePhaseAndTheCount() {
        let progress = SyncProgress(phase: .daily, done: 12, total: 36, detail: "bodyMass", elapsed: 10)
        XCTAssertTrue(progress.line.hasPrefix("สรุปรายวัน 12/36 · bodyMass"))
    }

    func testTheCountNeverReadsPastTheTotal() {
        XCTAssertEqual(SyncProgress(phase: .samples, done: 40, total: 36).line, "ดึงข้อมูลดิบ 36/36")
    }
}
