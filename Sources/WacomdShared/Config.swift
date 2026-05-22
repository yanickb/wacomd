import Foundation

/// User-tunable configuration for the touch surface behaviour.
/// Persisted to `~/Library/Application Support/wacomd/config.json` and
/// reloaded on SIGHUP so the user can iterate without restarting the daemon.
public struct WacomdConfig: Codable, Equatable {
    // ---- Touch enable toggles ---------------------------------------------
    public var oneFingerCursor:   Bool = true
    public var twoFingerScroll:   Bool = true
    public var threeFingerSwipes: Bool = true
    public var tapToClick:        Bool = true

    // ---- Sensitivities (raw-tablet-units → screen-pixels) -----------------
    /// 1-finger cursor : 0.35 ≈ MacBook trackpad "Tracking speed 5/10"
    public var cursorSensitivity: Double = 0.35
    /// 2-finger scroll : 0.5 ≈ ~one page per full-tablet swipe
    public var scrollSensitivity: Double = 0.5
    /// 3-finger swipe trigger threshold, in raw units of centroid travel.
    public var threeFingerSwipeThreshold: Double = 200

    // ---- Tap recognition --------------------------------------------------
    public var tapMaxDurationMs: Int = 200
    /// Max drift in raw tablet units during a contact for it to still be a tap.
    public var tapMaxRawMovement: Double = 60

    public init() {}

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
