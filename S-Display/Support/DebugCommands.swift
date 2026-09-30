#if DEBUG
import AppKit

/// Debug builds only: `scripts/debug-command.swift` drives the running app's real code paths
/// (the same calls the menu makes) and reads the resulting state back from the log.
@MainActor
enum DebugCommands {
    static let notification = Notification.Name("com.slyhuy.SDisplay.debug-command")

    static func install(on model: AppModel) {
        DistributedNotificationCenter.default().addObserver(forName: notification, object: nil, queue: .main) { [weak model] note in
            let command = note.object as? String ?? ""
            MainActor.assumeIsolated {
                _ = Task { await model?.runDebugCommand(command) }
            }
        }
    }
}

extension AppModel {
    /// Commands: dump | off <display> | on <display> | all-on | size <display> <looks-like width>
    /// | hidpi-install <display> | hidpi-remove <display> | blink <display> | strand <display>.
    /// <display> is an ID, UUID or name.
    func runDebugCommand(_ command: String) async {
        Log.displays.notice("debug command: \(command, privacy: .public)")
        let words = command.split(separator: " ").map(String.init)
        let target = words.count > 1 ? words[1] : ""
        let display = registry.displays.first { "\($0.id)" == target || $0.uuid == target || $0.name == target }

        switch words.first {
        case "dump":
            registry.refresh()
        case "off":
            if let display { await blackOut.turnOff(display) }
        case "on":
            if let record = blackOut.offRecords.first(where: { "\($0.lastDisplayID)" == target || $0.uuid == target || $0.name == target }) {
                await blackOut.turnOn(record)
            }
        case "all-on":
            await blackOut.turnAllOn()
        case "size":
            if let display, words.count > 2, let width = Int(words[2]),
               let stop = display.stops.first(where: { $0.width == width }) {
                await resolution.apply(stop, to: display)
            }
        case "hidpi-install":
            if let display { await hiDPI.install(for: display) }
        case "hidpi-remove":
            if let display { await hiDPI.remove(for: display) }
        case "blink":
            if let display {
                do { try await blackOut.softReconnect(display) } catch { Log.displays.error("\(error.localizedDescription, privacy: .public)") }
            }
        case "strand":
            // Rehearses S-Display dying mid-blink: marker written, display off, no enable. Kill and relaunch next.
            if let display { _ = await blackOut.beginBlink(display) }
        default:
            Log.displays.error("unknown debug command")
        }
        dumpState()
    }

    private func dumpState() {
        for display in registry.displays {
            let current = display.current.map { "\($0.width)x\($0.height) px \($0.pixelWidth)x\($0.pixelHeight) @\(Int($0.refreshRate))" } ?? "-"
            let stops = display.stops.map { stop -> String in
                if case .skyLight = stop.mode.source { return "\(stop.width)*" }
                return "\(stop.width)"
            }
            let line = "display \(display.id) '\(display.name)' uuid=\(display.uuid) native=\(display.nativeWidth)x\(display.nativeHeight) "
                + "current=\(current) stops=[\(stops.joined(separator: " "))] currentStop=\(display.currentStopIndex.map(String.init) ?? "-") "
                + "recommended=\(display.recommendedStopIndex.map { String(display.stops[$0].width) } ?? "-") "
                + "canTurnOff=\(blackOut.canTurnOff(display)) hidpiInstalled=\(hiDPI.isInstalled(display)) "
                + "busy=\(isBusy(display.uuid)) error=\(error(for: display.uuid) ?? "-")"
            Log.displays.notice("\(line, privacy: .public)")
        }
        for record in blackOut.offRecords {
            Log.displays.notice("off-record '\(record.name, privacy: .public)' uuid=\(record.uuid, privacy: .public) lastID=\(record.lastDisplayID) error=\(self.blackOut.errors[record.uuid] ?? "-", privacy: .public)")
        }
        Log.displays.notice("dump done: \(self.registry.displays.count) online, \(self.blackOut.offRecords.count) off")
    }
}
#endif
