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

/// Logical max of the 12-bit packed touch coordinates.
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

        // Status byte indicates approximate number of contacts :
        //   0x01 + data[2] == 0x81 : idle keepalive, no finger
        //   0x01 + data[2] != 0x81 : 1 finger active
        //   0x02                   : 2 fingers
        //   0x03                   : 3 fingers
        // In all "active" cases the per-slot layout below is identical,
        // so we just need to make sure we don't decode the idle keepalive.
        let status = data[1]
        let secondByte = data[2]
        let isIdleKeepalive = (status == 0x01 && secondByte == 0x81)
        if isIdleKeepalive { return [] }
        if status == 0x00 { return [] }
        // Status >= 0x80 are pen-interface heartbeats we don't care about.
        if status >= 0x80 { return [] }

        var contacts: [TouchContact] = []
        for slot in 0..<maxSlots {
            let off = headerBytes + slot * bytesPerSlot
            guard off + 7 < length else { break }

            let slotID = Int(data[off])
            if slotID == 0 { continue }

            // "Active contact" criterion empirically derived :
            //  - real-finger slots have bytes [+5..+7] = `02 0X 00`
            //  - just-released "ghost" slots have bytes [+5..+7] = `00 00 00`
            //    and a slot ID with bit 7 set (e.g. 0x81).
            // We treat byte+5 == 0 OR slotID high-bit set as "not in
            // contact" — these slots carry no usable position.
            let pressureByte = data[off + 5]
            let ghosted = (slotID & 0x80) != 0
            if pressureByte == 0 || ghosted { continue }

            // 12-bit X/Y packed across 3 bytes (Intuos5 touch layout) :
            //   X = (b[1] << 4)  | (b[2] >> 4)
            //   Y = ((b[2] & 0x0f) << 8) | b[3]
            // Max ≈ 4095 on each axis.
            let b1 = Int(data[off + 1])
            let b2 = Int(data[off + 2])
            let b3 = Int(data[off + 3])
            let x = (b1 << 4) | (b2 >> 4)
            let y = ((b2 & 0x0f) << 8) | b3

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
