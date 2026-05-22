import Foundation
import CoreGraphics
import AppKit

/// Capability mask attached to the tablet proximity event. Tells apps which
/// of the tablet point fields actually carry meaningful data.
/// Bit positions follow `NX_TABLET_CAPABILITY_*` from IOKit.
private struct TabletCapabilities: OptionSet {
    let rawValue: Int64
    static let deviceID            = TabletCapabilities(rawValue: 1 << 0)
    static let absX                = TabletCapabilities(rawValue: 1 << 1)
    static let absY                = TabletCapabilities(rawValue: 1 << 2)
    static let vendor1             = TabletCapabilities(rawValue: 1 << 3)
    static let vendor2             = TabletCapabilities(rawValue: 1 << 4)
    static let vendor3             = TabletCapabilities(rawValue: 1 << 5)
    static let buttons             = TabletCapabilities(rawValue: 1 << 6)
    static let tiltX               = TabletCapabilities(rawValue: 1 << 7)
    static let tiltY               = TabletCapabilities(rawValue: 1 << 8)
    static let absZ                = TabletCapabilities(rawValue: 1 << 9)
    static let pressure            = TabletCapabilities(rawValue: 1 << 10)
    static let tangentialPressure  = TabletCapabilities(rawValue: 1 << 11)
    static let orientInfo          = TabletCapabilities(rawValue: 1 << 12)
    static let rotation            = TabletCapabilities(rawValue: 1 << 13)
}

/// Values mirroring `NX_TABLET_POINTER_*` from IOKit / Quartz.
private enum TabletPointerType: Int64 {
    case unknown = 0
    case pen     = 1
    case cursor  = 2
    case eraser  = 3
}

final class EventInjector {
    private var lastTipDown: Bool = false
    private var lastBarrel: Bool = false
    private var lastInRange: Bool = false
    private var lastPosted: CFAbsoluteTime = 0
    private var postedCount: Int = 0
    private var lastLoggedCount: Int = 0
    private var lastLoggedAt: CFAbsoluteTime = 0

    /// Stable identifier we reuse across proximity + point events so apps can
    /// correlate the two. macOS doesn't care what the actual value is as long
    /// as it stays the same for the lifetime of a "device session".
    private let deviceID: Int64 = 1

    /// Set to the value carried by the latest proximity-enter packet
    /// (Wacom tool ID). Reused on every subsequent point event.
    private var currentPointerType: TabletPointerType = .pen
    private var currentToolID: Int64 = 0x802  // default = Grip Pen
    private var currentSerial: Int64 = 0

    /// Mask of all capabilities our driver actually populates.
    private static let capabilityMask: TabletCapabilities = [
        .deviceID, .absX, .absY, .buttons, .tiltX, .tiltY, .pressure
    ]

    /// Minimum delta between two cursor moves, in seconds.
    /// 240 Hz is plenty: the PTH-451 reports at ~200 Hz.
    private let throttleInterval: CFAbsoluteTime = 1.0 / 240.0

    // MARK: - Public API

    func update(state: PenState, model: WacomModel) {
        // ---- Proximity LEAVE ---------------------------------------------
        if !state.inRange {
            if lastTipDown {
                postMouseEvent(type: .leftMouseUp, at: .zero, state: state, model: model)
                lastTipDown = false
            }
            if lastInRange {
                postProximityEvent(entering: false, model: model)
                lastInRange = false
            }
            return
        }

        // ---- Proximity ENTER ---------------------------------------------
        let desiredPointerType: TabletPointerType = state.eraser ? .eraser : .pen
        if !lastInRange {
            currentPointerType = desiredPointerType
            postProximityEvent(entering: true, model: model)
            lastInRange = true
        } else if desiredPointerType != currentPointerType {
            // Le stylet a été retourné en proximité : on cycle
            // proximityLeave + proximityEnter pour que les apps
            // (Photoshop, Procreate…) basculent leur outil entre
            // crayon et gomme correctement.
            postProximityEvent(entering: false, model: model)
            currentPointerType = desiredPointerType
            postProximityEvent(entering: true, model: model)
        }

        let cgPoint = mapToScreen(state: state, model: model)

        // ---- Decide mouse-event type ------------------------------------
        let eventType: CGEventType
        if state.tipDown && !lastTipDown {
            eventType = .leftMouseDown
        } else if !state.tipDown && lastTipDown {
            eventType = .leftMouseUp
        } else if state.tipDown {
            eventType = .leftMouseDragged
        } else {
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastPosted < throttleInterval { return }
            lastPosted = now
            eventType = .mouseMoved
        }

        postMouseEvent(type: eventType, at: cgPoint, state: state, model: model)

        // Barrel button → right click, posted as a separate transition.
        if state.barrelButton != lastBarrel {
            let rightType: CGEventType = state.barrelButton ? .rightMouseDown : .rightMouseUp
            postMouseEvent(type: rightType, at: cgPoint, state: state, model: model, button: .right)
        }

        lastTipDown = state.tipDown
        lastBarrel = state.barrelButton
    }

