import Foundation
import IOKit.hid

/// Page HID *vendor-defined* utilisée par les Intuos Pro pour l'interface du
/// stylet. Tous les rapports pen (X/Y/pression/tilt) arrivent ici, en raw.
private let wacomDigitizerUsagePage = 0xff0d

final class WacomDevice {
    private let device: IOHIDDevice
    let model: WacomModel
    private let injector: EventInjector
    private var state = PenState()
    private var reportBuffer = [UInt8](repeating: 0, count: 64)
    private let usagePage: Int
    private let usage: Int
    private let interfaceLabel: String
    private let isPenInterface: Bool

    var modelName: String { model.name }

    init(device: IOHIDDevice, model: WacomModel) {
        self.device = device
        self.model = model
        self.injector = EventInjector()

        let pu  = (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? Int) ?? 0
        let pup = (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int) ?? 0
        self.usagePage = pup
        self.usage = pu
        self.interfaceLabel = String(format: "page=0x%02x usage=0x%02x", pup, pu)
        self.isPenInterface = (pup == wacomDigitizerUsagePage)
    }

    func start() {
        let opaque = Unmanaged.passUnretained(self).toOpaque()

        IOHIDDeviceRegisterInputValueCallback(device, { ctx, _, _, value in
            guard let ctx = ctx else { return }
            let dev = Unmanaged<WacomDevice>.fromOpaque(ctx).takeUnretainedValue()
            dev.handle(value: value)
        }, opaque)

        reportBuffer.withUnsafeMutableBufferPointer { buf in
            IOHIDDeviceRegisterInputReportCallback(
                device,
                buf.baseAddress!,
                CFIndex(buf.count),
                // (context, result, sender, type, reportID, report, reportLength)
                { ctx, _, _, _, reportID, report, reportLength in
                    guard let ctx = ctx else { return }
                    let dev = Unmanaged<WacomDevice>.fromOpaque(ctx).takeUnretainedValue()
                    dev.handle(report: report, length: reportLength, id: reportID)
                },
                opaque
            )
        }

        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        if result != kIOReturnSuccess {
            let hex = String(format: "0x%08x", result)
            FileHandle.standardError.write(Data("[wacomd] IOHIDDeviceOpen a échoué (\(hex)) sur \(interfaceLabel)\n".utf8))
        } else {
            Verbose.log("Ouvert interface \(interfaceLabel) (penInterface=\(isPenInterface))")
            dumpElements()
        }
    }

    func stop() {
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    }

    private func dumpElements() {
        guard Verbose.enabled else { return }
        let elems = IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] ?? []
        Verbose.log("  \(elems.count) éléments HID :")
        for e in elems {
            let p = IOHIDElementGetUsagePage(e)
            let u = IOHIDElementGetUsage(e)
            let k = IOHIDElementGetType(e)
            let lo = IOHIDElementGetLogicalMin(e), hi = IOHIDElementGetLogicalMax(e)
            Verbose.log(String(format: "    type=%d page=0x%04x usage=0x%04x range=%d..%d",
                               k.rawValue, p, u, lo, hi))
        }
    }

    // MARK: - Rapports HID bruts (Wacom vendor-defined)

    private func handle(report: UnsafeMutablePointer<UInt8>?, length: CFIndex, id: UInt32) {
        guard let report = report, length > 0 else { return }

        if Verbose.enabled {
            let bytes = (0..<min(Int(length), 16)).map { String(format: "%02x", report[$0]) }.joined(separator: " ")
            Verbose.log("rapport id=\(id) len=\(length) [\(interfaceLabel)] : \(bytes)\(length > 16 ? " …" : "")")
        }

        guard isPenInterface else { return }

        switch IntuosProParser.decode(reportID: id, data: report, length: Int(length)) {
        case .ignored:
            return
        case .proximityLeave:
            state.inRange = false
            state.tipDown = false
            state.barrelButton = false
            state.eraser = false
            injector.update(state: state, model: model)
        case .proximityEnter(let toolID, let serial):
            state.inRange = true
            // Le toolID de la gomme commence par 0x0e (Linux : wacom_intuos_get_tool_type).
            // Pour le Grip Pen standard livré avec la PTH-451 (LP-180), tool ≈ 0x802.
            state.eraser = ((toolID & 0x0fff) == 0x82a)
            injector.updateToolIdentity(toolID: toolID, serial: serial, isEraser: state.eraser)
            Verbose.log(String(format: "proximité ON, toolID=0x%05x serial=0x%llx", toolID, serial))
        case .pen(let sample):
            state.x = Double(sample.x)
            state.y = Double(sample.y)
            state.pressure = min(1.0, max(0.0, Double(sample.pressure) / model.maxPressure))
            state.tiltX = Double(sample.tiltX)
            state.tiltY = Double(sample.tiltY)
            state.inRange = true
            state.tipDown = sample.tipDown
            state.barrelButton = sample.barrelButton1 || sample.barrelButton2
            injector.update(state: state, model: model)
        }
    }

    // MARK: - Évènements HID structurés (utilisés si Apple décode quelque chose)

    private func handle(value: IOHIDValue) {
        guard Verbose.enabled else { return }
        let element = IOHIDValueGetElement(value)
        let page = Int(IOHIDElementGetUsagePage(element))
        let usage = Int(IOHIDElementGetUsage(element))
        let raw = IOHIDValueGetIntegerValue(value)
        Verbose.log(String(format: "valeur page=0x%04x usage=0x%04x v=%d [\(interfaceLabel)]", page, usage, raw))
    }
}
