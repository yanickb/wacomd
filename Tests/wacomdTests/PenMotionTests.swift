import XCTest
import CoreGraphics
import WacomdShared
@testable import wacomd

private struct TestModel: WacomModel {
    let name = "Test", vendorID = 0x056a, productID = 0x0314
    let maxX = 20000.0, maxY = 10000.0, maxPressure = 2047.0, maxTilt = 60.0
    let widthMM = 100.0, heightMM = 50.0
}
private func pen(_ x: Double = 1000, _ y: Double = 1000, upper: Bool = false,
                 lower: Bool = false, pressure: Double = 0) -> PenState {
    var state = PenState()
    state.x = x; state.y = y; state.inRange = true
    state.barrelButton1 = lower; state.barrelButton2 = upper
    state.pressure = pressure; state.tipDown = pressure > 0
    return state
}
private func relativeConfig() -> WacomdConfig {
    var config = WacomdConfig(); config.penMode = .relative
    return config
}

final class PenMotionTests: XCTestCase {
    private let model = TestModel()

    func testOldConfigAndOptInRoundTrip() throws {
        let old = try JSONDecoder().decode(WacomdConfig.self, from: Data("{}".utf8))
        XCTAssertEqual(old.penMode, .absolute)
        XCTAssertEqual(old.penScrollButton, .disabled)
        var config = relativeConfig(); config.penScrollButton = .upper
        config.penSensitivityX = 25; config.penScrollTapMiddleClick = false
        XCTAssertEqual(try JSONDecoder().decode(WacomdConfig.self, from: JSONEncoder().encode(config)), config)
    }

    func testRelativeOriginAndPhysicalSensitivity() {
        var motion = PenMotion(); var config = relativeConfig(); config.penSensitivityY = 10
        XCTAssertEqual(motion.update(state: pen(), model: model, config: config, now: 0).delta, .zero)
        XCTAssertEqual(motion.update(state: pen(1020, 1040), model: model, config: config, now: 0.01).delta,
                       CGPoint(x: 2, y: 2))
    }

    func testIdleLiftAndConfigChangesReanchor() {
        var motion = PenMotion(); var config = relativeConfig()
        _ = motion.update(state: pen(), model: model, config: config, now: 0)
        XCTAssertEqual(motion.update(state: pen(2000), model: model, config: config, now: 0.2).delta, .zero)
        XCTAssertEqual(motion.update(state: pen(2020), model: model, config: config, now: 0.21).delta.x, 2)
        var leave = pen(); leave.inRange = false
        _ = motion.update(state: leave, model: model, config: config, now: 0.22)
        XCTAssertEqual(motion.update(state: pen(5000), model: model, config: config, now: 0.23).delta, .zero)
        config.penSensitivityX = 40
        XCTAssertEqual(motion.update(state: pen(6000), model: model, config: config, now: 0.24).delta, .zero)
        XCTAssertEqual(motion.update(state: pen(6020), model: model, config: config, now: 0.25).delta.x, 4)
    }

    func testScrollFreezesAndReleaseResumesWithoutJump() {
        var motion = PenMotion(); var config = relativeConfig(); config.penScrollButton = .upper
        _ = motion.update(state: pen(), model: model, config: config, now: 0)
        let press = motion.update(state: pen(1000, upper: true), model: model, config: config, now: 0.01)
        XCTAssertTrue(press.buttonScrolling); XCTAssertEqual(press.delta, .zero)
        let scroll = motion.update(state: pen(1100, 1100, upper: true), model: model, config: config, now: 0.02)
        XCTAssertEqual(scroll.delta, .zero); XCTAssertEqual(scroll.scroll, CGPoint(x: -6, y: -6))
        let release = motion.update(state: pen(1200, 1200), model: model, config: config, now: 0.03)
        XCTAssertEqual(release.delta, .zero); XCTAssertEqual(release.scroll, .zero); XCTAssertFalse(release.middleClick)
        let next = motion.update(state: pen(1220, 1200), model: model, config: config, now: 0.04)
        XCTAssertEqual(next.delta, CGPoint(x: 2, y: 0))
    }

    func testStationaryTapIsDeferredAndLongHoldDoesNotClick() {
        var motion = PenMotion(); var config = relativeConfig(); config.penScrollButton = .upper
        _ = motion.update(state: pen(), model: model, config: config, now: 0)
        XCTAssertFalse(motion.update(state: pen(1000, upper: true), model: model, config: config, now: 0.01).middleClick)
        XCTAssertTrue(motion.update(state: pen(1002), model: model, config: config, now: 0.05).middleClick)
        XCTAssertFalse(motion.update(state: pen(1002), model: model, config: config, now: 0.06).middleClick)
        _ = motion.update(state: pen(1002, upper: true), model: model, config: config, now: 0.07)
        for i in 1...6 {
            _ = motion.update(state: pen(1002, upper: true), model: model, config: config, now: 0.07 + Double(i) * 0.09)
        }
        XCTAssertFalse(motion.update(state: pen(1002), model: model, config: config, now: 0.62).middleClick)
    }

