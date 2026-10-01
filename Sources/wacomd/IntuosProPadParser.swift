import Foundation

/// Decoder for the pad report (6 ExpressKeys + Touch Ring) of the
/// Intuos5 / Intuos Pro family, including the PTH-451.
///
/// The pad does NOT have its own HID interface: it shares the pen interface
/// (page 0xff0d) and arrives on its own Report ID (3), 10 bytes long.
/// Layout matches `wacom_intuos_pad` in Linux `drivers/hid/wacom_wac.c`
/// (INTUOS5S..INTUOSPL branch), validated against live PTH-451 captures:
///
///   buf[0] = 0x03 (Report ID)
///   buf[1] = 0x80
///   buf[2] = Touch Ring : bit 7 = finger on ring, bits 0..6 = position
///   buf[3] = bit 0 = Touch Ring centre button
///   buf[4] = ExpressKeys mechanical switches, bit n = key n+1 (top → bottom)
///   buf[5] = ExpressKeys capacitive sensors (finger resting on a key)
enum IntuosProPadParser {

    static let reportID: UInt32 = 3
    static let expressKeyCount = 6

    struct PadSample: Equatable {
        /// Pressed ExpressKeys, bit n = key n+1 (top → bottom).
        var keys: UInt8
        /// Keys being touched (capacitive), same bit layout. Not acted upon.
        var keysTouched: UInt8
        var ringCenterButton: Bool
        /// Ring position 0..127, nil when no finger is on the ring.
        var ringPosition: Int?

        func isPressed(key index: Int) -> Bool {
            keys & (1 << index) != 0
        }
    }

    static func decode(reportID: UInt32, data: UnsafeMutablePointer<UInt8>, length: Int) -> PadSample? {
        guard reportID == Self.reportID, length >= 6 else { return nil }
        let keyMask = UInt8((1 << expressKeyCount) - 1)
        let ring = data[2]
        return PadSample(
            keys: data[4] & keyMask,
            keysTouched: data[5] & keyMask,
            ringCenterButton: data[3] & 0x01 != 0,
            ringPosition: ring & 0x80 != 0 ? Int(ring & 0x7f) : nil
        )
    }
}
