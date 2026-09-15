import Foundation

protocol WacomModel {
    var name: String { get }
    var vendorID: Int { get }
    var productID: Int { get }
    var maxX: Double { get }
    var maxY: Double { get }
    var maxPressure: Double { get }
    var maxTilt: Double { get }
    var widthMM: Double { get }
    var heightMM: Double { get }
    /// Bit of each pad ExpressKey (left to right) in the button message of
    /// the touch interface. Empty when the pad isn't readable.
    var padButtonMasks: [UInt8] { get }
}

extension WacomModel {
    var padButtonMasks: [UInt8] { [] }
}

struct IntuosProSmall: WacomModel {
    let name = "Wacom Intuos Pro Small (PTH-451)"
    let vendorID = 0x056a
    let productID = 0x0314
    let maxX: Double = 31496
    let maxY: Double = 19685
    let maxPressure: Double = 2047
    let maxTilt: Double = 60
    let widthMM: Double = 157.0
    let heightMM: Double = 98.0
}

/// Intuos S 2015 (CTL-490, annoncée "Intuos PS" par le firmware).
/// Valeurs reprises de `wacom_features_0x33B` du pilote Linux (INTUOSHT2) :
/// même protocole pen que les Intuos Pro, pas de tilt.
struct IntuosSmall2: WacomModel {
    let name = "Wacom Intuos S 2 (CTL-490)"
    let vendorID = 0x056a
    let productID = 0x033b
    let maxX: Double = 15200
    let maxY: Double = 9500
    let maxPressure: Double = 2047
    let maxTilt: Double = 0
    let widthMM: Double = 152.0
    let heightMM: Double = 95.0
    // Relevé sur une CTL-490 : 4e touche = 0x04, 3e = 0x08.
    let padButtonMasks: [UInt8] = [0x01, 0x02, 0x08, 0x04]
}

enum KnownModels {
    static let all: [WacomModel] = [
        IntuosProSmall(),
        IntuosSmall2()
    ]

    static func lookup(vendorID: Int, productID: Int) -> WacomModel? {
        all.first { $0.vendorID == vendorID && $0.productID == productID }
    }
}
