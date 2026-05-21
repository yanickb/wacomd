import Foundation
import ApplicationServices
import IOKit.hid

enum Permissions {
    /// Demande l'autorisation Accessibilité. Avec `prompt: true`, macOS ouvre
    /// la fenêtre de demande la première fois ; sinon retourne simplement
    /// l'état courant.
    @discardableResult
    static func requestAccessibility(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as NSString
        let options: NSDictionary = [key: prompt]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    /// Tente d'évaluer le statut "Surveillance des entrées".
    /// macOS n'expose pas d'API publique propre pour ça : on déduit l'état
    /// par `IOHIDCheckAccess` (SPI privée, mais ABI stable depuis 10.15).
    /// Si le symbole n'existe pas, on retourne `.unknown`.
    static func inputMonitoringStatus() -> InputMonitoringStatus {
        typealias CheckFn = @convention(c) (UInt32) -> Int32
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "IOHIDCheckAccess") else {
            return .unknown
        }
        let fn = unsafeBitCast(sym, to: CheckFn.self)
        // kIOHIDRequestTypeListenEvent = 1
        switch fn(1) {
        case 0:  return .granted
        case 1:  return .denied
        case 2:  return .undetermined
        default: return .unknown
        }
    }

    /// Tente d'ouvrir la fenêtre de permission "Surveillance des entrées".
    /// Idem : SPI non publique, dégradation propre si absente.
    static func requestInputMonitoring() {
        typealias RequestFn = @convention(c) (UInt32, @convention(c) (Bool, UnsafeMutableRawPointer?) -> Void, UnsafeMutableRawPointer?) -> Void
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "IOHIDRequestAccess") else {
            return
        }
        let fn = unsafeBitCast(sym, to: RequestFn.self)
        // Note: certaines versions exposent une variante synchrone à 1 argument.
        // On tente la version "async with callback", sans capturer le résultat.
        let cb: @convention(c) (Bool, UnsafeMutableRawPointer?) -> Void = { _, _ in }
        fn(1, cb, nil)
    }
}

enum InputMonitoringStatus {
    case granted
    case denied
    case undetermined
    case unknown
}

extension InputMonitoringStatus {
    var humanReadable: String {
        switch self {
        case .granted:      return "accordée"
        case .denied:       return "REFUSÉE — cochez 'wacomd' dans Surveillance des entrées"
        case .undetermined: return "non encore demandée"
        case .unknown:      return "indéterminée"
        }
    }
}
