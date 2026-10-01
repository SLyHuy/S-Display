import CoreGraphics
import Foundation

/// Runs display-configuration transactions one at a time, off the main thread.
///
/// `CGCompleteDisplayConfiguration` blocks until WindowServer has rebuilt the display layout
/// (usually 1–3 s, up to ~10 s while a monitor renegotiates its link), so on the main thread
/// the menu would hang. The serial queue also guarantees two changes never overlap.
final class DisplayConfigurator: Sendable {
    static let shared = DisplayConfigurator()

    private let queue = DispatchQueue(label: "com.huyly.sdisplay.display-configuration", qos: .userInitiated)

    /// Begins a transaction, lets `body` add changes, then completes it with `option`
    /// (or cancels it if `body` fails). The result is WindowServer's own report, which can be wrong
    /// in both directions for enable/disable, so callers confirm through `DisplayRegistry.waitUntil`.
    func perform(_ option: CGConfigureOption, _ body: @escaping @Sendable (CGDisplayConfigRef) -> CGError) async -> CGError {
        await withCheckedContinuation { continuation in
            queue.async {
                var config: CGDisplayConfigRef?
                let begin = CGBeginDisplayConfiguration(&config)
                guard begin == .success, let config else {
                    continuation.resume(returning: begin)
                    return
                }
                let result = body(config)
                guard result == .success else {
                    CGCancelDisplayConfiguration(config)
                    continuation.resume(returning: result)
                    return
                }
                continuation.resume(returning: CGCompleteDisplayConfiguration(config, option))
            }
        }
    }

    func setEnabled(_ enabled: Bool, display: CGDirectDisplayID, option: CGConfigureOption) async -> CGError {
        await perform(option) { config in
            PrivateAPI.configureDisplayEnabled(config, display, enabled: enabled)
        }
    }

    /// Switches `display` to `mode`: through CoreGraphics when it lists the mode, otherwise through SkyLight
    /// by mode number. Both are re-resolved by shape here, since mode IDs get renumbered whenever macOS
    /// rebuilds the list (reconnect, override change, sleep).
    func apply(_ mode: RawMode, to display: CGDirectDisplayID, option: CGConfigureOption = .permanently) async -> CGError {
        await perform(option) { config in
            if let cgMode = DisplayEnumerator.cgDisplayMode(matching: mode, on: display), cgMode.isUsableForDesktopGUI() {
                return CGConfigureDisplayWithDisplayMode(config, display, cgMode, nil)
            }
            let hidden = PrivateAPI.skyLightModes(for: display).first { $0.usableForDesktop && $0.hasSameShape(as: mode) }
            guard let hidden, case let .skyLight(modeNumber) = hidden.source else { return .illegalArgument }
            return PrivateAPI.configureDisplayMode(config, display, modeNumber: modeNumber)
        }
    }
}
