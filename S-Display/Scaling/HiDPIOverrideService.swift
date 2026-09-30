import CoreGraphics
import Foundation
import Observation

/// Flexible HiDPI: installs a display override file listing a dense ladder of HiDPI sizes
/// (every 16 points from native down to half), then soft-reconnects the display so macOS loads them.
/// Same approach as BetterDisplay's Flexible Scaling and Crisp's Smooth Scaling.
@MainActor
@Observable
final class HiDPIOverrideService {
    private(set) var busy: Set<String> = []
    private(set) var errors: [String: String] = [:]
    /// `scale-resolutions` entries in each display's override file, by display UUID (0 = no file).
    private(set) var installedEntries: [String: Int] = [:]

    @ObservationIgnored private let registry: DisplayRegistry
    @ObservationIgnored private let blackOut: BlackOutService
    @ObservationIgnored private let resolution: ResolutionService

    init(registry: DisplayRegistry, blackOut: BlackOutService, resolution: ResolutionService) {
        self.registry = registry
        self.blackOut = blackOut
        self.resolution = resolution
    }

    func isInstalled(_ display: DisplayInfo) -> Bool {
        (installedEntries[display.uuid] ?? 0) > 0
    }

    func ladderCount(for display: DisplayInfo) -> Int {
        OverridePlist.ladder(nativeWidth: display.nativeWidth, nativeHeight: display.nativeHeight).count
    }

    /// Re-reads override files; reading /Library/Displays needs no privileges.
    func refresh(_ displays: [DisplayInfo]) {
        installedEntries = displays.reduce(into: [:]) { entries, display in
            let path = OverridePlist.path(vendor: display.vendorID, product: display.productID)
            let plist = FileManager.default.contents(atPath: path).flatMap(OverridePlist.read)
            entries[display.uuid] = OverridePlist.scaleResolutions(in: plist).count
        }
    }

    func install(for display: DisplayInfo) async {
        await run(display) {
            try self.writeOverride(for: display)
            try await self.reload(display, upgradeToHiDPI: true)
        }
    }

    func remove(for display: DisplayInfo) async {
        await run(display) {
            let path = OverridePlist.path(vendor: display.vendorID, product: display.productID)
            let backup = self.backupURL(for: display)
            if FileManager.default.fileExists(atPath: backup.path) {
                try Privileged.run("/usr/bin/install -m 644 \(Privileged.quote(backup.path)) \(Privileged.quote(path))")
                try? FileManager.default.removeItem(at: backup)
            } else {
                try Privileged.run("/bin/rm -f \(Privileged.quote(path))")
            }
            self.refresh(self.registry.displays)
            try await self.reload(display, upgradeToHiDPI: false)
        }
    }

    private func run(_ display: DisplayInfo, _ body: () async throws -> Void) async {
        let uuid = display.uuid
        guard !busy.contains(uuid) else { return }
        errors[uuid] = nil
        busy.insert(uuid)
        defer { busy.remove(uuid) }
        do {
            try await body()
        } catch SDisplayError.cancelled {
            Log.scaling.info("administrator prompt cancelled")
        } catch {
            errors[uuid] = error.localizedDescription
            Log.scaling.error("\(error.localizedDescription, privacy: .public)")
        }
        refresh(registry.displays)
    }

    /// Writes the override as root. Skips the write, and its password prompt, when the file already
    /// holds exactly this ladder. A file S-Display didn't write is backed up so Remove can put it back.
    private func writeOverride(for display: DisplayInfo) throws {
        guard display.nativeWidth > 0, display.nativeHeight > 0 else {
            throw SDisplayError.file("Couldn't read \(display.name)'s native resolution.")
        }
        let path = OverridePlist.path(vendor: display.vendorID, product: display.productID)
        let entries = OverridePlist.scaleResolutions(nativeWidth: display.nativeWidth, nativeHeight: display.nativeHeight)
        let existingData = FileManager.default.contents(atPath: path)
        let existing = existingData.flatMap(OverridePlist.read)
        if Set(OverridePlist.scaleResolutions(in: existing)) == Set(entries) {
            Log.scaling.info("override for \(display.name, privacy: .public) already installed")
            return
        }

        let backup = backupURL(for: display)
        if let existingData, !FileManager.default.fileExists(atPath: backup.path) {
            try FileManager.default.createDirectory(at: Preferences.overrideBackupDirectory, withIntermediateDirectories: true)
            try existingData.write(to: backup)
        }

        let temp = FileManager.default.temporaryDirectory.appending(path: "S-Display-override-\(UUID().uuidString).plist")
        try OverridePlist.makePlist(merging: existing, scaleResolutions: entries).write(to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }

        let directory = (path as NSString).deletingLastPathComponent
        Log.scaling.info("installing \(entries.count) HiDPI sizes at \(path, privacy: .public)")
        try Privileged.run("/bin/mkdir -p \(Privileged.quote(directory)) && /usr/bin/install -m 644 \(Privileged.quote(temp.path)) \(Privileged.quote(path))")
        refresh(registry.displays)
    }

    /// Soft-reconnects so macOS rebuilds the mode list, then returns the display to the size it showed.
    /// With `upgradeToHiDPI`, a 1x size moves to the HiDPI mode of the same size: same UI size, sharper text.
    private func reload(_ display: DisplayInfo, upgradeToHiDPI: Bool) async throws {
        let before = display.current
        try await blackOut.softReconnect(display)
        guard let before, let fresh = registry.display(uuid: display.uuid) else { return }

        var wanted = before
        if upgradeToHiDPI, let stop = fresh.stops.first(where: { $0.width == before.width && $0.height == before.height }) {
            wanted = stop.mode
        }
        guard let current = fresh.current, !current.hasSameShape(as: wanted) else { return }
        // Re-enumeration can land on macOS's default mode; only restore sizes that still exist.
        guard DisplayEnumerator.modes(for: fresh.id).contains(where: { $0.usableForDesktop && $0.hasSameShape(as: wanted) }) else { return }
        await resolution.apply(wanted, to: fresh)
    }

    private func backupURL(for display: DisplayInfo) -> URL {
        Preferences.overrideBackupDirectory.appending(
            path: String(format: "DisplayVendorID-%x-DisplayProductID-%x.plist", display.vendorID, display.productID)
        )
    }
}
