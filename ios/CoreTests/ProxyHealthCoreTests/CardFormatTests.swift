import XCTest
@testable import ProxyHealthCore

final class ReadinessFormatTests: XCTestCase {
    func testChangeCarriesADirection() {
        XCTAssertEqual(ReadinessFormat.change(percent: -24.4), "−24%")
        XCTAssertEqual(ReadinessFormat.change(percent: 2), "+2%")
    }

    func testNoChangeIsNotShownAsAGain() {
        XCTAssertEqual(ReadinessFormat.change(percent: 0.2), "±0%")
    }

    func testNothingToCompareShowsNothing() {
        XCTAssertNil(ReadinessFormat.change(percent: nil))
    }

    func testClockPadsTheMinutes() {
        XCTAssertEqual(ReadinessFormat.clock(304), "5:04")
        XCTAssertEqual(ReadinessFormat.clock(429), "7:09")
        XCTAssertEqual(ReadinessFormat.clock(480), "8:00")
        XCTAssertEqual(ReadinessFormat.clock(0), "0:00")
    }

    func testEachFactorKeepsItsOwnUnit() {
        XCTAssertEqual(ReadinessFormat.value(key: "hrv", value: 47.24), "47.2 ms")
        XCTAssertEqual(ReadinessFormat.value(key: "restingHeartRate", value: 61.4), "61 bpm")
        XCTAssertEqual(ReadinessFormat.value(key: "sleep", value: 304), "5:04")
        XCTAssertEqual(ReadinessFormat.value(key: "load", value: 36.2), "36 นาที")
    }

    func testAnUnknownFactorStillFormats() {
        XCTAssertEqual(ReadinessFormat.value(key: "somethingNew", value: 12.34), "12.3")
    }

    func testTheShortLabelsHaveAThaiMeaning() {
        XCTAssertEqual(ReadinessFormat.thaiName("hrv"), "ความแปรปรวนจังหวะหัวใจ")
        XCTAssertEqual(ReadinessFormat.thaiName("restingHeartRate"), "ชีพจรขณะพัก")
        XCTAssertEqual(ReadinessFormat.thaiName("sleep"), "เวลาที่หลับจริง")
        XCTAssertEqual(ReadinessFormat.thaiName("load"), "โหลดการซ้อม 7 วัน")
    }
}

final class BatteryFormatTests: XCTestCase {
    func testMissingInputsAreNamedInThai() {
        XCTAssertEqual(
            BatteryFormat.missingNames(["sleep", "restingHeartRate", "hourly"]),
            "การนอนคืนล่าสุด, ชีพจรขณะพัก, ข้อมูลรายชั่วโมงของวันนี้"
        )
    }

    func testAnUnknownInputIsShownRatherThanDropped() {
        XCTAssertEqual(BatteryFormat.missingNames(["workouts"]), "workouts")
    }

    func testNothingMissingIsAnEmptyString() {
        XCTAssertEqual(BatteryFormat.missingNames([]), "")
    }
}

final class BatterySegmentTests: XCTestCase {
    func testSegmentsSplitIntoLeftSpentAndNeverCharged() {
        let states = BatterySegments.states(level: 40, wakeLevel: 80)
        XCTAssertEqual(states.filter { $0 == .filled }.count, 8)
        XCTAssertEqual(states.filter { $0 == .used }.count, 8)
        XCTAssertEqual(states.filter { $0 == .empty }.count, 4)
    }

    func testAFullMorningLeavesNothingFaint() {
        let states = BatterySegments.states(level: 55, wakeLevel: 100)
        XCTAssertEqual(states.filter { $0 == .empty }.count, 0)
        XCTAssertEqual(states.filter { $0 == .filled }.count, 11)
    }

    func testAnEmptyBatteryLightsNothing() {
        XCTAssertEqual(BatterySegments.states(level: 0, wakeLevel: 70).filter { $0 == .filled }.count, 0)
    }

    func testANapAboveTheMorningDoesNotInvertTheBar() {
        let states = BatterySegments.states(level: 75, wakeLevel: 70)
        XCTAssertEqual(states.filter { $0 == .used }.count, 0)
        XCTAssertEqual(states.filter { $0 == .filled }.count, 15)
    }

    func testOutOfRangeValuesAreClamped() {
        XCTAssertEqual(BatterySegments.states(level: 140, wakeLevel: 140).filter { $0 == .filled }.count, 20)
        XCTAssertEqual(BatterySegments.states(level: -10, wakeLevel: 50).filter { $0 == .filled }.count, 0)
    }

    func testMarkersCollideOnlyWhenClose() {
        XCTAssertTrue(BatterySegments.markersCollide(level: 55, wakeLevel: 72))
        XCTAssertFalse(BatterySegments.markersCollide(level: 42, wakeLevel: 78))
    }

    func testSinceWakeReadsAsSpentOrGained() {
        XCTAssertEqual(BatterySegments.sinceWakeText(-36), "ใช้ไปแล้ว 36%")
        XCTAssertEqual(BatterySegments.sinceWakeText(4), "เพิ่มขึ้น 4%")
        XCTAssertEqual(BatterySegments.sinceWakeText(0), "ใช้ไปแล้ว 0%")
    }
}
