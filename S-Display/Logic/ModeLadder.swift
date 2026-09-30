import Foundation

/// One display mode reduced to plain values, from CoreGraphics (`CGDisplayMode`) or,
/// for modes CoreGraphics hides, from SkyLight's private mode list.
struct RawMode: Hashable, Sendable {
    enum Source: Hashable, Sendable {
        case coreGraphics(ioModeID: Int32)
        case skyLight(modeNumber: Int32)
    }

    /// Logical ("looks like") size in points.
    let width: Int
    let height: Int
    /// Backing framebuffer size in pixels.
    let pixelWidth: Int
    let pixelHeight: Int
    let refreshRate: Double
    let usableForDesktop: Bool
    let source: Source

    var isHiDPI: Bool { pixelWidth == width * 2 && pixelHeight == height * 2 }
    var is1x: Bool { pixelWidth == width && pixelHeight == height }

    /// Same geometry and refresh rate, whatever list the mode came from.
    func hasSameShape(as other: RawMode) -> Bool {
        width == other.width && height == other.height
            && pixelWidth == other.pixelWidth && pixelHeight == other.pixelHeight
            && abs(refreshRate - other.refreshRate) < 0.5
    }
}

/// One position of the UI-size slider: a HiDPI "looks like" size at the best refresh rate on offer.
struct ModeStop: Hashable, Sendable, Identifiable {
    let mode: RawMode

    var width: Int { mode.width }
    var height: Int { mode.height }
    var id: String { "\(width)x\(height)" }
}

enum ModeLadder {
    /// Largest 1x mode, i.e. the panel's native resolution (not whatever mode is current).
    static func nativeSize(of modes: [RawMode]) -> (width: Int, height: Int)? {
        modes.filter(\.is1x)
            .max { $0.width * $0.height < $1.width * $1.height }
            .map { ($0.width, $0.height) }
    }

    /// HiDPI stops with the panel's aspect ratio, from `minScale`×native up to native looks-like width,
    /// one per size, sorted from the largest text (smallest looks-like size) to the most space.
    /// Per size the refresh rate prefers `preferredRefresh`, then the highest, and CoreGraphics
    /// modes win over SkyLight-only twins at the same rate.
    static func stops(from modes: [RawMode], preferredRefresh: Double?, minScale: Double = 0.5) -> [ModeStop] {
        guard let native = nativeSize(of: modes) else { return [] }
        let aspect = Double(native.width) / Double(native.height)
        let minWidth = Int((Double(native.width) * minScale).rounded())

        var best: [String: RawMode] = [:]
        for mode in modes where mode.isHiDPI && mode.usableForDesktop {
            guard mode.width >= minWidth, mode.width <= native.width,
                  abs(Double(mode.width) / Double(mode.height) - aspect) < 0.01 else { continue }
            let key = "\(mode.width)x\(mode.height)"
            if let current = best[key], !isBetter(mode, than: current, preferredRefresh: preferredRefresh) { continue }
            best[key] = mode
        }
        return best.values
            .sorted { ($0.width, $0.height) < ($1.width, $1.height) }
            .map(ModeStop.init(mode:))
    }

    /// Index of the stop showing the current mode (same looks-like size, HiDPI).
    static func index(of current: RawMode?, in stops: [ModeStop]) -> Int? {
        guard let current, current.isHiDPI else { return nil }
        return stops.firstIndex { $0.width == current.width && $0.height == current.height }
    }

    /// Stop nearest to ~110 points per inch, the density macOS itself aims for on external displays
    /// (a 27" 16:9 panel lands on looks-like 2560×1440).
    static func recommendedIndex(in stops: [ModeStop], physicalWidthMM: Double?) -> Int? {
        guard let physicalWidthMM, physicalWidthMM > 0, !stops.isEmpty else { return nil }
        let target = physicalWidthMM / 25.4 * 110
        return stops.indices.min { abs(Double(stops[$0].width) - target) < abs(Double(stops[$1].width) - target) }
    }

    /// Text size relative to the panel's native 1x mode, in percent.
    static func textScalePercent(of stop: ModeStop, nativeWidth: Int) -> Int {
        Int((Double(nativeWidth) / Double(stop.width) * 100).rounded())
    }

    private static func isBetter(_ candidate: RawMode, than current: RawMode, preferredRefresh: Double?) -> Bool {
        if let preferredRefresh {
            let candidatePreferred = abs(candidate.refreshRate - preferredRefresh) < 0.5
            let currentPreferred = abs(current.refreshRate - preferredRefresh) < 0.5
            if candidatePreferred != currentPreferred { return candidatePreferred }
        }
        if abs(candidate.refreshRate - current.refreshRate) >= 0.5 {
            return candidate.refreshRate > current.refreshRate
        }
        if case .coreGraphics = candidate.source, case .skyLight = current.source { return true }
        return false
    }
}
