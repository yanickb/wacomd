import XCTest
import WacomdShared
@testable import wacomd

final class PenHoverFilterTests: XCTestCase {
    func testOldConfigDefaultsToUnfilteredPen() throws {
        let config = try JSONDecoder().decode(WacomdConfig.self, from: Data("{}".utf8))
        XCTAssertEqual(config.penHoverDeadbandMM, 0)
        XCTAssertFalse(config.penHoverRejectSpikes)
        var filter = PenHoverFilter()
        for x in [1000.0, 1001, 999] {
            XCTAssertEqual(filter.filter(CGPoint(x: x, y: 1000), mmPerUnit: CGPoint(x: 0.005, y: 0.005),
                deadbandMM: config.penHoverDeadbandMM, rejectSpikes: config.penHoverRejectSpikes,
                hovering: true).x, x)
        }
    }

    func testConfigRoundTripPreservesOptInSettings() throws {
        var config = WacomdConfig()
        config.penHoverDeadbandMM = 0.1
        config.penHoverRejectSpikes = true
        let roundTrip = try JSONDecoder().decode(WacomdConfig.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(roundTrip, config)
    }

    func testDeadbandUsesPhysicalDistanceAndPassesFullDisplacement() {
        var filter = PenHoverFilter()
        let scale = CGPoint(x: 0.005, y: 0.01)
        func feed(_ x: Double, _ y: Double) -> CGPoint {
            filter.filter(CGPoint(x: x, y: y), mmPerUnit: scale, deadbandMM: 0.1,
                          rejectSpikes: false, hovering: true)
        }
        XCTAssertEqual(feed(1000, 1000), CGPoint(x: 1000, y: 1000))
        XCTAssertEqual(feed(1004, 1002), CGPoint(x: 1000, y: 1000))
        XCTAssertEqual(feed(1000, 1011), CGPoint(x: 1000, y: 1011))
    }

    func testSingleSpikeAndItsReturnProduceNoMovement() {
        var filter = PenHoverFilter()
        for x in [1000.0, 1030, 1000, 1000] {
            XCTAssertEqual(filter.filter(CGPoint(x: x, y: 1000), mmPerUnit: CGPoint(x: 0.005, y: 0.005),
                deadbandMM: 0.1, rejectSpikes: true, hovering: true), CGPoint(x: 1000, y: 1000))
        }
    }

    func testSlowMotionHasOnlyOneReportOfMedianDelay() {
        var filter = PenHoverFilter()
        func feed(_ x: Double) -> Double {
            filter.filter(CGPoint(x: x, y: 1000), mmPerUnit: CGPoint(x: 0.005, y: 0.005),
                          deadbandMM: 0.1, rejectSpikes: true, hovering: true).x
        }
        XCTAssertEqual(feed(1000), 1000)
        XCTAssertEqual(feed(1025), 1000)
        XCTAssertEqual(feed(1030), 1025)
    }

    func testFastMovementBypassesWindowAndDoesNotRebound() {
        var filter = PenHoverFilter()
        for x in [1000.0, 1500, 1500] {
            XCTAssertEqual(filter.filter(CGPoint(x: x, y: 1000), mmPerUnit: CGPoint(x: 0.005, y: 0.005),
                deadbandMM: 0.1, rejectSpikes: true, hovering: true).x, x)
        }
    }

    func testContactBypassAndProximityResetDiscardHistory() {
        var filter = PenHoverFilter()
        let scale = CGPoint(x: 0.005, y: 0.005)
        _ = filter.filter(CGPoint(x: 1000, y: 1000), mmPerUnit: scale,
                          deadbandMM: 0.1, rejectSpikes: true, hovering: true)
        XCTAssertEqual(filter.filter(CGPoint(x: 1001, y: 1000), mmPerUnit: scale,
            deadbandMM: 0.1, rejectSpikes: true, hovering: false).x, 1001)
        XCTAssertEqual(filter.filter(CGPoint(x: 2000, y: 2000), mmPerUnit: scale,
            deadbandMM: 0.1, rejectSpikes: true, hovering: true), CGPoint(x: 2000, y: 2000))
        filter.reset()
        XCTAssertEqual(filter.filter(CGPoint(x: 4000, y: 4000), mmPerUnit: scale,
            deadbandMM: 0.1, rejectSpikes: true, hovering: true), CGPoint(x: 4000, y: 4000))
    }
}
