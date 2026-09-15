import SwiftUI
import AppKit
import UniformTypeIdentifiers
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
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // ---- Main window : guaranteed-visible, normal macOS window. ------
        let host = NSHostingController(rootView: ConfigView(model: model))
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: ConfigView.width, height: ConfigView.height),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
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

        // ---- Menu-bar item. If macOS Tahoe routes it into Control Center
        //      or hides it behind the notch the user can still access the
        //      app via the Dock icon + window.
        let bar = NSStatusBar.system.statusItem(withLength: 28)
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
        showWindow()
    }
}

// MARK: - View model

final class ConfigModel: ObservableObject {
    @Published var config: WacomdConfig {
        didSet { scheduleSave() }
    }
    @Published private(set) var daemonRunning: Bool = false
    /// Layer shown in the Boutons tab (1 or 2). Kept here rather than in
    /// `@State` : the Command Line Tools ship without the SwiftUI macro plugin.
    @Published var editingLayer: Int = 1
    /// Id of the shortcut field currently recording a key combination.
    @Published private(set) var recordingField: String?
    private var keyMonitor: Any?

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

    /// Captures the next key-down and hands its `cmd+shift+z`-style spec to `onRecord`.
    func startRecording(field: String, onRecord: @escaping (String) -> Void) {
        stopRecording()
        recordingField = field
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            onRecord(ShortcutField.spec(from: event))
            self?.stopRecording()
            return nil
        }
    }

    func stopRecording() {
        if let monitor = keyMonitor { NSEvent.removeMonitor(monitor) }
        keyMonitor = nil
        recordingField = nil
    }

    /// Live data from the daemon for the Test tab.
    let live = LiveTestModel()

    // MARK: Profiles

    /// Profile edited in the Boutons tab : -1 = default map, else an index
    /// in `config.appProfiles`.
    @Published var editingProfile: Int = -1
    /// Shows the double / long press rows under each button.
    @Published var showGestures: Bool = true

    /// Button map of the profile being edited.
    var editedMap: ButtonMap {
        get {
            config.appProfiles.indices.contains(editingProfile) ? config.appProfiles[editingProfile].buttons : config.buttons
        }
        set {
            if config.appProfiles.indices.contains(editingProfile) {
                config.appProfiles[editingProfile].buttons = newValue
            } else {
                config.buttons = newValue
            }
        }
    }

    func binding(for button: PhysicalButton, layer2: Bool) -> Binding<ButtonBinding> {
        Binding(
            get: { self.editedMap.layerBinding(for: button, layer2: layer2) },
            set: { newValue in
                var map = self.editedMap
                map.setLayerBinding(newValue, for: button, layer2: layer2)
                self.editedMap = map
            }
        )
    }

    /// Action of a pen gesture : 0 up, 1 right, 2 down, 3 left.
    func penGesture(_ index: Int) -> Binding<ButtonAction> {
        Binding(
            get: {
                let gestures = self.editedMap.penGestures
                return gestures.indices.contains(index) ? gestures[index] : .none
            },
            set: { newValue in
                var map = self.editedMap
                while map.penGestures.count <= index { map.penGestures.append(.none) }
                map.penGestures[index] = newValue
                self.editedMap = map
            }
        )
    }

    func radialItem(_ index: Int) -> Binding<RadialItem> {
        Binding(
            get: {
                let items = self.editedMap.radialMenu
                return items.indices.contains(index) ? items[index] : RadialItem("", .none)
            },
            set: { newValue in
                var map = self.editedMap
                while map.radialMenu.count <= index { map.radialMenu.append(RadialItem("", .none)) }
                map.radialMenu[index] = newValue
                self.editedMap = map
            }
        )
    }

    /// Asks for an app in /Applications and adds a profile for it, starting
    /// from a preset for known apps (Photoshop, Blender) or from the default map.
    func addProfile() {
        let panel = NSOpenPanel()
        panel.title = "Choisir une application"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier else { return }

        if let existing = config.appProfiles.firstIndex(where: { $0.bundleID == bundleID }) {
            editingProfile = existing
            return
        }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        let map = ButtonMap.preset(forBundleID: bundleID) ?? config.buttons
        config.appProfiles.append(AppProfile(bundleID: bundleID, name: name, buttons: map))
        editingProfile = config.appProfiles.count - 1
    }

    func removeEditedProfile() {
        guard config.appProfiles.indices.contains(editingProfile) else { return }
        config.appProfiles.remove(at: editingProfile)
        editingProfile = -1
    }

    func resetEditedProfileToPreset() {
        if config.appProfiles.indices.contains(editingProfile) {
            let bundleID = config.appProfiles[editingProfile].bundleID
            editedMap = ButtonMap.preset(forBundleID: bundleID) ?? ButtonMap()
        } else {
            editedMap = ButtonMap()
        }
    }
}

