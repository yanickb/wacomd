import Foundation

struct PenState {
    var x: Double = 0
    var y: Double = 0
    var pressure: Double = 0
    var tiltX: Double = 0
    var tiltY: Double = 0
    var inRange: Bool = false
    var tipDown: Bool = false
    /// Side button closest to the tip (status bit 0x02).
    var lowerButton: Bool = false
    /// Side button farthest from the tip (status bit 0x04).
    var upperButton: Bool = false
    var eraser: Bool = false
}

enum ToolKind {
    case pen
    case eraser
}
