import Foundation

// MARK: - Action

/// What a pen barrel button or a pad ExpressKey does while it is held.
/// Serialised as a plain string so the JSON stays hand-editable :
/// `"none"`, `"leftClick"`, `"rightClick"`, `"middleClick"`, `"precision"`,
/// `"layer"`, `"brushSize"`, `"eraser"`, `"scroll"`, `"radialMenu"`, or a
/// shortcut such as `"cmd+z"`, `"space"`, `"shift"` (held modifier) or
/// `"shift+middleClick"` (click with modifiers).
public enum ButtonAction: Codable, Equatable, Hashable {
    case none
    case leftClick
    case rightClick
    case middleClick
    /// While held, pen motion is scaled down around the cursor.
    case precision
    /// While held, the other buttons use their layer-2 binding.
    case layer
    /// Latched version of a held action : one press starts it, the next
    /// press stops it. Serialised as `"toggle:<action>"`.
    indirect case toggle(ButtonAction)
    /// While held, horizontal pen motion taps the brush-size keys.
    case brushSize
    /// While held, apps see the eraser end of the pen.
    case eraser
    /// While held, hovering pen motion scrolls instead of moving the cursor.
    case scroll
    /// While held, shows the radial menu ; releasing runs the pointed item.
    case radialMenu
    /// While held, the pen moves the cursor relatively, like a mouse.
    case mouseMode
    /// While held, inverts the stroke stabilizer's default state.
    case stabilizer
    /// While held, quick pen flicks up / right / down / left run actions.
    case penGestures
    case shortcut(String)

    public init(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased().hasPrefix("toggle:") {
            self = .toggle(ButtonAction(String(trimmed.dropFirst("toggle:".count))))
            return
        }
        switch trimmed.lowercased() {
        case "", "none":     self = .none
        case "leftclick":    self = .leftClick
        case "rightclick":   self = .rightClick
        case "middleclick":  self = .middleClick
        case "precision":    self = .precision
        case "layer":        self = .layer
        case "layertoggle":  self = .toggle(.layer)
        case "brushsize":    self = .brushSize
        case "eraser":       self = .eraser
        case "scroll":       self = .scroll
        case "radialmenu":   self = .radialMenu
        case "mousemode":    self = .mouseMode
        case "stabilizer":   self = .stabilizer
        case "pengestures":  self = .penGestures
        default:             self = .shortcut(trimmed)
        }
    }

    public var rawValue: String {
        switch self {
        case .none:            return "none"
        case .leftClick:       return "leftClick"
        case .rightClick:      return "rightClick"
        case .middleClick:     return "middleClick"
        case .precision:       return "precision"
        case .layer:           return "layer"
        case .toggle(let a):   return "toggle:" + a.rawValue
        case .brushSize:       return "brushSize"
        case .eraser:          return "eraser"
        case .scroll:          return "scroll"
        case .radialMenu:      return "radialMenu"
        case .mouseMode:       return "mouseMode"
        case .stabilizer:      return "stabilizer"
        case .penGestures:     return "penGestures"
        case .shortcut(let s): return s
        }
    }

    /// Modes that only make sense while held. On a button that also has a
    /// double or long press, the press action is a brief tap, so these are
    /// useless there.
    public var isHoldMode: Bool {
        switch self {
        case .precision, .layer, .brushSize, .eraser, .scroll, .radialMenu,
             .mouseMode, .stabilizer, .penGestures: return true
        case .shortcut(let s):
            // Lone modifiers (`alt`) and modifier+click must be held too.
            let key = s.lowercased().split(separator: "+").last.map(String.init) ?? ""
            return ["cmd", "command", "shift", "alt", "opt", "option", "ctrl", "control",
                    "leftclick", "rightclick", "middleclick", "space"].contains(key)
        default: return false
        }
    }

    /// Short human label, used by the on-screen HUD and the radial menu.
    public var displayName: String {
        switch self {
        case .none:            return "—"
        case .leftClick:       return "Clic gauche"
        case .rightClick:      return "Clic droit"
        case .middleClick:     return "Clic milieu"
        case .precision:       return "Précision"
        case .layer:           return "Calque 2"
        case .toggle(let a):   return a.displayName + " (bascule)"
        case .brushSize:       return "Taille pinceau"
        case .eraser:          return "Gomme"
        case .scroll:          return "Défilement"
        case .radialMenu:      return "Menu circulaire"
        case .mouseMode:       return "Mode souris"
        case .stabilizer:      return "Stabilisateur"
        case .penGestures:     return "Gestes au stylet"
        case .shortcut(let s): return Self.prettyShortcut(s)
        }
    }

