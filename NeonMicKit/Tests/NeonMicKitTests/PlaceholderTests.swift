import XCTest
@testable import NeonMicKit

final class PlaceholderTests: XCTestCase {
    func testPackageHasVersion() {
        XCTAssertFalse(NeonMicKit.version.isEmpty)
    }
}
