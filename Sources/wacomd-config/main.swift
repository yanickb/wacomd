import SwiftUI
import AppKit
import Carbon.HIToolbox
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
        didSet { if !applyingDiskChange { scheduleSave() } }
    }
    /// True while copying a config the daemon wrote, so it isn't saved back.
    private var applyingDiskChange = false
    @Published private(set) var daemonRunning: Bool = false

    private var saveWorkItem: DispatchWorkItem?
    private var refreshTimer: Timer?

    init() {
        self.config = ConfigStore.shared.current
        refreshDaemonStatus()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.refreshDaemonStatus()
                self?.syncFromDisk()
            }
        }
    }

    func refreshDaemonStatus() {
        daemonRunning = (DaemonControl.runningPID() != nil)
    }

    /// The daemon persists `touchEnabled` when an ExpressKey toggles it ;
    /// mirror that here, unless a local edit is still waiting to be saved.
    func syncFromDisk() {
        guard saveWorkItem == nil else { return }
        let onDisk = ConfigStore.shared.readFromDisk()
        guard onDisk != config else { return }
        applyingDiskChange = true
        config = onDisk
        applyingDiskChange = false
    }

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let snapshot = config
        let work = DispatchWorkItem { [weak self] in
            self?.saveWorkItem = nil
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
            ExpressKeysSection(model: model)
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxHeight: .infinity, alignment: .top)
        .scrollableIfNeeded()
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

private extension View {
    func scrollableIfNeeded() -> some View {
        ScrollView(.vertical) { self }
    }
}

// MARK: - ExpressKeys

struct ExpressKeysSection: View {
    @ObservedObject var model: ConfigModel
    /// Index of the key whose shortcut is being recorded, if any.
    @State private var recording: Int?
    @State private var monitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "keyboard")
                Text("ExpressKeys").font(.headline)
            }
            ForEach(0..<6, id: \.self) { i in
                row(i)
            }
        }
        .onDisappear(perform: stopRecording)
    }

    private func binding(_ i: Int) -> Binding<ExpressKeyBinding> {
        Binding(
            get: { i < model.config.expressKeys.count ? model.config.expressKeys[i] : ExpressKeyBinding() },
            set: { newValue in
                var keys = model.config.expressKeys
                while keys.count <= i { keys.append(ExpressKeyBinding()) }
                keys[i] = newValue
                model.config.expressKeys = keys
            }
        )
    }

    private func row(_ i: Int) -> some View {
        let b = binding(i)
        return VStack(alignment: .leading, spacing: 2) {
            Picker("Touche \(i + 1)", selection: b.action) {
                Text("Aucune").tag(ExpressKeyBinding.Action.none)
                Text("Activer/désactiver le tactile").tag(ExpressKeyBinding.Action.toggleTouch)
                Text("Écran suivant").tag(ExpressKeyBinding.Action.cycleDisplay)
                Text("Raccourci clavier").tag(ExpressKeyBinding.Action.keyCombo)
            }
            .font(.caption)
            if b.wrappedValue.action == .keyCombo {
                HStack {
                    Spacer()
                    Button(recording == i ? "Appuyez sur un raccourci… (Échap annule)"
                                          : KeyLabel.describe(b.wrappedValue)) {
                        recording == i ? stopRecording() : startRecording(i)
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private func startRecording(_ i: Int) {
        stopRecording()
        recording = i
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if Int(event.keyCode) != kVK_Escape {
                var b = binding(i).wrappedValue
                b.keyCode = Int(event.keyCode)
                b.modifiers = KeyLabel.modifierNames(event.modifierFlags)
                binding(i).wrappedValue = b
            }
            stopRecording()
            return nil   // swallow the key so it doesn't trigger anything else
        }
    }

    private func stopRecording() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        recording = nil
    }
}

/// Human-readable shortcut labels (⌃⌥⇧⌘ + key) for the configurator.
enum KeyLabel {
    static func modifierNames(_ flags: NSEvent.ModifierFlags) -> [String] {
        var names: [String] = []
        if flags.contains(.control) { names.append("ctrl") }
        if flags.contains(.option)  { names.append("option") }
        if flags.contains(.shift)   { names.append("shift") }
        if flags.contains(.command) { names.append("cmd") }
        return names
    }

    static func describe(_ binding: ExpressKeyBinding) -> String {
        guard let keyCode = binding.keyCode else { return "Enregistrer…" }
        let mods = binding.modifiers ?? []
        let symbols: [(String, String)] = [("ctrl", "⌃"), ("option", "⌥"), ("shift", "⇧"), ("cmd", "⌘")]
        let prefix = symbols.filter { s in mods.contains { aliases($0) == s.0 } }.map(\.1).joined()
        return prefix + keyName(keyCode)
    }

    private static func aliases(_ m: String) -> String {
        switch m.lowercased() {
        case "command": return "cmd"
        case "alt":     return "option"
        case "control": return "ctrl"
        default:        return m.lowercased()
        }
    }

    private static let special: [Int: String] = [
        kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Espace", kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦", kVK_Escape: "⎋", kVK_LeftArrow: "←",
        kVK_RightArrow: "→", kVK_DownArrow: "↓", kVK_UpArrow: "↑",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12",
    ]

    /// Character the key produces on the current keyboard layout.
    private static func keyName(_ keyCode: Int) -> String {
        if let s = special[keyCode] { return s }
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return "#\(keyCode)" }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = data.withUnsafeBytes { raw -> OSStatus in
            let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress!
            return UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                                  UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                  &deadKeys, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return "#\(keyCode)" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}