    /// Called by `WacomDevice` when a proximity-enter packet is parsed, so
    /// we can carry the real Wacom tool ID into the subsequent CGEvents.
    func updateToolIdentity(toolID: UInt32, serial: UInt64, isEraser: Bool) {
        self.currentToolID = Int64(toolID & 0xFFFF)  // vendor pointer type (16-bit)
        self.currentSerial = Int64(bitPattern: UInt64(serial & 0xFFFFFFFF))
        self.currentPointerType = isEraser ? .eraser : .pen
    }

    // MARK: - Tablet proximity event

    private func postProximityEvent(entering: Bool, model: WacomModel) {
        // `CGEvent(source:)` returns a "null" event. We then promote it to
        // a tablet-proximity event by overwriting its `type` property.
        guard let evt = CGEvent(source: nil) else { return }
        evt.type = .tabletProximity

        evt.setIntegerValueField(.tabletProximityEventVendorID,
                                 value: Int64(model.vendorID))
        evt.setIntegerValueField(.tabletProximityEventTabletID,
                                 value: Int64(model.productID))
        evt.setIntegerValueField(.tabletProximityEventPointerID,
                                 value: deviceID)
        evt.setIntegerValueField(.tabletProximityEventDeviceID,
                                 value: deviceID)
        evt.setIntegerValueField(.tabletProximityEventSystemTabletID, value: 0)
        evt.setIntegerValueField(.tabletProximityEventVendorPointerType,
                                 value: currentToolID)
        evt.setIntegerValueField(.tabletProximityEventVendorPointerSerialNumber,
                                 value: currentSerial)
        evt.setIntegerValueField(.tabletProximityEventVendorUniqueID,
                                 value: currentSerial)
        evt.setIntegerValueField(.tabletProximityEventCapabilityMask,
                                 value: Self.capabilityMask.rawValue)
        evt.setIntegerValueField(.tabletProximityEventPointerType,
                                 value: currentPointerType.rawValue)
        evt.setIntegerValueField(.tabletProximityEventEnterProximity,
                                 value: entering ? 1 : 0)

        evt.post(tap: .cghidEventTap)
        Verbose.log("proximity \(entering ? "ENTER" : "LEAVE") posted (deviceID=\(deviceID), pointerType=\(currentPointerType))")
    }

    // MARK: - Mouse + tablet point event

