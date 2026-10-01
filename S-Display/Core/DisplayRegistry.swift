import CoreGraphics
import Foundation
import Observation
import os

/// The online displays, kept current from WindowServer's reconfiguration callback.
/// It is also how operations confirm their effect: they wait for the display set to change
/// instead of trusting `CGCompleteDisplayConfiguration`'s result or polling.
@MainActor
@Observable
final class DisplayRegistry {
    private(set) var displays: [DisplayInfo] = []

    /// Called after every refresh, on the main actor.
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var waiters: [UUID: Waiter] = [:]

    private struct Waiter {
        let condition: ([DisplayInfo]) -> Bool
        let continuation: CheckedContinuation<Bool, Never>
    }

    func start() {
        activeRegistry = self
        CGDisplayRegisterReconfigurationCallback(displayReconfigured, nil)
        refresh()
    }

    func display(uuid: String) -> DisplayInfo? {
        displays.first { $0.uuid == uuid }
    }

    func refresh() {
        displays = DisplayEnumerator.onlineDisplays()
        for (key, waiter) in waiters where waiter.condition(displays) {
            waiters[key] = nil
            waiter.continuation.resume(returning: true)
        }
        onChange?()
    }

    /// Reconfiguration events come in bursts (one per display and flag); coalesce them.
    func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    /// Returns true as soon as `condition` holds for the display list, re-checked on every refresh,
    /// or false once `timeout` passes (after one last fresh look).
    func waitUntil(timeout: Duration, _ condition: @escaping ([DisplayInfo]) -> Bool) async -> Bool {
        if condition(displays) { return true }
        let key = UUID()
        return await withCheckedContinuation { continuation in
            waiters[key] = Waiter(condition: condition, continuation: continuation)
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard let self, let waiter = self.waiters.removeValue(forKey: key) else { return }
                self.displays = DisplayEnumerator.onlineDisplays()
                waiter.continuation.resume(returning: waiter.condition(self.displays))
            }
        }
    }
}

@MainActor private weak var activeRegistry: DisplayRegistry?

private func displayReconfigured(_ display: CGDirectDisplayID, _ flags: CGDisplayChangeSummaryFlags, _ userInfo: UnsafeMutableRawPointer?) {
    // Every change arrives twice: once before (beginConfiguration) and once after it lands.
    guard !flags.contains(.beginConfigurationFlag) else { return }
    Log.displays.debug("reconfigured display \(display) flags 0x\(String(flags.rawValue, radix: 16))")
    Task { @MainActor in activeRegistry?.scheduleRefresh() }
}

enum Log {
    static let displays = Logger(subsystem: "com.huyly.sdisplay", category: "displays")
    static let blackOut = Logger(subsystem: "com.huyly.sdisplay", category: "blackout")
    static let scaling = Logger(subsystem: "com.huyly.sdisplay", category: "scaling")
}
