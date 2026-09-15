import AppKit
import Vision
import WacomdShared

/// Scribble-like handwriting : while the mode is on, pen strokes are drawn
/// as ink on a click-through overlay instead of reaching the app. After a
/// pause the ink is recognised with Vision and typed into the focused field.
///
/// Main thread only, except the recognition itself.
final class Handwriting {
    static let shared = Handwriting()

    /// Strokes not yet sent to recognition, in CG global coordinates.
    private var pending: [[CGPoint]] = []
    /// Strokes being recognised, still drawn (faded) until their text is typed.
    private var recognizing: [Int: [[CGPoint]]] = [:]
    private var nextBatch = 0
    private var panels: [NSPanel] = []
    private var idleWork: DispatchWorkItem?
    /// Keeps results in writing order.
    private let recognitionQueue = DispatchQueue(label: "wacomd.handwriting")

    // MARK: - Strokes

    /// Starts a stroke. Returns true when it opens a new writing session
    /// (no ink on screen), so the caller can focus the field under the pen.
    @discardableResult
    func beginStroke(at point: CGPoint) -> Bool {
        idleWork?.cancel()
        let newSession = pending.isEmpty && recognizing.isEmpty
        showPanels()
        pending.append([point])
        invalidate(around: [point])
        return newSession
    }

    func moveStroke(to point: CGPoint) {
        guard var stroke = pending.popLast() else { return }
        let previous = stroke.last ?? point
        stroke.append(point)
        pending.append(stroke)
        invalidate(around: [previous, point])
    }

    func endStroke() {
        scheduleRecognition()
    }

    /// Recognises the pending ink right away (mode turned off).
    func finishNow() {
        idleWork?.cancel()
        recognizePending()
    }

    private func scheduleRecognition() {
        idleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.recognizePending() }
        idleWork = work
        let delay = Double(max(ConfigStore.shared.current.handwritingDelayMs, 200)) / 1000
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - Recognition

    private func recognizePending() {
        guard !pending.isEmpty else { return }
        let strokes = pending
        pending = []
        let batch = nextBatch
        nextBatch += 1
        recognizing[batch] = strokes
        redraw()

        let config = ConfigStore.shared.current
        guard let image = Self.render(strokes) else {
            finished(batch: batch, text: "")
            return
        }
        recognitionQueue.async { [weak self] in
            let text = Self.recognize(image, language: config.handwritingLanguage)
            DispatchQueue.main.async { self?.finished(batch: batch, text: text) }
        }
    }

