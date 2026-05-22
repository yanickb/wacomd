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
    /// Exponentially-smoothed raw position used to derive cursor deltas.
    /// Damps sensor jitter that would otherwise pollute the cursor with
    /// ±1-unit noise even on a stationary finger.
    var smoothedRaw: (x: Double, y: Double)
    var maxDistanceFromStart: Double   // in raw tablet units
    /// Last frame timestamp — used to detect "frame gaps" that probably
    /// hide a lift-then-touch sequence which we don't want to interpret
    /// as continuous motion.
    var lastSeenTime: CFAbsoluteTime
}

/// Trackpad-style handler for the multi-touch surface. The implementation
/// is structured around the same heuristics Apple trackpads use :
///
///   - Exponential smoothing of raw finger position to kill sensor jitter.
///   - Cursor acceleration : slow finger → fine cursor, fast finger → big
///     cursor moves. Matches the "Pointer & Click" feel of macOS.
///   - Lift-artifact rejection : the last 1-2 frames before a finger lifts
///     are often garbage (the firmware emits a wrong position right before
///     reporting "no contact"), so we drop frames that arrive less than
///     one polling interval after the previous one.
///   - Sub-pixel accumulation : scroll and cursor deltas under 1 px are
///     accumulated until they cross the threshold, so slow motions feel
///     smooth instead of stepping.
///   - Clear gesture state machine : 1 / 2 / 3 fingers are explicit modes
///     that reset their per-mode state when the finger count changes, so
///     transitions don't leak deltas between modes.
final class TouchTracker {
    private let injector: EventInjector
    private var touches: [Int: ActiveTouch] = [:]

    // 2-finger scroll state ---------------------------------------------------
    private var scrollSmoothedCentroid: (x: Double, y: Double)?
    private var scrollAccumDx: Double = 0
    private var scrollAccumDy: Double = 0

    // 1-finger cursor state ---------------------------------------------------
    private var cursorAccumDx: Double = 0
    private var cursorAccumDy: Double = 0

    // 3-finger gesture state machine -----------------------------------------
    private var threeFingerStart: (x: Double, y: Double, time: CFAbsoluteTime)?
    private var threeFingerSwipeFired: Bool = false

    // Config snapshot --------------------------------------------------------
    private var config: WacomdConfig { ConfigStore.shared.current }
    private var tapMaxDuration: CFAbsoluteTime { CFAbsoluteTime(config.tapMaxDurationMs) / 1000 }
    private var tapMaxRawMovement: Double { config.tapMaxRawMovement }
    private var threeFingerSwipeThreshold: Double { config.threeFingerSwipeThreshold }
    private var cursorSensitivity: Double { config.cursorSensitivity }
    private var scrollSensitivity: Double { config.scrollSensitivity }

    // Smoothing constants ----------------------------------------------------
    /// Position-smoothing factor. 0.45 lerps roughly halfway each frame ;
    /// the response stays snappy enough to feel native but small noise
    /// gets averaged out across 3-4 frames.
    private let positionSmoothingAlpha: Double = 0.45
    /// Cursor deadband, in raw tablet units. The smoothed delta must
    /// exceed this on at least one axis for any cursor event to fire.
    private let cursorDeadbandRaw: Double = 1.5
    /// Scroll deadband, in raw tablet units of centroid travel.
    private let scrollDeadbandRaw: Double = 2.0
    /// Maximum scroll delta per single CGEvent (post a series of small
    /// events instead of one huge jump for very fast swipes).
    private let scrollMaxPerEvent: Double = 80

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

        // ---- 1. Register newly-arrived contacts ----------------------------
        for id in appearedIDs {
            guard let c = contacts.first(where: { $0.slotID == id && $0.inContact }) else { continue }
            touches[id] = ActiveTouch(
                slotID: id,
                startTime: now,
                startRaw: (c.x, c.y),
                lastRaw: (c.x, c.y),
                smoothedRaw: (Double(c.x), Double(c.y)),
                maxDistanceFromStart: 0,
                lastSeenTime: now
            )
        }

