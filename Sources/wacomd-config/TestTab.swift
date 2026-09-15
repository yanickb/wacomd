import SwiftUI
import AppKit
import WacomdShared

// MARK: - Live data

/// Subscribes to the daemon's live status while the Test tab is shown.
final class LiveTestModel: ObservableObject {
    @Published var rawPressure = 0.0
    @Published var pressure = 0.0
    @Published var tipDown = false
    @Published var eraser = false
    @Published var profile = "—"
    @Published var layer2 = false
    @Published var modes: [String] = []
    /// Last button events, newest first.
    @Published var events: [String] = []
    @Published var receiving = false
    /// Profile the daemon uses while this app is frontmost ("" = its own).
    @Published var testBundleID = "" {
        didSet { subscribe() }
    }

    let canvas = DrawingCanvasView()

    private var observer: NSObjectProtocol?
    private var timer: Timer?
    private var lastReceived = Date.distantPast

    init() {
        canvas.isEraser = { [weak self] in self?.eraser ?? false }
    }

    func start() {
        guard observer == nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(
            forName: LiveStatusNames.status, object: nil, queue: .main
        ) { [weak self] note in
            self?.receive(note.userInfo ?? [:])
        }
        subscribe()
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.subscribe()
            self.receiving = Date().timeIntervalSince(self.lastReceived) < 3
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        if let observer = observer { DistributedNotificationCenter.default().removeObserver(observer) }
        observer = nil
        timer?.invalidate()
        timer = nil
    }

    private func subscribe() {
        guard observer != nil else { return }
        DistributedNotificationCenter.default().postNotificationName(
            LiveStatusNames.subscribe, object: nil,
            userInfo: [LiveStatusNames.testBundleIDKey: testBundleID], deliverImmediately: true)
    }

    private func receive(_ info: [AnyHashable: Any]) {
        lastReceived = Date()
        receiving = true
        // Handwriting results carry no state : keep the last one.
        if let profile = info["profile"] as? String { self.profile = profile }
        if let layer2 = info["layer2"] as? Bool { self.layer2 = layer2 }
        if let modes = info["modes"] as? [String] { self.modes = modes }

        switch info["event"] as? String {
        case "pen":
            rawPressure = info["rawPressure"] as? Double ?? 0
            pressure = info["pressure"] as? Double ?? 0
            tipDown = info["tip"] as? Bool ?? false
            eraser = info["eraser"] as? Bool ?? false
        case "button":
            let button = Self.buttonName(info["button"] as? String ?? "")
            let gesture = info["gesture"] as? String ?? ""
            let action = info["action"] as? String ?? ""
            let time = Self.timeFormatter.string(from: Date())
            events.insert("\(time)   \(button) · \(gesture) → \(action)", at: 0)
            if events.count > 8 { events.removeLast(events.count - 8) }
        default:
            break
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private static func buttonName(_ id: String) -> String {
        switch id {
        case "pen.upper": return "Stylet haut"
        case "pen.lower": return "Stylet bas"
        case "gesture":   return "Geste"
        case "writing":   return "Écriture"
        default:
            if id.hasPrefix("pad.") { return "Touche " + id.dropFirst(4) }
            return id
        }
    }
}

// MARK: - Drawing canvas

/// Draws what the tablet sends to apps : stroke width follows the pressure
/// received in the mouse events, red strokes are drawn with the eraser.
final class DrawingCanvasView: NSView {
    private struct Sample { let point: CGPoint; let pressure: CGFloat }
    private struct Stroke { var samples: [Sample]; let eraser: Bool }

    private var strokes: [Stroke] = []
    var isEraser: () -> Bool = { false }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func clear() {
        strokes.removeAll()
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        strokes.append(Stroke(samples: [sample(event)], eraser: isEraser()))
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard !strokes.isEmpty else { return }
        strokes[strokes.count - 1].samples.append(sample(event))
        needsDisplay = true
    }

    private func sample(_ event: NSEvent) -> Sample {
        // Plain mouse / trackpad clicks report no pressure : draw them mid-width.
        let pressure = event.subtype == .tabletPoint ? CGFloat(event.pressure) : 0.5
        return Sample(point: convert(event.locationInWindow, from: nil), pressure: pressure)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        NSColor.separatorColor.setStroke()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8).stroke()

        if strokes.isEmpty {
            let text = NSAttributedString(string: "Dessine ici pour tester la pression", attributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.tertiaryLabelColor,
            ])
            let size = text.size()
            text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
        }

        for stroke in strokes {
            (stroke.eraser ? NSColor.systemRed : NSColor.labelColor).setStroke()
            for (a, b) in zip(stroke.samples, stroke.samples.dropFirst()) {
                let path = NSBezierPath()
                path.move(to: a.point)
                path.line(to: b.point)
                path.lineWidth = 0.5 + (a.pressure + b.pressure) / 2 * 14
                path.lineCapStyle = .round
                path.stroke()
            }
        }
    }
}

