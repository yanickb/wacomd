import Foundation

/// User-tunable configuration for the touch surface behaviour.
/// Persisted to `~/Library/Application Support/wacomd/config.json` and
/// reloaded on SIGHUP so the user can iterate without restarting the daemon.
public struct WacomdConfig: Codable, Equatable {
    // ---- Touch enable toggles ---------------------------------------------
    /// Master switch — when false, the whole multi-touch surface is
    /// ignored regardless of the per-gesture toggles below.
    public var touchEnabled: Bool = true

    public var oneFingerCursor:   Bool = true
    public var twoFingerScroll:   Bool = true
    public var threeFingerSwipes: Bool = true
    public var tapToClick:        Bool = true

    /// When true : finger moves down → page goes down (macOS "Natural
    /// scrolling" feel). When false : finger moves down → page goes up
    /// (Windows / pre-Lion macOS / classic mouse-wheel feel).
    public var naturalScroll: Bool = false

    // ---- Sensitivities (raw-tablet-units → screen-pixels) -----------------
    /// 1-finger cursor : 0.35 ≈ MacBook trackpad "Tracking speed 5/10"
    public var cursorSensitivity: Double = 0.35
    /// 2-finger scroll : 0.5 ≈ ~one page per full-tablet swipe
    public var scrollSensitivity: Double = 0.5
    /// 3-finger swipe trigger threshold, in raw units of centroid travel.
    public var threeFingerSwipeThreshold: Double = 200

    // ---- Tap recognition --------------------------------------------------
    /// Max contact duration to still be considered a "tap" (not a drag).
    /// 120 ms is on the tight side — only sharp deliberate taps qualify.
    public var tapMaxDurationMs: Int = 120
    /// Max drift in raw tablet units during a contact for it to still be a tap.
    /// 25 ≈ 0.6 mm on a PTH-451 ; tighter than this and even real taps miss,
    /// looser and slow short cursor movements get hijacked as taps.
    public var tapMaxRawMovement: Double = 25

    // ---- Buttons ----------------------------------------------------------
    /// Bindings used when the frontmost app has no enabled profile.
    public var buttons = ButtonMap()
    /// Per-app bindings, matched on the frontmost app's bundle identifier.
    public var appProfiles: [AppProfile] = []
    /// Max delay between two presses to count as a double press.
    public var doubleTapMs: Int = 300
    /// Hold duration after which a press becomes a long press.
    public var longPressMs: Int = 500
    /// On-screen bubble showing active modes and fired shortcuts.
    public var hudEnabled: Bool = true
    /// Opacity of the bubble background, 0 (text only) … 1 (opaque).
    public var hudOpacity: Double = 0.35

    // ---- Pressure ---------------------------------------------------------
    /// Exponent applied to the normalised pressure : < 1 soft (thick strokes
    /// with little force), > 1 firm.
    public var pressureCurve: Double = 1.0
    /// Normalised pressure under which the tip is ignored (light grazes).
    public var pressureMin: Double = 0.0
    /// Normalised pressure at which the output saturates to 1.
    public var pressureMax: Double = 1.0

    // ---- Tablet → screen mapping ------------------------------------------
    /// How the tablet lies on the desk.
    public var tabletOrientation: TabletOrientation = .landscape
    /// Index in `NSScreen.screens` (0 = display with the menu bar).
    public var displayIndex: Int = 0
    /// Trim the active area so a circle drawn on the tablet stays round.
    public var keepAspectRatio: Bool = true
    /// Active area of the tablet, normalised 0…1 (origin top-left).
    public var areaLeft: Double = 0
    public var areaTop: Double = 0
    public var areaRight: Double = 1
    public var areaBottom: Double = 1

    // ---- Modes ------------------------------------------------------------
    /// Cursor speed factor while `.precision` is held.
    public var precisionScale: Double = 0.25
    /// Screen pixels of horizontal pen travel per brush-size key tap.
    public var brushSizeStep: Double = 15
    public var brushSizeDecrease: String = "["
    public var brushSizeIncrease: String = "]"
    /// Scroll pixels per screen pixel of pen travel while `.scroll` is held.
    public var scrollSpeed: Double = 1.0
    /// Cursor pixels per screen pixel of pen travel in mouse mode.
    public var mouseSpeed: Double = 1.0
    /// Screen pixels of pen travel that trigger a pen gesture.
    public var penGestureDistance: Double = 70

    // ---- Stabilizer -------------------------------------------------------
    /// Default state ; a `.stabilizer` button inverts it while active.
    public var stabilizerEnabled: Bool = false
    /// 0 (off) … 100 (strong smoothing, more lag).
    public var stabilizerStrength: Double = 40

