import Foundation
import WacomdShared

/// Publishes live pen / button state to the configurator's Test tab over
/// distributed notifications, only while that tab is subscribed.
final class LiveStatus {
    static let shared = LiveStatus()

    private var subscribedUntil: CFAbsoluteTime = 0
    private var lastPenPost: CFAbsoluteTime = 0
    /// Profile to use while the configurator is frontmost (nil = its own).
    private(set) var testBundleID: String?

    var active: Bool { CFAbsoluteTimeGetCurrent() < subscribedUntil }

    func start() {
        DistributedNotificationCenter.default().addObserver(
            forName: LiveStatusNames.subscribe, object: nil, queue: .main
        ) { [weak self] note in
            guard let self = self else { return }
            self.subscribedUntil = CFAbsoluteTimeGetCurrent() + LiveStatusNames.subscriptionLifetime
            let id = note.userInfo?[LiveStatusNames.testBundleIDKey] as? String ?? ""
            self.testBundleID = id.isEmpty ? nil : id
        }
    }

    /// `info` must only hold property-list values. Pen samples are capped at 30 Hz.
    func post(_ info: [String: Any], isPenSample: Bool = false) {
        guard active else { return }
        if isPenSample {
            let now = CFAbsoluteTimeGetCurrent()
            guard now - lastPenPost >= 1.0 / 30 else { return }
            lastPenPost = now
        }
        DistributedNotificationCenter.default().postNotificationName(
            LiveStatusNames.status, object: nil, userInfo: info, deliverImmediately: true)
    }
}
