import SwiftUI
import AppKit
import WacomdShared

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// .regular = Dock icon visible + can have a main window.
// On macOS Tahoe, .accessory + MenuBarExtra is too fragile for some
// configurations (notch, menu-bar saturation, Control-Center routing) ;
// a regular app is guaranteed to be visible.
app.setActivationPolicy(.regular)
app.run()

// MARK: - AppKit menu-bar driver

/// Uses NSStatusItem instead of SwiftUI's `MenuBarExtra`. The SwiftUI
/// MenuBarExtra has a known issue on macOS 26 Tahoe where the icon
/// silently fails to appear in the system menu bar; NSStatusItem is the
/// battle-tested AppKit API that has shipped since macOS 10.10.
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model = ConfigModel()
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // ---- Main window : guaranteed-visible, normal macOS window. ------
        let host = NSHostingController(rootView: ConfigView(model: model))
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 580),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = "Wacomd Config"
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .visible
        win.contentViewController = host
        win.center()
        win.isReleasedWhenClosed = false
        win.delegate = self
        self.window = win

        // ---- Menu-bar item (bonus). If macOS Tahoe routes it into Control
        //      Center or hides it behind the notch the user can still
        //      access the app via the Dock icon + window.
        if let bar = NSStatusBar.system.statusItem(withLength: 28) as NSStatusItem? {
            bar.isVisible = true
            if let button = bar.button {
                let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
                let img = NSImage(systemSymbolName: "pencil.tip.crop.circle",
                                  accessibilityDescription: "wacomd")?
                    .withSymbolConfiguration(cfg)
                img?.isTemplate = true
                button.image = img
                if img == nil { button.title = "wacomd" }
                button.toolTip = "Wacomd Config"
                button.action = #selector(toggle(_:))
                button.target = self
                button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            }
            statusItem = bar

            popover = NSPopover()
            popover?.behavior = .transient
            popover?.animates = true
            popover?.contentSize = NSSize(width: 320, height: 540)
            popover?.contentViewController = NSHostingController(
                rootView: ConfigView(model: model)
            )
        }

        // ---- Show the window front-and-centre at launch.
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    // Close button on the window : hide instead of terminate, so the menu
    // bar / Dock icon path still works for re-opening.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)   // hide Dock icon while hidden
        return false
    }

    // When the user re-activates the Dock icon, restore the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    private func showWindow() {
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func toggle(_ sender: Any?) {
        // Status-bar click : open the window. Simpler and more reliable than
        // the popover, which can get cut off near the screen edge with the
        // notch.
        showWindow()
    }
}

// MARK: - View model

final class ConfigModel: ObservableObject {
    @Published var config: WacomdConfig {
        didSet { scheduleSave() }
    }
    @Published private(set) var daemonRunning: Bool = false

    private var saveWorkItem: DispatchWorkItem?
    private var refreshTimer: Timer?

    init() {
        self.config = ConfigStore.shared.current
        refreshDaemonStatus()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.refreshDaemonStatus() }
        }
    }

    func refreshDaemonStatus() {
        daemonRunning = (DaemonControl.runningPID() != nil)
    }

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let snapshot = config
        let work = DispatchWorkItem {
            if ConfigStore.shared.save(snapshot) {
                DaemonControl.sendReloadSignal()
            }
        }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func resetToDefaults() {
        config = WacomdConfig()
    }
}

// MARK: - Main view

struct ConfigView: View {
    @ObservedObject var model: ConfigModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            masterToggle
            Divider()
            togglesSection
                .disabled(!model.config.touchEnabled)
                .opacity(model.config.touchEnabled ? 1.0 : 0.45)
            Divider()
            slidersSection
                .disabled(!model.config.touchEnabled)
                .opacity(model.config.touchEnabled ? 1.0 : 0.45)
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 320)
    }

    private var header: some View {
        HStack {
            Image(systemName: model.daemonRunning ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(model.daemonRunning ? .green : .orange)
            VStack(alignment: .leading) {
                Text("wacomd").font(.headline)
                Text(model.daemonRunning ? "Démon actif" : "Démon arrêté")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var masterToggle: some View {
        Toggle(isOn: $model.config.touchEnabled) {
            HStack(spacing: 6) {
                Image(systemName: "hand.tap.fill")
                Text("Tactile").font(.headline)
            }
        }
        .toggleStyle(.switch)
        .help("Active ou désactive entièrement la surface tactile (1, 2 et 3 doigts).")
    }

    private var togglesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Curseur 1 doigt",   isOn: $model.config.oneFingerCursor)
            Toggle("Scroll 2 doigts",   isOn: $model.config.twoFingerScroll)
            Toggle("Scroll naturel",    isOn: $model.config.naturalScroll)
                .help("Activé : doigt ↓ = page ↓ (style macOS). Désactivé : doigt ↓ = page ↑ (style classique).")
            Toggle("Gestes 3 doigts",   isOn: $model.config.threeFingerSwipes)
            Toggle("Tap to click",      isOn: $model.config.tapToClick)
        }
        .toggleStyle(.switch)
    }

    private var slidersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sliderRow(
                label: "Sensibilité curseur",
                value: $model.config.cursorSensitivity,
                range: 0.05...1.5,
                format: { String(format: "%.2f", $0) }
            )
            sliderRow(
                label: "Sensibilité scroll",
                value: $model.config.scrollSensitivity,
                range: 0.05...2.0,
                format: { String(format: "%.2f", $0) }
            )
            sliderRow(
                label: "Seuil swipe 3 doigts",
                value: $model.config.threeFingerSwipeThreshold,
                range: 50...500,
                format: { String(format: "%.0f", $0) }
            )
            sliderRow(
                label: "Durée max tap (ms)",
                value: Binding(
                    get: { Double(model.config.tapMaxDurationMs) },
                    set: { model.config.tapMaxDurationMs = Int($0) }
                ),
                range: 50...300,
                format: { String(format: "%.0f", $0) }
            )
            sliderRow(
                label: "Drift max tap",
                value: $model.config.tapMaxRawMovement,
                range: 5...100,
                format: { String(format: "%.0f", $0) }
            )
        }
    }

    private func sliderRow(
        label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        format: @escaping (Double) -> String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.caption)
                Spacer()
                Text(format(value.wrappedValue))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
    }

    private var footer: some View {
        HStack {
            Button("Réinitialiser") { model.resetToDefaults() }
                .controlSize(.small)
            Spacer()
            Button("Quitter") { NSApplication.shared.terminate(nil) }
                .controlSize(.small)
        }
    }
}
