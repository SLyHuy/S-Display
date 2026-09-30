import Foundation

/// Display override files that add HiDPI modes, the way BetterDisplay's Flexible Scaling
/// and Crisp's Smooth Scaling do. Ladder and encoding adapted from Crisp's HiDPIService (MIT).
enum OverridePlist {
    static let directory = "/Library/Displays/Contents/Resources/Overrides"
    static let scaleResolutionsKey = "scale-resolutions"

    static func path(vendor: UInt32, product: UInt32) -> String {
        String(format: "%@/DisplayVendorID-%x/DisplayProductID-%x", directory, vendor, product)
    }

    /// Looks-like sizes from native width down to `minScale`×native in `step`-point steps
    /// (BetterDisplay's grid), height following the panel's aspect ratio. Native first.
    static func ladder(nativeWidth: Int, nativeHeight: Int, minScale: Double = 0.5, step: Int = 16) -> [(width: Int, height: Int)] {
        let minWidth = Int((Double(nativeWidth) * minScale).rounded())
        var sizes: [(width: Int, height: Int)] = []
        var width = nativeWidth
        while width >= minWidth {
            let height = Int((Double(width) * Double(nativeHeight) / Double(nativeWidth)).rounded())
            if width >= 800, height >= 600 { sizes.append((width, height)) }
            width -= step
        }
        return sizes
    }

    /// `scale-resolutions` entries for the ladder: each is the 2× backing size of one looks-like size.
    static func scaleResolutions(nativeWidth: Int, nativeHeight: Int) -> [Data] {
        ladder(nativeWidth: nativeWidth, nativeHeight: nativeHeight)
            .map { encode(backingWidth: $0.width * 2, backingHeight: $0.height * 2) }
    }

    /// 8 bytes: backing width then backing height, each a big-endian UInt32.
    static func encode(backingWidth: Int, backingHeight: Int) -> Data {
        var bytes = Data(capacity: 8)
        withUnsafeBytes(of: UInt32(backingWidth).bigEndian) { bytes.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(backingHeight).bigEndian) { bytes.append(contentsOf: $0) }
        return bytes
    }

    static func decode(_ entry: Data) -> (backingWidth: Int, backingHeight: Int)? {
        guard entry.count >= 8 else { return nil }
        let bytes = [UInt8](entry.prefix(8))
        let width = bytes[0 ..< 4].reduce(0) { $0 << 8 | Int($1) }
        let height = bytes[4 ..< 8].reduce(0) { $0 << 8 | Int($1) }
        return (width, height)
    }

    /// XML plist with `scale-resolutions` replaced; any other keys already in the file are kept.
    static func makePlist(merging existing: [String: Any]?, scaleResolutions: [Data]) throws -> Data {
        var plist = existing ?? [:]
        plist[scaleResolutionsKey] = scaleResolutions
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    static func read(_ data: Data) -> [String: Any]? {
        try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    static func scaleResolutions(in plist: [String: Any]?) -> [Data] {
        (plist?[scaleResolutionsKey] as? [Data]) ?? []
    }
}
