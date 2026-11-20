import CoreGraphics
import Foundation

/// Per-display gamma-table dimming for external displays that don't support DDC/CI.
/// Captures each display's baseline transfer table before dimming so returning to 100%
/// restores the original ColorSync profile without disturbing other displays.
@MainActor
final class SoftwareDimmer {
    private struct GammaTable {
        let red: [CGGammaValue]
        let green: [CGGammaValue]
        let blue: [CGGammaValue]
    }

    private var baselines: [CGDirectDisplayID: GammaTable] = [:]

    func apply(brightness normalized: Double, to displayID: CGDirectDisplayID) {
        let clamped = BrightnessSync.clamp(normalized)
        if clamped >= 0.999 {
            restore(displayID: displayID)
            return
        }

        let baseline = baselines[displayID] ?? captureBaseline(for: displayID)
        guard let baseline else {
            let gain = BrightnessSync.softwareGammaGain(for: clamped)
            CGSetDisplayTransferByFormula(displayID, 0, gain, 1, 0, gain, 1, 0, gain, 1)
            return
        }
        baselines[displayID] = baseline

        let gain = BrightnessSync.softwareGammaGain(for: clamped)
        let red = baseline.red.map { $0 * gain }
        let green = baseline.green.map { $0 * gain }
        let blue = baseline.blue.map { $0 * gain }
        CGSetDisplayTransferByTable(displayID, UInt32(red.count), red, green, blue)
    }

    func restore(displayID: CGDirectDisplayID) {
        guard let baseline = baselines.removeValue(forKey: displayID) else { return }
        CGSetDisplayTransferByTable(displayID, UInt32(baseline.red.count), baseline.red, baseline.green, baseline.blue)
    }

    func restoreAll() {
        for displayID in Array(baselines.keys) {
            restore(displayID: displayID)
        }
    }

    /// Discards cached baselines after sleep/wake so fresh post-wake ColorSync tables are captured.
    func resetBaselines() {
        baselines.removeAll()
    }

    private func captureBaseline(for displayID: CGDirectDisplayID) -> GammaTable? {
        let capacity = Int(CGDisplayGammaTableCapacity(displayID))
        guard capacity > 1 else { return nil }
        var red = [CGGammaValue](repeating: 0, count: capacity)
        var green = [CGGammaValue](repeating: 0, count: capacity)
        var blue = [CGGammaValue](repeating: 0, count: capacity)
        var sampleCount: UInt32 = 0
        let status = CGGetDisplayTransferByTable(displayID, UInt32(capacity), &red, &green, &blue, &sampleCount)
        guard status == .success, sampleCount > 1 else { return nil }
        let count = Int(sampleCount)
        return GammaTable(
            red: Array(red.prefix(count)),
            green: Array(green.prefix(count)),
            blue: Array(blue.prefix(count))
        )
    }
}

