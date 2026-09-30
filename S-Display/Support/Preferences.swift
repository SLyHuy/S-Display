import CoreGraphics
import Foundation

enum Preferences {
    private static let offRecordsKey = "offDisplays"
    private static let pendingReconnectsKey = "pendingReconnects"
    private static let keepOffAfterRestartKey = "keepOffAfterRestart"
    private static let screenSizeOverridesKey = "screenSizeOverrides"

    static var offRecords: [OffDisplayRecord] {
        get { records(forKey: offRecordsKey) }
        set { setRecords(newValue, forKey: offRecordsKey) }
    }

    /// Displays in the middle of a soft reconnect. A marker left behind means S-Display died mid-blink
    /// with the display off, so the next launch turns it back on.
    static var pendingReconnects: [OffDisplayRecord] {
        get { records(forKey: pendingReconnectsKey) }
        set { setRecords(newValue, forKey: pendingReconnectsKey) }
    }

    private static func records(forKey key: String) -> [OffDisplayRecord] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([OffDisplayRecord].self, from: data)) ?? []
    }

    private static func setRecords(_ records: [OffDisplayRecord], forKey key: String) {
        UserDefaults.standard.set(try? JSONEncoder().encode(records), forKey: key)
    }

    /// Diagonal sizes in inches the user picked, by display UUID, for monitors whose EDID reports a wrong size.
    static var screenSizeOverrides: [String: Double] {
        get { (UserDefaults.standard.dictionary(forKey: screenSizeOverridesKey) as? [String: Double]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: screenSizeOverridesKey) }
    }

    static var keepOffAfterRestart: Bool {
        get { UserDefaults.standard.bool(forKey: keepOffAfterRestartKey) }
        set { UserDefaults.standard.set(newValue, forKey: keepOffAfterRestartKey) }
    }

    /// Copies of override files that existed before S-Display replaced them, restored on Remove.
    static var overrideBackupDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "S-Display/OverrideBackups", directoryHint: .isDirectory)
    }
}

enum SDisplayError: LocalizedError {
    case unsupported
    case lastDisplay
    case needsAnotherDisplay
    case didNotTurnOff(String, CGError)
    case didNotComeBack(String, CGError)
    case modeNotApplied(String, CGError)
    case cancelled
    case privileged(String)
    case file(String)

    var errorDescription: String? {
        switch self {
        case .unsupported:
            "This Mac doesn't expose the display-disconnect API (Apple Silicon and macOS 14+ needed)."
        case .lastDisplay:
            "S-Display won't turn off the last visible display."
        case .needsAnotherDisplay:
            "Another display must stay on while this one reconnects. Replug its cable to load the new sizes."
        case let .didNotTurnOff(name, error):
            "\(name) didn't turn off (WindowServer error \(error.rawValue))."
        case let .didNotComeBack(name, error):
            "\(name) didn't come back (WindowServer error \(error.rawValue)). Press ⌃⌥⌘0, or replug its cable."
        case let .modeNotApplied(size, error):
            "Couldn't switch to \(size) (WindowServer error \(error.rawValue))."
        case .cancelled:
            "Cancelled."
        case let .privileged(message):
            "Administrator command failed: \(message)"
        case let .file(message):
            message
        }
    }
}
