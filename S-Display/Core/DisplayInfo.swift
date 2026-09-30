import ColorSync
import CoreGraphics
import Foundation

/// Snapshot of one online display, rebuilt on every display reconfiguration.
struct DisplayInfo: Identifiable, Hashable, Sendable {
    let id: CGDirectDisplayID
    let uuid: String
    let name: String
    let vendorID: UInt32
    let productID: UInt32
    let isMain: Bool
    /// The display this one mirrors, or 0.
    let mirrorsDisplay: CGDirectDisplayID
    let physicalWidthMM: Double?
    let physicalHeightMM: Double?
    /// Diagonal reported by the display's EDID, which some monitors get wrong.
    let edidDiagonalInches: Double?
    /// True when the physical size comes from the user's choice rather than EDID.
    let hasCustomSize: Bool
    let nativeWidth: Int
    let nativeHeight: Int
    let current: RawMode?
    /// HiDPI sizes for the UI-size slider, largest text first.
    let stops: [ModeStop]

    var isViewable: Bool { BlackOutPolicy.isViewable(vendor: vendorID) }
    var isMirrorTarget: Bool { mirrorsDisplay != 0 }
    var currentStopIndex: Int? { ModeLadder.index(of: current, in: stops) }
    var recommendedStopIndex: Int? { ModeLadder.recommendedIndex(in: stops, physicalWidthMM: physicalWidthMM) }

    var pixelsPerInch: Int? {
        guard let physicalWidthMM, physicalWidthMM > 0, nativeWidth > 0 else { return nil }
        return Int((Double(nativeWidth) / (physicalWidthMM / 25.4)).rounded())
    }

    var diagonalInches: Double? {
        guard let physicalWidthMM, let physicalHeightMM else { return nil }
        return ScreenGeometry.diagonalInches(widthMM: physicalWidthMM, heightMM: physicalHeightMM)
    }
}

extension RawMode {
    init(cgMode mode: CGDisplayMode) {
        self.init(
            width: mode.width,
            height: mode.height,
            pixelWidth: mode.pixelWidth,
            pixelHeight: mode.pixelHeight,
            refreshRate: mode.refreshRate,
            usableForDesktop: mode.isUsableForDesktopGUI(),
            source: .coreGraphics(ioModeID: mode.ioDisplayModeID)
        )
    }
}

/// Reads displays and their modes. Thread-safe; used from the main actor and the configuration queue.
enum DisplayEnumerator {
    private static var modeOptions: CFDictionary {
        [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
    }

    static func onlineIDs() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    static func onlineDisplays() -> [DisplayInfo] {
        onlineIDs().map(info(for:))
    }

    /// Cheap check used by the blackout rescue, without building full snapshots.
    static func hasViewableDisplay() -> Bool {
        onlineIDs().contains { BlackOutPolicy.isViewable(vendor: CGDisplayVendorNumber($0)) }
    }

    static func uuid(of display: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    static func info(for display: CGDirectDisplayID) -> DisplayInfo {
        let info = PrivateAPI.displayInfo(display)
        let modes = modes(for: display)
        let current = CGDisplayCopyDisplayMode(display).map(RawMode.init(cgMode:))
        let native = ModeLadder.nativeSize(of: modes)
        let screenSize = CGDisplayScreenSize(display)

        func millimeters(_ key: String, fallback: Double) -> Double? {
            let value = (info[key] as? NSNumber)?.doubleValue ?? fallback
            return value > 0 ? value : nil
        }

        let uuid = uuid(of: display) ?? "display-\(display)"
        let nativeWidth = native?.width ?? current?.pixelWidth ?? 0
        let nativeHeight = native?.height ?? current?.pixelHeight ?? 0
        // EDID size; CGDisplayScreenSize is scaled by the current mode while mirroring.
        let edidWidth = millimeters("DisplayHorizontalImageSize", fallback: screenSize.width)
        let edidHeight = millimeters("DisplayVerticalImageSize", fallback: screenSize.height)
        let edidDiagonal = edidWidth.flatMap { width in edidHeight.map { ScreenGeometry.diagonalInches(widthMM: width, heightMM: $0) } }
        var physical = (width: edidWidth, height: edidHeight)
        let customDiagonal = Preferences.screenSizeOverrides[uuid]
        if let customDiagonal, nativeWidth > 0, nativeHeight > 0 {
            let size = ScreenGeometry.physicalSize(diagonalInches: customDiagonal, pixelWidth: nativeWidth, pixelHeight: nativeHeight)
            physical = (size.width, size.height)
        }

        return DisplayInfo(
            id: display,
            uuid: uuid,
            name: name(from: info) ?? "Display \(display)",
            vendorID: CGDisplayVendorNumber(display),
            productID: CGDisplayModelNumber(display),
            isMain: CGDisplayIsMain(display) != 0,
            mirrorsDisplay: CGDisplayMirrorsDisplay(display),
            physicalWidthMM: physical.width,
            physicalHeightMM: physical.height,
            edidDiagonalInches: edidDiagonal,
            hasCustomSize: customDiagonal != nil,
            nativeWidth: nativeWidth,
            nativeHeight: nativeHeight,
            current: current,
            stops: ModeLadder.stops(from: modes, preferredRefresh: current?.refreshRate)
        )
    }

    /// CoreGraphics modes plus the SkyLight-only ones CoreGraphics hides.
    static func modes(for display: CGDirectDisplayID) -> [RawMode] {
        let coreGraphics = ((CGDisplayCopyAllDisplayModes(display, modeOptions) as? [CGDisplayMode]) ?? [])
            .map(RawMode.init(cgMode:))
        let hidden = PrivateAPI.skyLightModes(for: display).filter { mode in
            !coreGraphics.contains { $0.hasSameShape(as: mode) && ($0.usableForDesktop || !mode.usableForDesktop) }
        }
        return coreGraphics + hidden
    }

    /// Finds the live `CGDisplayMode` for `mode` by shape; mode IDs get renumbered whenever the list is rebuilt.
    static func cgDisplayMode(matching mode: RawMode, on display: CGDirectDisplayID) -> CGDisplayMode? {
        let candidates = ((CGDisplayCopyAllDisplayModes(display, modeOptions) as? [CGDisplayMode]) ?? [])
            .filter { RawMode(cgMode: $0).hasSameShape(as: mode) }
        if case let .coreGraphics(ioModeID) = mode.source,
           let exact = candidates.first(where: { $0.ioDisplayModeID == ioModeID && $0.isUsableForDesktopGUI() }) {
            return exact
        }
        return candidates.first { $0.isUsableForDesktopGUI() } ?? candidates.first
    }

    private static func name(from info: [String: Any]) -> String? {
        guard let names = info["DisplayProductName"] as? [String: String], !names.isEmpty else { return nil }
        return names["en_US"] ?? names.values.sorted().first
    }
}
