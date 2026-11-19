import Foundation

/// A display S-Display turned off. Persisted because the display stays off after S-Display quits,
/// and a disabled display vanishes from the normal display lists.
struct OffDisplayRecord: Codable, Hashable, Sendable, Identifiable {
    let uuid: String
    var lastDisplayID: UInt32
    let name: String
    let vendorID: UInt32
    let productID: UInt32
    let turnedOffAt: Date

    var id: String { uuid }
}

enum ReconcileReason: Sendable {
    /// S-Display just launched: a remembered display that is lit again came back through a reboot or replug.
    case launch
    /// The Mac just woke: macOS may re-enable displays on its own.
    case wake
    /// Anything else, e.g. the user replugged the cable while S-Display was running.
    case change
}

enum ReconcileAction: Equatable, Sendable {
    case keep
    case forget
    case turnOffAgain
}

enum BlackOutPolicy {
    struct DisplayCandidate: Equatable, Sendable {
        let id: UInt32
        let isMain: Bool
        let isViewable: Bool
        let isMirrorTarget: Bool
        let isBusy: Bool
    }

    /// A real panel someone can look at. Empty display pipes and the placeholder macOS creates once the
    /// last display is gone report vendor 0 or a four-character code ('unkn', 'virt') that EDID's 16 bits can't hold.
    static func isViewable(vendor: UInt32) -> Bool {
        vendor != 0 && vendor <= 0xFFFF
    }

    /// Turning `target` off must leave at least one other viewable display not already in flight.
    static func canTurnOff(_ target: UInt32, viewable: [UInt32], busy: Set<UInt32> = []) -> Bool {
        viewable.contains { $0 != target && !busy.contains($0) }
    }

    /// When disabling the current main display, picks a remaining viewable display to move to origin (0, 0)
    /// in the same configuration transaction so WindowServer doesn't have to guess mid-teardown.
    static func replacementMain(turningOff target: UInt32, among displays: [DisplayCandidate]) -> UInt32? {
        guard displays.contains(where: { $0.id == target && $0.isMain }) else { return nil }
        return displays.first { $0.id != target && $0.isViewable && !$0.isMirrorTarget && !$0.isBusy }?.id
    }

    /// Chooses the reconciliation context for a display change, or `nil` while asleep or waiting for displays to settle.
    static func reconcileReason(
        now: Date,
        asleep: Bool,
        settleUntil: Date,
        wakeWindowEnds: Date,
        launchedAt: Date,
        launchWindow: TimeInterval = 10
    ) -> ReconcileReason? {
        guard !asleep, now >= settleUntil else { return nil }
        if now < wakeWindowEnds { return .wake }
        if now.timeIntervalSince(launchedAt) < launchWindow { return .launch }
        return .change
    }

    /// What to do with a remembered turned-off display after the display set changed.
    static func reconcile(isOnline: Bool, reason: ReconcileReason, keepOffAfterRestart: Bool, safeToTurnOff: Bool) -> ReconcileAction {
        guard isOnline else { return .keep }
        switch reason {
        case .wake:
            // Displays return one by one after a wake; if the others aren't back yet, wait for them.
            return safeToTurnOff ? .turnOffAgain : .keep
        case .launch:
            return keepOffAfterRestart && safeToTurnOff ? .turnOffAgain : .forget
        case .change:
            return .forget
        }
    }
}
