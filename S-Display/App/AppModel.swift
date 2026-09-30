import AppKit
import Carbon.HIToolbox
import Observation
import ServiceManagement

@MainActor
@Observable
final class AppModel {
    let registry = DisplayRegistry()
    let blackOut: BlackOutService
    let resolution: ResolutionService
    let hiDPI: HiDPIOverrideService

    private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    private(set) var launchAtLoginError: String?

    init() {
        blackOut = BlackOutService(registry: registry)
        resolution = ResolutionService(registry: registry)
        hiDPI = HiDPIOverrideService(registry: registry, blackOut: blackOut, resolution: resolution)
        registry.onChange = { [weak self] in self?.displaysChanged() }
        registry.start()
        blackOut.start()
        registerHotkeys()
        #if DEBUG
        DebugCommands.install(on: self)
        #endif
    }

    func isBusy(_ uuid: String) -> Bool {
        blackOut.busy.contains(uuid) || resolution.busy.contains(uuid) || hiDPI.busy.contains(uuid)
    }

    func error(for uuid: String) -> String? {
        hiDPI.errors[uuid] ?? resolution.errors[uuid] ?? blackOut.errors[uuid]
    }

    /// Overrides the display's diagonal (nil = use EDID). Drives PPI and the Recommended size.
    func setScreenSize(_ inches: Double?, for display: DisplayInfo) {
        var overrides = Preferences.screenSizeOverrides
        overrides[display.uuid] = inches
        Preferences.screenSizeOverrides = overrides
        registry.refresh()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = "Launch at login: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func turnOffDisplayUnderPointer() {
        let point = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }),
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let display = registry.displays.first(where: { $0.id == number.uint32Value }),
              blackOut.canTurnOff(display)
        else {
            NSSound.beep()
            return
        }
        Task { await blackOut.turnOff(display) }
    }

    /// Plain Quit leaves turned-off displays off (they come back with a replug, a restart or S-Display).
    func quit(turningDisplaysOn: Bool) {
        Task {
            if turningDisplaysOn { await blackOut.turnAllOn() }
            NSApp.terminate(nil)
        }
    }

    private func displaysChanged() {
        blackOut.displaysChanged()
        hiDPI.refresh(registry.displays)
    }

    private func registerHotkeys() {
        let modifiers = controlKey | optionKey | cmdKey
        HotkeyService.shared.register(keyCode: kVK_ANSI_0, modifiers: modifiers) { [weak self] in
            guard let self else { return }
            Task { await self.blackOut.turnAllOn() }
        }
        HotkeyService.shared.register(keyCode: kVK_ANSI_B, modifiers: modifiers) { [weak self] in
            self?.turnOffDisplayUnderPointer()
        }
    }
}
