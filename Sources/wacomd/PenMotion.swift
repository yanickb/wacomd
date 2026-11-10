import Foundation
import WacomdShared

struct PenMotionResult {
    var relative = false
    var delta = CGPoint.zero
    var scroll = CGPoint.zero
    var buttonScrolling = false
    var middleClick = false
}

/// Pure coordinate/gesture state; no CGEvent creation or posting.
struct PenMotion {
    private struct Options: Equatable {
        var mode: PenPositionMode
        var sensitivityX, sensitivityY, resetSeconds, scrollSensitivity: Double
        var button: PenScrollButton
        var natural, tapMiddle: Bool
        init(_ config: WacomdConfig) {
            func bounded(_ value: Double, _ fallback: Double, _ low: Double, _ high: Double) -> Double {
                value.isFinite ? min(max(value, low), high) : fallback
            }
            mode = config.penMode
            sensitivityX = bounded(config.penSensitivityX, 20, 0, 200)
            sensitivityY = bounded(config.penSensitivityY, 20, 0, 200)
            resetSeconds = bounded(config.penRelativeResetMs, 100, 1, 5000) / 1000
            scrollSensitivity = bounded(config.penScrollSensitivity, 12, 0, 200)
            button = config.penScrollButton
            natural = config.penScrollNatural
            tapMiddle = config.penScrollTapMiddleClick
        }
    }
    private var options: Options?
    private var lastPosition: CGPoint?
    private var lastTime: Double?
    private var buttonDown = false
    private var pressOrigin = CGPoint.zero
    private var pressTime = 0.0
    private var clickEligible = false
    private var scrolling = false
    private var remainder = CGPoint.zero

    mutating func reset() {
        lastPosition = nil
        lastTime = nil
        buttonDown = false
        clickEligible = false
        scrolling = false
        remainder = .zero
    }

    mutating func update(state: PenState, model: WacomModel, config: WacomdConfig,
                         now: Double) -> PenMotionResult {
        let next = Options(config)
        if next != options { reset(); options = next }
        var output = PenMotionResult(relative: next.mode == .relative)
        guard state.inRange, state.x.isFinite, state.y.isFinite, now.isFinite,
              model.maxX > 0, model.maxY > 0, model.widthMM > 0, model.heightMM > 0 else {
            reset()
            return output
        }
        let position = CGPoint(x: state.x, y: state.y)
        let scale = CGPoint(x: model.widthMM / model.maxX, y: model.heightMM / model.maxY)
        func millimetres(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
            CGPoint(x: (a.x - b.x) * scale.x, y: (a.y - b.y) * scale.y)
        }
        func length(_ delta: CGPoint) -> Double { hypot(delta.x, delta.y) }
        let pressed: Bool
        switch next.button {
        case .disabled: pressed = false
        case .lower: pressed = state.barrelButton1
        case .upper: pressed = state.barrelButton2
        }
        output.buttonScrolling = pressed
        let otherButton = next.button == .upper ? state.barrelButton1 : state.barrelButton2
        let contact = state.tipDown || state.pressure > 0 || otherButton || state.eraser
        let gap = lastTime.map { now < $0 || now - $0 > next.resetSeconds } ?? true
        let transition = pressed != buttonDown
        defer {
            lastPosition = position
            lastTime = now
            buttonDown = pressed
        }
        if lastPosition == nil || gap || transition {
            if !pressed && buttonDown && !gap {
                output.middleClick = next.tapMiddle && clickEligible && !contact &&
                    now - pressTime <= 0.5 && length(millimetres(position, pressOrigin)) <= 0.3
            }
            remainder = .zero
            scrolling = false
            if pressed {
                pressOrigin = position
                pressTime = now
                clickEligible = transition && !gap && !contact
            } else {
                clickEligible = false
            }
            return output
        }
        if pressed {
            let excursion = millimetres(position, pressOrigin)
            clickEligible = clickEligible && !contact && now - pressTime <= 0.5 && length(excursion) <= 0.3
            var delta = millimetres(position, lastPosition!)
            if !scrolling {
                guard length(excursion) > 0.3 else { return output }
                scrolling = true
                clickEligible = false
                delta = excursion
            }
            let sign = next.natural ? -1.0 : 1.0
            remainder.x += delta.x * next.scrollSensitivity * sign
            remainder.y += delta.y * next.scrollSensitivity * sign
            guard remainder.x.isFinite, remainder.y.isFinite else {
                remainder = .zero
                return output
            }
            func whole(_ value: Double) -> Double {
                min(max(value.rounded(.towardZero), -Double(Int32.max)), Double(Int32.max))
            }
            output.scroll = CGPoint(x: whole(remainder.x), y: whole(remainder.y))
            remainder.x -= output.scroll.x
            remainder.y -= output.scroll.y
        } else if next.mode == .relative {
            let delta = millimetres(position, lastPosition!)
            output.delta = CGPoint(x: delta.x * next.sensitivityX, y: delta.y * next.sensitivityY)
        }
        return output
    }
}