// MARK: - Main view

struct ConfigView: View {
    static let width: CGFloat = 480
    static let height: CGFloat = 700

    @ObservedObject var model: ConfigModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding([.horizontal, .top], 16).padding(.bottom, 10)
            TabView {
                ScrollView { PenTab(model: model).padding(16) }
                    .tabItem { Label("Stylet", systemImage: "pencil.tip") }
                ScrollView { ScreenTab(model: model).padding(16) }
                    .tabItem { Label("Écran", systemImage: "display") }
                ScrollView { ButtonsTab(model: model).padding(16) }
                    .tabItem { Label("Boutons", systemImage: "button.horizontal.top.press") }
                ScrollView { TouchTab(model: model).padding(16) }
                    .tabItem { Label("Tactile", systemImage: "hand.tap") }
                ScrollView { TestTab(model: model, live: model.live).padding(16) }
                    .tabItem { Label("Test", systemImage: "waveform.path.ecg") }
            }
            .padding(.horizontal, 10)
            Divider()
            footer.padding(12)
        }
        .frame(width: Self.width, height: Self.height)
    }

    private var header: some View {
        HStack {
            Image(systemName: model.daemonRunning ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(model.daemonRunning ? .green : .orange)
            VStack(alignment: .leading) {
                Text("wacomd").font(.headline)
                Text(model.daemonRunning ? "Démon actif — les réglages s'appliquent en direct" : "Démon arrêté")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var footer: some View {
        HStack {
            Button("Réinitialiser tout") { model.resetToDefaults() }
                .controlSize(.small)
            Spacer()
            Button("Quitter") { NSApplication.shared.terminate(nil) }
                .controlSize(.small)
        }
    }
}

// MARK: - Shared controls

struct SectionTitle: View {
    let text: String
    let symbol: String
    var body: some View {
        Label(text, systemImage: symbol).font(.headline).padding(.top, 4)
    }
}

struct SliderRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format: (Double) -> String = { String(format: "%.2f", $0) }
    var help: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.callout)
                Spacer()
                Text(format(value))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
            if let help = help {
                Text(help).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Stylet tab

struct PenTab: View {
    @ObservedObject var model: ConfigModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle(text: "Pression", symbol: "scribble.variable")
            PressureCurveView(config: model.config)
                .frame(height: 150)
            SliderRow(label: "Courbe", value: $model.config.pressureCurve, range: 0.3...3,
                      format: { $0 < 0.95 ? String(format: "souple (%.2f)", $0)
                                : $0 > 1.05 ? String(format: "ferme (%.2f)", $0) : "linéaire" },
                      help: "Souple : traits épais sans appuyer fort. Ferme : il faut appuyer pour épaissir.")
            SliderRow(label: "Pression minimum", value: $model.config.pressureMin, range: 0...0.3,
                      format: { String(format: "%.0f %%", $0 * 100) },
                      help: "En dessous, la pointe est ignorée : les effleurements ne dessinent pas.")
            SliderRow(label: "Pression maximum", value: $model.config.pressureMax, range: 0.5...1,
                      format: { String(format: "%.0f %%", $0 * 100) },
                      help: "Pression à partir de laquelle le trait est au maximum.")

            Divider()
            SectionTitle(text: "Général", symbol: "gearshape")
            Toggle("Bulle d'info collée au curseur (modes actifs, raccourcis)", isOn: $model.config.hudEnabled)
                .toggleStyle(.switch)
            SliderRow(label: "Opacité du fond de la bulle", value: $model.config.hudOpacity, range: 0...1,
                      format: { $0 < 0.01 ? "texte seul" : String(format: "%.0f %%", $0 * 100) })
                .disabled(!model.config.hudEnabled)
            SliderRow(label: "Délai double appui",
                      value: Binding(get: { Double(model.config.doubleTapMs) },
                                     set: { model.config.doubleTapMs = Int($0) }),
                      range: 150...600, format: { String(format: "%.0f ms", $0) },
                      help: "Temps maximum entre deux appuis pour un double appui.")
            SliderRow(label: "Durée appui long",
                      value: Binding(get: { Double(model.config.longPressMs) },
                                     set: { model.config.longPressMs = Int($0) }),
                      range: 250...1200, format: { String(format: "%.0f ms", $0) })
            SliderRow(label: "Vitesse du défilement au stylet", value: $model.config.scrollSpeed, range: 0.2...4,
                      format: { String(format: "×%.1f", $0) })

            Divider()
            SectionTitle(text: "Stabilisateur de trait", symbol: "scribble")
            Toggle("Activé par défaut", isOn: $model.config.stabilizerEnabled)
                .toggleStyle(.switch)
            SliderRow(label: "Force", value: $model.config.stabilizerStrength, range: 0...100,
                      format: { String(format: "%.0f", $0) },
                      help: "Lisse le trait pendant que la pointe touche. Plus c'est fort, plus le trait est propre mais suit avec un léger retard. Un bouton « Stabilisateur » inverse l'état par défaut.")

            Divider()
            SectionTitle(text: "Écriture manuscrite", symbol: "pencil.and.scribble")
            Text("Avec le bouton « Écriture manuscrite », écris n'importe où : l'encre s'affiche à l'écran, puis le texte reconnu est tapé dans le champ actif (reconnaissance intégrée à macOS, hors ligne).")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Langue", selection: $model.config.handwritingLanguage) {
                Text("Français").tag("fr-FR")
                Text("Anglais").tag("en-US")
                Text("Détection automatique").tag("auto")
            }
            SliderRow(label: "Pause avant reconnaissance",
                      value: Binding(get: { Double(model.config.handwritingDelayMs) },
                                     set: { model.config.handwritingDelayMs = Int($0) }),
                      range: 300...2500, format: { String(format: "%.1f s", $0 / 1000) })
            Toggle("Ajouter un espace après chaque mot", isOn: $model.config.handwritingAddSpace)
                .toggleStyle(.switch)
            Toggle("Cliquer au début de l'écriture (sélectionne le champ)", isOn: $model.config.handwritingClickToFocus)
                .toggleStyle(.switch)

            Divider()
            SectionTitle(text: "Mode souris", symbol: "computermouse")
            SliderRow(label: "Vitesse", value: $model.config.mouseSpeed, range: 0.3...4,
                      format: { String(format: "×%.1f", $0) },
                      help: "Avec le bouton « Mode souris », le stylet déplace le curseur comme une souris : lever le stylet et le reposer ne fait pas sauter le curseur.")

            Divider()
            SectionTitle(text: "Gestes au stylet", symbol: "hand.draw")
            SliderRow(label: "Distance du geste", value: $model.config.penGestureDistance, range: 30...200,
                      format: { String(format: "%.0f px", $0) },
                      help: "Déplacement du curseur qui déclenche un geste. Les actions se règlent dans l'onglet Boutons.")

            Divider()
            SectionTitle(text: "Mode précision", symbol: "scope")
            SliderRow(label: "Vitesse du curseur", value: $model.config.precisionScale, range: 0.05...0.8,
                      format: { String(format: "×%.2f", $0) },
                      help: "Tant que le bouton « Précision » est maintenu, le curseur bouge à cette vitesse.")

            Divider()
            SectionTitle(text: "Taille du pinceau", symbol: "circle.dotted")
            SliderRow(label: "Déplacement par cran", value: $model.config.brushSizeStep, range: 5...60,
                      format: { String(format: "%.0f px", $0) },
                      help: "Maintiens « Taille pinceau » et glisse le stylet à gauche / droite.")
            HStack {
                Text("Touche réduire").font(.callout)
                TextField("[", text: $model.config.brushSizeDecrease)
                    .textFieldStyle(.roundedBorder).frame(width: 60)
                Spacer()
                Text("Touche agrandir").font(.callout)
                TextField("]", text: $model.config.brushSizeIncrease)
                    .textFieldStyle(.roundedBorder).frame(width: 60)
            }
        }
    }
}

