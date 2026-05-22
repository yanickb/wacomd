import Foundation

/// One finger contact on the tablet surface.
struct TouchContact: Equatable {
    let slotID: Int
    let inContact: Bool
    /// Absolute X / Y on the touch surface, in raw 12-bit units
    /// (0..maxTouchAxis ≈ 4095).
    let x: Int
    let y: Int
}

/// Logical max of the 12-bit touch coordinates on a PTH-451.
let maxTouchAxis: Int = 4095

/// Decoder for the multi-touch reports of the Wacom Intuos Pro family.
///
/// Empirical format observed on a PTH-451 over USB on macOS 26 :
///
/// ```
///   data[0] : 0x02 (Report ID, shared with the pen interface)
///   data[1] : status byte
///             - 0x01 + data[2]=0x81 → idle keepalive (no fingers)
///             - 0x01 + data[2]=0x02 → pen-related info, ignore here
///             - 0x02                → multi-touch frame, N fingers active
///   data[2..9]   : finger slot 1 (8 bytes)
///   data[10..17] : finger slot 2 (8 bytes)
///   …
///   each slot :
///     [+0] : slot ID (0x02, 0x03, … non-zero when in contact)
///     [+1..+4] : position bytes (encoding undocumented; treated as opaque
///                pair of 16-bit values for delta tracking)
///     [+5..+7] : flags / pressure / padding
/// ```
///
/// We don't try to convert the position bytes to absolute X/Y in tablet
/// units because the encoding isn't fully characterised yet and would need
/// many more capture frames to nail down. For 2-finger scroll we only need
/// frame-to-frame deltas, which work just as well on the raw bytes.
enum IntuosProTouchParser {

    /// Distinguishes the touch interface from the pen interface.
    /// Both expose Report ID 2 but the touch interface lives on this
    /// vendor page.
    static let interfaceUsagePage = 0xff00

    private static let bytesPerSlot = 8
    private static let headerBytes = 2
    private static let maxSlots = 5

    static func decode(data: UnsafeMutablePointer<UInt8>, length: Int) -> [TouchContact] {
        guard length >= headerBytes + bytesPerSlot else { return [] }

        // Status byte = number of fingers currently in contact :
        //   0x01 + data[2] == 0x81 : idle keepalive (no finger)
        //   0x01                    : 1 finger
        //   0x02                    : 2 fingers
        //   0x03                    : 3 fingers
        // Bytes after the active slots are stale data we MUST NOT read,
        // otherwise the cursor / scroll picks up phantom contacts that
        // make it jump around.
        let status = data[1]
        let secondByte = data[2]
        if status == 0x01 && secondByte == 0x81 { return [] }
        if status == 0x00 { return [] }
        if status >= 0x80 { return [] }   // pen-interface heartbeat, ignore

        let numFingers = min(Int(status), maxSlots)
        guard numFingers > 0 else { return [] }

        var contacts: [TouchContact] = []
        for slot in 0..<numFingers {
            let off = headerBytes + slot * bytesPerSlot
            guard off + 7 < length else { break }

            let slotID = Int(data[off])
            // A real finger slot has a small slot ID (0x02..0x10) and
            // non-zero "pressure" byte at +5. Anything else is a stale
            // record left over by the firmware.
            let pressureByte = data[off + 5]
            let validSlotID = (slotID >= 0x02 && slotID < 0x20)
            if !validSlotID || pressureByte == 0 { continue }

            // Real format observed in a verbose capture of a user horizontal
            // swipe : 12-bit X and Y, asymmetric packing where the low
            // nibble of the high byte of each axis lives in a SEPARATE
            // companion byte.
            //
            //   X = (b[+2] << 4) | (b[+1] >> 4)      // max ≈ 4095
            //   Y = (b[+3] << 4) | (b[+4] >> 4)
            //
            // The middle byte holds the high 8 bits of position, the
            // adjacent byte holds 4 bits of refinement in its high nibble.
            // (b[+1] and b[+4] also have a low nibble that's pure noise /
            // status — we discard it.)
            let b1 = Int(data[off + 1])
            let b2 = Int(data[off + 2])
            let b3 = Int(data[off + 3])
            let b4 = Int(data[off + 4])
            let x = (b2 << 4) | (b1 >> 4)
            let y = (b3 << 4) | (b4 >> 4)

            if Verbose.enabled {
                let raw = (0..<8).map { String(format: "%02x", data[off + $0]) }.joined(separator: " ")
                Verbose.log("touch slot=\(slotID) bytes=[\(raw)] → x=\(x) y=\(y)")
            }

            contacts.append(TouchContact(
                slotID: slotID,
                inContact: true,
                x: x,
                y: y
            ))
        }
        return contacts
    }
}
