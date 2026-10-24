import XCTest
@testable import ProxyHealthCore

/// These cover the bug that blanked every tab: a path carrying a query string was handed to
/// `URL.appending(path:)`, which percent-encoded the `?` into the path and returned 404.
final class APIPathTests: XCTestCase {
    private let base = URL(string: "https://api.example.com")!

    func testPlainPath() {
        XCTAssertEqual(APIPath.url(base: base, pathAndQuery: "v1/metrics").absoluteString,
                       "https://api.example.com/v1/metrics")
    }

    func testQueryStaysAQuery() {
        let url = APIPath.url(base: base, pathAndQuery: "v1/daily?from=2026-07-27&to=2026-10-24")
        XCTAssertEqual(url.absoluteString, "https://api.example.com/v1/daily?from=2026-07-27&to=2026-10-24")
        XCTAssertFalse(url.absoluteString.contains("%3F"), "the ? must not be encoded into the path")
        XCTAssertEqual(url.path(), "/v1/daily")
        XCTAssertEqual(url.query(), "from=2026-07-27&to=2026-10-24")
    }

    func testSingleParameter() {
        let url = APIPath.url(base: base, pathAndQuery: "v1/catalog?version=8824adcf35c0")
        XCTAssertEqual(url.query(), "version=8824adcf35c0")
    }

    func testTrailingQuestionMarkIsIgnored() {
        XCTAssertEqual(APIPath.url(base: base, pathAndQuery: "v1/syncs?").absoluteString,
                       "https://api.example.com/v1/syncs")
    }

    func testBaseWithTrailingSlash() {
        let slashed = URL(string: "https://api.example.com/")!
        XCTAssertEqual(APIPath.url(base: slashed, pathAndQuery: "v1/me").absoluteString,
                       "https://api.example.com/v1/me")
    }

    func testAlreadyEncodedValuesSurvive() {
        let url = APIPath.url(base: base, pathAndQuery: "v1/samples?source=Apple%20Watch")
        XCTAssertEqual(url.query(percentEncoded: true), "source=Apple%20Watch")
    }
}
