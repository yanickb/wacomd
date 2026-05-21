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

enum KnownModels {
    static let all: [WacomModel] = [
        IntuosProSmall()
    ]

    static func lookup(vendorID: Int, productID: Int) -> WacomModel? {
        all.first { $0.vendorID == vendorID && $0.productID == productID }
    }
}
