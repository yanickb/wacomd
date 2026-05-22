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

    public init() {}

    /// Custom decoder so adding new fields doesn't reject existing config
    /// files — missing keys fall back to the default value of that field.
    private enum CodingKeys: String, CodingKey {
        case touchEnabled
        case oneFingerCursor, twoFingerScroll, threeFingerSwipes, tapToClick
        case naturalScroll
        case cursorSensitivity, scrollSensitivity, threeFingerSwipeThreshold
        case tapMaxDurationMs, tapMaxRawMovement
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
        task.arguments = ["-f", "wacomd"]
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
