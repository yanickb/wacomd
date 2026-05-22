import Foundation
import AppKit

/// Per-finger state we maintain across HID frames. Positions are kept in
/// raw tablet units (0..maxTouchAxis) because the multi-touch surface
/// drives the cursor in RELATIVE / trackpad mode, not as an absolute
/// digitizer like the pen.
private struct ActiveTouch {
    let slotID: Int
    let startTime: CFAbsoluteTime
    let startRaw: (x: Int, y: Int)
    var lastRaw: (x: Int, y: Int)
    var maxDistanceFromStart: Double   // in raw tablet units
}

/// Trackpad-style handler for the multi-touch surface :
///   - 1 finger drag → cursor moves by the same delta (relative mode)
///   - 1 finger quick tap (< 200 ms, < tapMaxRawMovement units) → left-click
///   - 2 fingers drag → scroll on the cursor's current position
///   - 3+ fingers → ignored
final class TouchTracker {
    private let injector: EventInjector
    private var touches: [Int: ActiveTouch] = [:]
    private var lastScrollCentroid: (x: Double, y: Double)?

    /// Tap recognised if : duration < `tapMaxDuration` AND max raw-unit
    /// displacement during the contact < `tapMaxRawMovement`.
    private let tapMaxDuration: CFAbsoluteTime = 0.20
    /// In raw tablet units (~4095 = full tablet). 60 units ≈ 1.5 mm — tight
    /// enough to reject accidental drags while letting natural taps through.
    private let tapMaxRawMovement: Double = 60

    /// Cursor sensitivity, in screen pixels per raw tablet unit.
    /// 0.35 → a 1-inch finger swipe (~800 raw units on a PTH-451) moves the
    /// cursor by ~280 px, roughly matching a MacBook trackpad in its
    /// "Tracking speed = 5/10" preset.
    private let cursorSensitivity: Double = 0.35

    /// Scroll sensitivity, in scroll pixels per raw tablet unit.
    /// Slightly above cursor sensitivity since scroll typically traverses
    /// more screen distance per finger swipe than cursor moves.
    private let scrollSensitivity: Double = 0.5
    private let scrollDeadZoneRaw: Double = 4
    private let scrollMaxPerEvent: Double = 120

    init(injector: EventInjector) {
        self.injector = injector
    }

    // MARK: - Frame handler

    func handleFrame(contacts: [TouchContact]) {
        let now = CFAbsoluteTimeGetCurrent()

        let activeIDs = Set(contacts.filter { $0.inContact }.map { $0.slotID })
        let previousIDs = Set(touches.keys)
        let appearedIDs = activeIDs.subtracting(previousIDs)
        let releasedIDs = previousIDs.subtracting(activeIDs)

        // Register newly-arrived contacts
        for id in appearedIDs {
            guard let contact = contacts.first(where: { $0.slotID == id && $0.inContact }) else { continue }
            touches[id] = ActiveTouch(
                slotID: id,
                startTime: now,
                startRaw: (contact.x, contact.y),
                lastRaw: (contact.x, contact.y),
                maxDistanceFromStart: 0
            )
        }

        // Compute per-finger deltas and update positions
        var deltas: [Int: (dx: Int, dy: Int)] = [:]
        for contact in contacts where contact.inContact {
            guard var touch = touches[contact.slotID] else { continue }
            let dx = contact.x - touch.lastRaw.x
            let dy = contact.y - touch.lastRaw.y
            deltas[contact.slotID] = (dx, dy)

            let totalDx = Double(contact.x - touch.startRaw.x)
            let totalDy = Double(contact.y - touch.startRaw.y)
            let d = (totalDx * totalDx + totalDy * totalDy).squareRoot()
            touch.lastRaw = (contact.x, contact.y)
            touch.maxDistanceFromStart = max(touch.maxDistanceFromStart, d)
            touches[contact.slotID] = touch
        }

        // Releases → maybe a tap
        let releaseCount = releasedIDs.count
        for id in releasedIDs {
            guard let touch = touches.removeValue(forKey: id) else { continue }
            let duration = now - touch.startTime
            let wasTap = duration <= tapMaxDuration
                      && touch.maxDistanceFromStart <= tapMaxRawMovement
                      && previousIDs.count == 1  // ignore taps that were part of a 2-finger gesture
                      && releaseCount == 1
            if wasTap {
                Verbose.log(String(format: "tap detected (duration=%.0fms, drift=%.0f units)",
                                   duration * 1000, touch.maxDistanceFromStart))
                injector.tapClick()
            }
        }

        // Continuous behaviour based on current finger count
        switch touches.count {
        case 0:
            lastScrollCentroid = nil
        case 1:
            // 1-finger relative cursor drive
            if let delta = deltas.values.first {
                applyCursorDelta(dx: delta.dx, dy: delta.dy)
            }
            lastScrollCentroid = nil
        case 2:
            handleTwoFingerScroll()
        default:
            lastScrollCentroid = nil
        }
    }

    // MARK: - 1-finger cursor (relative)

    private func applyCursorDelta(dx: Int, dy: Int) {
        // Ignore zero-deltas (no movement frame)
        guard dx != 0 || dy != 0 else { return }
        let screenDx = Double(dx) * cursorSensitivity
        let screenDy = Double(dy) * cursorSensitivity
        injector.moveCursorBy(dx: screenDx, dy: screenDy)
    }

    // MARK: - 2-finger scroll (centroid delta in raw units)

    private func handleTwoFingerScroll() {
        let fingers = Array(touches.values)
        guard fingers.count == 2 else { return }
        let cx = Double(fingers[0].lastRaw.x + fingers[1].lastRaw.x) / 2.0
        let cy = Double(fingers[0].lastRaw.y + fingers[1].lastRaw.y) / 2.0
        defer { lastScrollCentroid = (cx, cy) }

        guard let prev = lastScrollCentroid else { return }
        let dx = cx - prev.x
        let dy = cy - prev.y
        if abs(dx) < scrollDeadZoneRaw && abs(dy) < scrollDeadZoneRaw { return }

        let scrollX = clamp(-dx * scrollSensitivity, -scrollMaxPerEvent, scrollMaxPerEvent)
        let scrollY = clamp(-dy * scrollSensitivity, -scrollMaxPerEvent, scrollMaxPerEvent)
        injector.scroll(dx: scrollX, dy: scrollY)
    }

    private func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        min(max(v, lo), hi)
    }
}