    public init() {}

    /// Custom decoder so adding new fields doesn't reject existing config
    /// files — missing keys fall back to the default value of that field.
    private enum CodingKeys: String, CodingKey {
        case touchEnabled
        case oneFingerCursor, twoFingerScroll, threeFingerSwipes, tapToClick
        case naturalScroll
        case cursorSensitivity, scrollSensitivity, threeFingerSwipeThreshold
        case tapMaxDurationMs, tapMaxRawMovement
        case buttons, appProfiles, doubleTapMs, longPressMs, hudEnabled, hudOpacity
        case pressureCurve, pressureMin, pressureMax
        case tabletOrientation, mouseSpeed, penGestureDistance, stabilizerEnabled, stabilizerStrength
        case displayIndex, keepAspectRatio, areaLeft, areaTop, areaRight, areaBottom
        case precisionScale, brushSizeStep, brushSizeDecrease, brushSizeIncrease, scrollSpeed
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = WacomdConfig()  // baseline of defaults
        self.touchEnabled      = try c.decodeIfPresent(Bool.self,   forKey: .touchEnabled)      ?? d.touchEnabled
        self.oneFingerCursor   = try c.decodeIfPresent(Bool.self,   forKey: .oneFingerCursor)   ?? d.oneFingerCursor
        self.twoFingerScroll   = try c.decodeIfPresent(Bool.self,   forKey: .twoFingerScroll)   ?? d.twoFingerScroll
        self.threeFingerSwipes = try c.decodeIfPresent(Bool.self,   forKey: .threeFingerSwipes) ?? d.threeFingerSwipes
        self.tapToClick        = try c.decodeIfPresent(Bool.self,   forKey: .tapToClick)        ?? d.tapToClick
        self.naturalScroll     = try c.decodeIfPresent(Bool.self,   forKey: .naturalScroll)     ?? d.naturalScroll
        self.cursorSensitivity = try c.decodeIfPresent(Double.self, forKey: .cursorSensitivity) ?? d.cursorSensitivity
        self.scrollSensitivity = try c.decodeIfPresent(Double.self, forKey: .scrollSensitivity) ?? d.scrollSensitivity
        self.threeFingerSwipeThreshold = try c.decodeIfPresent(Double.self, forKey: .threeFingerSwipeThreshold) ?? d.threeFingerSwipeThreshold
        self.tapMaxDurationMs  = try c.decodeIfPresent(Int.self,    forKey: .tapMaxDurationMs)  ?? d.tapMaxDurationMs
        self.tapMaxRawMovement = try c.decodeIfPresent(Double.self, forKey: .tapMaxRawMovement) ?? d.tapMaxRawMovement
        // Before profiles, button keys lived at top level : read them from
        // the same container when there is no "buttons" object.
        self.buttons           = try c.decodeIfPresent(ButtonMap.self, forKey: .buttons) ?? ButtonMap(from: decoder)
        self.appProfiles       = try c.decodeIfPresent([AppProfile].self, forKey: .appProfiles) ?? d.appProfiles
        self.doubleTapMs       = try c.decodeIfPresent(Int.self,    forKey: .doubleTapMs)       ?? d.doubleTapMs
        self.longPressMs       = try c.decodeIfPresent(Int.self,    forKey: .longPressMs)       ?? d.longPressMs
        self.hudEnabled        = try c.decodeIfPresent(Bool.self,   forKey: .hudEnabled)        ?? d.hudEnabled
        self.hudOpacity        = try c.decodeIfPresent(Double.self, forKey: .hudOpacity)        ?? d.hudOpacity
        self.scrollSpeed       = try c.decodeIfPresent(Double.self, forKey: .scrollSpeed)       ?? d.scrollSpeed
        // An unknown orientation must not reject the whole file.
        self.tabletOrientation = ((try? c.decodeIfPresent(TabletOrientation.self, forKey: .tabletOrientation)) ?? nil) ?? d.tabletOrientation
        self.mouseSpeed        = try c.decodeIfPresent(Double.self, forKey: .mouseSpeed)        ?? d.mouseSpeed
        self.penGestureDistance = try c.decodeIfPresent(Double.self, forKey: .penGestureDistance) ?? d.penGestureDistance
        self.stabilizerEnabled = try c.decodeIfPresent(Bool.self,   forKey: .stabilizerEnabled) ?? d.stabilizerEnabled
        self.stabilizerStrength = try c.decodeIfPresent(Double.self, forKey: .stabilizerStrength) ?? d.stabilizerStrength
        self.pressureCurve     = try c.decodeIfPresent(Double.self, forKey: .pressureCurve)     ?? d.pressureCurve
        self.pressureMin       = try c.decodeIfPresent(Double.self, forKey: .pressureMin)       ?? d.pressureMin
        self.pressureMax       = try c.decodeIfPresent(Double.self, forKey: .pressureMax)       ?? d.pressureMax
        self.displayIndex      = try c.decodeIfPresent(Int.self,    forKey: .displayIndex)      ?? d.displayIndex
        self.keepAspectRatio   = try c.decodeIfPresent(Bool.self,   forKey: .keepAspectRatio)   ?? d.keepAspectRatio
        self.areaLeft          = try c.decodeIfPresent(Double.self, forKey: .areaLeft)          ?? d.areaLeft
        self.areaTop           = try c.decodeIfPresent(Double.self, forKey: .areaTop)           ?? d.areaTop
        self.areaRight         = try c.decodeIfPresent(Double.self, forKey: .areaRight)         ?? d.areaRight
        self.areaBottom        = try c.decodeIfPresent(Double.self, forKey: .areaBottom)        ?? d.areaBottom
        self.precisionScale    = try c.decodeIfPresent(Double.self, forKey: .precisionScale)    ?? d.precisionScale
        self.brushSizeStep     = try c.decodeIfPresent(Double.self, forKey: .brushSizeStep)     ?? d.brushSizeStep
        self.brushSizeDecrease = try c.decodeIfPresent(String.self, forKey: .brushSizeDecrease) ?? d.brushSizeDecrease
        self.brushSizeIncrease = try c.decodeIfPresent(String.self, forKey: .brushSizeIncrease) ?? d.brushSizeIncrease
    }

