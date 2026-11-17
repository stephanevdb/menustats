import AppKit

/// Apps that "Force quit all apps" leaves alone, stored as newline-separated bundle IDs.
enum KeepRunning {
    static let key = "forceQuit.keepRunning"
    static let defaultValue = "net.pangolin.Pangolin"

    static func ids(from raw: String) -> [String] {
        raw.split(separator: "\n").map(String.init)
    }

    static func raw(from ids: [String]) -> String {
        ids.joined(separator: "\n")
    }

    static var current: Set<String> {
        Set(ids(from: UserDefaults.standard.string(forKey: key) ?? defaultValue))
    }

    static func name(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    static func icon(for bundleID: String) -> NSImage? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map {
            NSWorkspace.shared.icon(forFile: $0.path)
        }
    }
}
