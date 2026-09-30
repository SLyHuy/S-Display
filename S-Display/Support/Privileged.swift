import Foundation

/// Runs a shell command as root after macOS asks for an administrator password.
/// Adapted from Crisp's HiDPIService.executePrivilegedCommand (MIT).
enum Privileged {
    @MainActor
    static func run(_ command: String) throws {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        guard let script = NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges") else {
            throw SDisplayError.privileged("couldn't build the AppleScript")
        }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        guard let error else { return }
        if (error[NSAppleScript.errorNumber] as? Int) == -128 { throw SDisplayError.cancelled }
        throw SDisplayError.privileged(error[NSAppleScript.errorMessage] as? String ?? "unknown error")
    }

    /// Single-quotes `path` for /bin/sh.
    static func quote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