    /// Enabled profile of the given app, if any.
    public func profile(forApp bundleID: String?) -> AppProfile? {
        guard let bundleID = bundleID else { return nil }
        return appProfiles.first { $0.enabled && $0.bundleID == bundleID }
    }

    /// Bindings for the given frontmost app : its enabled profile, else the default map.
    public func buttonMap(forApp bundleID: String?) -> ButtonMap {
        profile(forApp: bundleID)?.buttons ?? buttons
    }

    /// Maps a raw normalised pressure (0…1) through min / max / curve.
    public func mappedPressure(_ raw: Double) -> Double {
        let lo = min(max(pressureMin, 0), 0.95)
        let hi = max(min(pressureMax, 1), lo + 0.05)
        let t = min(max((raw - lo) / (hi - lo), 0), 1)
        return pow(t, min(max(pressureCurve, 0.1), 10))
    }

    /// Active tablet area (normalised, origin top-left) after aspect-ratio
    /// trimming. `tabletAspect` and `screenAspect` are width / height.
    public func effectiveArea(tabletAspect: Double, screenAspect: Double) -> (left: Double, top: Double, right: Double, bottom: Double) {
        var l = min(max(areaLeft, 0), 0.95), t = min(max(areaTop, 0), 0.95)
        var r = max(min(areaRight, 1), l + 0.05), b = max(min(areaBottom, 1), t + 0.05)
        guard keepAspectRatio, tabletAspect > 0, screenAspect > 0 else { return (l, t, r, b) }

        let areaAspect = ((r - l) * tabletAspect) / (b - t)
        if areaAspect > screenAspect {
            // Too wide : shrink width around the centre.
            let newWidth = (b - t) * screenAspect / tabletAspect
            let cx = (l + r) / 2
            l = cx - newWidth / 2; r = cx + newWidth / 2
        } else {
            let newHeight = (r - l) * tabletAspect / screenAspect
            let cy = (t + b) / 2
            t = cy - newHeight / 2; b = cy + newHeight / 2
        }
        return (l, t, r, b)
    }

    // ---- Where the config lives ------------------------------------------
    public static var defaultPath: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library/Application Support/wacomd")
            .appendingPathComponent("config.json")
    }
}

/// Thread-safe, hot-reloadable configuration store. Loads from disk on
/// init, exposes the current snapshot via `current`, and reloads on
/// `reload()` (called from a SIGHUP signal handler).
public final class ConfigStore {
    public static let shared = ConfigStore()

    private let queue = DispatchQueue(label: "wacomd.config")
    private var _current: WacomdConfig = WacomdConfig()
    public let path: URL = WacomdConfig.defaultPath

    public var current: WacomdConfig {
        queue.sync { _current }
    }

    private init() {
        loadFromDisk()
    }

