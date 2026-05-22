import Foundation

/// One finger contact on the tablet surface.
struct TouchContact: Equatable {
    let slotID: Int
    let inContact: Bool
    /// Opaque 32-bit position derived from the 4 position bytes of the
    /// slot. The exact X/Y semantics aren't documented but stay consistent
    /// frame-to-frame, which is all we need for delta-based scroll.
    let positionA: Int   // bytes [+1..+2] interpreted as 16-bit big-endian
    let positionB: Int   // bytes [+3..+4] interpreted as 16-bit big-endian
}

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

        let status = data[1]
        // Only status 0x02 carries multi-touch finger data on this firmware.
        guard status == 0x02 else { return [] }

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

            let positionA = (Int(data[off + 1]) << 8) | Int(data[off + 2])
            let positionB = (Int(data[off + 3]) << 8) | Int(data[off + 4])

            contacts.append(TouchContact(
                slotID: slotID,
                inContact: true,
                positionA: positionA,
                positionB: positionB
            ))
        }
        return contacts
    }
}
