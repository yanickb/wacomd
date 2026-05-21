import Foundation

enum Verbose {
    static let enabled: Bool = {
        if let v = ProcessInfo.processInfo.environment["WACOMD_VERBOSE"], !v.isEmpty, v != "0" {
            return true
        }
        return CommandLine.arguments.contains("-v") || CommandLine.arguments.contains("--verbose")
    }()

    static func log(_ message: @autoclosure () -> String) {
        if enabled {
            FileHandle.standardError.write(Data("[v] \(message())\n".utf8))
        }
    }
}