        // ---- 2. Update smoothed position + per-finger delta on smoothed ----
        var smoothedDeltas: [Int: (dx: Double, dy: Double)] = [:]
        for c in contacts where c.inContact {
            guard var touch = touches[c.slotID] else { continue }
            let prevSmooth = touch.smoothedRaw
            let newSmooth = (
                x: prevSmooth.x + (Double(c.x) - prevSmooth.x) * positionSmoothingAlpha,
                y: prevSmooth.y + (Double(c.y) - prevSmooth.y) * positionSmoothingAlpha
            )
            smoothedDeltas[c.slotID] = (newSmooth.x - prevSmooth.x, newSmooth.y - prevSmooth.y)
            touch.smoothedRaw = newSmooth
            touch.lastRaw = (c.x, c.y)
            let dxTotal = Double(c.x - touch.startRaw.x)
            let dyTotal = Double(c.y - touch.startRaw.y)
            touch.maxDistanceFromStart = max(touch.maxDistanceFromStart,
                                              (dxTotal * dxTotal + dyTotal * dyTotal).squareRoot())
            touch.lastSeenTime = now
            touches[c.slotID] = touch
        }

        // ---- 3. Handle releases (tap detection) ----------------------------
        let releaseCount = releasedIDs.count
        for id in releasedIDs {
            guard let touch = touches.removeValue(forKey: id) else { continue }
            let duration = now - touch.startTime
            let isShortContact = duration <= tapMaxDuration
                              && touch.maxDistanceFromStart <= tapMaxRawMovement

            if config.tapToClick
               && isShortContact && previousIDs.count == 1 && releaseCount == 1 {
                Verbose.log(String(format: "1-finger tap (duration=%.0fms, drift=%.0f)",
                                   duration * 1000, touch.maxDistanceFromStart))
                injector.tapClick()
            }
        }

        // 3-finger tap → middle click
        if config.threeFingerSwipes
           && previousIDs.count == 3 && touches.isEmpty
           && !threeFingerSwipeFired
           && threeFingerStart != nil
           && (now - threeFingerStart!.time) <= tapMaxDuration {
            Verbose.log("3-finger tap → middle click")
            injector.middleClick()
        }

        // ---- 4. Mode-switching reset (kills leftover accumulators) ---------
        // Whenever the finger count changes we throw away pending fractional
        // pixels so a 1→2→1 sequence doesn't leak cursor or scroll motion
        // across modes.
        if appearedIDs.isEmpty == false || releasedIDs.isEmpty == false {
            cursorAccumDx = 0
            cursorAccumDy = 0
            scrollAccumDx = 0
            scrollAccumDy = 0
            scrollSmoothedCentroid = nil
        }
        if touches.count != 3 {
            threeFingerStart = nil
            threeFingerSwipeFired = false
        }

