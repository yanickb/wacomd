import Foundation

setbuf(stdout, nil)

print("""
[wacomd] Démon de pilote Wacom pour macOS — version 0.4.0
[wacomd] Modèle supporté actuellement: Intuos Pro Small (PTH-451)
[wacomd] Fonctionnalités: stylet + pression + tap/1-doigt/2-doigts touch
""")

// 1. Permissions Accessibilité — déclenche la pop-up macOS la 1re fois.
let axOK = Permissions.requestAccessibility(prompt: true)
print("[wacomd] Accessibilité ........... \(axOK ? "accordée" : "REFUSÉE — cochez 'wacomd' dans Accessibilité puis relancez")")

// 2. Permissions Surveillance des entrées.
let imStatus = Permissions.inputMonitoringStatus()
print("[wacomd] Surveillance des entrées . \(imStatus.humanReadable)")
if imStatus == .undetermined || imStatus == .denied {
    // Tente d'ouvrir la fenêtre de demande système (SPI, dégrade en silence).
    Permissions.requestInputMonitoring()
}

if !axOK || imStatus == .denied {
    print("""

    [wacomd] Sans ces deux permissions le pilote ne peut pas fonctionner.
    Ouvrez les panneaux avec ces commandes :

        open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        open "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"

    Cochez l'entrée 'wacomd' (utilisez le bouton '+' et sélectionnez
    .build/release/wacomd si elle n'apparaît pas), puis relancez le démon.

    """)
}

let monitor = HIDMonitor()
monitor.start()

let signals: [Int32] = [SIGINT, SIGTERM]
var sources: [DispatchSourceSignal] = []
for sig in signals {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler {
        print("\n[wacomd] Arrêt demandé.")
        monitor.stop()
        exit(0)
    }
    src.resume()
    sources.append(src)
}
_ = sources

print("[wacomd] En attente d'une tablette… (Ctrl+C pour quitter)")
RunLoop.current.run()
