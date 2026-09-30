#!/usr/bin/env swift
// Read-only display probe for S-Display. Changes nothing.
// Usage: swift scripts/probe-displays.swift [-v]
//   -v  also list every HiDPI mode macOS enumerates (CG + CGS)

import AppKit
import CoreGraphics
import Foundation

let verbose = CommandLine.arguments.contains("-v")

// MARK: - Private symbols (resolved at runtime, same as the app)

let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
let coreGraphics = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY)
let coreDisplay = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY)

func symbol(_ names: [String], in handles: [UnsafeMutableRawPointer?]) -> (String, UnsafeMutableRawPointer)? {
    for name in names {
        for handle in handles.compactMap({ $0 }) {
            if let pointer = dlsym(handle, name) { return (name, pointer) }
        }
    }
    return nil
}

typealias ListFn = @convention(c) (UInt32, UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<UInt32>?) -> Int32
typealias ModeCountFn = @convention(c) (UInt32, UnsafeMutablePointer<Int32>?) -> Int32
typealias ModeDescriptionFn = @convention(c) (UInt32, Int32, UnsafeMutableRawPointer?, Int32) -> Int32
typealias InfoFn = @convention(c) (UInt32) -> Unmanaged<CFDictionary>?

let checks: [(String, [String], [UnsafeMutableRawPointer?])] = [
    ("enable/disable", ["SLSConfigureDisplayEnabled", "CGSConfigureDisplayEnabled"], [skyLight, coreGraphics]),
    ("display list", ["SLSGetDisplayList", "CGSGetDisplayList"], [skyLight, coreGraphics]),
    ("mode count", ["CGSGetNumberOfDisplayModes"], [coreGraphics, skyLight]),
    ("mode description", ["CGSGetDisplayModeDescriptionOfLength"], [coreGraphics, skyLight]),
    ("configure mode", ["CGSConfigureDisplayMode"], [coreGraphics, skyLight]),
    ("display info", ["CoreDisplay_DisplayCreateInfoDictionary"], [coreDisplay]),
]
print("Private API")
for (label, names, handles) in checks {
    let found = symbol(names, in: handles)
    print("  \(found == nil ? "✗" : "✓") \(label.padding(toLength: 17, withPad: " ", startingAt: 0)) \(found?.0 ?? names.joined(separator: " / "))")
}

let listFn = symbol(["SLSGetDisplayList", "CGSGetDisplayList"], in: [skyLight, coreGraphics]).map { unsafeBitCast($0.1, to: ListFn.self) }
let modeCountFn = symbol(["CGSGetNumberOfDisplayModes"], in: [coreGraphics, skyLight]).map { unsafeBitCast($0.1, to: ModeCountFn.self) }
let modeDescriptionFn = symbol(["CGSGetDisplayModeDescriptionOfLength"], in: [coreGraphics, skyLight]).map { unsafeBitCast($0.1, to: ModeDescriptionFn.self) }
let infoFn = symbol(["CoreDisplay_DisplayCreateInfoDictionary"], in: [coreDisplay]).map { unsafeBitCast($0.1, to: InfoFn.self) }

// MARK: - Helpers

func onlineDisplays() -> [CGDirectDisplayID] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 32)
    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(32, &ids, &count) == .success else { return [] }
    return Array(ids.prefix(Int(count)))
}

func slsDisplays() -> [CGDirectDisplayID] {
    guard let listFn else { return [] }
    var ids = [CGDirectDisplayID](repeating: 0, count: 32)
    var count: UInt32 = 0
    guard listFn(32, &ids, &count) == 0 else { return [] }
    return Array(ids.prefix(Int(count)))
}

func info(_ id: CGDirectDisplayID) -> [String: Any] {
    (infoFn?(id)?.takeRetainedValue() as? [String: Any]) ?? [:]
}

func name(_ id: CGDirectDisplayID, _ info: [String: Any]) -> String {
    if let names = info["DisplayProductName"] as? [String: String] {
        return names["en_US"] ?? names.values.sorted().first ?? "Display \(id)"
    }
    return "Display \(id)"
}

func uuid(_ id: CGDirectDisplayID) -> String {
    guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return "-" }
    return CFUUIDCreateString(nil, uuid) as String
}

struct CGSMode {
    let number: UInt32, flags: UInt32, width: Int, height: Int, freq: Int, density: Float
    var usable: Bool { flags & 0x4000_0000 == 0 }
}

/// Layout of CGSDisplayModeDescription (212 bytes) per Crisp's bridging header (MIT).
func cgsModes(_ id: CGDirectDisplayID) -> [CGSMode] {
    guard let modeCountFn, let modeDescriptionFn else { return [] }
    var count: Int32 = 0
    guard modeCountFn(id, &count) == 0, count > 0 else { return [] }
    var modes: [CGSMode] = []
    var buffer = [UInt8](repeating: 0, count: 212)
    for index in 0 ..< count {
        let err = buffer.withUnsafeMutableBytes { modeDescriptionFn(id, index, $0.baseAddress, 212) }
        guard err == 0 else { continue }
        buffer.withUnsafeBytes { raw in
            modes.append(CGSMode(
                number: raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self),
                flags: raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self),
                width: Int(raw.loadUnaligned(fromByteOffset: 8, as: UInt32.self)),
                height: Int(raw.loadUnaligned(fromByteOffset: 12, as: UInt32.self)),
                freq: Int(raw.loadUnaligned(fromByteOffset: 190, as: UInt16.self)),
                density: raw.loadUnaligned(fromByteOffset: 208, as: Float.self)
            ))
        }
    }
    return modes
}

