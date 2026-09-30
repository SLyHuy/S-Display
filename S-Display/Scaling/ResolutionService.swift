import CoreGraphics
import Observation

/// Switches a display's mode (the UI-size slider). Changes use `.permanently`, so macOS keeps the
/// chosen size like it does for System Settings, whether or not S-Display is running.
@MainActor
@Observable
final class ResolutionService {
    private(set) var busy: Set<String> = []
    private(set) var errors: [String: String] = [:]

    @ObservationIgnored private let registry: DisplayRegistry

    init(registry: DisplayRegistry) {
        self.registry = registry
    }

    func apply(_ stop: ModeStop, to display: DisplayInfo) async {
        await apply(stop.mode, to: display)
    }

    func apply(_ mode: RawMode, to display: DisplayInfo) async {
        let uuid = display.uuid
        guard !busy.contains(uuid) else { return }
        errors[uuid] = nil
        // A mirror's mode is driven by its source; setting it on the target hangs or fails.
        guard !display.isMirrorTarget else {
            errors[uuid] = "\(display.name) is mirroring another display; change the size there."
            return
        }
        busy.insert(uuid)
        defer { busy.remove(uuid) }

        let label = "\(mode.width)×\(mode.height)\(mode.isHiDPI ? " HiDPI" : "")"
        Log.scaling.info("\(display.name, privacy: .public): switching to \(label, privacy: .public) @\(mode.refreshRate) Hz")
        let result = await DisplayConfigurator.shared.apply(mode, to: display.id)
        let applied = await registry.waitUntil(timeout: .seconds(5)) { displays in
            guard let current = displays.first(where: { $0.uuid == uuid })?.current else { return false }
            return current.width == mode.width && current.height == mode.height && current.pixelWidth == mode.pixelWidth
        }
        if !applied {
            errors[uuid] = SDisplayError.modeNotApplied(label, result).localizedDescription
        }
    }
}
