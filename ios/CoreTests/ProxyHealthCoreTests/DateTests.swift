import XCTest
@testable import ProxyHealthCore

final class ISODateTests: XCTestCase {
    func testParsesFractionalSeconds() {
        // Firestore timestamps come back this way.
        XCTAssertNotNil(ISODate.parse("2026-10-24T02:48:36.090Z"))
    }

    func testParsesWithoutFractionalSeconds() {
        // The OAuth and connector payloads do not carry them.
        XCTAssertNotNil(ISODate.parse("2026-10-23T06:24:03Z"))
    }

    func testBothFormsAgreeToTheSecond() {
        let a = ISODate.parse("2026-10-24T02:48:36.000Z")!
        let b = ISODate.parse("2026-10-24T02:48:36Z")!
        XCTAssertEqual(a.timeIntervalSince1970, b.timeIntervalSince1970, accuracy: 0.001)
    }

    func testRejectsGarbage() {
        XCTAssertNil(ISODate.parse("not a date"))
    }
}

final class RelativeThaiTests: XCTestCase {
    private let now = ISODate.parse("2026-10-24T12:00:00Z")!

    private func ago(_ seconds: TimeInterval) -> String {
        RelativeThai.describe(now.addingTimeInterval(-seconds), now: now)
    }

    func testJustNow() { XCTAssertEqual(ago(30), "เมื่อครู่") }
    func testMinutes() { XCTAssertEqual(ago(10 * 60), "10 นาทีที่แล้ว") }
    func testHours() { XCTAssertEqual(ago(3 * 3600), "3 ชม.ที่แล้ว") }
    func testYesterday() { XCTAssertEqual(ago(30 * 3600), "เมื่อวาน") }
    func testDays() { XCTAssertEqual(ago(9 * 86_400), "9 วันก่อน") }

    func testOlderThanAMonthFallsBackToADate() {
        // 787 days is the VO2 max case; it must not read as "787 วันก่อน".
        let text = ago(787 * 86_400)
        XCTAssertFalse(text.contains("วันก่อน"))
        XCTAssertFalse(text.isEmpty)
    }
}

final class SyncedPhraseTests: XCTestCase {
    private let now = ISODate.parse("2026-10-24T12:00:00Z")!

    private func phrase(_ seconds: TimeInterval) -> String {
        RelativeThai.syncedPhrase(now.addingTimeInterval(-seconds), now: now)
    }

    func testJustNowDoesNotStutter() {
        // "ซิงก์เมื่อ เมื่อครู่" was what prompted this.
        XCTAssertEqual(phrase(30), "ซิงก์เมื่อครู่")
    }

    func testYesterdayDoesNotStutter() {
        XCTAssertEqual(phrase(30 * 3600), "ซิงก์เมื่อวาน")
    }

    func testMinutesReadNaturally() {
        XCTAssertEqual(phrase(8 * 60), "ซิงก์เมื่อ 8 นาทีที่แล้ว")
    }

    func testDaysReadNaturally() {
        XCTAssertEqual(phrase(5 * 86_400), "ซิงก์เมื่อ 5 วันก่อน")
    }

    func testNeverRepeatsTheWord() {
        let spans: [TimeInterval] = [10, 300, 7200, 90_000, 400_000, 60 * 86_400]
        for seconds in spans {
            let text = phrase(seconds)
            XCTAssertFalse(text.contains("เมื่อ เมื่อ"), "stutter in: \(text)")
        }
    }
}
