import Foundation

struct PenState {
    var x: Double = 0
    var y: Double = 0
    var pressure: Double = 0
    var tiltX: Double = 0
    var tiltY: Double = 0
    var inRange: Bool = false
    var tipDown: Bool = false
    var barrelButton: Bool = false
    var eraser: Bool = false
}

enum ToolKind {
    case pen
    case eraser
}