/// Plots output pressure against the force applied on the tip.
struct PressureCurveView: View {
    let config: WacomdConfig

    var body: some View {
        Canvas { ctx, size in
            let frame = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
            ctx.stroke(Path(roundedRect: frame, cornerRadius: 6), with: .color(.secondary.opacity(0.4)))

            var linear = Path()
            linear.move(to: CGPoint(x: frame.minX, y: frame.maxY))
            linear.addLine(to: CGPoint(x: frame.maxX, y: frame.minY))
            ctx.stroke(linear, with: .color(.secondary.opacity(0.3)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))

            var curve = Path()
            let steps = 80
            for i in 0...steps {
                let raw = Double(i) / Double(steps)
                let p = CGPoint(x: frame.minX + CGFloat(raw) * frame.width,
                                y: frame.maxY - CGFloat(config.mappedPressure(raw)) * frame.height)
                if i == 0 { curve.move(to: p) } else { curve.addLine(to: p) }
            }
            ctx.stroke(curve, with: .color(.accentColor), lineWidth: 2.5)
        }
        .overlay(alignment: .bottomTrailing) {
            Text("force →").font(.caption2).foregroundStyle(.secondary).padding(6)
        }
        .overlay(alignment: .topLeading) {
            Text("↑ trait").font(.caption2).foregroundStyle(.secondary).padding(6)
        }
    }
}