func overridePath(vendor: UInt32, product: UInt32) -> String {
    String(format: "/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-%x/DisplayProductID-%x", vendor, product)
}

func overrideEntries(_ path: String) -> [(Int, Int)]? {
    guard let data = FileManager.default.contents(atPath: path),
          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    else { return nil }
    let entries = (plist["scale-resolutions"] as? [Data]) ?? []
    return entries.compactMap { entry in
        guard entry.count >= 8 else { return nil }
        let bytes = [UInt8](entry)
        let w = Int(bytes[0]) << 24 | Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])
        let h = Int(bytes[4]) << 24 | Int(bytes[5]) << 16 | Int(bytes[6]) << 8 | Int(bytes[7])
        return (w, h)
    }
}

// MARK: - Report

let online = onlineDisplays()
let sls = slsDisplays()
print("\nCG online: \(online)   SLS list (includes disabled): \(sls)")
let disabled = sls.filter { !online.contains($0) && CGDisplayVendorNumber($0) != 0 }
if !disabled.isEmpty { print("Disabled (in SLS list, not online): \(disabled)") }

for id in online {
    let info = info(id)
    let vendor = CGDisplayVendorNumber(id), product = CGDisplayModelNumber(id)
    let mmW = (info["DisplayHorizontalImageSize"] as? Int) ?? Int(CGDisplayScreenSize(id).width)
    let mmH = (info["DisplayVerticalImageSize"] as? Int) ?? Int(CGDisplayScreenSize(id).height)
    let inches = sqrt(Double(mmW * mmW + mmH * mmH)) / 25.4
    print("\n[\(id)] \(name(id, info))  uuid=\(uuid(id))")
    print("    vendor=0x\(String(vendor, radix: 16)) product=0x\(String(product, radix: 16)) serial=\(CGDisplaySerialNumber(id)) main=\(CGDisplayIsMain(id) != 0) builtin=\(CGDisplayIsBuiltin(id) != 0) mirrorsDisplay=\(CGDisplayMirrorsDisplay(id)) inMirrorSet=\(CGDisplayIsInMirrorSet(id) != 0)")

    let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue!] as CFDictionary
    let modes = (CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode]) ?? []
    let native = modes.filter { $0.pixelWidth == $0.width }.max { $0.width * $0.height < $1.width * $1.height }
    let current = CGDisplayCopyDisplayMode(id)
    if let native, let current {
        let ppi = Double(native.pixelWidth) / (Double(mmW) / 25.4)
        print("    size \(mmW)×\(mmH) mm (\(String(format: "%.1f", inches))\")  native \(native.width)×\(native.height) (\(Int(ppi.rounded())) PPI)  max refresh \(Int(modes.map(\.refreshRate).max() ?? 0)) Hz")
        print("    current: looks like \(current.width)×\(current.height), \(current.pixelWidth)×\(current.pixelHeight) px @\(Int(current.refreshRate)) Hz \(current.pixelWidth > current.width ? "HiDPI" : "1x")")
    }

    let aspect = native.map { Double($0.width) / Double($0.height) } ?? 16.0 / 9.0
    let hiDPI = modes.filter {
        $0.pixelWidth == $0.width * 2 && $0.isUsableForDesktopGUI()
            && abs(Double($0.width) / Double($0.height) - aspect) < 0.01
    }
    let cgStops = Set(hiDPI.map { $0.width }).sorted()
    print("    HiDPI stops (CG, \(cgStops.count)): \(cgStops.map(String.init).joined(separator: " "))")

    let cgs = cgsModes(id)
    let cgsHiDPI = cgs.filter { $0.usable && $0.density >= 1.5 && abs(Double($0.width) / Double($0.height) - aspect) < 0.01 }
    let hidden = Set(cgsHiDPI.map(\.width)).subtracting(cgStops).sorted()
    print("    CGS modes: \(cgs.count), HiDPI: \(cgsHiDPI.count), hidden from CG: \(hidden.isEmpty ? "none" : hidden.map(String.init).joined(separator: " "))")
    if let current, let match = cgs.first(where: { $0.width == current.width && $0.height == current.height && $0.freq == Int(current.refreshRate.rounded()) && ($0.density >= 1.5) == (current.pixelWidth > current.width) }) {
        print("    CGS layout check: current mode found as #\(match.number) (\(match.width)×\(match.height) @\(match.freq) Hz, density \(match.density)) ✓")
    } else {
        print("    CGS layout check: current mode NOT found in CGS list ✗")
    }

    let path = overridePath(vendor: vendor, product: product)
    if let entries = overrideEntries(path) {
        print("    override: \(path)  (\(entries.count) scale-resolutions)")
    } else {
        print("    override: none (\(path))")
    }

    if verbose {
        for mode in hiDPI.sorted(by: { ($0.width, $0.refreshRate) < ($1.width, $1.refreshRate) }) {
            print("      CG  \(mode.width)×\(mode.height) px \(mode.pixelWidth)×\(mode.pixelHeight) @\(Int(mode.refreshRate)) id=\(mode.ioDisplayModeID)")
        }
        for mode in cgsHiDPI.sorted(by: { ($0.width, $0.freq) < ($1.width, $1.freq) }) {
            print("      CGS #\(mode.number) \(mode.width)×\(mode.height) @\(mode.freq) density \(mode.density)")
        }
    }
}
