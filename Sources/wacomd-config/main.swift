import SwiftUI
import AppKit
import WacomdShared

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)  // no Dock icon — menu-bar only
app.run()

// MARK: - AppKit menu-bar driver

/// Uses NSStatusItem instead of SwiftUI's `MenuBarExtra`. The SwiftUI
/// MenuBarExtra has a known issue on macOS 26 Tahoe where the icon
/// silently fails to appear in the system menu bar; NSStatusItem is the
/// battle-tested AppKit API that has shipped since macOS 10.10.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = ConfigModel()
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var monitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 1. Reserve a slot in the menu bar.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            // SF Symbol icon ; on a MacBook with a notch we still want a
            // visible glyph, so we set both the image and an accessibility
            // description (for VoiceOver).
            let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
            let image = NSImage(systemSymbolName: "pencil.tip.crop.circle",
                                accessibilityDescription: "wacomd")?
                .withSymbolConfiguration(cfg)
            image?.isTemplate = true       // tints to the menu-bar's foreground colour
            button.image = image
            button.toolTip = "wacomd — paramétrage"
            button.action = #selector(toggle(_:))
            button.target = self
            // Allow right-click to also toggle, plus left-click default.
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // 2. Build the popover that hosts the SwiftUI settings panel.
        popover = NSPopover()
        popover.behavior = .transient            // dismiss on click-outside
        popover.animates = true
        popover.contentSize = NSSize(width: 320, height: 540)
        popover.contentViewController = NSHostingController(
            rootView: ConfigView(model: model)
        )
    }

    @objc private func toggle(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Auto-dismiss on click outside the popover.
        if monitor == nil {
            monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                self?.popover.performClose(nil)
            }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
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