// MARK: - Écran tab

struct ScreenTab: View {
    @ObservedObject var model: ConfigModel

    /// Width / height of the active surface as seen by the user. PTH-451
    /// (157×98 mm) and CTL-490 (152×95 mm) are both 1.6 in landscape.
    private var tabletAspect: Double { model.config.tabletOrientation.aspect(tabletAspect: 1.6) }

    private var screens: [NSScreen] { NSScreen.screens }

    private var screenAspect: Double {
        let list = screens
        guard !list.isEmpty else { return 16.0 / 9 }
        let index = list.indices.contains(model.config.displayIndex) ? model.config.displayIndex : 0
        let frame = list[index].frame
        return frame.height > 0 ? Double(frame.width / frame.height) : 16.0 / 9
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle(text: "Orientation de la tablette", symbol: "rotate.left")
            Picker("Orientation", selection: $model.config.tabletOrientation) {
                ForEach(TabletOrientation.allCases, id: \.self) { orientation in
                    Text(orientation.title).tag(orientation)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(model.config.tabletOrientation == .landscape
                 ? "Touches en haut, numérotées de gauche à droite."
                 : "Tablette tournée d'un quart de tour vers la gauche : touches à gauche, 1 en bas et 4 en haut.")
                .font(.caption).foregroundStyle(.secondary)

            Divider()
            SectionTitle(text: "Écran cible", symbol: "display")
            Picker("Écran", selection: $model.config.displayIndex) {
                ForEach(Array(screens.enumerated()), id: \.offset) { index, screen in
                    Text("\(screen.localizedName) — \(Int(screen.frame.width))×\(Int(screen.frame.height))")
                        .tag(index)
                }
            }
            .labelsHidden()

            Toggle("Garder les proportions (cercles bien ronds)", isOn: $model.config.keepAspectRatio)
                .toggleStyle(.switch)

            Divider()
            SectionTitle(text: "Zone active de la tablette", symbol: "rectangle.dashed")
            AreaPreview(config: model.config, tabletAspect: tabletAspect, screenAspect: screenAspect)
                .frame(height: 190)
            Text("Gris : tablette entière · Pointillés : zone choisie · Couleur : zone réellement utilisée")
                .font(.caption).foregroundStyle(.secondary)

            SliderRow(label: "Bord gauche", value: $model.config.areaLeft, range: 0...0.9,
                      format: { String(format: "%.0f %%", $0 * 100) })
            SliderRow(label: "Bord droit", value: $model.config.areaRight, range: 0.1...1,
                      format: { String(format: "%.0f %%", $0 * 100) })
            SliderRow(label: "Bord haut", value: $model.config.areaTop, range: 0...0.9,
                      format: { String(format: "%.0f %%", $0 * 100) })
            SliderRow(label: "Bord bas", value: $model.config.areaBottom, range: 0.1...1,
                      format: { String(format: "%.0f %%", $0 * 100) })
            Button("Utiliser toute la tablette") {
                model.config.areaLeft = 0; model.config.areaTop = 0
                model.config.areaRight = 1; model.config.areaBottom = 1
            }
            .controlSize(.small)
        }
    }
}

struct AreaPreview: View {
    let config: WacomdConfig
    let tabletAspect: Double
    let screenAspect: Double

