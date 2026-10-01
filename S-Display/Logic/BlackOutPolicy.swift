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
    /// A real panel someone can look at. Empty display pipes and the placeholder macOS creates once the
    /// last display is gone report vendor 0 or a four-character code ('unkn', 'virt') that EDID's 16 bits can't hold.
    static func isViewable(vendor: UInt32) -> Bool {
        vendor != 0 && vendor <= 0xFFFF
    }

    /// Turning `target` off must leave at least one other viewable display.
    static func canTurnOff(_ target: UInt32, viewable: [UInt32]) -> Bool {
        viewable.contains { $0 != target }
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
