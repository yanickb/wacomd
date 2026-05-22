import Foundation
import AppKit

/// Per-finger state we maintain across HID frames.
private struct ActiveTouch {
    let slotID: Int
    let startTime: CFAbsoluteTime
    let startScreenPoint: CGPoint
    var lastScreenPoint: CGPoint
    var maxDistanceFromStart: Double
}

/// Translates the multi-touch surface into:
///   - 1 finger → cursor moves (absolute mapping)
///   - 1-finger quick tap → left-click at the touch start position
///   - 2 fingers → 2-axis scroll (centroid delta)
///   - 3+ fingers → ignored
final class TouchTracker {
    private let injector: EventInjector
    private var touches: [Int: ActiveTouch] = [:]
    private var lastScrollCentroidScreen: CGPoint?

    /// Tap recognised if : duration < `tapMaxDuration` AND
    /// max displacement during contact < `tapMaxMovementPx`.
    private let tapMaxDuration: CFAbsoluteTime = 0.20
    private let tapMaxMovementPx: Double = 10

    /// Sensitivity for 2-finger scroll, in scroll-pixels per screen-pixel of
    /// finger movement. ~0.3 matches the feel of a MacBook trackpad swipe :
    /// a full-tablet finger swipe scrolls roughly one page.
    private let scrollScale: Double = 0.3
    private let scrollDeadZone: Double = 1.0
    private let scrollMaxPerEvent: Double = 60

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
            let p = mapToScreen(touch: contact)
            touches[id] = ActiveTouch(
                slotID: id,
                startTime: now,
                startScreenPoint: p,
                lastScreenPoint: p,
                maxDistanceFromStart: 0
            )
        }

        // Update positions for still-present contacts
        for contact in contacts where contact.inContact {
            guard var touch = touches[contact.slotID] else { continue }
            let p = mapToScreen(touch: contact)
            let d = hypot(p.x - touch.startScreenPoint.x, p.y - touch.startScreenPoint.y)
            touch.lastScreenPoint = p
            touch.maxDistanceFromStart = max(touch.maxDistanceFromStart, Double(d))
            touches[contact.slotID] = touch
        }

        // Process releases (and tap detection)
        for id in releasedIDs {
            guard let touch = touches.removeValue(forKey: id) else { continue }
            let duration = now - touch.startTime
            let wasTap = duration <= tapMaxDuration
                      && touch.maxDistanceFromStart <= tapMaxMovementPx
                      && previousIDs.count == 1  // only count single-finger taps
            if wasTap {
                Verbose.log(String(format: "tap detected @ (%.0f, %.0f) duration=%.0fms",
                                   touch.startScreenPoint.x,
                                   touch.startScreenPoint.y,
                                   duration * 1000))
                injector.tapClick(at: touch.startScreenPoint)
            }
        }

        // Continuous behaviour based on the current finger count
        switch touches.count {
        case 0:
            lastScrollCentroidScreen = nil
        case 1:
            // 1-finger : drive the cursor in absolute mapping
            if let touch = touches.values.first {
                injector.moveCursor(to: touch.lastScreenPoint)
            }
            lastScrollCentroidScreen = nil
        case 2:
            // 2-finger : scroll
            handleTwoFingerScroll()
        default:
            // 3+ fingers : ignore (would need private SPI for gestures)
            lastScrollCentroidScreen = nil
        }
    }

    // MARK: - 2-finger scroll

    private func handleTwoFingerScroll() {
        let fingers = Array(touches.values)
        guard fingers.count == 2 else { return }
        let cx = (fingers[0].lastScreenPoint.x + fingers[1].lastScreenPoint.x) / 2
        let cy = (fingers[0].lastScreenPoint.y + fingers[1].lastScreenPoint.y) / 2
        let centroid = CGPoint(x: cx, y: cy)
        defer { lastScrollCentroidScreen = centroid }

        guard let prev = lastScrollCentroidScreen else { return }
        let dx = centroid.x - prev.x
        let dy = centroid.y - prev.y
        if abs(dx) < scrollDeadZone && abs(dy) < scrollDeadZone { return }

        let scrollY = clamp(-Double(dy) * scrollScale, -scrollMaxPerEvent, scrollMaxPerEvent)
        let scrollX = clamp(-Double(dx) * scrollScale, -scrollMaxPerEvent, scrollMaxPerEvent)
        injector.scroll(dx: scrollX, dy: scrollY)
    }

    // MARK: - Coordinate mapping

    /// Map touch surface coordinates (12-bit packed) onto the primary screen.
    private func mapToScreen(touch: TouchContact) -> CGPoint {
        let normX = Double(touch.x) / Double(maxTouchAxis)
        let normY = Double(touch.y) / Double(maxTouchAxis)
        let primary = NSScreen.screens.first ?? NSScreen.main
        let w = primary?.frame.width  ?? 1920
        let h = primary?.frame.height ?? 1080
        return CGPoint(x: normX * w, y: normY * h)
    }

    private func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        min(max(v, lo), hi)
    }
}
