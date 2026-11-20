import AppKit
import CoreGraphics
import Foundation
import Observation

/// Controls brightness for every display (Apple DisplayServices for built-in/Apple panels,
/// DDC/CI hardware backlight for external monitors, and CoreGraphics gamma fallback) and
/// optionally links secondary displays to the primary display (built-in if online, otherwise
/// the macOS Main display) while remembering each display pair's manual calibration offset.
@MainActor
@Observable
final class BrightnessService {
    /// Current normalized brightness (0...1), keyed by display UUID.
    private(set) var values: [String: Double] = [:]
    /// Active brightness backend per display UUID.
    private(set) var methods: [String: BrightnessMethod] = [:]
    /// Saved `follower - leader` offsets, keyed by `BrightnessSync.offsetKey(leader:follower:)`.
    private(set) var offsets: [String: Double] = Preferences.brightnessOffsets
    /// Display UUIDs currently probing DDC/CI.
    private(set) var probing: Set<String> = []
    private(set) var syncEnabled: Bool = Preferences.syncBrightnessWithBuiltIn

    private final class ObserverToken: Sendable {}

    @ObservationIgnored private let registry: DisplayRegistry
    @ObservationIgnored private let ddc = DDCController()
    @ObservationIgnored private let dimmer = SoftwareDimmer()
    @ObservationIgnored private let observerToken = ObserverToken()

    @ObservationIgnored private var probedDisplayIDs: [String: CGDirectDisplayID] = [:]
    @ObservationIgnored private var observedNativeLeaderID: CGDirectDisplayID?
    @ObservationIgnored private var lastLeaderValue: Double?
    @ObservationIgnored private var activeDragUUIDs: Set<String> = []
    @ObservationIgnored private var asleep = false
    @ObservationIgnored private var wakeTask: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var workspaceObservers: [NSObjectProtocol] = []

    init(registry: DisplayRegistry) {
        self.registry = registry
    }

    /// Primary display that drives synced brightness: built-in if online, else macOS Main, else first viewable.
    var syncLeader: DisplayInfo? {
        let viewable = registry.displays.filter(\.isViewable)
        let candidates = viewable.map {
            BrightnessSync.DisplayCandidate(
                uuid: $0.uuid,
                isBuiltin: $0.isBuiltin,
                isMain: $0.isMain,
                isViewable: $0.isViewable
            )
        }
        guard let leaderUUID = BrightnessSync.leaderUUID(in: candidates) else { return nil }
        return viewable.first { $0.uuid == leaderUUID }
    }

    var hasSyncFollowers: Bool {
        registry.displays.filter(\.isViewable).count >= 2
    }

    func isSyncLeader(_ display: DisplayInfo) -> Bool {
        syncLeader?.uuid == display.uuid
    }

