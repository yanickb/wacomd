import Foundation
import IOKit
import IOKit.hid

final class HIDMonitor {
    private var manager: IOHIDManager!
    private var devices: [IOHIDDevice: WacomDevice] = [:]

    static let wacomVendorID = 0x056a

    func start() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

        // Match any Wacom device, filter by known PIDs inside the callback.
        let matching: [String: Any] = [
            kIOHIDVendorIDKey: HIDMonitor.wacomVendorID
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

        let opaque = Unmanaged.passUnretained(self).toOpaque()

        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, device in
            guard let ctx = ctx else { return }
            let m = Unmanaged<HIDMonitor>.fromOpaque(ctx).takeUnretainedValue()
            m.deviceAdded(device)
        }, opaque)

        IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, device in
            guard let ctx = ctx else { return }
            let m = Unmanaged<HIDMonitor>.fromOpaque(ctx).takeUnretainedValue()
            m.deviceRemoved(device)
        }, opaque)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if result != kIOReturnSuccess {
            let hex = String(format: "0x%08x", result)
            FileHandle.standardError.write(Data("""
                [wacomd] IOHIDManagerOpen a échoué (\(hex)).
                  → Ouvrez Réglages Système > Confidentialité et sécurité > Surveillance des entrées,
                    autorisez le binaire 'wacomd', puis relancez le démon.

                """.utf8))
        }
    }

    func stop() {
        for (_, device) in devices { device.stop() }
        devices.removeAll()
        if manager != nil {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        }
    }

    private func deviceAdded(_ device: IOHIDDevice) {
        let vid = (IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int) ?? 0
        let pid = (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int) ?? 0
        let product = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String) ?? "Wacom"

        guard let model = KnownModels.lookup(vendorID: vid, productID: pid) else {
            let hex = String(format: "VID 0x%04x PID 0x%04x", vid, pid)
            print("[wacomd] Périphérique Wacom inconnu ignoré: \(product) (\(hex))")
            return
        }

        // The same physical tablet exposes several HID interfaces (pen, touch, pad).
        // We currently open every matching interface and let the input-value
        // callback parse what it understands.
        print("[wacomd] + Connecté: \(model.name)")
        let wacom = WacomDevice(device: device, model: model)
        wacom.start()
        devices[device] = wacom
    }

    private func deviceRemoved(_ device: IOHIDDevice) {
        guard let wacom = devices.removeValue(forKey: device) else { return }
        print("[wacomd] - Déconnecté: \(wacom.modelName)")
        wacom.stop()
    }
}