    private func finished(batch: Int, text: String) {
        recognizing[batch] = nil
        redraw()
        if pending.isEmpty && recognizing.isEmpty { hidePanels() }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            Hud.shared.flash("✎ non reconnu")
            return
        }
        let config = ConfigStore.shared.current
        Self.type(trimmed + (config.handwritingAddSpace ? " " : ""))
        Hud.shared.flash("✎ \(trimmed)")
        LiveStatus.shared.post(["event": "button", "button": "writing", "gesture": "écriture", "action": trimmed])
    }

    static func recognize(_ image: CGImage, language: String) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.revision = VNRecognizeTextRequestRevision3
        if language == "auto" {
            request.automaticallyDetectsLanguage = true
        } else {
            request.recognitionLanguages = [language]
        }
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            FileHandle.standardError.write(Data("[wacomd] Reconnaissance d'écriture impossible : \(error)\n".utf8))
            return ""
        }
        // Lines top to bottom, then left to right (Vision boxes have a bottom-left origin).
        let lines = (request.results ?? []).sorted { a, b in
            let sameLine = abs(a.boundingBox.midY - b.boundingBox.midY) < min(a.boundingBox.height, b.boundingBox.height) / 2
            return sameLine ? a.boundingBox.minX < b.boundingBox.minX : a.boundingBox.midY > b.boundingBox.midY
        }
        return lines.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }

    /// Black ink on white, cropped to the strokes. Screen y grows downwards,
    /// bitmap y upwards.
    static func render(_ strokes: [[CGPoint]]) -> CGImage? {
        let points = strokes.flatMap { $0 }
        guard let first = points.first else { return nil }
        var box = CGRect(origin: first, size: .zero)
        for p in points { box = box.union(CGRect(origin: p, size: .zero)) }

        let padding: CGFloat = 24
        let scale = min(2, 4000 / max(box.width + padding * 2, box.height + padding * 2))
        let width = Int((box.width + padding * 2) * scale), height = Int((box.height + padding * 2) * scale)
        guard width > 8, height > 8,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }

        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setStrokeColor(gray: 0, alpha: 1)
        ctx.setFillColor(gray: 0, alpha: 1)
        let lineWidth = 3 * scale
        ctx.setLineWidth(lineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        func map(_ p: CGPoint) -> CGPoint {
            CGPoint(x: (p.x - box.minX + padding) * scale, y: CGFloat(height) - (p.y - box.minY + padding) * scale)
        }
        for stroke in strokes {
            guard let start = stroke.first else { continue }
            if stroke.count == 1 {
                // A tap : the dot of an i, a full stop.
                let c = map(start)
                ctx.fillEllipse(in: CGRect(x: c.x - lineWidth, y: c.y - lineWidth, width: lineWidth * 2, height: lineWidth * 2))
                continue
            }
            ctx.move(to: map(start))
            for p in stroke.dropFirst() { ctx.addLine(to: map(p)) }
            ctx.strokePath()
        }
        return ctx.makeImage()
    }

    /// Types text whatever the keyboard layout, through Unicode key events.
    private static func type(_ text: String) {
        let units = Array(text.utf16)
        var index = 0
        while index < units.count {
            var chunk = Array(units[index..<min(index + 16, units.count)])
            index += chunk.count
            for keyDown in [true, false] {
                guard let evt = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: keyDown) else { continue }
                evt.flags = []
                evt.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                evt.post(tap: .cghidEventTap)
            }
        }
    }

    // MARK: - Overlay

    fileprivate func drawInk(in view: InkView) {
        guard let window = view.window else { return }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        func local(_ p: CGPoint) -> NSPoint {
            NSPoint(x: p.x - window.frame.minX, y: primaryHeight - p.y - window.frame.minY)
        }
        func draw(_ strokes: [[CGPoint]], alpha: CGFloat) {
            for stroke in strokes {
                guard let start = stroke.first else { continue }
                if stroke.count == 1 {
                    let c = local(start)
                    NSColor.systemBlue.withAlphaComponent(alpha).setFill()
                    NSBezierPath(ovalIn: NSRect(x: c.x - 2, y: c.y - 2, width: 4, height: 4)).fill()
                    continue
                }
                let path = NSBezierPath()
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                path.move(to: local(start))
                for p in stroke.dropFirst() { path.line(to: local(p)) }
                // White halo keeps the ink visible on dark content.
                NSColor.white.withAlphaComponent(0.7 * alpha).setStroke()
                path.lineWidth = 5
                path.stroke()
                NSColor.systemBlue.withAlphaComponent(alpha).setStroke()
                path.lineWidth = 2.5
                path.stroke()
            }
        }
        for key in recognizing.keys.sorted() { draw(recognizing[key] ?? [], alpha: 0.35) }
        draw(pending, alpha: 1)
    }

    private func showPanels() {
        let screens = NSScreen.screens
        if panels.count != screens.count || zip(panels, screens).contains(where: { $0.frame != $1.frame }) {
            panels.forEach { $0.orderOut(nil) }
            panels = screens.map { screen in
                let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                    backing: .buffered, defer: false)
                panel.setFrame(screen.frame, display: false)
                panel.isOpaque = false
                panel.backgroundColor = .clear
                panel.hasShadow = false
                panel.level = .screenSaver
                panel.ignoresMouseEvents = true
                panel.hidesOnDeactivate = false
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
                panel.contentView = InkView(frame: NSRect(origin: .zero, size: screen.frame.size))
                return panel
            }
        }
        panels.forEach { $0.orderFrontRegardless() }
    }

    private func hidePanels() {
        panels.forEach { $0.orderOut(nil) }
    }

    /// Redraws only the segment that changed : a full-screen redraw per pen
    /// report would be far too slow.
    private func invalidate(around points: [CGPoint]) {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        for panel in panels {
            guard let view = panel.contentView else { continue }
            var rect = NSRect.null
            for p in points {
                let local = NSPoint(x: p.x - panel.frame.minX, y: primaryHeight - p.y - panel.frame.minY)
                rect = rect.union(NSRect(origin: local, size: .zero))
            }
            let dirty = rect.insetBy(dx: -6, dy: -6).intersection(view.bounds)
            if !dirty.isEmpty { view.setNeedsDisplay(dirty) }
        }
    }

    private func redraw() {
        panels.forEach { $0.contentView?.needsDisplay = true }
    }
}

private final class InkView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        Handwriting.shared.drawInk(in: self)
    }
}
