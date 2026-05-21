import XCTest
@testable import wacomd

/// Vecteurs de test issus de captures HID réelles d'une PTH-451 (toutes les
/// frames débutent par l'octet `0x02` qui est le Report ID).
final class IntuosProParserTests: XCTestCase {

    /// Décode un tableau d'octets via le parseur.
    private func decode(_ bytes: [UInt8]) -> IntuosProParser.Result {
        var buffer = bytes
        return buffer.withUnsafeMutableBufferPointer { buf in
            IntuosProParser.decode(reportID: UInt32(buf.baseAddress!.pointee),
                                   data: buf.baseAddress!,
                                   length: buf.count)
        }
    }

    func testRealPenSampleWithPressure() {
        // Frame capturée en live, pen pressant la surface :
        //   02 e0 0f 6c 1a 37 91 e6 52 43
        let res = decode([0x02, 0xe0, 0x0f, 0x6c, 0x1a, 0x37, 0x91, 0xe6, 0x52, 0x43])
        guard case .pen(let s) = res else {
            return XCTFail("attendu .pen, obtenu \(res)")
        }
        // Vérifications calculées manuellement à partir des formules Intuos Pro
        XCTAssertEqual(s.x, (0x0f << 9) | (0x6c << 1) | ((0x43 >> 1) & 1))   // 7897
        XCTAssertEqual(s.y, (0x1a << 9) | (0x37 << 1) | (0x43 & 1))           // 6767
        XCTAssertEqual(s.pressure,
                       (((0x91 << 2) | ((0xe6 >> 6) & 3)) << 1) | (0xe0 & 1)) // 1166
        XCTAssertTrue(s.tipDown, "pression > seuil → tip-switch attendu")
        XCTAssertEqual(s.distance, (0x43 >> 2) & 0x3f)
    }

    func testHoverPacketHasZeroPressureAndNoTip() {
        // Frame avec pression nulle (pen en survol) :
        //   02 e0 22 9d 1f 3f 00 22 52 64
        let res = decode([0x02, 0xe0, 0x22, 0x9d, 0x1f, 0x3f, 0x00, 0x22, 0x52, 0x64])
        guard case .pen(let s) = res else {
            return XCTFail("attendu .pen, obtenu \(res)")
        }
        XCTAssertEqual(s.pressure, 0)
        XCTAssertFalse(s.tipDown)
    }

    func testProximityLeaveRecognised() {
        // (data[1] & 0xfe) == 0x80 → sortie de proximité.
        let res = decode([0x02, 0x80, 0, 0, 0, 0, 0, 0, 0, 0])
        guard case .proximityLeave = res else {
            return XCTFail("attendu .proximityLeave, obtenu \(res)")
        }
    }

    func testProximityEnterDecodesToolID() {
        // (data[1] & 0xfc) == 0xc0 → entrée en proximité.
        // Octets choisis pour produire un toolID non-nul.
        let res = decode([0x02, 0xc2,
                          0x80, 0x10,
                          0x00, 0x00, 0x00, 0x02,
                          0x30, 0x00])
        guard case .proximityEnter(let toolID, _) = res else {
            return XCTFail("attendu .proximityEnter, obtenu \(res)")
        }
        XCTAssertNotEqual(toolID, 0)
    }

    func testWrongLengthIsIgnored() {
        let res = decode([0x02, 0xe0, 0x0f, 0x6c])  // tronqué
        guard case .ignored = res else {
            return XCTFail("attendu .ignored")
        }
    }

    func testWrongReportIDIsIgnored() {
        // Report ID 12 = pad (différent du pen, on ne le décode pas encore).
        let res = decode([0x0c, 0xe0, 0x0f, 0x6c, 0x1a, 0x37, 0x91, 0xe6, 0x52, 0x43])
        guard case .ignored = res else {
            return XCTFail("attendu .ignored")
        }
    }
}
