import CoreGraphics
import Foundation
import IOKit

struct DDCProbeResult: Sendable {
    let current: Double
    let maxValue: Int
}

/// Talks VESA DDC/CI (VCP 0x10 Luminance) to external monitors over Apple Silicon's `IOAVService` I2C bus.
/// All IOKit handles and I2C transfers stay on a single serial queue, with per-display write coalescing so
/// dragging a slider or holding the keyboard brightness keys never builds up a backlog of stale I2C writes.
final class DDCController: @unchecked Sendable {
    private struct Handle {
        let displayID: CGDirectDisplayID
        let avService: CFTypeRef
        let maxValue: Int
        var lastWritten: UInt16?
    }

    private struct PendingWrite {
        var normalized: Double
        var workItem: DispatchWorkItem
    }

    private let queue = DispatchQueue(label: "com.huyly.sdisplay.ddc", qos: .userInitiated)
    private var handles: [String: Handle] = [:]
    private var pendingWrites: [String: PendingWrite] = [:]

    /// Minimum interval between consecutive DDC brightness writes to the same monitor.
    private let writeInterval: TimeInterval = 0.045

    func probe(display: DisplayInfo) async -> DDCProbeResult? {
        guard !display.isBuiltin, PrivateAPI.canUseIOAVService else { return nil }
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard let avService = findAVService(for: display) else {
                    handles[display.uuid] = nil
                    continuation.resume(returning: nil)
                    return
                }
                guard let reading = readLuminance(from: avService, attempts: 3) else {
                    handles[display.uuid] = nil
                    continuation.resume(returning: nil)
                    return
                }
                handles[display.uuid] = Handle(
                    displayID: display.id,
                    avService: avService,
                    maxValue: reading.max,
                    lastWritten: UInt16(clamping: reading.current)
                )
                let normalized = DDCProtocol.normalizedValue(current: reading.current, max: reading.max)
                continuation.resume(returning: DDCProbeResult(current: normalized, maxValue: reading.max))
            }
        }
    }

    /// Reads the monitor's current hardware brightness (e.g. if changed from its physical OSD buttons).
    func readBrightness(for uuid: String) async -> Double? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard var handle = handles[uuid],
                      let reading = readLuminance(from: handle.avService, attempts: 2) else {
                    continuation.resume(returning: nil)
                    return
                }
                handle.lastWritten = UInt16(clamping: reading.current)
                handles[uuid] = handle
                continuation.resume(returning: DDCProtocol.normalizedValue(current: reading.current, max: reading.max))
            }
        }
    }

    /// Schedules a coalesced DDC write for `uuid`. Rapid updates replace the pending target value.
    func setBrightness(_ normalized: Double, for uuid: String) {
        let clamped = BrightnessSync.clamp(normalized)
        queue.async { [self] in
            if var existing = pendingWrites[uuid] {
                existing.normalized = clamped
                pendingWrites[uuid] = existing
                return
            }
            // Write immediately on the first change, then throttle follow-up changes to `writeInterval`.
            writeNow(clamped, for: uuid)
            scheduleDrain(for: uuid)
        }
    }

    func invalidate(uuid: String) {
        queue.async { [self] in
            pendingWrites.removeValue(forKey: uuid)?.workItem.cancel()
            handles[uuid] = nil
        }
    }

    func invalidateAll() {
        queue.async { [self] in
            for pending in pendingWrites.values { pending.workItem.cancel() }
            pendingWrites.removeAll()
            handles.removeAll()
        }
    }

    // MARK: - Serial queue internals

    private func scheduleDrain(for uuid: String) {
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let pending = self.pendingWrites.removeValue(forKey: uuid)
            if let pending, pending.normalized >= 0 {
                self.writeNow(pending.normalized, for: uuid)
                self.scheduleDrain(for: uuid)
            }
        }
        // Sentinel holds the throttle window open; overwritten if another update arrives during the window.
        pendingWrites[uuid] = PendingWrite(normalized: -1, workItem: item)
        queue.asyncAfter(deadline: .now() + writeInterval, execute: item)
    }

    private func writeNow(_ normalized: Double, for uuid: String) {
        guard normalized >= 0, var handle = handles[uuid] else { return }
        let target = DDCProtocol.ddcValue(for: normalized, max: handle.maxValue)
        guard handle.lastWritten != target else { return }

        var packet = DDCProtocol.setLuminancePacket(value: target)
        var status = PrivateAPI.writeI2C(
            handle.avService,
            chipAddress: DDCProtocol.chipAddress,
            dataAddress: DDCProtocol.dataAddress,
            bytes: &packet
        )
        if status != KERN_SUCCESS {
            usleep(15_000)
            status = PrivateAPI.writeI2C(
                handle.avService,
                chipAddress: DDCProtocol.chipAddress,
                dataAddress: DDCProtocol.dataAddress,
                bytes: &packet
            )
        }
        if status == KERN_SUCCESS {
            handle.lastWritten = target
            handles[uuid] = handle
        } else {
            Log.brightness.debug("DDC write failed for \(uuid, privacy: .public): 0x\(String(status, radix: 16))")
        }
    }

    private func readLuminance(from avService: CFTypeRef, attempts: Int) -> (current: Int, max: Int)? {
        for attempt in 0 ..< attempts {
            if attempt > 0 { usleep(25_000) }
            var request = DDCProtocol.getLuminancePacket()
            let wr = PrivateAPI.writeI2C(
                avService,
                chipAddress: DDCProtocol.chipAddress,
                dataAddress: DDCProtocol.dataAddress,
                bytes: &request
            )
            guard wr == KERN_SUCCESS else { continue }
            // VESA DDC/CI requires >= 40 ms between Get VCP Feature request and reading the reply.
            usleep(40_000)
            var reply = [UInt8](repeating: 0, count: 12)
            let rd = PrivateAPI.readI2C(
                avService,
                chipAddress: DDCProtocol.chipAddress,
                dataAddress: DDCProtocol.dataAddress,
                into: &reply
            )
            guard rd == KERN_SUCCESS else { continue }
            if let parsed = DDCProtocol.parseLuminanceReply(reply) {
                return parsed
            }
        }
        return nil
    }

    /// Finds the `IOAVService` for `display` by matching its IORegistry port token first (`dispext0`, etc.)
    /// so identical dual monitors still map uniquely, falling back to EDID vendor/product/serial over I2C.
    private func findAVService(for display: DisplayInfo) -> CFTypeRef? {
        let proxies = externalAVServices()
        guard !proxies.isEmpty else { return nil }

        if let location = display.ioDisplayLocation,
           let token = DDCProtocol.portToken(from: location),
           let exact = proxies.first(where: { DDCProtocol.servicePath($0.path, matchesPortToken: token) }) {
            return exact.avService
        }

        // Fallback: read 16-byte EDID header over I2C 0x50 and match vendor/product(/serial).
        var vendorProductFallback: CFTypeRef?
        for proxy in proxies {
            var header = [UInt8](repeating: 0, count: 16)
            guard PrivateAPI.readI2C(proxy.avService, chipAddress: 0x50, dataAddress: 0x00, into: &header) == KERN_SUCCESS,
                  let edid = DDCProtocol.parseEDIDIdentity(header),
                  edid.vendor == display.vendorID,
                  edid.product == display.productID
            else { continue }
            if display.serialNumber != 0, edid.serial == display.serialNumber {
                return proxy.avService
            }
            if vendorProductFallback == nil {
                vendorProductFallback = proxy.avService
            }
        }
        return vendorProductFallback
    }

    private func externalAVServices() -> [(path: String, avService: CFTypeRef)] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var results: [(path: String, avService: CFTypeRef)] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            if let location = IORegistryEntryCreateCFProperty(service, "Location" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
               location != "External" {
                continue
            }
            var pathBuffer = [CChar](repeating: 0, count: 1024)
            let path: String
            if IORegistryEntryGetPath(service, kIOServicePlane, &pathBuffer) == KERN_SUCCESS {
                let end = pathBuffer.firstIndex(of: 0) ?? pathBuffer.count
                path = String(decoding: pathBuffer[..<end].map(UInt8.init(bitPattern:)), as: UTF8.self)
            } else {
                path = ""
            }
            if let avService = PrivateAPI.createAVService(for: service) {
                results.append((path: path, avService: avService))
            }
        }
        return results
    }
}
