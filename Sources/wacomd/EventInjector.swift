import Foundation
import CoreGraphics
import AppKit

final class EventInjector {
    private var lastTipDown: Bool = false
    private var lastBarrel: Bool = false
    private var lastInRange: Bool = false
    private var lastPosted: CFAbsoluteTime = 0
    private var postedCount: Int = 0
    private var lastLoggedCount: Int = 0
    private var lastLoggedAt: CFAbsoluteTime = 0

    /// Minimum delta between two cursor moves, in seconds.
    /// 240 Hz is plenty: the PTH-451 reports at ~200 Hz.
    private let throttleInterval: CFAbsoluteTime = 1.0 / 240.0

    func update(state: PenState, model: WacomModel) {
        guard state.inRange else {
            // Pen left the proximity zone — release any held button.
            if lastTipDown {
                postMouseEvent(type: .leftMouseUp, at: .zero, state: state, model: model)
                lastTipDown = false
            }
            lastInRange = false
            return
        }
        lastInRange = true

        let cgPoint = mapToScreen(state: state, model: model)

        let eventType: CGEventType
        if state.tipDown && !lastTipDown {
            eventType = .leftMouseDown
        } else if !state.tipDown && lastTipDown {
            eventType = .leftMouseUp
        } else if state.tipDown {
            eventType = .leftMouseDragged
        } else {
            // Throttle hover moves so we don't drown the event tap.
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastPosted < throttleInterval { return }
            lastPosted = now
            eventType = .mouseMoved
        }

        postMouseEvent(type: eventType, at: cgPoint, state: state, model: model)

        // Barrel button → right click (synthesised separately so apps see both
        // the pen position update and a button transition).
        if state.barrelButton != lastBarrel {
            let rightType: CGEventType = state.barrelButton ? .rightMouseDown : .rightMouseUp
            postMouseEvent(type: rightType, at: cgPoint, state: state, model: model, button: .right)
        }

        lastTipDown = state.tipDown
        lastBarrel = state.barrelButton
    }

    private func mapToScreen(state: PenState, model: WacomModel) -> CGPoint {
        let normX = clamp(state.x / model.maxX, 0, 1)
        let normY = clamp(state.y / model.maxY, 0, 1)

        // Primary screen in CG (top-left origin) coordinates.
        // NSScreen.main returns the screen containing the key window,
        // we want the primary monitor which is always NSScreen.screens.first.
        let primary = NSScreen.screens.first ?? NSScreen.main
        let width = primary?.frame.width ?? 1920
        let height = primary?.frame.height ?? 1080

        return CGPoint(x: normX * width, y: normY * height)
    }

    private func postMouseEvent(
        type: CGEventType,
        at point: CGPoint,
        state: PenState,
        model: WacomModel,
        button: CGMouseButton = .left
    ) {
        guard let evt = CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: button
        ) else { return }

        // Mouse pressure (used by Force Touch APIs as a fallback)
        evt.setDoubleValueField(.mouseEventPressure, value: state.pressure)

        // Tablet point payload — read by Photoshop, Procreate, Krita, Affinity,
        // Clip Studio, Sketch, etc. via NSEvent.tabletPoint translation.
        evt.setDoubleValueField(.tabletEventPointPressure, value: state.pressure)
        evt.setIntegerValueField(.tabletEventPointX, value: Int64(state.x))
        evt.setIntegerValueField(.tabletEventPointY, value: Int64(state.y))
        evt.setIntegerValueField(
            .tabletEventPointButtons,
            value: tabletButtonsMask(state: state)
        )

        // Tilt is reported in degrees by Wacom (-60..60). NSEvent expects a
        // value in radians on -π/2..π/2; the mouse-event field accepts the raw
        // integer and apps usually re-scale.
        evt.setIntegerValueField(.tabletEventTiltX, value: Int64(state.tiltX))
        evt.setIntegerValueField(.tabletEventTiltY, value: Int64(state.tiltY))

        evt.post(tap: .cghidEventTap)
        postedCount += 1

        // Log de débit toutes les 5 s, uniquement en mode verbose.
        if Verbose.enabled {
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastLoggedAt >= 5.0 {
                let delta = postedCount - lastLoggedCount
                let rate = Double(delta) / max(0.001, now - lastLoggedAt)
                Verbose.log(String(format: "%d évènements postés (+%d, %.0f/s) — dernier (%.0f, %.0f) pression=%.2f",
                                   postedCount, delta, rate, point.x, point.y, state.pressure))
                lastLoggedCount = postedCount
                lastLoggedAt = now
            }
        }
    }

    private func tabletButtonsMask(state: PenState) -> Int64 {
        var mask: Int64 = 0
        if state.tipDown      { mask |= 0x01 }
        if state.barrelButton { mask |= 0x02 }
        if state.eraser       { mask |= 0x04 }
        return mask
    }

    private func clamp<T: Comparable>(_ x: T, _ lo: T, _ hi: T) -> T {
        min(max(x, lo), hi)
    }
}
