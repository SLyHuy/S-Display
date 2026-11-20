import Foundation

/// How S-Display controls a display's brightness.
enum BrightnessMethod: String, Equatable, Hashable, Sendable {
    /// Apple DisplayServices (MacBook built-in panel, Apple Studio Display, Pro Display XDR).
    case native
    /// Hardware backlight over DDC/CI (VCP 0x10 Luminance via IOAVService I2C).
    case ddc
    /// CoreGraphics gamma-table dimming for external displays that don't respond to DDC/CI.
    case software

    var label: String {
        switch self {
        case .native: "Native"
        case .ddc: "DDC"
        case .software: "Software"
        }
    }
}

/// Pure math for harmonious brightness sync, leader selection, manual offset calibration, and safe software dimming.
enum BrightnessSync {
    struct DisplayCandidate: Equatable, Sendable {
        let uuid: String
        let isBuiltin: Bool
        let isMain: Bool
        let isViewable: Bool
    }

    /// Minimum gamma multiplier for software dimming so the panel never goes completely pitch black.
    static let softwareGammaFloor: Float = 0.15

    /// Picks the primary display that drives synced brightness for all other displays:
    /// built-in display first (since macOS keyboard brightness keys control it),
    /// otherwise the macOS Main display, otherwise the first viewable display.
    static func leaderUUID(in displays: [DisplayCandidate]) -> String? {
        let viewable = displays.filter(\.isViewable)
        if let builtin = viewable.first(where: \.isBuiltin) { return builtin.uuid }
        if let main = viewable.first(where: \.isMain) { return main.uuid }
        return viewable.first?.uuid
    }

    /// Storage key for a follower's offset relative to a specific leader display, so calibrating
    /// e.g. ROG against LG (clamshell) doesn't overwrite ROG's calibration against MacBook.
    static func offsetKey(leader: String, follower: String) -> String {
        "\(leader)->\(follower)"
    }

    static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    static func clampOffset(_ offset: Double) -> Double {
        min(max(offset, -1), 1)
    }

    /// Target follower brightness given the leader display's brightness and this monitor's saved offset.
    /// Moving leader by Δ moves follower by the same Δ (clamped to 0...1 while preserving the offset).
    static func syncedBrightness(leader: Double, offset: Double) -> Double {
        clamp(leader + offset)
    }

    /// Computes the new remembered offset when the user manually drags a secondary display's slider
    /// while sync is enabled. Small residuals (< 0.5%) snap cleanly to 0.
    static func calibratedOffset(follower: Double, leader: Double) -> Double {
        let raw = clampOffset(clamp(follower) - clamp(leader))
        return abs(raw) < 0.005 ? 0 : raw
    }

    /// Avoids spamming DDC writes for negligible floating-point jitter.
    static func shouldApply(current: Double?, target: Double, tolerance: Double = 0.005) -> Bool {
        guard let current else { return true }
        return abs(current - clamp(target)) >= tolerance
    }

    /// Maps normalized UI brightness [0, 1] to a safe CoreGraphics gamma gain [floor, 1].
    static func softwareGammaGain(for brightness: Double, floor: Float = softwareGammaFloor) -> Float {
        let clamped = Float(clamp(brightness))
        return floor + clamped * (1 - floor)
    }

    static func percentLabel(_ value: Double) -> String {
        "\(Int((clamp(value) * 100).rounded()))%"
    }

    /// Formats a non-zero calibrated offset like "+15%" or "-10%", or nil when effectively zero.
    static func offsetLabel(_ offset: Double) -> String? {
        let points = Int((clampOffset(offset) * 100).rounded())
        guard points != 0 else { return nil }
        return points > 0 ? "+\(points)%" : "\(points)%"
    }
}

/// VESA DDC/CI packet framing (VCP 0x10 Luminance) and Apple Silicon IORegistry port matching.
enum DDCProtocol {
    static let chipAddress: UInt32 = 0x37
    static let dataAddress: UInt32 = 0x51
    static let writeAddressByte: UInt8 = 0x6E // 0x37 << 1
    static let hostReceiveByte: UInt8 = 0x50
    static let luminanceVCP: UInt8 = 0x10

    /// DDC/CI "Get VCP Feature" request for Luminance (0x10).
    static func getLuminancePacket() -> [UInt8] {
        let payload: [UInt8] = [0x82, 0x01, luminanceVCP]
        return payload + [writeChecksum(for: payload)]
    }

