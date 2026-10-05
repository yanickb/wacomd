import Foundation
import CoreGraphics
import AppKit
import WacomdShared

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
    private var lastLowerButton: Bool = false
    private var lastUpperButton: Bool = false
    private var lastPoint: CGPoint = .zero
    /// Last pen sample in range, so button clicks carry tablet data.
    private var lastState = PenState()
    private var lastModel: WacomModel?
    /// Mouse buttons currently held by a button action (count per button, in
    /// case both pen buttons are bound to the same click).
    private var heldMouseButtons: [CGMouseButton: Int] = [:]
    /// Chords pressed by a button action, keyed by button id, so the key-up
    /// matches the key-down even if the config is reloaded in between.
    private var heldChords: [String: KeyChord] = [:]
    /// Modifiers held by button actions (`"alt"`, `"shift+middleClick"`…),
    /// keyed by button id. Their union is added to every posted event.
    private var heldModifiers: [String: CGEventFlags] = [:]
    /// Mouse button of a `modifiers+click` shortcut currently held, by button id.
    private var heldModifiedClicks: [String: CGMouseButton] = [:]

    private lazy var gestures = ButtonGestures { [unowned self] action, id, pressed, kind in
        self.perform(action, id: id, pressed: pressed)
        if pressed {
            self.publishStatus(extra: ["event": "button", "button": id, "gesture": kind.rawValue,
                                       "action": action.displayName])
        }
    }

    // Modes driven by held buttons. Counters, since two buttons may share one.
    private var layerHeld = 0
    private var layer2Active: Bool { layerHeld > 0 }
    /// Actions latched on by a `.toggle` press, by raw value.
    private var toggledActions: Set<String> = []
    private var precisionHeld = 0
    private var mouseModeHeld = 0
    /// Relative cursor (precision, mouse mode) : cursor position and the
    /// previous absolute pen position it moves from.
    private var relativeCursor: CGPoint = .zero
    private var relativePen: CGPoint?
    private var stabilizerHeld = 0
    /// Smoothed pen position while the tip is down, and its last update time.
    private var smoothedPoint: CGPoint?
    private var smoothedAt: CFAbsoluteTime = 0
    private var penGesturesHeld = 0
    private var handwritingHeld = 0
    /// A stroke started in handwriting mode : its drags and tip-up stay out
    /// of the app even if the mode is turned off mid-stroke.
    private var handwritingStrokeOpen = false
    private var penGestureAnchor: CGPoint?
    private var brushSizeHeld = 0
    /// Pen X (screen px) at which the next brush-size step is measured.
    private var brushAnchorX: CGFloat?
    private var eraserHeld = 0
    private var scrollHeld = 0
    /// Previous absolute pen position while scrolling, and sub-pixel leftovers.
    private var scrollAnchor: CGPoint?
    private var scrollRemainder = CGPoint.zero
    /// Radial menu open state : its items, centre, pen anchor and pointed item.
    private var radialItems: [RadialItem] = []
    private var radialHeld = 0
    private var radialCenter: CGPoint = .zero
    private var radialAnchor: CGPoint?
    private var radialSelection: Int?
    /// Cursor position kept still while a mode reinterprets pen motion
    /// (brush size, scroll, radial menu).
    private var frozenPoint: CGPoint?

    private var cachedDisplay: (index: Int, bounds: CGRect, at: CFAbsoluteTime)?
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

    private var cursorFrozen: Bool { brushSizeHeld > 0 || scrollHeld > 0 || radialHeld > 0 || penGesturesHeld > 0 }
    private var stabilizerActive: Bool { ConfigStore.shared.current.stabilizerEnabled != (stabilizerHeld > 0) }
    private var heldModifierFlags: CGEventFlags {
        heldModifiers.values.reduce(into: CGEventFlags()) { $0.formUnion($1) }
    }

    // MARK: - Public API

    func update(state: PenState, model: WacomModel) {
        // ---- Proximity LEAVE ---------------------------------------------
        if !state.inRange {
            if lastTipDown {
                if handwritingStrokeOpen {
                    Handwriting.shared.endStroke()
                    handwritingStrokeOpen = false
                } else {
                    postMouseEvent(type: .leftMouseUp, at: lastPoint, state: state, model: model)
                }
                lastTipDown = false
            }
            releasePenButtons()
            // Lifting the pen and putting it back down doesn't move a
            // relative cursor, like lifting a mouse.
            relativePen = nil
            penGestureAnchor = nil
            smoothedPoint = nil
            if lastInRange {
                postProximityEvent(entering: false, model: model)
                lastInRange = false
            }
            return
        }

        // ---- Proximity ENTER ---------------------------------------------
        // An `.eraser` button makes apps see the eraser end of the pen.
        let desiredPointerType: TabletPointerType = (state.eraser || eraserHeld > 0) ? .eraser : .pen
        if !lastInRange {
            currentPointerType = desiredPointerType
            postProximityEvent(entering: true, model: model)
            lastInRange = true
        } else if desiredPointerType != currentPointerType {
            // Le stylet a été retourné en proximité (ou une touche gomme
            // change d'état) : on cycle proximityLeave + proximityEnter pour
            // que les apps (Photoshop, Procreate…) basculent leur outil
            // entre crayon et gomme correctement.
            postProximityEvent(entering: false, model: model)
            currentPointerType = desiredPointerType
            postProximityEvent(entering: true, model: model)
        }

        let absolute = stabilize(mapToScreen(state: state, model: model), tipDown: state.tipDown)
        let cgPoint = applyModes(to: absolute)
        lastPoint = cgPoint
        lastState = state
        lastModel = model
        if LiveStatus.shared.active {
            publishStatus(extra: ["event": "pen", "rawPressure": state.rawPressure, "pressure": state.pressure,
                                  "x": Double(cgPoint.x), "y": Double(cgPoint.y), "tip": state.tipDown,
                                  "eraser": currentPointerType == .eraser],
                          isPenSample: true)
        }

        // ---- Decide mouse-event type ------------------------------------
        let eventType: CGEventType
        var eventButton: CGMouseButton = .left
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
            // A button held as right/middle click turns hover into a drag
            // (Blender orbit on middle-drag, context-menu drag on right).
            if heldMouseButtons[.right, default: 0] > 0 {
                eventType = .rightMouseDragged
                eventButton = .right
            } else if heldMouseButtons[.center, default: 0] > 0 {
                eventType = .otherMouseDragged
                eventButton = .center
            } else {
                eventType = .mouseMoved
            }
        }

        if handwritingStrokeOpen || (handwritingHeld > 0 && eventType == .leftMouseDown) {
            // Handwriting : the stroke becomes ink, the app only sees the cursor move.
            switch eventType {
            case .leftMouseDown:
                handwritingStrokeOpen = true
                if Handwriting.shared.beginStroke(at: cgPoint), ConfigStore.shared.current.handwritingClickToFocus {
                    postPlainClick(at: cgPoint)
                }
            case .leftMouseDragged:
                Handwriting.shared.moveStroke(to: cgPoint)
            case .leftMouseUp:
                Handwriting.shared.moveStroke(to: cgPoint)
                Handwriting.shared.endStroke()
                handwritingStrokeOpen = false
            default:
                break
            }
            if let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: cgPoint, mouseButton: .left) {
                move.post(tap: .cghidEventTap)
            }
        } else if !(cursorFrozen && eventType == .mouseMoved) {
            // Modes that reinterpret pen motion keep the cursor still.
            postMouseEvent(type: eventType, at: cgPoint, state: state, model: model, button: eventButton)
        }

        // Side buttons → configurable actions, posted as separate transitions.
        if state.lowerButton != lastLowerButton {
            lastLowerButton = state.lowerButton
            buttonChanged(.penLower, pressed: state.lowerButton)
        }
        if state.upperButton != lastUpperButton {
            lastUpperButton = state.upperButton
            buttonChanged(.penUpper, pressed: state.upperButton)
        }

        lastTipDown = state.tipDown
    }

    private func releasePenButtons() {
        if lastLowerButton {
            lastLowerButton = false
            buttonChanged(.penLower, pressed: false)
        }
        if lastUpperButton {
            lastUpperButton = false
            buttonChanged(.penUpper, pressed: false)
        }
    }

    /// Applies the held modes to the absolute pen position.
    private func applyModes(to absolute: CGPoint) -> CGPoint {
        let config = ConfigStore.shared.current
        if cursorFrozen {
            let frozen = frozenPoint ?? currentCursorPosition()
            frozenPoint = frozen

            if radialHeld > 0 {
                // Point at an item by moving the pen away from where it started.
                let anchor = radialAnchor ?? absolute
                radialAnchor = anchor
                radialSelection = RadialMenuView.sector(dx: absolute.x - anchor.x, dy: absolute.y - anchor.y,
                                                        count: radialItems.count)
                Hud.shared.highlightRadial(radialSelection)
            } else if penGesturesHeld > 0 {
                // A quick flick past the distance runs its direction's action,
                // then re-anchors so several flicks can follow while held.
                let anchor = penGestureAnchor ?? absolute
                let dx = absolute.x - anchor.x, dy = absolute.y - anchor.y
                if hypot(dx, dy) >= CGFloat(max(config.penGestureDistance, 15)) {
                    // 0 up, 1 right, 2 down, 3 left (screen y grows downwards).
                    let direction = abs(dx) > abs(dy) ? (dx > 0 ? 1 : 3) : (dy > 0 ? 2 : 0)
                    runPenGesture(direction)
                    penGestureAnchor = absolute
                } else {
                    penGestureAnchor = anchor
                }
            } else if brushSizeHeld > 0 {
                // Horizontal travel taps the brush-size keys.
                let step = CGFloat(max(config.brushSizeStep, 2))
                var anchor = brushAnchorX ?? absolute.x
                while abs(absolute.x - anchor) >= step {
                    let growing = absolute.x > anchor
                    tapShortcut(growing ? config.brushSizeIncrease : config.brushSizeDecrease)
                    anchor += growing ? step : -step
                }
                brushAnchorX = anchor
            } else if scrollHeld > 0 {
                // Pen motion drags the content : down moves it down.
                if let previous = scrollAnchor {
                    let speed = CGFloat(clamp(config.scrollSpeed, 0.1, 10))
                    let dx = (absolute.x - previous.x) * speed + scrollRemainder.x
                    let dy = (absolute.y - previous.y) * speed + scrollRemainder.y
                    scrollRemainder = CGPoint(x: dx - dx.rounded(), y: dy - dy.rounded())
                    scroll(dx: Double(dx.rounded()), dy: Double(dy.rounded()))
                }
                scrollAnchor = absolute
            }
            return frozen
        }
        if precisionHeld > 0 || mouseModeHeld > 0 {
            guard let previous = relativePen else {
                relativePen = absolute
                relativeCursor = currentCursorPosition()
                return relativeCursor
            }
            var scale = 1.0
            if precisionHeld > 0 { scale *= clamp(config.precisionScale, 0.02, 1) }
            if mouseModeHeld > 0 { scale *= clamp(config.mouseSpeed, 0.1, 5) }
            relativePen = absolute
            relativeCursor = clampToDisplays(CGPoint(x: relativeCursor.x + (absolute.x - previous.x) * CGFloat(scale),
                                                     y: relativeCursor.y + (absolute.y - previous.y) * CGFloat(scale)))
            return relativeCursor
        }
        return absolute
    }

    /// Exponential smoothing of the stroke while the tip is down. Time based,
    /// so the feel doesn't depend on the tablet's report rate. Hovering is
    /// never smoothed, and each stroke starts exactly under the pen.
    private func stabilize(_ point: CGPoint, tipDown: Bool) -> CGPoint {
        let strength = clamp(ConfigStore.shared.current.stabilizerStrength, 0, 100) / 100
        let now = CFAbsoluteTimeGetCurrent()
        guard tipDown, stabilizerActive, strength > 0, let previous = smoothedPoint else {
            smoothedPoint = tipDown ? point : nil
            smoothedAt = now
            return point
        }
        // Time constant 0 … 120 ms, quadratic so low settings stay subtle.
        let tau = 0.12 * strength * strength
        let dt = clamp(now - smoothedAt, 0, 0.05)
        let alpha = CGFloat(1 - exp(-dt / tau))
        let smoothed = CGPoint(x: previous.x + (point.x - previous.x) * alpha,
                               y: previous.y + (point.y - previous.y) * alpha)
        smoothedPoint = smoothed
        smoothedAt = now
        return smoothed
    }

    /// Keeps a relative cursor on the displays.
    private func clampToDisplays(_ point: CGPoint) -> CGPoint {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(UInt32(ids.count), &ids, &count) == .success, count > 0 else { return point }
        let bounds = ids.prefix(Int(count)).map { CGDisplayBounds($0) }
        if bounds.contains(where: { $0.contains(point) }) { return point }
        // Outside every display : pull onto the nearest one.
        let nearest = bounds.min { a, b in
            hypot(clamp(point.x, a.minX, a.maxX - 1) - point.x, clamp(point.y, a.minY, a.maxY - 1) - point.y)
                < hypot(clamp(point.x, b.minX, b.maxX - 1) - point.x, clamp(point.y, b.minY, b.maxY - 1) - point.y)
        }!
        return CGPoint(x: clamp(point.x, nearest.minX, nearest.maxX - 1), y: clamp(point.y, nearest.minY, nearest.maxY - 1))
    }

    /// Focuses whatever is under the pen before handwriting into it.
    private func postPlainClick(at point: CGPoint) {
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            guard let evt = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { continue }
            evt.setIntegerValueField(.mouseEventClickState, value: 1)
            evt.post(tap: .cghidEventTap)
        }
    }

    private func runPenGesture(_ direction: Int) {
        let gestures = currentButtonMap(ConfigStore.shared.current).penGestures
        guard gestures.indices.contains(direction), gestures[direction] != .none else { return }
        let action = gestures[direction]
        let arrow = ["↑", "→", "↓", "←"][direction]
        Hud.shared.flash("\(arrow) \(action.displayName)")
        perform(action, id: "gesture", pressed: true)
        perform(action, id: "gesture", pressed: false)
        publishStatus(extra: ["event": "button", "button": "gesture", "gesture": "geste \(arrow)",
                              "action": action.displayName])
    }

    private func tapShortcut(_ spec: String) {
        guard case .key(let chord)? = KeyShortcut.parse(spec) else {
            FileHandle.standardError.write(Data("[wacomd] Touche invalide : \"\(spec)\"\n".utf8))
            return
        }
        postKey(chord, down: true)
        postKey(chord, down: false)
    }

    // MARK: - Button actions (pen side buttons + pad ExpressKeys)

    /// Entry point for a physical button transition. The binding is resolved
    /// on press from the frontmost app's profile and the current layer, then
    /// press / double / long presses are told apart by `ButtonGestures`.
    func buttonChanged(_ button: PhysicalButton, pressed: Bool) {
        let config = ConfigStore.shared.current
        gestures.changed(id: button.id, pressed: pressed,
                         doubleTap: Double(max(config.doubleTapMs, 80)) / 1000,
                         longPress: Double(max(config.longPressMs, 150)) / 1000) {
            self.currentButtonMap(config).binding(for: button, layer2: self.layer2Active)
        }
    }

    private func currentButtonMap(_ config: WacomdConfig) -> ButtonMap {
        config.buttonMap(forApp: effectiveBundleID())
    }

    /// Frontmost app, or the profile picked in the configurator's Test tab
    /// while the configurator itself is frontmost.
    private func effectiveBundleID() -> String? {
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if frontmost == LiveStatusNames.configuratorBundleID, LiveStatus.shared.active,
           let test = LiveStatus.shared.testBundleID {
            return test
        }
        return frontmost
    }

    /// Sends the current state (profile, layer, modes) plus `extra` to the Test tab.
    private func publishStatus(extra: [String: Any] = [:], isPenSample: Bool = false) {
        guard LiveStatus.shared.active else { return }
        let config = ConfigStore.shared.current
        let bundleID = effectiveBundleID()
        var info = extra
        info["app"] = bundleID ?? ""
        info["profile"] = config.profile(forApp: bundleID)?.name ?? "Par défaut"
        info["layer2"] = layer2Active
        info["modes"] = activeModes
        LiveStatus.shared.post(info, isPenSample: isPenSample)
    }

    private var activeModes: [String] {
        var modes: [String] = []
        if layer2Active { modes.append("Calque 2") }
        if eraserHeld > 0 { modes.append("Gomme") }
        if precisionHeld > 0 { modes.append("Précision") }
        if mouseModeHeld > 0 { modes.append("Mode souris") }
        if stabilizerActive { modes.append("Stabilisateur") }
        if brushSizeHeld > 0 { modes.append("Taille pinceau") }
        if scrollHeld > 0 { modes.append("Défilement") }
        if radialHeld > 0 { modes.append("Menu circulaire") }
        if penGesturesHeld > 0 { modes.append("Gestes") }
        if handwritingHeld > 0 { modes.append("Écriture") }
        let flags = heldModifierFlags
        for (flag, name) in [(CGEventFlags.maskControl, "⌃"), (.maskAlternate, "⌥"), (.maskShift, "⇧"), (.maskCommand, "⌘")]
        where flags.contains(flag) { modes.append(name) }
        return modes
    }

    /// Press or release an action. `id` identifies the physical button so a
    /// held chord or modifier is released exactly as it was pressed.
    private func perform(_ action: ButtonAction, id: String, pressed: Bool) {
        Verbose.log("bouton \(id) \(pressed ? "appuyé" : "relâché") → \(action.rawValue)")
        let delta = pressed ? 1 : -1
        switch action {
        case .none:
            return
        case .layer:
            layerHeld = max(0, layerHeld + delta)
            Hud.shared.setMode(ButtonAction.layer.displayName, active: layer2Active)
        case .toggle(let inner):
            // Each press flips the latched action ; releases are ignored.
            guard pressed else { return }
            let key = inner.rawValue
            let turningOn = !toggledActions.contains(key)
            if turningOn { toggledActions.insert(key) } else { toggledActions.remove(key) }
            perform(inner, id: "toggle.\(key)", pressed: turningOn)
        case .precision:
            precisionHeld = max(0, precisionHeld + delta)
            relativePen = nil
            Hud.shared.setMode(action.displayName, active: precisionHeld > 0)
        case .mouseMode:
            mouseModeHeld = max(0, mouseModeHeld + delta)
            relativePen = nil
            Hud.shared.setMode(action.displayName, active: mouseModeHeld > 0)
        case .stabilizer:
            stabilizerHeld = max(0, stabilizerHeld + delta)
            smoothedPoint = nil
            let on = stabilizerActive
            Hud.shared.setMode("Stabilisateur", active: on)
            if !on { Hud.shared.flash("Stabilisateur off") }
        case .handwriting:
            handwritingHeld = max(0, handwritingHeld + delta)
            Hud.shared.setMode("✎ Écriture", active: handwritingHeld > 0)
            if handwritingHeld == 0 { Handwriting.shared.finishNow() }
        case .penGestures:
            penGesturesHeld = max(0, penGesturesHeld + delta)
            penGestureAnchor = nil
            modeFreezeChanged()
            Hud.shared.setMode("Gestes ↑→↓←", active: penGesturesHeld > 0)
        case .brushSize:
            brushSizeHeld = max(0, brushSizeHeld + delta)
            brushAnchorX = nil
            modeFreezeChanged()
            Hud.shared.setMode("Taille pinceau ↔", active: brushSizeHeld > 0)
        case .scroll:
            scrollHeld = max(0, scrollHeld + delta)
            scrollAnchor = nil
            scrollRemainder = .zero
            modeFreezeChanged()
            Hud.shared.setMode(action.displayName, active: scrollHeld > 0)
        case .eraser:
            eraserHeld = max(0, eraserHeld + delta)
            Hud.shared.setMode(action.displayName, active: eraserHeld > 0)
        case .radialMenu:
            radialMenuChanged(pressed: pressed)
        case .leftClick:
            click(.left, pressed: pressed)
        case .rightClick:
            click(.right, pressed: pressed)
        case .middleClick:
            click(.center, pressed: pressed)
        case .shortcut(let spec):
            shortcut(spec, id: id, pressed: pressed)
        }
    }

    private func modeFreezeChanged() {
        if !cursorFrozen { frozenPoint = nil }
    }

    private func radialMenuChanged(pressed: Bool) {
        if pressed {
            radialHeld += 1
            guard radialHeld == 1 else { return }
            let config = ConfigStore.shared.current
            radialItems = Array(currentButtonMap(config).radialMenu.filter { $0.action != .none }.prefix(8))
            radialAnchor = nil
            radialSelection = nil
            frozenPoint = currentCursorPosition()
            radialCenter = frozenPoint ?? .zero
            Hud.shared.showRadial(titles: radialItems.map(\.title), at: radialCenter)
        } else {
            guard radialHeld > 0 else { return }
            radialHeld -= 1
            guard radialHeld == 0 else { return }
            Hud.shared.hideRadial()
            modeFreezeChanged()
            if let index = radialSelection, radialItems.indices.contains(index) {
                let item = radialItems[index]
                Hud.shared.flash(item.title)
                perform(item.action, id: "radial", pressed: true)
                perform(item.action, id: "radial", pressed: false)
            }
            radialSelection = nil
        }
    }

    private func shortcut(_ spec: String, id: String, pressed: Bool) {
        if !pressed {
            if let chord = heldChords.removeValue(forKey: id) {
                postKey(chord, down: false)
            }
            if let button = heldModifiedClicks.removeValue(forKey: id) {
                click(button, pressed: false)
            }
            if heldModifiers[id] != nil {
                setModifiers(nil, for: id)
            }
            return
        }

        switch KeyShortcut.parse(spec) {
        case .key(let chord)?:
            heldChords[id] = chord
            postKey(chord, down: true)
            Hud.shared.flash(ButtonAction.prettyShortcut(spec))
        case .modifiers(let flags)?:
            setModifiers(flags, for: id)
        case .click(let button, let flags)?:
            setModifiers(flags, for: id)
            heldModifiedClicks[id] = button
            click(button, pressed: true)
        case nil:
            FileHandle.standardError.write(Data("[wacomd] Raccourci invalide pour \(id) : \"\(spec)\"\n".utf8))
        }
    }

    /// Holds (or releases, with nil) modifiers for a button, posting the
    /// modifier key transitions apps listen to (flagsChanged).
    private func setModifiers(_ flags: CGEventFlags?, for id: String) {
        let own = flags ?? heldModifiers[id] ?? []
        let before = heldModifierFlags
        heldModifiers[id] = flags
        let after = heldModifierFlags
        for (flag, keyCode) in KeyShortcut.modifierKeyCodes where before.contains(flag) != after.contains(flag) {
            guard let evt = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: after.contains(flag)) else { continue }
            evt.flags = after
            evt.post(tap: .cghidEventTap)
        }
        let names = [(CGEventFlags.maskControl, "⌃"), (.maskAlternate, "⌥"), (.maskShift, "⇧"), (.maskCommand, "⌘")]
        let label = names.filter { own.contains($0.0) }.map(\.1).joined()
        if !label.isEmpty { Hud.shared.setMode(label, active: flags != nil) }
    }

    private func postKey(_ chord: KeyChord, down: Bool) {
        guard let evt = CGEvent(keyboardEventSource: nil, virtualKey: chord.keyCode, keyDown: down) else { return }
        evt.flags = chord.flags.union(heldModifierFlags)
        evt.post(tap: .cghidEventTap)
    }

    private func click(_ button: CGMouseButton, pressed: Bool) {
        let count = heldMouseButtons[button, default: 0]
        if pressed {
            heldMouseButtons[button] = count + 1
            guard count == 0 else { return }
        } else {
            guard count > 0 else { return }
            heldMouseButtons[button] = count - 1
            guard count == 1 else { return }
        }
        let type: CGEventType
        switch button {
        case .left:  type = pressed ? .leftMouseDown : .leftMouseUp
        case .right: type = pressed ? .rightMouseDown : .rightMouseUp
        default:     type = pressed ? .otherMouseDown : .otherMouseUp
        }
        if lastInRange, let model = lastModel {
            postMouseEvent(type: type, at: lastPoint, state: lastState, model: model, button: button)
        } else if let evt = CGEvent(mouseEventSource: nil, mouseType: type,
                                    mouseCursorPosition: currentCursorPosition(), mouseButton: button) {
            let flags = heldModifierFlags
            if !flags.isEmpty { evt.flags = flags }
            evt.post(tap: .cghidEventTap)
        }
    }

    /// Unplugging the tablet must not leave a mode latched on : no button
    /// can turn it off any more. Releases everything the driver holds.
    func resetState() {
        gestures.reset()
        for (button, count) in heldMouseButtons where count > 0 {
            heldMouseButtons[button] = 1
            click(button, pressed: false)
        }
        heldMouseButtons.removeAll()
        for (id, chord) in heldChords {
            postKey(chord, down: false)
            heldChords[id] = nil
        }
        for id in heldModifiers.keys { setModifiers(nil, for: id) }
        heldModifiedClicks.removeAll()
        toggledActions.removeAll()
        layerHeld = 0
        precisionHeld = 0
        mouseModeHeld = 0
        stabilizerHeld = 0
        brushSizeHeld = 0
        eraserHeld = 0
        scrollHeld = 0
        penGesturesHeld = 0
        handwritingHeld = 0
        handwritingStrokeOpen = false
        radialHeld = 0
        radialSelection = nil
        radialItems = []
        relativePen = nil
        smoothedPoint = nil
        frozenPoint = nil
        penGestureAnchor = nil
        scrollAnchor = nil
        brushAnchorX = nil
        lastLowerButton = false
        lastUpperButton = false
        Hud.shared.hideRadial()
        Hud.shared.clearModes()
        Handwriting.shared.finishNow()
        Verbose.log("état remis à zéro (tablette déconnectée)")
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

        // Eraser tool IDs have a low nibble of 0xa (Grip Pen 0x802 → 0x80a).
        let vendorPointerType = currentPointerType == .eraser ? (currentToolID & ~0xf) | 0xa : currentToolID

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
                                 value: vendorPointerType)
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
        let config = ConfigStore.shared.current
        let bounds = displayBounds(index: config.displayIndex)
        let orientation = config.tabletOrientation
        // The active area is expressed in the surface as the user sees it.
        let area = config.effectiveArea(tabletAspect: orientation.aspect(tabletAspect: model.widthMM / model.heightMM),
                                        screenAspect: Double(bounds.width / bounds.height))
        let seen = orientation.orient(x: state.x / model.maxX, y: state.y / model.maxY)
        let normX = clamp((seen.x - area.left) / (area.right - area.left), 0, 1)
        let normY = clamp((seen.y - area.top) / (area.bottom - area.top), 0, 1)
        return CGPoint(x: bounds.minX + CGFloat(normX) * (bounds.width - 1),
                       y: bounds.minY + CGFloat(normY) * (bounds.height - 1))
    }

    /// Global CG bounds (top-left origin) of `NSScreen.screens[index]`,
    /// falling back to the menu-bar display. Cached for a second since this
    /// runs for every pen report.
    private func displayBounds(index: Int) -> CGRect {
        let now = CFAbsoluteTimeGetCurrent()
        if let cached = cachedDisplay, cached.index == index, now - cached.at < 1 {
            return cached.bounds
        }
        let screens = NSScreen.screens
        let screen = screens.indices.contains(index) ? screens[index] : screens.first
        var bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        if let number = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            bounds = CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
        }
        cachedDisplay = (index, bounds, now)
        return bounds
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

        // Modifiers held by a button (⌥ pipette, ⇧ + middle-drag…).
        let flags = heldModifierFlags
        if !flags.isEmpty { evt.flags = flags }

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

    // MARK: - Keyboard shortcut emission (for 3-finger gestures)

    /// Post a single keyboard chord (modifier flags + virtual key code).
    /// Used by the 3-finger gesture handler to fire system shortcuts like
    /// Mission Control (Ctrl+↑) or "switch Space" (Ctrl+←/→).
    func postKeyCombo(keyCode: CGKeyCode, modifiers: CGEventFlags) {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let up   = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
        else { return }
        down.flags = modifiers
        up.flags = modifiers
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        Verbose.log(String(format: "key combo keyCode=0x%02x modifiers=0x%08x", keyCode, modifiers.rawValue))
    }

    /// Post a middle-mouse click at the current cursor position.
    /// Used as the default 3-finger tap binding.
    func middleClick() {
        let p = currentCursorPosition()
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown,
                                 mouseCursorPosition: p, mouseButton: .center),
              let up   = CGEvent(mouseEventSource: nil, mouseType: .otherMouseUp,
                                 mouseCursorPosition: p, mouseButton: .center)
        else { return }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    // MARK: - Scroll wheel (2-finger touch, hover scroll)

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

        let flags = heldModifierFlags
        if !flags.isEmpty { evt.flags = flags }
        evt.post(tap: .cghidEventTap)
        Verbose.log(String(format: "scroll dy=%d dx=%d", intDy, intDx))
    }

    private func tabletButtonsMask(state: PenState) -> Int64 {
        var mask: Int64 = 0
        if state.tipDown      { mask |= 0x01 }
        if state.lowerButton  { mask |= 0x02 }
        if state.upperButton || state.eraser { mask |= 0x04 }
        return mask
    }

    private func clamp<T: Comparable>(_ x: T, _ lo: T, _ hi: T) -> T {
        min(max(x, lo), hi)
    }
}
