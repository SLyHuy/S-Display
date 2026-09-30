import CoreGraphics
import Darwin
import Foundation

/// SkyLight / CoreDisplay SPI, resolved at runtime with dlsym so that a macOS release dropping
/// a symbol hides the matching feature instead of crashing S-Display at launch.
enum PrivateAPI {
    private typealias ConfigureEnabledFn = @convention(c) (CGDisplayConfigRef?, UInt32, Bool) -> Int32
    private typealias DisplayListFn = @convention(c) (UInt32, UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<UInt32>?) -> Int32
    private typealias ModeCountFn = @convention(c) (UInt32, UnsafeMutablePointer<Int32>?) -> Int32
    private typealias ModeDescriptionFn = @convention(c) (UInt32, Int32, UnsafeMutableRawPointer?, Int32) -> Int32
    private typealias ConfigureModeFn = @convention(c) (CGDisplayConfigRef?, UInt32, Int32) -> Int32
    private typealias InfoDictionaryFn = @convention(c) (UInt32) -> Unmanaged<CFDictionary>?

    private struct Symbols: @unchecked Sendable {
        let configureEnabled: ConfigureEnabledFn?
        let displayList: DisplayListFn?
        let modeCount: ModeCountFn?
        let modeDescription: ModeDescriptionFn?
        let configureMode: ConfigureModeFn?
        let infoDictionary: InfoDictionaryFn?

        init() {
            let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
            let coreGraphics = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY)
            let coreDisplay = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY)

            func load<T>(_ names: [String], from handles: [UnsafeMutableRawPointer?], as _: T.Type) -> T? {
                for name in names {
                    for handle in handles.compactMap({ $0 }) {
                        if let pointer = dlsym(handle, name) { return unsafeBitCast(pointer, to: T.self) }
                    }
                }
                return nil
            }

            configureEnabled = load(["SLSConfigureDisplayEnabled", "CGSConfigureDisplayEnabled"], from: [skyLight, coreGraphics], as: ConfigureEnabledFn.self)
            displayList = load(["SLSGetDisplayList", "CGSGetDisplayList"], from: [skyLight, coreGraphics], as: DisplayListFn.self)
            modeCount = load(["CGSGetNumberOfDisplayModes", "SLSGetNumberOfDisplayModes"], from: [coreGraphics, skyLight], as: ModeCountFn.self)
            modeDescription = load(["CGSGetDisplayModeDescriptionOfLength", "SLSGetDisplayModeDescriptionOfLength"], from: [coreGraphics, skyLight], as: ModeDescriptionFn.self)
            configureMode = load(["CGSConfigureDisplayMode", "SLSConfigureDisplayMode"], from: [coreGraphics, skyLight], as: ConfigureModeFn.self)
            infoDictionary = load(["CoreDisplay_DisplayCreateInfoDictionary"], from: [coreDisplay], as: InfoDictionaryFn.self)
        }
    }

    private static let symbols = Symbols()

    /// Turning displays off and on needs both the toggle and the list that still shows disabled displays.
    static var canToggleDisplays: Bool {
        symbols.configureEnabled != nil && symbols.displayList != nil
    }

    /// Adds "enable/disable this display" to an open configuration transaction.
    static func configureDisplayEnabled(_ config: CGDisplayConfigRef, _ display: CGDirectDisplayID, enabled: Bool) -> CGError {
        guard let configureEnabled = symbols.configureEnabled else { return .notImplemented }
        return CGError(rawValue: configureEnabled(config, display, enabled)) ?? .failure
    }

    /// Every display WindowServer knows about, including ones disabled with `configureDisplayEnabled`
    /// (which `CGGetOnlineDisplayList` leaves out) and empty display pipes (vendor 0).
    static func allDisplayIDs() -> [CGDirectDisplayID] {
        guard let displayList = symbols.displayList else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard displayList(UInt32(ids.count), &ids, &count) == 0 else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    /// SkyLight's mode list. It includes HiDPI modes CoreGraphics never returns, such as
    /// looks-like 2560×1440 on a 1440p panel.
    ///
    /// Reads the 212-byte `CGSDisplayModeDescription` by offset (layout from Crisp's bridging header, MIT):
    /// mode number @0, flags @4 (0x40000000 = unusable), width @8, height @12, refresh Hz @190 (UInt16),
    /// backing scale @208 (Float).
    static func skyLightModes(for display: CGDirectDisplayID) -> [RawMode] {
        guard let modeCount = symbols.modeCount, let modeDescription = symbols.modeDescription else { return [] }
        var count: Int32 = 0
        guard modeCount(display, &count) == 0, count > 0 else { return [] }

        let length = 212
        var buffer = [UInt8](repeating: 0, count: length)
        var modes: [RawMode] = []
        for index in 0 ..< count {
            let status = buffer.withUnsafeMutableBytes { modeDescription(display, index, $0.baseAddress, Int32(length)) }
            guard status == 0 else { continue }
            buffer.withUnsafeBytes { raw in
                let number = raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
                let flags = raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
                let width = Int(raw.loadUnaligned(fromByteOffset: 8, as: UInt32.self))
                let height = Int(raw.loadUnaligned(fromByteOffset: 12, as: UInt32.self))
                let refresh = Double(raw.loadUnaligned(fromByteOffset: 190, as: UInt16.self))
                let density = Double(raw.loadUnaligned(fromByteOffset: 208, as: Float.self))
                guard width > 0, height > 0, density >= 1 else { return }
                modes.append(RawMode(
                    width: width,
                    height: height,
                    pixelWidth: Int((Double(width) * density).rounded()),
                    pixelHeight: Int((Double(height) * density).rounded()),
                    refreshRate: refresh,
                    usableForDesktop: flags & 0x4000_0000 == 0,
                    source: .skyLight(modeNumber: Int32(bitPattern: number))
                ))
            }
        }
        return modes
    }

    /// Adds "switch to SkyLight mode `modeNumber`" to an open configuration transaction.
    /// The first argument must be the transaction token: passing a connection id crashes on macOS 26+.
    static func configureDisplayMode(_ config: CGDisplayConfigRef, _ display: CGDirectDisplayID, modeNumber: Int32) -> CGError {
        guard let configureMode = symbols.configureMode else { return .notImplemented }
        return CGError(rawValue: configureMode(config, display, modeNumber)) ?? .failure
    }

    /// CoreDisplay's info dictionary: EDID name, vendor/product, physical size in mm.
    static func displayInfo(_ display: CGDirectDisplayID) -> [String: Any] {
        (symbols.infoDictionary?(display)?.takeRetainedValue() as? [String: Any]) ?? [:]
    }
}
