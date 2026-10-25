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