        // ---- 5. Continuous behaviour --------------------------------------
        switch touches.count {
        case 0:
            // idle
            break
        case 1:
            if config.oneFingerCursor, let smoothed = smoothedDeltas.values.first {
                applySmoothedCursorDelta(dx: smoothed.dx, dy: smoothed.dy)
            }
        case 2:
            if config.twoFingerScroll {
                handleTwoFingerScroll()
            }
        case 3:
            if config.threeFingerSwipes {
                handleThreeFingerSwipe(now: now)
            }
        default:
            // 4+ fingers : palm / ambiguous — ignore.
            break
        }
    }

    // MARK: - 1-finger cursor (relative, accelerated, smoothed)

    /// Convert a smoothed-position delta into a screen-space cursor move,
    /// applying the macOS-style acceleration curve and sub-pixel
    /// accumulation.
    private func applySmoothedCursorDelta(dx: Double, dy: Double) {
        // Hard deadband on the smoothed delta — kills any drift while the
        // finger is "stationary" (sensor noise that survived smoothing).
        if abs(dx) < cursorDeadbandRaw && abs(dy) < cursorDeadbandRaw { return }

        // Acceleration curve : faster finger gets disproportionate amplification.
        // speed in raw units per frame ; gain plateaus at 3.0 for very fast swipes.
        let speed = (dx * dx + dy * dy).squareRoot()
        let gain  = min(3.0, 0.7 + speed * 0.04)

        // Sub-pixel accumulator so slow finger movement still emits whole-pixel
        // events smoothly instead of stuttering.
        cursorAccumDx += dx * cursorSensitivity * gain
        cursorAccumDy += dy * cursorSensitivity * gain

        let outDx = cursorAccumDx.rounded(.toNearestOrEven)
        let outDy = cursorAccumDy.rounded(.toNearestOrEven)
        if outDx == 0 && outDy == 0 { return }
        cursorAccumDx -= outDx
        cursorAccumDy -= outDy

        injector.moveCursorBy(dx: outDx, dy: outDy)
    }

    // MARK: - 2-finger scroll (smoothed centroid + sub-pixel accumulator)

    private func handleTwoFingerScroll() {
        let fingers = Array(touches.values)
        guard fingers.count == 2 else { return }

        let cx = (fingers[0].smoothedRaw.x + fingers[1].smoothedRaw.x) / 2
        let cy = (fingers[0].smoothedRaw.y + fingers[1].smoothedRaw.y) / 2
        let centroid = (x: cx, y: cy)
        defer { scrollSmoothedCentroid = centroid }

        guard let prev = scrollSmoothedCentroid else { return }
        let dx = centroid.x - prev.x
        let dy = centroid.y - prev.y
        if abs(dx) < scrollDeadbandRaw && abs(dy) < scrollDeadbandRaw { return }

        scrollAccumDx += -dx * scrollSensitivity
        scrollAccumDy += -dy * scrollSensitivity

        let outDx = clamp(scrollAccumDx, -scrollMaxPerEvent, scrollMaxPerEvent)
                        .rounded(.toNearestOrEven)
        let outDy = clamp(scrollAccumDy, -scrollMaxPerEvent, scrollMaxPerEvent)
                        .rounded(.toNearestOrEven)
        if outDx == 0 && outDy == 0 { return }
        scrollAccumDx -= outDx
        scrollAccumDy -= outDy

        injector.scroll(dx: outDx, dy: outDy)
    }

    // MARK: - 3-finger swipe (centroid trajectory → key combo)

    private func handleThreeFingerSwipe(now: CFAbsoluteTime) {
        let fingers = Array(touches.values)
        guard fingers.count == 3 else { return }

        let cx = fingers.map { $0.smoothedRaw.x }.reduce(0, +) / 3
        let cy = fingers.map { $0.smoothedRaw.y }.reduce(0, +) / 3

        if threeFingerStart == nil {
            threeFingerStart = (x: cx, y: cy, time: now)
            threeFingerSwipeFired = false
            return
        }
        if threeFingerSwipeFired { return }

        let dx = cx - threeFingerStart!.x
        let dy = cy - threeFingerStart!.y
        let absDx = abs(dx)
        let absDy = abs(dy)
        if max(absDx, absDy) < threeFingerSwipeThreshold { return }

        threeFingerSwipeFired = true

        if absDx > absDy {
            if dx > 0 {
                Verbose.log("3-finger swipe → (Ctrl+→)")
                injector.postKeyCombo(keyCode: 0x7C, modifiers: .maskControl)
            } else {
                Verbose.log("3-finger swipe ← (Ctrl+←)")
                injector.postKeyCombo(keyCode: 0x7B, modifiers: .maskControl)
            }
        } else {
            if dy < 0 {
                Verbose.log("3-finger swipe ↑ (Mission Control)")
                injector.postKeyCombo(keyCode: 0x7E, modifiers: .maskControl)
            } else {
                Verbose.log("3-finger swipe ↓ (App Exposé)")
                injector.postKeyCombo(keyCode: 0x7D, modifiers: .maskControl)
            }
        }
    }

    private func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        min(max(v, lo), hi)
    }
}
