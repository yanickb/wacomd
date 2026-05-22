import Foundation

/// Maintains frame-to-frame state of the multi-touch surface and turns
/// 2-finger drags into scroll events.
final class TouchTracker {
    private let injector: EventInjector
    private var lastCentroidA: Double?
    private var lastCentroidB: Double?

    /// Scroll sensitivity. Touch position bytes span roughly 0..65535 across
    /// the surface. A full-tablet swipe should scroll ~600 pixels (one big
    /// page), so scale = 600/30000 ≈ 0.02.
    private let scrollScale: Double = 0.02

    /// Dead zone in raw position units to dampen jitter.
    private let deadZone: Double = 8

    /// Per-event cap (scroll pixels) — prevents extreme jumps when the
    /// finger ID set changes between two consecutive frames.
    private let maxPerEvent: Double = 80

    init(injector: EventInjector) {
        self.injector = injector
    }

    func handleFrame(contacts: [TouchContact]) {
        // We only act on exactly two fingers in contact. 1-finger gestures
        // are reserved for the pen ; 3+ fingers are out of scope (would
        // need private SPI).
        guard contacts.count == 2 else {
            lastCentroidA = nil
            lastCentroidB = nil
            return
        }

        let centroidA = Double(contacts[0].positionA + contacts[1].positionA) / 2.0
        let centroidB = Double(contacts[0].positionB + contacts[1].positionB) / 2.0

        defer {
            lastCentroidA = centroidA
            lastCentroidB = centroidB
        }

        guard let prevA = lastCentroidA, let prevB = lastCentroidB else { return }

        let deltaA = centroidA - prevA
        let deltaB = centroidB - prevB

        if abs(deltaA) < deadZone && abs(deltaB) < deadZone { return }

        // The position bytes don't have a documented X/Y mapping yet, so we
        // assume positionA correlates with one axis and positionB with the
        // other. On the PTH-451 over USB, empirically deltaB tracks the
        // "long axis" of the tablet (= horizontal in default orientation,
        // = scroll Y for the user).
        //
        // The signs are flipped so that fingers moving "down/right" produce
        // the natural macOS scroll direction (the OS handles the user's
        // "natural scrolling" preference on top).
        let rawScrollY = -deltaB * scrollScale
        let rawScrollX = -deltaA * scrollScale
        let scrollY = max(-maxPerEvent, min(maxPerEvent, rawScrollY))
        let scrollX = max(-maxPerEvent, min(maxPerEvent, rawScrollX))
        injector.scroll(dx: scrollX, dy: scrollY)
    }
}
