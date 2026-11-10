import Foundation

/// Optional position-only filtering in physical units. Pressure, tilt and
/// button reports are never altered. Small continuous motion through the
/// three-sample median trails by one report; large motion bypasses it.
struct PenHoverFilter {
    private var anchor: CGPoint?
    private var previous: CGPoint?
    private var older: CGPoint?

    mutating func reset() {
        anchor = nil
        previous = nil
        older = nil
    }

    mutating func filter(_ position: CGPoint, mmPerUnit: CGPoint,
                         deadbandMM: Double, rejectSpikes: Bool,
                         hovering: Bool) -> CGPoint {
        guard hovering, deadbandMM.isFinite, deadbandMM > 0,
              position.x.isFinite, position.y.isFinite,
              mmPerUnit.x.isFinite, mmPerUnit.y.isFinite,
              mmPerUnit.x > 0, mmPerUnit.y > 0 else {
            reset()
            return position
        }
        let radius = min(deadbandMM, 1)
        func distanceSquared(_ a: CGPoint, _ b: CGPoint) -> Double {
            let dx = (a.x - b.x) * mmPerUnit.x
            let dy = (a.y - b.y) * mmPerUnit.y
            return dx * dx + dy * dy
        }
        var candidate = position
        if rejectSpikes {
            if let anchor = anchor, let previous = previous, let older = older,
               distanceSquared(position, anchor) <= 16 * radius * radius {
                func median(_ a: Double, _ b: Double, _ c: Double) -> Double {
                    max(min(a, b), min(max(a, b), c))
                }
                candidate = CGPoint(x: median(position.x, previous.x, older.x),
                                    y: median(position.y, previous.y, older.y))
                self.older = previous
            } else {
                older = position
            }
            previous = position
        } else {
            previous = nil
            older = nil
        }
        if let anchor = anchor, distanceSquared(candidate, anchor) <= radius * radius {
            return anchor
        }
        anchor = candidate
        return candidate
    }
}
