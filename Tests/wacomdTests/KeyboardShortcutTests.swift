import XCTest
import CoreGraphics
@testable import wacomd

final class KeyboardShortcutTests: XCTestCase {
    func testAllArrowChordsCarrySymbolicHotkeyFlagsOnDownAndUp() throws {
        for key: CGKeyCode in [0x7B, 0x7C, 0x7D, 0x7E] {
            let (down, up) = try XCTUnwrap(EventInjector.keyComboEvents(keyCode: key, modifiers: .maskControl))
            XCTAssertEqual(down.type, .keyDown)
            XCTAssertEqual(up.type, .keyUp)
            for event in [down, up] {
                XCTAssertEqual(event.getIntegerValueField(.keyboardEventKeycode), Int64(key))
                XCTAssertEqual(event.flags.rawValue, 0x840000)
            }
        }
    }

    func testNonArrowChordsPreserveRequestedModifiers() throws {
        let (down, up) = try XCTUnwrap(EventInjector.keyComboEvents(keyCode: 0, modifiers: .maskCommand))
        XCTAssertEqual(down.flags, .maskCommand)
        XCTAssertEqual(up.flags, .maskCommand)
    }
}