    private func mapToScreen(state: PenState, model: WacomModel) -> CGPoint {
        let normX = clamp(state.x / model.maxX, 0, 1)
        let normY = clamp(state.y / model.maxY, 0, 1)

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

        evt.setIntegerValueField(.mouseEventSubtype, value: 1)  // NSEventSubtype.tabletPoint = 1
        evt.setDoubleValueField(.mouseEventPressure, value: state.pressure)

        // ----- Tablet point payload --------------------------------------
        // pressure: float 0..1
        evt.setDoubleValueField(.tabletEventPointPressure, value: state.pressure)

        // tilt: float -1..1 (Wacom raw is -64..63 degrees, normalise to unit)
        let tiltXNormalized = max(-1.0, min(1.0, state.tiltX / 64.0))
        let tiltYNormalized = max(-1.0, min(1.0, state.tiltY / 64.0))
        evt.setDoubleValueField(.tabletEventTiltX, value: tiltXNormalized)
        evt.setDoubleValueField(.tabletEventTiltY, value: tiltYNormalized)

        // rotation / tangential pressure unsupported on Grip Pen
        evt.setDoubleValueField(.tabletEventRotation, value: 0)
        evt.setDoubleValueField(.tabletEventTangentialPressure, value: 0)

        // absolute coordinates (raw tablet units, useful for some apps)
        evt.setIntegerValueField(.tabletEventPointX, value: Int64(state.x))
        evt.setIntegerValueField(.tabletEventPointY, value: Int64(state.y))
        evt.setIntegerValueField(.tabletEventPointZ, value: 0)

        evt.setIntegerValueField(.tabletEventDeviceID, value: deviceID)
        evt.setIntegerValueField(.tabletEventVendor1, value: 0)
        evt.setIntegerValueField(.tabletEventVendor2, value: 0)
        evt.setIntegerValueField(.tabletEventVendor3, value: 0)

        evt.setIntegerValueField(.tabletEventPointButtons,
                                 value: tabletButtonsMask(state: state))

        evt.post(tap: .cghidEventTap)
        postedCount += 1

        if Verbose.enabled {
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastLoggedAt >= 5.0 {
                let delta = postedCount - lastLoggedCount
                let rate = Double(delta) / max(0.001, now - lastLoggedAt)
                Verbose.log(String(format: "%d évènements postés (+%d, %.0f/s) — dernier (%.0f, %.0f) pression=%.2f tiltN=(%.2f, %.2f)",
                                   postedCount, delta, rate, point.x, point.y,
                                   state.pressure, tiltXNormalized, tiltYNormalized))
                lastLoggedCount = postedCount
                lastLoggedAt = now
            }
        }
    }

    // MARK: - Cursor / click from the multi-touch surface

    /// Move the cursor relative to its current screen position by `dx`/`dy`
    /// screen pixels. Trackpad-style behaviour : where the finger LANDS on
    /// the tablet doesn't matter, only the delta of motion is consumed.
    func moveCursorBy(dx: Double, dy: Double) {
        let current = currentCursorPosition()
        let target = CGPoint(x: current.x + dx, y: current.y + dy)

        guard let evt = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: target,
            mouseButton: .left
        ) else { return }
        // Also expose the delta to apps that read it.
        evt.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx.rounded()))
        evt.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy.rounded()))
        evt.post(tap: .cghidEventTap)
    }

    /// Read the current cursor position. CGEvent returns coordinates in
    /// the CG "flipped" space (top-left origin) which is what we use to
    /// post events too.
    private func currentCursorPosition() -> CGPoint {
        // CGEvent(source: nil) creates a "null" event ; its `.location`
        // is populated with the current pointer location by the OS.
        if let probe = CGEvent(source: nil) {
            return probe.location
        }
        // Fallback : convert NSEvent.mouseLocation (Cocoa, bottom-left
        // origin) into CG coordinates by flipping Y.
        let cocoaLoc = NSEvent.mouseLocation
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 1080
        return CGPoint(x: cocoaLoc.x, y: primaryHeight - cocoaLoc.y)
    }

    /// Post a quick left mouse down + up at the cursor's CURRENT position.
    /// Used by tap-to-click on the multi-touch surface (in relative mode,
    /// we don't care where on the tablet the tap happened — only that a
    /// tap happened).
    func tapClick() {
        let p = currentCursorPosition()
        guard let down = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDown,
            mouseCursorPosition: p,
            mouseButton: .left
        ),
        let up = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseUp,
            mouseCursorPosition: p,
            mouseButton: .left
        ) else { return }
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventClickState, value: 1)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    // MARK: - Scroll wheel (2-finger touch)

    /// Posts a pixel-precise scroll event. `dx` / `dy` are in OS scroll units
    /// already (i.e. the caller is responsible for sensitivity scaling).
    func scroll(dx: Double, dy: Double) {
        let intDy = Int32(dy.rounded())
        let intDx = Int32(dx.rounded())
        if intDx == 0 && intDy == 0 { return }

        guard let evt = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: intDy,
            wheel2: intDx,
            wheel3: 0
        ) else { return }

        evt.post(tap: .cghidEventTap)
        Verbose.log(String(format: "scroll dy=%d dx=%d", intDy, intDx))
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