    func testReturningScrollPressureAndProximityNeverClick() {
        var motion = PenMotion(); var config = relativeConfig(); config.penScrollButton = .upper
        _ = motion.update(state: pen(), model: model, config: config, now: 0)
        _ = motion.update(state: pen(1000, upper: true), model: model, config: config, now: 0.01)
        _ = motion.update(state: pen(1100, upper: true), model: model, config: config, now: 0.02)
        XCTAssertFalse(motion.update(state: pen(1000), model: model, config: config, now: 0.03).middleClick)
        _ = motion.update(state: pen(1000, upper: true, pressure: 0.2), model: model, config: config, now: 0.04)
        XCTAssertFalse(motion.update(state: pen(), model: model, config: config, now: 0.05).middleClick)
        _ = motion.update(state: pen(1000, upper: true), model: model, config: config, now: 0.06)
        var leave = pen(); leave.inRange = false
        _ = motion.update(state: leave, model: model, config: config, now: 0.07)
        XCTAssertFalse(motion.update(state: pen(), model: model, config: config, now: 0.08).middleClick)
    }

    func testFractionalWheelAccumulationAndDirection() {
        var motion = PenMotion(); var config = relativeConfig()
        config.penScrollButton = .lower; config.penScrollNatural = false
        _ = motion.update(state: pen(), model: model, config: config, now: 0)
        _ = motion.update(state: pen(1000, lower: true), model: model, config: config, now: 0.01)
        var total = motion.update(state: pen(1062, lower: true), model: model, config: config, now: 0.02).scroll.x
        for i in 1...9 {
            total += motion.update(state: pen(1062 + Double(i) * 2, lower: true), model: model,
                                   config: config, now: 0.02 + Double(i) * 0.001).scroll.x
        }
        XCTAssertEqual(total, 4)
    }

    func testInvalidInputResetsAndDoesNotProduceMotion() {
        var motion = PenMotion(); let config = relativeConfig()
        _ = motion.update(state: pen(), model: model, config: config, now: 0)
        XCTAssertEqual(motion.update(state: pen(.nan), model: model, config: config, now: 0.01).delta, .zero)
        XCTAssertEqual(motion.update(state: pen(9000), model: model, config: config, now: 0.02).delta, .zero)
    }

    func testActualRelativeEventsPreservePressureAndReleaseButtons() {
        let injector = EventInjector(); let config = relativeConfig()
        var now = 1.0; var cursor = CGPoint(x: 500, y: 400); var events: [CGEvent] = []
        injector.clock = { now }; injector.configProvider = { config }; injector.cursorPositionProvider = { cursor }
        injector.eventPoster = { event in
            events.append(event)
            if [.mouseMoved, .leftMouseDown, .leftMouseDragged].contains(event.type) { cursor = event.location }
        }
        injector.update(state: pen(), model: model)
        now += 0.01; injector.update(state: pen(1020, pressure: 0.5), model: model)
        let down = events.first { $0.type == .leftMouseDown }!
        XCTAssertEqual(down.location, CGPoint(x: 502, y: 400))
        XCTAssertEqual(down.getDoubleValueField(.tabletEventPointPressure), 0.5, accuracy: 0.001)
        now += 0.01; injector.update(state: pen(1020, lower: true, pressure: 0.5), model: model)
        var leave = pen(); leave.inRange = false
        now += 0.01; injector.update(state: leave, model: model)
        XCTAssertEqual(events.filter { $0.type == .leftMouseUp }.count, 1)
        XCTAssertEqual(events.filter { $0.type == .rightMouseUp }.count, 1)
    }

    func testActualUpperScrollConsumesButtonAndTipWithoutReleaseJump() {
        let injector = EventInjector(); var config = relativeConfig(); config.penScrollButton = .upper
        var now = 1.0; var events: [CGEvent] = []; let cursor = CGPoint(x: 500, y: 400)
        injector.clock = { now }; injector.configProvider = { config }; injector.cursorPositionProvider = { cursor }
        injector.eventPoster = { events.append($0) }
        injector.update(state: pen(), model: model)
        now += 0.01; injector.update(state: pen(1000, upper: true), model: model)
        now += 0.01; injector.update(state: pen(1100, upper: true, pressure: 0.5), model: model)
        now += 0.01; injector.update(state: pen(1100), model: model)
        XCTAssertTrue(events.contains { $0.type == .scrollWheel })
        XCTAssertFalse(events.contains { [.leftMouseDown, .rightMouseDown, .otherMouseDown, .mouseMoved].contains($0.type) })
        now += 0.01; injector.update(state: pen(1120), model: model)
        XCTAssertEqual(events.last { $0.type == .mouseMoved }!.location, CGPoint(x: 502, y: 400))
    }

    func testActualStationaryUpperTapPostsOnlyOneMiddleClickPair() {
        let injector = EventInjector(); var config = relativeConfig(); config.penScrollButton = .upper
        var now = 1.0; var events: [CGEvent] = []
        injector.clock = { now }; injector.configProvider = { config }
        injector.cursorPositionProvider = { CGPoint(x: 500, y: 400) }
        injector.eventPoster = { events.append($0) }
        injector.update(state: pen(), model: model)
        now += 0.01; injector.update(state: pen(1000, upper: true), model: model)
        now += 0.01; injector.update(state: pen(), model: model)
        let middle = events.filter { [.otherMouseDown, .otherMouseUp].contains($0.type) }
        XCTAssertEqual(middle.count, 2)
        XCTAssertTrue(middle.allSatisfy { $0.getIntegerValueField(.mouseEventButtonNumber) == 2 })
        XCTAssertFalse(events.contains { $0.type == .rightMouseDown || $0.type == .scrollWheel })
    }
}