    /// Re-read the config file. Safe to call from a signal handler context
    /// via DispatchSource.makeSignalSource (which dispatches on a queue).
    public func reload() {
        loadFromDisk()
        print("[wacomd] Config rechargée depuis \(path.path)")
        print("[wacomd]   cursor=\(_current.cursorSensitivity) scroll=\(_current.scrollSensitivity)")
        print("[wacomd]   1f=\(_current.oneFingerCursor) 2f=\(_current.twoFingerScroll) 3f=\(_current.threeFingerSwipes) tap=\(_current.tapToClick)")
    }

    /// Write a fresh config to disk. Returns false if the write failed.
    @discardableResult
    public func save(_ config: WacomdConfig) -> Bool {
        do {
            try writeToDisk(config)
            queue.sync { _current = config }
            return true
        } catch {
            FileHandle.standardError.write(Data(
                "[wacomd] Échec écriture config : \(error)\n".utf8))
            return false
        }
    }

    private func loadFromDisk() {
        queue.sync {
            do {
                let data = try Data(contentsOf: path)
                _current = try JSONDecoder().decode(WacomdConfig.self, from: data)
            } catch CocoaError.fileReadNoSuchFile {
                _current = WacomdConfig()
                try? writeToDisk(_current)
            } catch {
                FileHandle.standardError.write(Data(
                    "[wacomd] Config illisible (\(error)). Valeurs par défaut.\n".utf8))
                _current = WacomdConfig()
            }
        }
    }

    private func writeToDisk(_ config: WacomdConfig) throws {
        let dir = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try data.write(to: path, options: .atomic)
    }
}

// MARK: - Daemon control helpers (used by the configurator)

public enum DaemonControl {
    /// Find the PID of the running wacomd (if any). Returns nil if none.
    public static func runningPID() -> pid_t? {
        let task = Process()
        task.launchPath = "/usr/bin/pgrep"
        // Exact process name : `-f wacomd` also matched wacomd-config and
        // any shell whose command line mentions the repo.
        task.arguments = ["-x", "wacomd"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let myPID = ProcessInfo.processInfo.processIdentifier
        for line in String(data: data, encoding: .utf8)?.split(separator: "\n") ?? [] {
            if let pid = pid_t(line.trimmingCharacters(in: .whitespaces)),
               pid != myPID {
                return pid
            }
        }
        return nil
    }

    /// Send SIGHUP to the running daemon to hot-reload its config.
    public static func sendReloadSignal() {
        guard let pid = runningPID() else { return }
        kill(pid, SIGHUP)
    }
}

// MARK: - Orientation

public enum TabletOrientation: String, Codable, CaseIterable {
    /// Keys along the top edge, numbered left to right.
    case landscape
    /// Tablet turned a quarter counter-clockwise : keys on the left edge,
    /// numbered bottom to top.
    case portraitButtonsLeft

    public var title: String {
        switch self {
        case .landscape:           return "Paysage (touches en haut)"
        case .portraitButtonsLeft: return "Portrait, touches à gauche"
        }
    }

    /// How the pad keys are numbered as seen by the user.
    public var keyOrder: String {
        switch self {
        case .landscape:           return "de gauche à droite"
        case .portraitButtonsLeft: return "de bas en haut"
        }
    }

    /// Width / height of the surface as the user sees it.
    public func aspect(tabletAspect: Double) -> Double {
        self == .landscape ? tabletAspect : 1 / tabletAspect
    }

    /// Raw tablet position (normalised, origin top-left of the landscape
    /// surface) → position as seen by the user.
    public func orient(x: Double, y: Double) -> (x: Double, y: Double) {
        switch self {
        case .landscape:
            return (x, y)
        case .portraitButtonsLeft:
            // The landscape top edge becomes the left edge ; its right end
            // (key 4) ends up at the top.
            return (y, 1 - x)
        }
    }
}

// MARK: - Live status (daemon ⇄ configurator test tab)

/// Distributed notifications between the daemon and the configurator's Test
/// tab. The configurator sends `subscribe` every couple of seconds while the
/// tab is open ; the daemon only publishes `status` while subscribed.
public enum LiveStatusNames {
    public static let subscribe = Notification.Name("com.local.wacomd.live.subscribe")
    public static let status = Notification.Name("com.local.wacomd.live.status")
    /// Seconds a subscription lasts without renewal.
    public static let subscriptionLifetime: Double = 5
    /// `subscribe` userInfo key : bundle id whose profile the daemon uses
    /// while the configurator itself is frontmost ("" = its own profile).
    public static let testBundleIDKey = "testBundleID"
    public static let configuratorBundleID = "com.local.wacomd-config"
}