    var body: some View {
        Canvas { ctx, size in
            // Fit the tablet rectangle in the canvas.
            var w = size.width - 4
            var h = w / CGFloat(tabletAspect)
            if h > size.height - 4 { h = size.height - 4; w = h * CGFloat(tabletAspect) }
            let tablet = CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
            func rect(_ l: Double, _ t: Double, _ r: Double, _ b: Double) -> CGRect {
                CGRect(x: tablet.minX + CGFloat(l) * w, y: tablet.minY + CGFloat(t) * h,
                       width: CGFloat(r - l) * w, height: CGFloat(b - t) * h)
            }

            ctx.fill(Path(roundedRect: tablet, cornerRadius: 8), with: .color(.secondary.opacity(0.15)))
            ctx.stroke(Path(roundedRect: tablet, cornerRadius: 8), with: .color(.secondary.opacity(0.5)))

            var raw = config
            raw.keepAspectRatio = false
            let chosen = raw.effectiveArea(tabletAspect: tabletAspect, screenAspect: screenAspect)
            ctx.stroke(Path(rect(chosen.left, chosen.top, chosen.right, chosen.bottom)),
                       with: .color(.secondary), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))

            let used = config.effectiveArea(tabletAspect: tabletAspect, screenAspect: screenAspect)
            let usedRect = rect(used.left, used.top, used.right, used.bottom)
            ctx.fill(Path(usedRect), with: .color(.accentColor.opacity(0.25)))
            ctx.stroke(Path(usedRect), with: .color(.accentColor), lineWidth: 2)
        }
    }
}

// MARK: - Boutons tab

