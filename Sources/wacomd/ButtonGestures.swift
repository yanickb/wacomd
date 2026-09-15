import Foundation
import WacomdShared

/// Turns raw press / release transitions of each physical button into
/// press / release of actions, recognising double and long presses.
///
/// - Binding without gestures : the press action follows the button.
/// - With a long action : held past `longPress`, the long action starts
///   and lasts until release.
/// - With a double action : a second press within `doubleTap` of the first
///   release runs the double action for as long as it is held.
/// - Otherwise the press action is fired as a short tap once the delays
///   are over.
///
/// Everything runs on the main queue.
final class ButtonGestures {
    typealias Emit = (_ action: ButtonAction, _ id: String, _ pressed: Bool) -> Void

    private enum Phase {
        /// An action is down and will be released with the button.
        case holding(ButtonAction)
        /// Pressed, waiting to know whether it becomes a long press.
        case pressed(ButtonBinding, token: Int)
        /// Released once, waiting for a possible second press.
        case awaitingDouble(ButtonBinding, token: Int)
    }

    private var phases: [String: Phase] = [:]
    private var nextToken = 0
    private let emit: Emit

    init(emit: @escaping Emit) {
        self.emit = emit
    }

    func changed(id: String, pressed: Bool, doubleTap: TimeInterval, longPress: TimeInterval,
                 binding: () -> ButtonBinding) {
        if pressed {
            press(id: id, longPress: longPress, binding: binding)
        } else {
            release(id: id, doubleTap: doubleTap)
        }
    }

    private func press(id: String, longPress: TimeInterval, binding: () -> ButtonBinding) {
        if case .awaitingDouble(let b, _)? = phases[id] {
            phases[id] = .holding(b.double)
            emit(b.double, id, true)
            return
        }

        let b = binding()
        guard b.hasGestures else {
            phases[id] = .holding(b.press)
            emit(b.press, id, true)
            return
        }

        let token = makeToken()
        phases[id] = .pressed(b, token: token)
        guard b.long != .none else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + longPress) { [weak self] in
            guard let self = self, case .pressed(_, let current)? = self.phases[id], current == token else { return }
            self.phases[id] = .holding(b.long)
            self.emit(b.long, id, true)
        }
    }

    private func release(id: String, doubleTap: TimeInterval) {
        switch phases[id] {
        case .holding(let action)?:
            phases[id] = nil
            emit(action, id, false)
        case .pressed(let b, _)?:
            guard b.double != .none else {
                phases[id] = nil
                tap(b.press, id: id)
                return
            }
            let token = makeToken()
            phases[id] = .awaitingDouble(b, token: token)
            DispatchQueue.main.asyncAfter(deadline: .now() + doubleTap) { [weak self] in
                guard let self = self, case .awaitingDouble(_, let current)? = self.phases[id], current == token else { return }
                self.phases[id] = nil
                self.tap(b.press, id: id)
            }
        case .awaitingDouble?, nil:
            break
        }
    }

    private func tap(_ action: ButtonAction, id: String) {
        emit(action, id, true)
        emit(action, id, false)
    }

    private func makeToken() -> Int {
        nextToken += 1
        return nextToken
    }
}
