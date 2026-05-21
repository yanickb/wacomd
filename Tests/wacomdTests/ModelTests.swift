import XCTest
@testable import wacomd

final class ModelTests: XCTestCase {
    func testIntuosProSmallIdentity() {
        let m = IntuosProSmall()
        XCTAssertEqual(m.vendorID, 0x056a)
        XCTAssertEqual(m.productID, 0x0314)
        XCTAssertEqual(m.maxPressure, 2047)
        XCTAssertGreaterThan(m.maxX, 0)
        XCTAssertGreaterThan(m.maxY, 0)
    }

    func testKnownModelsLookup() {
        XCTAssertNotNil(KnownModels.lookup(vendorID: 0x056a, productID: 0x0314))
        XCTAssertNil(KnownModels.lookup(vendorID: 0x056a, productID: 0xffff))
    }
}
