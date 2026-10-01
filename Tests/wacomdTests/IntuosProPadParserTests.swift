import XCTest
import WacomdShared
@testable import wacomd

/// Vectors captured live from a PTH-451 (pen interface, Report ID 3).
final class IntuosProPadParserTests: XCTestCase {

    private func decode(_ bytes: [UInt8]) -> IntuosProPadParser.PadSample? {
        var buffer = bytes
        return buffer.withUnsafeMutableBufferPointer { buf in
            IntuosProPadParser.decode(reportID: UInt32(buf.baseAddress!.pointee),
                                      data: buf.baseAddress!,
                                      length: buf.count)
        }
    }

    func testEachExpressKeyPressMapsToItsBit() {
        // Key n pressed: buf[4] = buf[5] = 1 << (n-1)
        let captures: [UInt8] = [0x01, 0x02, 0x04, 0x08, 0x10, 0x20]
        for (i, bit) in captures.enumerated() {
            let pad = decode([0x03, 0x80, 0x00, 0x00, bit, bit, 0x00, 0x00, 0x00, 0x00])
            XCTAssertNotNil(pad)
            for k in 0..<6 {
                XCTAssertEqual(pad!.isPressed(key: k), k == i, "key \(i + 1), bit \(k)")
            }
        }
    }

    func testCapacitiveTouchIsNotAPress() {
        // Finger resting on key 1, not pressed: 03 80 00 00 00 01 …
        let pad = decode([0x03, 0x80, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00])
        XCTAssertEqual(pad?.keys, 0)
        XCTAssertEqual(pad?.keysTouched, 0x01)
    }

    func testTouchRingAndCenterButton() {
        let ring = decode([0x03, 0x80, 0xae, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        XCTAssertEqual(ring?.ringPosition, 0x2e)
        XCTAssertEqual(ring?.ringCenterButton, false)

        let center = decode([0x03, 0x80, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        XCTAssertNil(center?.ringPosition)
        XCTAssertEqual(center?.ringCenterButton, true)
    }

    func testPenReportIsNotAPadReport() {
        XCTAssertNil(decode([0x02, 0xe0, 0x0f, 0x6c, 0x1a, 0x37, 0x91, 0xe6, 0x52, 0x43]))
    }

    func testOldConfigWithoutExpressKeysStillDecodes() throws {
        let json = #"{ "touchEnabled" : false }"#.data(using: .utf8)!
        let config = try JSONDecoder().decode(WacomdConfig.self, from: json)
        XCTAssertFalse(config.touchEnabled)
        XCTAssertEqual(config.expressKeys.count, 6)
        XCTAssertTrue(config.expressKeys.allSatisfy { $0.action == .none })
    }

    func testBindingsDecodeFromJSON() throws {
        let json = #"""
        { "expressKeys" : [ { "action" : "toggleTouch" }, { "action" : "cycleDisplay" },
                            { "action" : "keyCombo", "keyCode" : 6, "modifiers" : ["cmd"] } ] }
        """#.data(using: .utf8)!
        let keys = try JSONDecoder().decode(WacomdConfig.self, from: json).expressKeys
        XCTAssertEqual(keys.map(\.action), [.toggleTouch, .cycleDisplay, .keyCombo])
        XCTAssertEqual(keys[2].keyCode, 6)
        XCTAssertEqual(keys[2].modifiers, ["cmd"])
    }

    func testModifierNamesMapToEventFlags() {
        XCTAssertEqual(WacomDevice.eventFlags(["cmd", "Shift"]), [.maskCommand, .maskShift])
        XCTAssertEqual(WacomDevice.eventFlags(["alt", "ctrl"]), [.maskAlternate, .maskControl])
    }
}
