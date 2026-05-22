import SwiftUI
import WacomdShared

@main
struct WacomdConfigApp: App {
    @StateObject private var model = ConfigModel()

    var body: some Scene {
        MenuBarExtra("wacomd", systemImage: "pencil.tip.crop.circle") {
            ConfigView(model: model)
                .frame(width: 320)
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - View model

@MainActor
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
        // Poll daemon presence once a second.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshDaemonStatus() }
        }
    }

    func refreshDaemonStatus() {
        daemonRunning = (DaemonControl.runningPID() != nil)
    }

    /// Debounce writes so dragging a slider doesn't fsync the file 60×/sec.
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
            togglesSection
            Divider()
            slidersSection
            Divider()
            footer
        }
        .padding(14)
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

    private var togglesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Curseur 1 doigt",   isOn: $model.config.oneFingerCursor)
            Toggle("Scroll 2 doigts",   isOn: $model.config.twoFingerScroll)
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
