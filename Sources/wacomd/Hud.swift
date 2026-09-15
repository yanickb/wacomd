import AppKit
import WacomdShared

/// On-screen feedback drawn by the daemon : a small bubble near the cursor
/// (held modes + last fired shortcut) and the radial menu.
///
/// Both are borderless, click-through panels floating above every app and
/// Space. Main thread only.
final class Hud {
    static let shared = Hud()

    private var modes: [String] = []
    private var flashText: String?
    private var flashToken = 0

    private lazy var bubble: NSPanel = {
        let panel = Self.makePanel(size: NSSize(width: 120, height: 26))
        panel.hasShadow = false
        return panel
    }()
    private let bubbleLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        // Keeps white text readable on light content when the background is faint.
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.8)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = .zero
        label.shadow = shadow
        return label
    }()
    private lazy var bubbleBackground: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 8
        view.addSubview(bubbleLabel)
        return view
    }()
    /// Repositions the bubble under the cursor while it is visible.
    private var followTimer: Timer?
    private var bubbleSize = NSSize.zero

    private lazy var radialPanel: NSPanel = Self.makePanel(size: NSSize(width: RadialMenuView.diameter,
                                                                        height: RadialMenuView.diameter))
    private let radialView = RadialMenuView(frame: NSRect(x: 0, y: 0,
                                                          width: RadialMenuView.diameter,
                                                          height: RadialMenuView.diameter))

    private var enabled: Bool { ConfigStore.shared.current.hudEnabled }

    // MARK: - Bubble

    /// Shows `name` for as long as the mode is active.
    func setMode(_ name: String, active: Bool) {
        modes.removeAll { $0 == name }
        if active { modes.append(name) }
        refreshBubble()
    }

    /// Shows `text` for a moment.
    func flash(_ text: String) {
        flashText = text
        flashToken += 1
        let token = flashToken
        refreshBubble()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self = self, self.flashToken == token else { return }
            self.flashText = nil
            self.refreshBubble()
        }
    }

    private func refreshBubble() {
        let text = (modes + [flashText].compactMap { $0 }).joined(separator: "  ·  ")
        guard enabled, !text.isEmpty else {
            bubble.orderOut(nil)
            followTimer?.invalidate()
            followTimer = nil
            return
        }
        if bubble.contentView !== bubbleBackground { bubble.contentView = bubbleBackground }
        let opacity = min(max(ConfigStore.shared.current.hudOpacity, 0), 1)
        bubbleBackground.layer?.backgroundColor = NSColor.black.withAlphaComponent(CGFloat(opacity)).cgColor
        bubbleLabel.stringValue = text
        bubbleLabel.sizeToFit()
        bubbleSize = NSSize(width: bubbleLabel.frame.width + 16, height: 22)
        bubbleLabel.frame = NSRect(x: 8, y: (bubbleSize.height - bubbleLabel.frame.height) / 2,
                                   width: bubbleLabel.frame.width, height: bubbleLabel.frame.height)
        bubble.setContentSize(bubbleSize)
        followCursor()
        bubble.orderFrontRegardless()

        if followTimer == nil {
            // 60 Hz, only while visible : follows pen, mouse and trackpad alike.
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.followCursor() }
            RunLoop.main.add(timer, forMode: .common)
            followTimer = timer
        }
    }

    /// Sticks the bubble just below-right of the cursor, inside the screen under it.
    private func followCursor() {
        let mouse = NSEvent.mouseLocation
        var origin = NSPoint(x: mouse.x + 16, y: mouse.y - 18 - bubbleSize.height)
        if let visible = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main)?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 2), visible.maxX - bubbleSize.width - 2)
            origin.y = min(max(origin.y, visible.minY + 2), visible.maxY - bubbleSize.height - 2)
        }
        if bubble.frame.origin != origin { bubble.setFrameOrigin(origin) }
    }

    // MARK: - Radial menu

    /// Opens the menu centred on `point` (CG global coordinates, top-left origin).
    func showRadial(titles: [String], at point: CGPoint) {
        radialView.titles = titles
        radialView.highlighted = nil
        if radialPanel.contentView !== radialView { radialPanel.contentView = radialView }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let d = RadialMenuView.diameter
        radialPanel.setFrame(NSRect(x: point.x - d / 2, y: primaryHeight - point.y - d / 2, width: d, height: d),
                             display: true)
        radialPanel.orderFrontRegardless()
    }

    func highlightRadial(_ index: Int?) {
        guard radialView.highlighted != index else { return }
        radialView.highlighted = index
    }

    func hideRadial() {
        radialPanel.orderOut(nil)
    }

    // MARK: -

    private static func makePanel(size: NSSize) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .screenSaver
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return panel
    }
}