struct ButtonsTab: View {
    @ObservedObject var model: ConfigModel
    private var layer2: Bool { model.editingLayer == 2 }
    private var prefix: String { "P\(model.editingProfile).L\(model.editingLayer)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            profileSection

            Divider()
            Picker("Calque", selection: $model.editingLayer) {
                Text("Calque 1 (normal)").tag(1)
                Text("Calque 2 (touche calque maintenue)").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(layer2
                 ? "Actions utilisées pendant qu'une touche « Calque 2 » est maintenue. La touche calque elle-même reste inchangée."
                 : "Assigne « Calque 2 » à une touche : tant qu'elle est maintenue, les autres boutons prennent leur action du calque 2.")
                .font(.caption).foregroundStyle(.secondary)

            Toggle("Afficher double appui et appui long", isOn: $model.showGestures)
                .toggleStyle(.switch)

            SectionTitle(text: "Stylet", symbol: "pencil")
            BindingRows(model: model, id: "\(prefix).pen.upper", label: "Bouton du haut",
                        binding: model.binding(for: .penUpper, layer2: layer2))
            BindingRows(model: model, id: "\(prefix).pen.lower", label: "Bouton du bas",
                        binding: model.binding(for: .penLower, layer2: layer2))

            Divider()
            SectionTitle(text: "Touches de la tablette", symbol: "square.grid.4x3.fill")
            ForEach(0..<4, id: \.self) { index in
                BindingRows(model: model, id: "\(prefix).pad.\(index)", label: "Touche \(index + 1)",
                            binding: model.binding(for: .pad(index), layer2: layer2))
            }
            Text("Touches numérotées \(model.config.tabletOrientation.keyOrder) (orientation réglée dans l'onglet Écran).")
                .font(.caption).foregroundStyle(.secondary)

            Divider()
            SectionTitle(text: "Gestes au stylet", symbol: "arrow.up.and.down.and.arrow.left.and.right")
            Text("Maintiens (ou bascule) le bouton « Gestes au stylet » et fais un petit geste rapide au-dessus de la tablette. Plusieurs gestes possibles d'affilée.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(0..<4, id: \.self) { index in
                ActionRow(model: model, id: "P\(model.editingProfile).gesture.\(index)",
                          label: ["↑ Haut", "→ Droite", "↓ Bas", "← Gauche"][index],
                          action: model.penGesture(index))
            }

            Divider()
            SectionTitle(text: "Menu circulaire", symbol: "circle.grid.cross")
            Text("Maintiens le bouton « Menu circulaire », pointe un élément avec le stylet, relâche pour le lancer. Élément 1 en haut, dans le sens des aiguilles d'une montre.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(0..<8, id: \.self) { index in
                RadialItemRow(model: model, id: "P\(model.editingProfile).radial.\(index)",
                              index: index, item: model.radialItem(index))
            }
        }
    }

    private var profileSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: "Profil", symbol: "square.stack.3d.up")
            HStack {
                Picker("Profil", selection: $model.editingProfile) {
                    Text("Par défaut (toutes les apps)").tag(-1)
                    ForEach(Array(model.config.appProfiles.enumerated()), id: \.offset) { index, profile in
                        Text(profile.name).tag(index)
                    }
                }
                .labelsHidden()
                Button("Ajouter une app…") { model.addProfile() }
                    .controlSize(.small)
            }
            if model.config.appProfiles.indices.contains(model.editingProfile) {
                HStack {
                    Toggle("Actif", isOn: $model.config.appProfiles[model.editingProfile].enabled)
                        .toggleStyle(.switch)
                    Spacer()
                    Button("Remettre le preset") { model.resetEditedProfileToPreset() }
                        .controlSize(.small)
                    Button("Supprimer") { model.removeEditedProfile() }
                        .controlSize(.small)
                }
                Text("Utilisé quand \(model.config.appProfiles[model.editingProfile].name) est au premier plan.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Utilisé pour toutes les apps sans profil. Photoshop et Blender ont des presets tout prêts : « Ajouter une app… ».")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Press row, plus double / long rows when gestures are shown.
struct BindingRows: View {
    @ObservedObject var model: ConfigModel
    let id: String
    let label: String
    @Binding var binding: ButtonBinding

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ActionRow(model: model, id: "\(id).press", label: label, action: $binding.press)
            if model.showGestures {
                ActionRow(model: model, id: "\(id).double", label: "   double appui", action: $binding.double, secondary: true)
                ActionRow(model: model, id: "\(id).long", label: "   appui long", action: $binding.long, secondary: true)
                if binding.hasGestures && binding.press.isHoldMode {
                    Label("Avec un double appui ou un appui long, l'action simple devient un appui bref : « \(binding.press.displayName) » ne pourra pas être maintenue.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                        .padding(.leading, 118)
                }
            }
        }
        .padding(.bottom, model.showGestures ? 6 : 0)
    }
}

struct RadialItemRow: View {
    @ObservedObject var model: ConfigModel
    let id: String
    let index: Int
    @Binding var item: RadialItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ActionRow(model: model, id: id, label: "Élément \(index + 1)", action: $item.action)
            if item.action != .none {
                TextField("Nom affiché (optionnel)", text: $item.label)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .padding(.leading, 118)
            }
        }
    }
}