    func start() {
        activeBrightnessService = self
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.noteSleep() }
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.noteWake() }
            })
        }
        displaysChanged()
    }

    func brightness(for display: DisplayInfo) -> Double? {
        values[display.uuid]
    }

    func method(for display: DisplayInfo) -> BrightnessMethod? {
        methods[display.uuid]
    }

    func offset(for display: DisplayInfo) -> Double {
        guard let leader = syncLeader, leader.uuid != display.uuid else { return 0 }
        let pairKey = BrightnessSync.offsetKey(leader: leader.uuid, follower: display.uuid)
        if let saved = offsets[pairKey] { return saved }
        // Legacy fallback for offsets stored by follower UUID before pair keys were introduced.
        if leader.isBuiltin, let legacy = offsets[display.uuid] { return legacy }
        return 0
    }

    /// Shows whether brightness controls can act on `display`.
    func isAvailable(for display: DisplayInfo) -> Bool {
        if methods[display.uuid] != nil || probing.contains(display.uuid) { return true }
        if display.isBuiltin { return PrivateAPI.canUseDisplayServices && PrivateAPI.canChangeBrightness(display.id) }
        return true
    }

    func setEditing(_ editing: Bool, for display: DisplayInfo) {
        if editing {
            activeDragUUIDs.insert(display.uuid)
        } else {
            activeDragUUIDs.remove(display.uuid)
            commitChanges(for: display)
        }
    }

    /// Applies a user-initiated brightness change from the slider or debug command.
    /// - Moving the sync leader moves all secondary displays harmoniously when sync is enabled.
    /// - Moving a secondary display adjusts only that display and remembers its offset from the leader.
    func setBrightness(_ value: Double, for display: DisplayInfo, persist: Bool = false) {
        let clamped = BrightnessSync.clamp(value)
        applyBrightness(clamped, to: display, updateCalibration: true, persist: persist)
    }

    func commitChanges(for display: DisplayInfo) {
        if !isSyncLeader(display), syncEnabled {
            Preferences.brightnessOffsets = offsets
        }
        if methods[display.uuid] == .software, let value = values[display.uuid] {
            saveSoftwareBrightness(value, for: display.uuid)
        }
    }

    /// Clears a secondary display's manual offset and snaps it back to the sync leader's brightness.
    func resetOffset(for display: DisplayInfo) {
        guard let leader = syncLeader, leader.uuid != display.uuid else { return }
        let pairKey = BrightnessSync.offsetKey(leader: leader.uuid, follower: display.uuid)
        offsets.removeValue(forKey: pairKey)
        if leader.isBuiltin { offsets.removeValue(forKey: display.uuid) }
        Preferences.brightnessOffsets = offsets
        if syncEnabled, let leaderValue = leaderBrightness(refreshFromHardware: true) {
            applyBrightness(leaderValue, to: display, updateCalibration: false, persist: true)
        }
    }

    func setSyncEnabled(_ enabled: Bool) {
        syncEnabled = enabled
        Preferences.syncBrightnessWithBuiltIn = enabled
        updateFallbackPolling()
        guard enabled, let leaderValue = leaderBrightness(refreshFromHardware: true) else { return }
        syncFollowers(toLeader: leaderValue)
    }

    /// Refreshes live hardware readings when the menu panel opens.
    func refreshVisibleValues() {
        let leaderUUID = syncLeader?.uuid
        for display in registry.displays where display.isViewable && !activeDragUUIDs.contains(display.uuid) {
            switch methods[display.uuid] {
            case .native:
                if let current = PrivateAPI.getBrightness(display.id) {
                    values[display.uuid] = current
                    if display.uuid == leaderUUID {
                        handleNativeLeaderObservation(current)
                    }
                }
            case .ddc:
                let uuid = display.uuid
                Task { [weak self] in
                    guard let self, let current = await self.ddc.readBrightness(for: uuid) else { return }
                    guard !self.activeDragUUIDs.contains(uuid), self.methods[uuid] == .ddc else { return }
                    self.values[uuid] = current
                    if uuid == self.syncLeader?.uuid {
                        self.handleObservedLeaderValue(current)
                    }
                }
            case .software, nil:
                break
            }
        }
    }

    /// Called whenever the online display list changes.
    func displaysChanged() {
        let viewable = registry.displays.filter(\.isViewable)
        let onlineUUIDs = Set(viewable.map(\.uuid))

        // Clean up displays that went offline (unplugged or turned off with BlackOut).
        for uuid in Array(probedDisplayIDs.keys) where !onlineUUIDs.contains(uuid) {
            if let oldID = probedDisplayIDs.removeValue(forKey: uuid) {
                dimmer.restore(displayID: oldID)
            }
            ddc.invalidate(uuid: uuid)
            methods[uuid] = nil
            values[uuid] = nil
            probing.remove(uuid)
        }

        updateNativeLeaderObserver()
        let leaderUUID = syncLeader?.uuid

        for display in viewable {
            let uuid = display.uuid
            if probedDisplayIDs[uuid] == display.id, methods[uuid] != nil {
                if methods[uuid] == .native, let current = PrivateAPI.getBrightness(display.id) {
                    values[uuid] = current
                    if uuid == leaderUUID { lastLeaderValue = current }
                }
                continue
            }

            if PrivateAPI.canUseDisplayServices, PrivateAPI.canChangeBrightness(display.id) {
                methods[uuid] = .native
                probedDisplayIDs[uuid] = display.id
                let current = PrivateAPI.getBrightness(display.id) ?? values[uuid] ?? 0.5
                values[uuid] = current
                if uuid == leaderUUID {
                    lastLeaderValue = current
                    if syncEnabled { syncFollowers(toLeader: current) }
                } else if syncEnabled, let leaderValue = leaderBrightness(refreshFromHardware: false) {
                    let target = BrightnessSync.syncedBrightness(leader: leaderValue, offset: offset(for: display))
                    if BrightnessSync.shouldApply(current: current, target: target) {
                        applyBrightness(target, to: display, updateCalibration: false, persist: false)
                    }
                }
                continue
            }

            // Never fall back to DDC or gamma on a built-in display.
            guard !display.isBuiltin else { continue }
            probeExternal(display)
        }

        updateFallbackPolling()
    }

    func restoreBeforeQuit() {
        unregisterNativeLeaderObserver()
        pollTask?.cancel()
        pollTask = nil
        wakeTask?.cancel()
        wakeTask = nil
        dimmer.restoreAll()
    }

    /// Entry point invoked by DisplayServices whenever macOS changes brightness on the native leader
    /// (keyboard brightness keys, Control Center, or Auto-Brightness).
    fileprivate func nativeLeaderBrightnessDidChange() {
        guard !asleep, let leader = syncLeader, methods[leader.uuid] == .native else { return }
        guard let current = PrivateAPI.getBrightness(leader.id) else { return }
        handleNativeLeaderObservation(current)
    }

    // MARK: - Internals

    private func leaderBrightness(refreshFromHardware: Bool) -> Double? {
        guard let leader = syncLeader else { return nil }
        if refreshFromHardware, methods[leader.uuid] == .native, let live = PrivateAPI.getBrightness(leader.id) {
            values[leader.uuid] = live
            lastLeaderValue = live
            return live
        }
        if let cached = values[leader.uuid] { return cached }
        if methods[leader.uuid] == .native { return PrivateAPI.getBrightness(leader.id) }
        return nil
    }

    private func handleNativeLeaderObservation(_ current: Double) {
        guard let leader = syncLeader else { return }
        if !activeDragUUIDs.contains(leader.uuid) {
            values[leader.uuid] = current
        }
        handleObservedLeaderValue(current)
    }

    private func handleObservedLeaderValue(_ current: Double) {
        // Ignore self-echo from our own DisplayServicesSetBrightness call (Float32 rounding).
        if let previous = lastLeaderValue, abs(current - previous) < 0.002 {
            return
        }
        lastLeaderValue = current
        guard syncEnabled else { return }
        syncFollowers(toLeader: current)
    }

    private func syncFollowers(toLeader leaderValue: Double) {
        guard let leader = syncLeader else { return }
        for display in registry.displays where display.isViewable && display.uuid != leader.uuid {
            guard !activeDragUUIDs.contains(display.uuid), methods[display.uuid] != nil else { continue }
            let target = BrightnessSync.syncedBrightness(leader: leaderValue, offset: offset(for: display))
            guard BrightnessSync.shouldApply(current: values[display.uuid], target: target) else { continue }
            applyBrightness(target, to: display, updateCalibration: false, persist: false)
        }
    }

    private func applyBrightness(
        _ clamped: Double,
        to display: DisplayInfo,
        updateCalibration: Bool,
        persist: Bool
    ) {
        let uuid = display.uuid
        values[uuid] = clamped

        switch methods[uuid] {
        case .native:
            PrivateAPI.setBrightness(display.id, value: clamped)
        case .ddc:
            ddc.setBrightness(clamped, for: uuid)
        case .software:
            dimmer.apply(brightness: clamped, to: display.id)
            if persist { saveSoftwareBrightness(clamped, for: uuid) }
        case nil:
            if PrivateAPI.canUseDisplayServices, PrivateAPI.canChangeBrightness(display.id) {
                methods[uuid] = .native
                PrivateAPI.setBrightness(display.id, value: clamped)
            } else if !display.isBuiltin {
                methods[uuid] = .software
                dimmer.apply(brightness: clamped, to: display.id)
                if persist { saveSoftwareBrightness(clamped, for: uuid) }
            }
        }

        if let leader = syncLeader {
            if uuid == leader.uuid {
                lastLeaderValue = clamped
                if syncEnabled {
                    syncFollowers(toLeader: clamped)
                }
            } else if updateCalibration, syncEnabled, let leaderValue = leaderBrightness(refreshFromHardware: true) {
                let pairKey = BrightnessSync.offsetKey(leader: leader.uuid, follower: uuid)
                let newOffset = BrightnessSync.calibratedOffset(follower: clamped, leader: leaderValue)
                if leader.isBuiltin { offsets.removeValue(forKey: uuid) }
                if newOffset == 0 {
                    offsets.removeValue(forKey: pairKey)
                } else {
                    offsets[pairKey] = newOffset
                }
                if persist {
                    Preferences.brightnessOffsets = offsets
                }
            }
        }
    }

    private func probeExternal(_ display: DisplayInfo) {
        let uuid = display.uuid
        guard !probing.contains(uuid) else { return }
        probing.insert(uuid)

        Task { [weak self] in
            guard let self else { return }
            let result = await self.ddc.probe(display: display)
            self.probing.remove(uuid)

            // Confirm the same display is still online before committing probe results.
            guard let fresh = self.registry.display(uuid: uuid), fresh.id == display.id else { return }
            self.probedDisplayIDs[uuid] = fresh.id

            if let result {
                self.methods[uuid] = .ddc
                self.values[uuid] = result.current
                Log.brightness.info("\(fresh.name, privacy: .public): DDC brightness \(Int((result.current * 100).rounded()))% (max \(result.maxValue))")
            } else {
                self.methods[uuid] = .software
                let saved = Preferences.softwareBrightness[uuid] ?? 1.0
                self.values[uuid] = saved
                self.dimmer.apply(brightness: saved, to: fresh.id)
                Log.brightness.info("\(fresh.name, privacy: .public): DDC unavailable; using software dimming")
            }

            guard self.syncEnabled else { return }
            if self.isSyncLeader(fresh), let leaderValue = self.values[uuid] {
                self.lastLeaderValue = leaderValue
                self.syncFollowers(toLeader: leaderValue)
            } else if let leaderValue = self.leaderBrightness(refreshFromHardware: false) {
                let target = BrightnessSync.syncedBrightness(leader: leaderValue, offset: self.offset(for: fresh))
                if BrightnessSync.shouldApply(current: self.values[uuid], target: target) {
                    self.applyBrightness(target, to: fresh, updateCalibration: false, persist: false)
                }
            }
        }
    }

    private func updateNativeLeaderObserver() {
        let leader = syncLeader
        let desiredID: CGDirectDisplayID? = (leader != nil && PrivateAPI.canChangeBrightness(leader!.id)) ? leader!.id : nil
        guard desiredID != observedNativeLeaderID else { return }

        unregisterNativeLeaderObserver()
        guard let id = desiredID, PrivateAPI.canObserveBrightnessChanges else { return }
        let pointer = Unmanaged.passUnretained(observerToken).toOpaque()
        if PrivateAPI.registerBrightnessNotification(for: id, observer: pointer, callback: nativeLeaderBrightnessCallback) {
            observedNativeLeaderID = id
            Log.brightness.debug("registered DisplayServices brightness observer for leader display \(id)")
        }
    }

    private func unregisterNativeLeaderObserver() {
        guard let id = observedNativeLeaderID else { return }
        let pointer = Unmanaged.passUnretained(observerToken).toOpaque()
        PrivateAPI.unregisterBrightnessNotification(for: id, observer: pointer)
        observedNativeLeaderID = nil
    }

    /// Only runs if DisplayServices' push notification symbol is unavailable on a future macOS release
    /// while the sync leader is a native Apple display.
    private func updateFallbackPolling() {
        let leaderIsNative = syncLeader.map { PrivateAPI.canChangeBrightness($0.id) } ?? false
        let needsPoll = syncEnabled && leaderIsNative && observedNativeLeaderID == nil && PrivateAPI.canUseDisplayServices
        if !needsPoll {
            pollTask?.cancel()
            pollTask = nil
            return
        }
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled, let self else { return }
                self.nativeLeaderBrightnessDidChange()
            }
        }
    }

    private func noteSleep() {
        asleep = true
        wakeTask?.cancel()
        wakeTask = nil
    }

    private func noteWake() {
        asleep = false
        dimmer.resetBaselines()
        ddc.invalidateAll()
        probedDisplayIDs.removeAll()
        wakeTask?.cancel()
        // Monitors often take ~2 s after wake before their DDC I2C bus responds.
        wakeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, !self.asleep else { return }
            self.displaysChanged()
        }
    }

    private func saveSoftwareBrightness(_ value: Double, for uuid: String) {
        var saved = Preferences.softwareBrightness
        saved[uuid] = value
        Preferences.softwareBrightness = saved
    }
}

@MainActor private weak var activeBrightnessService: BrightnessService?

private func nativeLeaderBrightnessCallback(_ observer: UnsafeMutableRawPointer?, _ userInfo: UnsafeMutableRawPointer?) {
    Task { @MainActor in activeBrightnessService?.nativeLeaderBrightnessDidChange() }
}
