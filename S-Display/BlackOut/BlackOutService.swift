import AppKit
import CoreGraphics
import Observation

/// Turns physical displays fully off and on with SkyLight's `SLSConfigureDisplayEnabled`, the way
/// Lunar's BlackOut and BetterDisplay's Disconnect work: the display leaves the layout, windows move to the
/// remaining displays, and the panel gets no signal. Changes use `.permanently`, so a display stays off
/// after S-Display quits; replugging its cable or restarting the Mac brings it back.
@MainActor
@Observable
final class BlackOutService {
    private(set) var offRecords: [OffDisplayRecord] = Preferences.offRecords
    /// UUIDs of displays with an operation in flight; reconcile leaves them alone.
    private(set) var busy: Set<String> = []
    private(set) var errors: [String: String] = [:]
    var keepOffAfterRestart = Preferences.keepOffAfterRestart {
        didSet { Preferences.keepOffAfterRestart = keepOffAfterRestart }
    }

    let isSupported = PrivateAPI.canToggleDisplays

    @ObservationIgnored private let registry: DisplayRegistry
    @ObservationIgnored private let launchedAt = Date()
    @ObservationIgnored private var wakeWindowEnds = Date.distantPast
    @ObservationIgnored private var rescueTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init(registry: DisplayRegistry) {
        self.registry = registry
    }

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.noteWake() }
            })
        }
        // Let the display set settle after login before deciding about remembered displays.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            await self?.recoverStrandedReconnects()
            self?.registry.refresh()
        }
    }

    func canTurnOff(_ display: DisplayInfo) -> Bool {
        BlackOutPolicy.canTurnOff(display.id, viewable: registry.displays.filter(\.isViewable).map(\.id))
    }

    // MARK: - Off / on

    func turnOff(_ display: DisplayInfo) async {
        let uuid = display.uuid
        guard !busy.contains(uuid) else { return }
        errors[uuid] = nil
        guard isSupported else { return fail(uuid, .unsupported) }
        guard canTurnOff(display) else { return fail(uuid, .lastDisplay) }
        busy.insert(uuid)
        defer { busy.remove(uuid) }

        let othersBefore = registry.displays.filter { $0.id != display.id }.compactMap { other in
            other.current.map { (id: other.id, mode: $0) }
        }
        // Written before the call: if S-Display dies mid-transaction, the next launch still offers Turn On.
        remember(OffDisplayRecord(
            uuid: uuid, lastDisplayID: display.id, name: display.name,
            vendorID: display.vendorID, productID: display.productID, turnedOffAt: .now
        ))
        Log.blackOut.info("turning off \(display.name, privacy: .public) (\(display.id))")
        let result = await DisplayConfigurator.shared.setEnabled(false, display: display.id, option: .permanently)
        let gone = await registry.waitUntil(timeout: .seconds(5)) { !$0.contains { $0.uuid == uuid } }
        guard gone else {
            forget(uuid)
            return fail(uuid, .didNotTurnOff(display.name, result))
        }
        Log.blackOut.info("\(display.name, privacy: .public) is off (result \(result.rawValue))")
        await restoreModes(othersBefore)
    }

    func turnOn(_ record: OffDisplayRecord) async {
        let uuid = record.uuid
        guard !busy.contains(uuid) else { return }
        errors[uuid] = nil
        busy.insert(uuid)
        defer { busy.remove(uuid) }

        let id = resolveID(for: record)
        Log.blackOut.info("turning on \(record.name, privacy: .public) (\(id))")
        let result = await DisplayConfigurator.shared.setEnabled(true, display: id, option: .permanently)
        if await registry.waitUntil(timeout: .seconds(8), { $0.contains { $0.uuid == uuid } }) {
            forget(uuid)
        } else {
            fail(uuid, .didNotComeBack(record.name, result))
        }
    }

    /// Turns on every display S-Display turned off, plus any other disabled display WindowServer still lists.
    func turnAllOn() async {
        let online = Set(DisplayEnumerator.onlineIDs())
        var targets: [(id: CGDirectDisplayID, uuid: String?)] = offRecords
            .filter { !busy.contains($0.uuid) }
            .map { (resolveID(for: $0), $0.uuid) }
        // Empty display pipes are listed too, with vendor 0; skip those. A built-in panel macOS turned off
        // itself (lid closed) is left alone unless S-Display turned it off (then it has a record above).
        for id in PrivateAPI.allDisplayIDs()
        where CGDisplayVendorNumber(id) != 0 && CGDisplayIsBuiltin(id) == 0 && !targets.contains(where: { $0.id == id }) {
            targets.append((id, DisplayEnumerator.uuid(of: id)))
        }
        targets.removeAll { online.contains($0.id) }

        let uuids = Set(targets.compactMap(\.uuid))
        busy.formUnion(uuids)
        // One transaction per display: a display that was unplugged fails its own commit without blocking the rest.
        for target in targets {
            let result = await DisplayConfigurator.shared.setEnabled(true, display: target.id, option: .permanently)
            Log.blackOut.info("turn all on: display \(target.id) result \(result.rawValue)")
        }
        if !targets.isEmpty {
            // A disabled display has no UUID until it is back, so match by ID as well.
            _ = await registry.waitUntil(timeout: .seconds(8)) { displays in
                targets.allSatisfy { target in
                    displays.contains { $0.id == target.id || $0.uuid == target.uuid }
                }
            }
        }
        busy.subtract(uuids)
        Preferences.pendingReconnects.removeAll { registry.display(uuid: $0.uuid) != nil }

        for record in offRecords where !busy.contains(record.uuid) {
            if registry.display(uuid: record.uuid) != nil {
                forget(record.uuid)
            } else {
                fail(record.uuid, .didNotComeBack(record.name, .failure))
            }
        }
    }

    /// Drops a record without touching the display, e.g. for a monitor that has been unplugged for good.
    func forget(_ uuid: String) {
        offRecords.removeAll { $0.uuid == uuid }
        errors[uuid] = nil
        Preferences.offRecords = offRecords
    }

    /// Off then on again, so macOS re-reads the display's override file and rebuilds its mode list.
    /// `.forAppOnly` would not help here: measured on macOS 27, a display disabled that way stays off
    /// after the process is killed. So a marker in UserDefaults covers the blink instead, and the next
    /// launch turns a stranded display back on.
    func softReconnect(_ display: DisplayInfo) async throws {
        guard isSupported else { throw SDisplayError.unsupported }
        guard canTurnOff(display) else { throw SDisplayError.needsAnotherDisplay }
        let uuid = display.uuid
        busy.insert(uuid)
        defer { busy.remove(uuid) }

        Log.blackOut.info("soft reconnect \(display.name, privacy: .public)")
        let record = await beginBlink(display)
        // Never re-issue the enable: doing it during the 2–4 s link handshake restarts the handshake.
        let result = await DisplayConfigurator.shared.setEnabled(true, display: resolveID(for: record), option: .permanently)
        guard await registry.waitUntil(timeout: .seconds(8), { $0.contains { $0.uuid == uuid } }) else {
            throw SDisplayError.didNotComeBack(display.name, result)
        }
        Preferences.pendingReconnects.removeAll { $0.uuid == uuid }
    }

    /// First half of a soft reconnect: leaves the marker, then turns the display off.
    func beginBlink(_ display: DisplayInfo) async -> OffDisplayRecord {
        let record = OffDisplayRecord(
            uuid: display.uuid, lastDisplayID: display.id, name: display.name,
            vendorID: display.vendorID, productID: display.productID, turnedOffAt: .now
        )
        Preferences.pendingReconnects = Preferences.pendingReconnects.filter { $0.uuid != record.uuid } + [record]
        _ = await DisplayConfigurator.shared.setEnabled(false, display: display.id, option: .permanently)
        _ = await registry.waitUntil(timeout: .seconds(5)) { !$0.contains { $0.uuid == record.uuid } }
        return record
    }

    /// Turns on displays a previous run left dark in the middle of a soft reconnect.
    private func recoverStrandedReconnects() async {
        for record in Preferences.pendingReconnects where registry.display(uuid: record.uuid) == nil {
            Log.blackOut.notice("\(record.name, privacy: .public) was left off mid-reconnect; turning it back on")
            let id = resolveID(for: record)
            _ = await DisplayConfigurator.shared.setEnabled(true, display: id, option: .permanently)
            _ = await registry.waitUntil(timeout: .seconds(8)) { $0.contains { $0.id == id || $0.uuid == record.uuid } }
        }
        Preferences.pendingReconnects = []
    }

    // MARK: - Keeping records true

    /// Called after every display refresh.
    func displaysChanged() {
        let now = Date()
        let reason: ReconcileReason = if now < wakeWindowEnds {
            .wake
        } else if now.timeIntervalSince(launchedAt) < 10 {
            .launch
        } else {
            .change
        }
        reconcile(reason)
        scheduleRescueIfNeeded()
    }

    private func reconcile(_ reason: ReconcileReason) {
        for record in offRecords where !busy.contains(record.uuid) {
            let display = registry.display(uuid: record.uuid)
            let action = BlackOutPolicy.reconcile(
                isOnline: display != nil,
                reason: reason,
                keepOffAfterRestart: keepOffAfterRestart,
                safeToTurnOff: display.map(canTurnOff) ?? false
            )
            switch action {
            case .keep:
                continue
            case .forget:
                Log.blackOut.info("\(record.name, privacy: .public) is on again; forgetting it")
                forget(record.uuid)
            case .turnOffAgain:
                guard let display else { continue }
                Log.blackOut.info("\(record.name, privacy: .public) came back after \(String(describing: reason)); turning it off again")
                Task { await self.turnOff(display) }
            }
        }
    }

    /// If nothing viewable is left (say the only lit display was unplugged), turn everything back on.
    private func scheduleRescueIfNeeded() {
        guard !offRecords.isEmpty, !registry.displays.contains(where: \.isViewable) else { return }
        rescueTask?.cancel()
        rescueTask = Task { [weak self] in
            // This process's copy of the display list can trail WindowServer's; look again before acting.
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self, !DisplayEnumerator.hasViewableDisplay() else { return }
            Log.blackOut.notice("no visible display left; turning everything back on")
            await self.turnAllOn()
        }
    }

    private func noteWake() {
        wakeWindowEnds = Date().addingTimeInterval(20)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            self?.registry.refresh()
        }
    }

    // MARK: - Helpers

    private func remember(_ record: OffDisplayRecord) {
        offRecords.removeAll { $0.uuid == record.uuid }
        offRecords.append(record)
        Preferences.offRecords = offRecords
    }

    /// Finds a (possibly disabled) display in SkyLight's list. A disabled display reports no UUID
    /// but keeps its vendor and model, so match by UUID, then last known ID, then vendor and model.
    private func resolveID(for record: OffDisplayRecord) -> CGDirectDisplayID {
        let ids = PrivateAPI.allDisplayIDs()
        if let id = ids.first(where: { DisplayEnumerator.uuid(of: $0) == record.uuid }) { return id }
        if ids.contains(record.lastDisplayID) { return record.lastDisplayID }
        let online = Set(DisplayEnumerator.onlineIDs())
        return ids.first {
            !online.contains($0) && CGDisplayVendorNumber($0) == record.vendorID && CGDisplayModelNumber($0) == record.productID
        } ?? record.lastDisplayID
    }

    /// macOS re-applies the arrangement it stored for the smaller display set, which can change the
    /// remaining displays' modes (Crisp issue #108); put back any that moved.
    private func restoreModes(_ before: [(id: CGDirectDisplayID, mode: RawMode)]) async {
        try? await Task.sleep(for: .milliseconds(500))
        for (id, mode) in before {
            guard let now = CGDisplayCopyDisplayMode(id).map(RawMode.init(cgMode:)), !now.hasSameShape(as: mode) else { continue }
            Log.blackOut.info("display \(id) moved to \(now.width)×\(now.height); restoring \(mode.width)×\(mode.height)")
            _ = await DisplayConfigurator.shared.apply(mode, to: id)
        }
    }

    private func fail(_ uuid: String, _ error: SDisplayError) {
        errors[uuid] = error.localizedDescription
        Log.blackOut.error("\(error.localizedDescription, privacy: .public)")
    }
}