/// Pie of up to 8 sectors, item 0 at the top, clockwise.
final class RadialMenuView: NSView {
    static let diameter: CGFloat = 280
    static let innerRadius: CGFloat = 34

    var titles: [String] = [] { didSet { needsDisplay = true } }
    var highlighted: Int? { didSet { needsDisplay = true } }

    /// Sector under a pen offset from the menu centre (CG coordinates, y down),
    /// or nil inside the dead zone.
    static func sector(dx: CGFloat, dy: CGFloat, count: Int) -> Int? {
        guard count > 0, hypot(dx, dy) > innerRadius else { return nil }
        let clockwiseFromTop = (atan2(dx, -dy) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        let step = 360 / CGFloat(count)
        return Int((clockwiseFromTop + step / 2) / step) % count
    }

    override func draw(_ dirtyRect: NSRect) {
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let outer = Self.diameter / 2 - 6
        let count = max(titles.count, 1)
        let step = 360 / CGFloat(count)

        let disc = NSBezierPath(ovalIn: NSRect(x: center.x - outer, y: center.y - outer, width: outer * 2, height: outer * 2))
        NSColor.windowBackgroundColor.withAlphaComponent(0.94).setFill()
        disc.fill()

        for (index, title) in titles.enumerated() {
            // Cocoa angles are counter-clockwise from +x ; item 0 is centred on the top.
            let mid = 90 - CGFloat(index) * step
            if index == highlighted {
                let sector = NSBezierPath()
                sector.appendArc(withCenter: center, radius: outer, startAngle: mid - step / 2, endAngle: mid + step / 2)
                sector.appendArc(withCenter: center, radius: Self.innerRadius, startAngle: mid + step / 2,
                                 endAngle: mid - step / 2, clockwise: true)
                sector.close()
                NSColor.controlAccentColor.withAlphaComponent(0.85).setFill()
                sector.fill()
            }

            if count > 1 {
                let separator = NSBezierPath()
                let edge = (mid + step / 2) * .pi / 180
                separator.move(to: NSPoint(x: center.x + cos(edge) * Self.innerRadius, y: center.y + sin(edge) * Self.innerRadius))
                separator.line(to: NSPoint(x: center.x + cos(edge) * outer, y: center.y + sin(edge) * outer))
                NSColor.separatorColor.setStroke()
                separator.lineWidth = 1
                separator.stroke()
            }

            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: index == highlighted ? NSColor.white : NSColor.labelColor,
            ]
            let text = NSAttributedString(string: title, attributes: attributes)
            let size = text.size()
            let radius = (outer + Self.innerRadius) / 2 + 6
            let angle = mid * .pi / 180
            text.draw(at: NSPoint(x: center.x + cos(angle) * radius - size.width / 2,
                                  y: center.y + sin(angle) * radius - size.height / 2))
        }

        let hub = NSBezierPath(ovalIn: NSRect(x: center.x - Self.innerRadius, y: center.y - Self.innerRadius,
                                              width: Self.innerRadius * 2, height: Self.innerRadius * 2))
        NSColor.separatorColor.setStroke()
        hub.lineWidth = 1
        hub.stroke()
    }
}