/// Kind of action shown in the picker ; `.shortcut` reveals a text field.
enum ActionKind: String, CaseIterable, Identifiable {
    case none, leftClick, rightClick, middleClick, shortcut, eraser, precision, layer, brushSize, scroll, radialMenu,
         mouseMode, stabilizer, penGestures, handwriting
    var id: String { rawValue }

    var title: String {
        switch self {
        case .none:        return "Aucune action"
        case .leftClick:   return "Clic gauche"
        case .rightClick:  return "Clic droit"
        case .middleClick: return "Clic milieu"
        case .shortcut:    return "Raccourci clavier…"
        case .eraser:      return "Gomme"
        case .precision:   return "Précision"
        case .layer:       return "Calque 2"
        case .brushSize:   return "Taille pinceau"
        case .scroll:      return "Défilement au stylet"
        case .radialMenu:  return "Menu circulaire"
        case .mouseMode:   return "Mode souris"
        case .stabilizer:  return "Stabilisateur"
        case .penGestures: return "Gestes au stylet"
        case .handwriting: return "Écriture manuscrite"
        }
    }

    init(_ action: ButtonAction) {
        switch action {
        case .none:        self = .none
        case .leftClick:   self = .leftClick
        case .rightClick:  self = .rightClick
        case .middleClick: self = .middleClick
        case .shortcut:    self = .shortcut
        case .eraser:      self = .eraser
        case .precision:   self = .precision
        case .layer:       self = .layer
        case .brushSize:   self = .brushSize
        case .scroll:      self = .scroll
        case .radialMenu:  self = .radialMenu
        case .mouseMode:   self = .mouseMode
        case .stabilizer:  self = .stabilizer
        case .penGestures: self = .penGestures
        case .handwriting: self = .handwriting
        case .toggle(let inner): self.init(inner)
        }
    }

    func makeAction(keeping previous: ButtonAction) -> ButtonAction {
        switch self {
        case .none:        return .none
        case .leftClick:   return .leftClick
        case .rightClick:  return .rightClick
        case .middleClick: return .middleClick
        case .eraser:      return .eraser
        case .precision:   return .precision
        case .layer:       return .layer
        case .brushSize:   return .brushSize
        case .scroll:      return .scroll
        case .radialMenu:  return .radialMenu
        case .mouseMode:   return .mouseMode
        case .stabilizer:  return .stabilizer
        case .penGestures: return .penGestures
        case .handwriting: return .handwriting
        case .shortcut:
            if case .shortcut = previous { return previous }
            return .shortcut("")
        }
    }
}

struct ActionRow: View {
    @ObservedObject var model: ConfigModel
    let id: String
    let label: String
    @Binding var action: ButtonAction
    var secondary = false

    /// Action without its toggle wrapper : what the picker edits.
    private var inner: ButtonAction {
        if case .toggle(let a) = action { return a }
        return action
    }
    private var isToggle: Bool {
        if case .toggle = action { return true }
        return false
    }

    private func setInner(_ newInner: ButtonAction, toggle: Bool) {
        action = (toggle && newInner.isHoldMode) ? .toggle(newInner) : newInner
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(secondary ? .caption : .callout)
                    .foregroundStyle(secondary ? .secondary : .primary)
                    .frame(width: 110, alignment: .leading)
                Picker(label, selection: Binding(
                    get: { ActionKind(inner) },
                    set: { setInner($0.makeAction(keeping: inner), toggle: isToggle) }
                )) {
                    ForEach(ActionKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .labelsHidden()
                if inner.isHoldMode {
                    Toggle("Bascule", isOn: Binding(
                        get: { isToggle },
                        set: { setInner(inner, toggle: $0) }
                    ))
                    .toggleStyle(.checkbox)
                    .help("Coché : un appui active, l'appui suivant désactive (pas besoin de maintenir).")
                }
            }
            if case .shortcut(let spec) = inner {
                ShortcutField(model: model, id: id, spec: Binding(
                    get: { spec },
                    set: { setInner(.shortcut($0), toggle: isToggle) }
                ))
                .padding(.leading, 118)
            }
        }
    }
}