struct DrawingCanvas: NSViewRepresentable {
    let view: DrawingCanvasView
    func makeNSView(context: Context) -> DrawingCanvasView { view }
    func updateNSView(_ nsView: DrawingCanvasView, context: Context) {}
}

// MARK: - Tab

struct TestTab: View {
    @ObservedObject var model: ConfigModel
    @ObservedObject var live: LiveTestModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Circle()
                    .fill(live.receiving ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(live.receiving ? "Données reçues du démon" : "En attente : approche le stylet de la tablette")
                    .font(.callout)
            }

            HStack {
                Text("Profil testé").font(.callout)
                Picker("Profil testé", selection: $live.testBundleID) {
                    Text("Par défaut").tag("")
                    ForEach(model.config.appProfiles) { profile in
                        Text(profile.name).tag(profile.bundleID)
                    }
                }
                .labelsHidden()
            }
            Text("Tant que cette fenêtre est au premier plan, les boutons utilisent ce profil. Les raccourcis arrivent dans cette fenêtre, où ils n'ont pas d'effet.")
                .font(.caption).foregroundStyle(.secondary)

            Divider()
            SectionTitle(text: "État", symbol: "gauge.with.dots.needle.33percent")
            PressureBar(label: "Pression brute", value: live.rawPressure)
            PressureBar(label: "Après la courbe", value: live.pressure)
            infoRow("Pointe", live.tipDown ? "posée" : "en survol")
            infoRow("Outil", live.eraser ? "gomme" : "stylet")
            infoRow("Profil utilisé", live.profile)
            infoRow("Calque", live.layer2 ? "2" : "1")
            infoRow("Modes actifs", live.modes.isEmpty ? "aucun" : live.modes.joined(separator: " · "))

            Divider()
            HStack {
                SectionTitle(text: "Zone de dessin", symbol: "paintbrush.pointed")
                Spacer()
                Button("Effacer") { live.canvas.clear() }
                    .controlSize(.small)
            }
            DrawingCanvas(view: live.canvas)
                .frame(height: 200)

            Divider()
            SectionTitle(text: "Derniers boutons", symbol: "list.bullet")
            if live.events.isEmpty {
                Text("Appuie sur un bouton du stylet ou de la tablette.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(live.events.enumerated()), id: \.offset) { _, event in
                Text(event).font(.system(.caption, design: .monospaced))
            }
        }
        .onAppear { live.start() }
        .onDisappear { live.stop() }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).font(.callout).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            Text(value).font(.callout)
        }
    }
}

struct PressureBar: View {
    let label: String
    let value: Double

    var body: some View {
        HStack {
            Text(label).font(.callout).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.2))
                    RoundedRectangle(cornerRadius: 3).fill(Color.accentColor)
                        .frame(width: geo.size.width * CGFloat(min(max(value, 0), 1)))
                }
            }
            .frame(height: 8)
            Text(String(format: "%3.0f %%", value * 100))
                .font(.callout.monospacedDigit())
                .frame(width: 44, alignment: .trailing)
        }
    }
}
