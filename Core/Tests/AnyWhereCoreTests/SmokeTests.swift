import XCTest
@testable import AnyWhereCore

final class SmokeTests: XCTestCase {
    func testVersion() {
        XCTAssertEqual(AnyWhereCoreInfo.version, "0.1.0")
    }
}