/// Text field + recorder : click « Enregistrer » then press the combination.
struct ShortcutField: View {
    @ObservedObject var model: ConfigModel
    let id: String
    @Binding var spec: String

    private var recording: Bool { model.recordingField == id }

    var body: some View {
        HStack {
            TextField("ex. cmd+shift+z", text: $spec)
                .textFieldStyle(.roundedBorder)
                .frame(width: 150)
            Button(recording ? "Appuie sur les touches…" : "Enregistrer") {
                if recording {
                    model.stopRecording()
                } else {
                    let binding = $spec
                    model.startRecording(field: id) { binding.wrappedValue = $0 }
                }
            }
            .controlSize(.small)
        }
    }

    private static let namedKeys: [UInt16: String] = [
        49: "space", 48: "tab", 36: "return", 53: "esc", 51: "delete",
        123: "left", 124: "right", 125: "down", 126: "up",
        122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6",
        98: "f7", 100: "f8", 101: "f9", 109: "f10", 103: "f11", 111: "f12",
    ]

    /// Same syntax as the daemon's parser : `cmd+shift+z`.
    static func spec(from event: NSEvent) -> String {
        var parts: [String] = []
        let flags = event.modifierFlags
        if flags.contains(.control) { parts.append("ctrl") }
        if flags.contains(.option)  { parts.append("alt") }
        if flags.contains(.shift)   { parts.append("shift") }
        if flags.contains(.command) { parts.append("cmd") }
        if let named = namedKeys[event.keyCode] {
            parts.append(named)
        } else if let chars = event.charactersIgnoringModifiers?.lowercased(), !chars.isEmpty {
            parts.append(chars)
        }
        return parts.joined(separator: "+")
    }
}

// MARK: - Tactile tab

struct TouchTab: View {
    @ObservedObject var model: ConfigModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Seulement pour les tablettes avec surface tactile (ex. Intuos Pro PTH-451).")
                .font(.caption).foregroundStyle(.secondary)
            Toggle(isOn: $model.config.touchEnabled) {
                Label("Tactile", systemImage: "hand.tap.fill").font(.headline)
            }
            .toggleStyle(.switch)

            Group {
                Toggle("Curseur 1 doigt",   isOn: $model.config.oneFingerCursor)
                Toggle("Scroll 2 doigts",   isOn: $model.config.twoFingerScroll)
                Toggle("Scroll naturel",    isOn: $model.config.naturalScroll)
                    .help("Activé : doigt ↓ = page ↓ (style macOS). Désactivé : doigt ↓ = page ↑ (style classique).")
                Toggle("Gestes 3 doigts",   isOn: $model.config.threeFingerSwipes)
                Toggle("Tap to click",      isOn: $model.config.tapToClick)
            }
            .toggleStyle(.switch)
            .disabled(!model.config.touchEnabled)

            Divider()
            Group {
                SliderRow(label: "Sensibilité curseur", value: $model.config.cursorSensitivity, range: 0.05...1.5)
                SliderRow(label: "Sensibilité scroll", value: $model.config.scrollSensitivity, range: 0.05...2.0)
                SliderRow(label: "Seuil swipe 3 doigts", value: $model.config.threeFingerSwipeThreshold,
                          range: 50...500, format: { String(format: "%.0f", $0) })
                SliderRow(label: "Durée max tap (ms)",
                          value: Binding(get: { Double(model.config.tapMaxDurationMs) },
                                         set: { model.config.tapMaxDurationMs = Int($0) }),
                          range: 50...300, format: { String(format: "%.0f", $0) })
                SliderRow(label: "Drift max tap", value: $model.config.tapMaxRawMovement,
                          range: 5...100, format: { String(format: "%.0f", $0) })
            }
            .disabled(!model.config.touchEnabled)
        }
    }
}