    /// `"cmd+shift+z"` → `"⌘⇧Z"`, `"shift+middleClick"` → `"⇧ Clic milieu"`.
    public static func prettyShortcut(_ spec: String) -> String {
        let symbols: [String: String] = [
            "cmd": "⌘", "command": "⌘", "shift": "⇧", "alt": "⌥", "opt": "⌥", "option": "⌥",
            "ctrl": "⌃", "control": "⌃",
        ]
        let names: [String: String] = [
            "space": "Espace", "tab": "⇥", "return": "↩", "enter": "↩", "esc": "⎋", "escape": "⎋",
            "delete": "⌫", "backspace": "⌫", "left": "←", "right": "→", "up": "↑", "down": "↓",
            "home": "↖", "end": "↘", "pageup": "⇞", "pagedown": "⇟",
            "leftclick": " Clic gauche", "rightclick": " Clic droit", "middleclick": " Clic milieu",
        ]
        var parts = spec.lowercased().split(separator: "+").map(String.init)
        if spec.hasSuffix("++") { parts.append("+") }
        guard let key = parts.popLast() else { return spec }
        let mods = parts.map { symbols[$0] ?? $0 }.joined()
        if let symbol = symbols[key] { return mods + symbol }
        if let name = names[key] { return (mods + name).trimmingCharacters(in: .whitespaces) }
        if key.hasPrefix("num"), key.count > 3 { return mods + "Pavé " + key.dropFirst(3).uppercased() }
        return mods + key.uppercased()
    }

