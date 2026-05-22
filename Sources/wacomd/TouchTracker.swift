import Foundation
import AppKit
import WacomdShared

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
///   - 3 fingers → swipe gestures (Mission Control / Spaces / App Exposé)
///                + tap → middle click
///   - 4+ fingers → ignored
final class TouchTracker {
    private let injector: EventInjector
    private var touches: [Int: ActiveTouch] = [:]
    private var lastScrollCentroid: (x: Double, y: Double)?

    /// 3-finger gesture state machine — tracks the initial 3-finger centroid
    /// position and whether a swipe has already fired during the current
    /// session (we only fire once per 3-finger touch event to avoid
    /// repeating Mission Control commands).
    private var threeFingerStart: (x: Double, y: Double, time: CFAbsoluteTime)?
    private var threeFingerSwipeFired: Bool = false

    private var config: WacomdConfig { ConfigStore.shared.current }
    private var tapMaxDuration: CFAbsoluteTime { CFAbsoluteTime(config.tapMaxDurationMs) / 1000 }
    private var tapMaxRawMovement: Double { config.tapMaxRawMovement }
    private var threeFingerSwipeThreshold: Double { config.threeFingerSwipeThreshold }
    private var cursorSensitivity: Double { config.cursorSensitivity }
    private var scrollSensitivity: Double { config.scrollSensitivity }

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

        // Releases → maybe a tap (1-finger or 3-finger)
        let releaseCount = releasedIDs.count
        for id in releasedIDs {
            guard let touch = touches.removeValue(forKey: id) else { continue }
            let duration = now - touch.startTime
            let isShortContact = duration <= tapMaxDuration
                              && touch.maxDistanceFromStart <= tapMaxRawMovement

            // 1-finger tap → left click
            if config.tapToClick
               && isShortContact && previousIDs.count == 1 && releaseCount == 1 {
                Verbose.log(String(format: "1-finger tap (duration=%.0fms, drift=%.0f)",
                                   duration * 1000, touch.maxDistanceFromStart))
                injector.tapClick()
            }
        }

        // 3-finger TAP : all 3 fingers released together within tapMaxDuration
        // without a swipe having fired during the contact.
        if config.threeFingerSwipes
           && previousIDs.count == 3 && touches.isEmpty
           && !threeFingerSwipeFired
           && threeFingerStart != nil
           && (now - threeFingerStart!.time) <= tapMaxDuration {
            Verbose.log("3-finger tap → middle click")
            injector.middleClick()
        }
        if touches.count != 3 {
            threeFingerStart = nil
            threeFingerSwipeFired = false
        }

        // Continuous behaviour based on current finger count
        switch touches.count {
        case 0:
            lastScrollCentroid = nil
        case 1:
            if config.oneFingerCursor, let delta = deltas.values.first {
                applyCursorDelta(dx: delta.dx, dy: delta.dy)
            }
            lastScrollCentroid = nil
        case 2:
            if config.twoFingerScroll {
                handleTwoFingerScroll()
            } else {
                lastScrollCentroid = nil
            }
        case 3:
            if config.threeFingerSwipes {
                handleThreeFingerSwipe(now: now)
            }
            lastScrollCentroid = nil
        default:
            lastScrollCentroid = nil
        }
    }

    // MARK: - 1-finger cursor (relative)

    private func applyCursorDelta(dx: Int, dy: Int) {
        // Sensor jitter regularly produces ±1 deltas on a stationary finger.
        // Filter them so we don't a) pollute the cursor with noise and
        // b) tag the contact as "moved" and accidentally suppress real taps.
        guard abs(dx) > 1 || abs(dy) > 1 else { return }
        let screenDx = Double(dx) * cursorSensitivity
        let screenDy = Double(dy) * cursorSensitivity
        injector.moveCursorBy(dx: screenDx, dy: screenDy)
    }

    // MARK: - 3-finger swipe (centroid trajectory → key combo)

    private func handleThreeFingerSwipe(now: CFAbsoluteTime) {
        let fingers = Array(touches.values)
        guard fingers.count == 3 else { return }

        let cx = fingers.map { Double($0.lastRaw.x) }.reduce(0, +) / 3
        let cy = fingers.map { Double($0.lastRaw.y) }.reduce(0, +) / 3

        if threeFingerStart == nil {
            threeFingerStart = (x: cx, y: cy, time: now)
            threeFingerSwipeFired = false
            return
        }
        // Once a swipe has fired we wait until all fingers lift before
        // looking again, so a single 3-finger drag doesn't spam keys.
        if threeFingerSwipeFired { return }

        let dx = cx - threeFingerStart!.x
        let dy = cy - threeFingerStart!.y
        let absDx = abs(dx)
        let absDy = abs(dy)

        // Pick the dominant axis ; trigger only if it exceeds the threshold.
        if max(absDx, absDy) < threeFingerSwipeThreshold { return }

        threeFingerSwipeFired = true

        if absDx > absDy {
            // Horizontal swipe → switch Space
            if dx > 0 {
                Verbose.log("3-finger swipe → (Ctrl+→)")
                injector.postKeyCombo(keyCode: 0x7C /* RightArrow */,
                                      modifiers: .maskControl)
            } else {
                Verbose.log("3-finger swipe ← (Ctrl+←)")
                injector.postKeyCombo(keyCode: 0x7B /* LeftArrow */,
                                      modifiers: .maskControl)
            }
        } else {
            // Vertical swipe → Mission Control vs App Exposé
            if dy < 0 {
                Verbose.log("3-finger swipe ↑ (Ctrl+↑ = Mission Control)")
                injector.postKeyCombo(keyCode: 0x7E /* UpArrow */,
                                      modifiers: .maskControl)
            } else {
                Verbose.log("3-finger swipe ↓ (Ctrl+↓ = App Exposé)")
                injector.postKeyCombo(keyCode: 0x7D /* DownArrow */,
                                      modifiers: .maskControl)
            }
        }
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