    /// DDC/CI "Set VCP Feature" request for Luminance (0x10).
    static func setLuminancePacket(value: UInt16) -> [UInt8] {
        let hi = UInt8((value >> 8) & 0xFF)
        let lo = UInt8(value & 0xFF)
        let payload: [UInt8] = [0x84, 0x03, luminanceVCP, hi, lo]
        return payload + [writeChecksum(for: payload)]
    }

    /// Parses a 11+ byte DDC/CI "VCP Feature Reply" for Luminance (0x10).
    static func parseLuminanceReply(_ bytes: [UInt8]) -> (current: Int, max: Int)? {
        guard bytes.count >= 11 else { return nil }
        guard bytes[0] == writeAddressByte else { return nil }
        let length = Int(bytes[1] & 0x7F)
        guard length >= 8 else { return nil }
        guard bytes[2] == 0x02, bytes[3] == 0x00, bytes[4] == luminanceVCP else { return nil }

        let expectedChecksum = bytes[0 ..< 10].reduce(hostReceiveByte, ^)
        guard bytes[10] == expectedChecksum else { return nil }

        let maxValue = (Int(bytes[6]) << 8) | Int(bytes[7])
        let currentValue = (Int(bytes[8]) << 8) | Int(bytes[9])
        guard maxValue > 0, currentValue >= 0, currentValue <= maxValue else { return nil }
        return (current: currentValue, max: maxValue)
    }

    static func ddcValue(for normalized: Double, max: Int) -> UInt16 {
        guard max > 0 else { return 0 }
        let clamped = BrightnessSync.clamp(normalized)
        return UInt16((clamped * Double(max)).rounded())
    }

    static func normalizedValue(current: Int, max: Int) -> Double {
        guard max > 0 else { return 0 }
        return BrightnessSync.clamp(Double(current) / Double(max))
    }

    /// Extracts the Apple Silicon display controller token (e.g. "dispext0", "dispext1", "disp0")
    /// from CoreDisplay's `IODisplayLocation` path.
    static func portToken(from ioDisplayLocation: String) -> String? {
        for segment in ioDisplayLocation.split(separator: "/") {
            let base = segment.split(separator: "@", maxSplits: 1).first ?? segment
            if isDisplayPortToken(base) { return String(base) }
        }
        return nil
    }

    /// Checks whether a `DCPAVServiceProxy` IORegistry path corresponds to `portToken`
    /// (matching e.g. `dispext0:` / `/dispext0@` or its paired `dcpext0@` controller).
    static func servicePath(_ path: String, matchesPortToken portToken: String) -> Bool {
        let dcpToken = portToken.hasPrefix("disp")
            ? "dcp" + portToken.dropFirst(4)
            : nil
        for segment in path.split(separator: "/") {
            let head = segment.split(whereSeparator: { $0 == "@" || $0 == ":" }).first ?? segment
            if head == portToken { return true }
            if let dcpToken, head == dcpToken { return true }
        }
        return false
    }

    /// Parses EDID header bytes 0..<16 (read from I2C address 0x50) into vendor, product, and serial.
    static func parseEDIDIdentity(_ bytes: [UInt8]) -> (vendor: UInt32, product: UInt32, serial: UInt32)? {
        guard bytes.count >= 16 else { return nil }
        let header: [UInt8] = [0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00]
        guard Array(bytes[0 ..< 8]) == header else { return nil }
        let vendor = (UInt32(bytes[8]) << 8) | UInt32(bytes[9])
        let product = UInt32(bytes[10]) | (UInt32(bytes[11]) << 8)
        let serial = UInt32(bytes[12])
            | (UInt32(bytes[13]) << 8)
            | (UInt32(bytes[14]) << 16)
            | (UInt32(bytes[15]) << 24)
        return (vendor, product, serial)
    }

    private static func writeChecksum(for payload: [UInt8]) -> UInt8 {
        payload.reduce(writeAddressByte ^ UInt8(dataAddress), ^)
    }

    private static func isDisplayPortToken(_ token: Substring) -> Bool {
        guard token.hasPrefix("disp") else { return false }
        var rest = token.dropFirst(4)
        if rest.hasPrefix("ext") { rest = rest.dropFirst(3) }
        return !rest.isEmpty && rest.allSatisfy(\.isNumber)
    }
}