    public init(from decoder: Decoder) throws {
        self.init(try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

// MARK: - Binding (press / double / long)

/// Actions of one physical button. When `double` and `long` are both
/// `.none` the press action follows the button exactly (it can be held).
/// Otherwise the press action becomes a short tap, decided once the double
/// press delay or the long press delay is over.
///
/// Encoded as a plain action string when only `press` is set, so older
/// config files (`"padButtons": ["cmd+z", …]`) stay valid.
public struct ButtonBinding: Codable, Equatable, Hashable {
    public var press: ButtonAction
    public var double: ButtonAction
    public var long: ButtonAction

    public init(_ press: ButtonAction, double: ButtonAction = .none, long: ButtonAction = .none) {
        self.press = press
        self.double = double
        self.long = long
    }

    public var hasGestures: Bool { double != .none || long != .none }

    private enum CodingKeys: String, CodingKey { case press, double, long }

    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer().decode(String.self) {
            self.init(ButtonAction(single))
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(try c.decodeIfPresent(ButtonAction.self, forKey: .press) ?? .none,
                  double: try c.decodeIfPresent(ButtonAction.self, forKey: .double) ?? .none,
                  long: try c.decodeIfPresent(ButtonAction.self, forKey: .long) ?? .none)
    }

    public func encode(to encoder: Encoder) throws {
        if !hasGestures {
            try press.encode(to: encoder)
            return
        }
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(press, forKey: .press)
        try c.encode(double, forKey: .double)
        try c.encode(long, forKey: .long)
    }
}

// MARK: - Radial menu

public struct RadialItem: Codable, Equatable, Hashable {
    /// Label shown in the menu ; empty = the action's display name.
    public var label: String
    public var action: ButtonAction

    public init(_ label: String, _ action: ButtonAction) {
        self.label = label
        self.action = action
    }

    public var title: String { label.isEmpty ? action.displayName : label }
}

// MARK: - Button map

public enum PhysicalButton: Hashable {
    case penLower
    case penUpper
    case pad(Int)

    public var id: String {
        switch self {
        case .penLower:       return "pen.lower"
        case .penUpper:       return "pen.upper"
        case .pad(let index): return "pad.\(index + 1)"
        }
    }
}

/// Every binding of one profile : pen buttons, pad keys (layers 1 and 2)
/// and the radial menu. Its key names match the flat keys older config
/// files had at top level, so those files decode into the default map.
public struct ButtonMap: Codable, Equatable {
    /// Pen side button closest to the tip.
    public var penLowerButton = ButtonBinding(.rightClick)
    /// Pen side button farthest from the tip.
    public var penUpperButton = ButtonBinding(.radialMenu)
    /// Pad ExpressKeys, left to right. Hold modes (eraser, precision, layer)
    /// get a button of their own : see `ButtonAction.isHoldMode`.
    public var padButtons: [ButtonBinding] = [
        ButtonBinding(.shortcut("cmd+z"), double: .shortcut("cmd+shift+z")),
        ButtonBinding(.eraser),
        ButtonBinding(.precision),
        ButtonBinding(.toggle(.layer), long: .layer),
    ]
    public var layer2PenLowerButton = ButtonBinding(.rightClick)
    public var layer2PenUpperButton = ButtonBinding(.middleClick)
    public var layer2PadButtons: [ButtonBinding] = [
        ButtonBinding(.shortcut("cmd+-"), double: .shortcut("cmd+0")),
        ButtonBinding(.shortcut("cmd+=")),
        ButtonBinding(.brushSize),
        ButtonBinding(.toggle(.layer), long: .layer),
    ]
    /// Up to 8 items, clockwise from the top.
    public var radialMenu: [RadialItem] = [
        RadialItem("Annuler", .shortcut("cmd+z")),
        RadialItem("Rétablir", .shortcut("cmd+shift+z")),
        RadialItem("Zoom +", .shortcut("cmd+=")),
        RadialItem("Zoom −", .shortcut("cmd+-")),
        RadialItem("Copier", .shortcut("cmd+c")),
        RadialItem("Coller", .shortcut("cmd+v")),
        RadialItem("Enregistrer", .shortcut("cmd+s")),
        RadialItem("Clic droit", .rightClick),
    ]

    /// Pen flicks while `.penGestures` is held : up, right, down, left.
    public var penGestures: [ButtonAction] = [
        .shortcut("cmd+="), .shortcut("cmd+shift+z"), .shortcut("cmd+-"), .shortcut("cmd+z"),
    ]

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case penLowerButton, penUpperButton, padButtons
        case layer2PenLowerButton, layer2PenUpperButton, layer2PadButtons
        case radialMenu, penGestures
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ButtonMap()
        penLowerButton       = try c.decodeIfPresent(ButtonBinding.self,   forKey: .penLowerButton)       ?? d.penLowerButton
        penUpperButton       = try c.decodeIfPresent(ButtonBinding.self,   forKey: .penUpperButton)       ?? d.penUpperButton
        padButtons           = try c.decodeIfPresent([ButtonBinding].self, forKey: .padButtons)           ?? d.padButtons
        layer2PenLowerButton = try c.decodeIfPresent(ButtonBinding.self,   forKey: .layer2PenLowerButton) ?? d.layer2PenLowerButton
        layer2PenUpperButton = try c.decodeIfPresent(ButtonBinding.self,   forKey: .layer2PenUpperButton) ?? d.layer2PenUpperButton
        layer2PadButtons     = try c.decodeIfPresent([ButtonBinding].self, forKey: .layer2PadButtons)     ?? d.layer2PadButtons
        radialMenu           = try c.decodeIfPresent([RadialItem].self,    forKey: .radialMenu)           ?? d.radialMenu
        penGestures          = try c.decodeIfPresent([ButtonAction].self,  forKey: .penGestures)          ?? d.penGestures
    }

    /// Binding of a button once the layer state is known. A button bound to
    /// `.layer` or `.toggle(.layer)` (press, double or long) keeps its layer-1
    /// binding on layer 2, so it can always bring layer 1 back.
    public func binding(for button: PhysicalButton, layer2: Bool) -> ButtonBinding {
        let base = layerBinding(for: button, layer2: false)
        let layerKeys: [ButtonAction] = [.layer, .toggle(.layer)]
        guard layer2, !layerKeys.contains(base.press), !layerKeys.contains(base.long),
              !layerKeys.contains(base.double) else { return base }
        return layerBinding(for: button, layer2: true)
    }

    public func layerBinding(for button: PhysicalButton, layer2: Bool) -> ButtonBinding {
        switch button {
        case .penLower: return layer2 ? layer2PenLowerButton : penLowerButton
        case .penUpper: return layer2 ? layer2PenUpperButton : penUpperButton
        case .pad(let index):
            let keys = layer2 ? layer2PadButtons : padButtons
            return keys.indices.contains(index) ? keys[index] : ButtonBinding(.none)
        }
    }

    public mutating func setLayerBinding(_ binding: ButtonBinding, for button: PhysicalButton, layer2: Bool) {
        switch button {
        case .penLower:
            if layer2 { layer2PenLowerButton = binding } else { penLowerButton = binding }
        case .penUpper:
            if layer2 { layer2PenUpperButton = binding } else { penUpperButton = binding }
        case .pad(let index):
            var keys = layer2 ? layer2PadButtons : padButtons
            while keys.count <= index { keys.append(ButtonBinding(.none)) }
            keys[index] = binding
            if layer2 { layer2PadButtons = keys } else { padButtons = keys }
        }
    }
}

// MARK: - Presets

extension ButtonMap {
    /// Preset for a known app, `nil` otherwise.
    public static func preset(forBundleID bundleID: String) -> ButtonMap? {
        switch bundleID {
        case "com.adobe.Photoshop":           return .photoshop
        case "org.blenderfoundation.blender": return .blender
        default:                              return nil
        }
    }

    public static var photoshop: ButtonMap {
        var m = ButtonMap()
        // ⌥ held on the pen : pipette while painting.
        m.penLowerButton = ButtonBinding(.shortcut("alt"))
        m.penUpperButton = ButtonBinding(.radialMenu)
        m.padButtons = [
            ButtonBinding(.shortcut("cmd+z"), double: .shortcut("cmd+shift+z")),
            ButtonBinding(.eraser),
            ButtonBinding(.brushSize),
            ButtonBinding(.toggle(.layer), long: .layer),
        ]
        m.layer2PenLowerButton = ButtonBinding(.shortcut("alt"))
        m.layer2PenUpperButton = ButtonBinding(.precision)
        m.layer2PadButtons = [
            // Double : fit on screen.
            ButtonBinding(.shortcut("cmd+-"), double: .shortcut("cmd+0")),
            ButtonBinding(.shortcut("cmd+=")),
            // Space held : drag with the tip to pan.
            ButtonBinding(.shortcut("space")),
            ButtonBinding(.toggle(.layer), long: .layer),
        ]
        m.radialMenu = [
            RadialItem("Pinceau", .shortcut("b")),
            RadialItem("Gomme", .shortcut("e")),
            RadialItem("Pipette", .shortcut("i")),
            RadialItem("Lasso", .shortcut("l")),
            RadialItem("Déplacer", .shortcut("v")),
            RadialItem("Transformer", .shortcut("cmd+t")),
            RadialItem("Désélectionner", .shortcut("cmd+d")),
            RadialItem("Inverser couleurs", .shortcut("x")),
        ]
        return m
    }

    public static var blender: ButtonMap {
        var m = ButtonMap()
        // Middle-drag orbits, ⇧ + middle-drag pans.
        m.penUpperButton = ButtonBinding(.middleClick)
        m.penLowerButton = ButtonBinding(.shortcut("shift+middleClick"))
        m.padButtons = [
            ButtonBinding(.shortcut("cmd+z"), double: .shortcut("cmd+shift+z")),
            // Hover-scroll zooms the viewport.
            ButtonBinding(.scroll),
            // Tab : edit mode. Double : frame the selection. Long : front view.
            ButtonBinding(.shortcut("tab"), double: .shortcut("num."), long: .shortcut("num1")),
            ButtonBinding(.toggle(.layer), long: .layer),
        ]
        m.layer2PenUpperButton = ButtonBinding(.shortcut("ctrl+middleClick"))
        m.layer2PenLowerButton = ButtonBinding(.rightClick)
        m.layer2PadButtons = [
            ButtonBinding(.shortcut("g"), double: .shortcut("r")),
            ButtonBinding(.precision),
            ButtonBinding(.radialMenu),
            ButtonBinding(.toggle(.layer), long: .layer),
        ]
        m.radialMenu = [
            RadialItem("Dessus", .shortcut("num7")),
            RadialItem("Déplacer", .shortcut("g")),
            RadialItem("Droite", .shortcut("num3")),
            RadialItem("Tourner", .shortcut("r")),
            RadialItem("Face", .shortcut("num1")),
            RadialItem("Échelle", .shortcut("s")),
            RadialItem("Persp / Ortho", .shortcut("num5")),
            RadialItem("Ajouter", .shortcut("shift+a")),
        ]
        // Views : top, right, front, left.
        m.penGestures = [.shortcut("num7"), .shortcut("num3"), .shortcut("num1"), .shortcut("ctrl+num3")]
        return m
    }
}

// MARK: - App profiles

public struct AppProfile: Codable, Equatable, Identifiable {
    public var bundleID: String
    public var name: String
    public var enabled: Bool
    public var buttons: ButtonMap

    public var id: String { bundleID }

    public init(bundleID: String, name: String, enabled: Bool = true, buttons: ButtonMap) {
        self.bundleID = bundleID
        self.name = name
        self.enabled = enabled
        self.buttons = buttons
    }
}
