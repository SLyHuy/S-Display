import Foundation
import Testing

struct BlackOutPolicyTests {
    @Test func placeholdersAndEmptyPipesAreNotViewable() {
        #expect(BlackOutPolicy.isViewable(vendor: 0x469))
        #expect(!BlackOutPolicy.isViewable(vendor: 0))
        #expect(!BlackOutPolicy.isViewable(vendor: 0x7669_7274)) // 'virt'
        #expect(!BlackOutPolicy.isViewable(vendor: 0x756E_6B6E)) // 'unkn'
    }

    @Test func neverTurnsOffTheLastViewableDisplay() {
        #expect(BlackOutPolicy.canTurnOff(4, viewable: [1, 4]))
        #expect(!BlackOutPolicy.canTurnOff(1, viewable: [1]))
        #expect(!BlackOutPolicy.canTurnOff(1, viewable: []))
    }

    @Test func busyDisplaysDoNotCountAsRemainingViewable() {
        // Display 1 is already turning off, so turning off 4 would leave nothing lit.
        #expect(!BlackOutPolicy.canTurnOff(4, viewable: [1, 4], busy: [1]))
        // Target itself being marked busy doesn't block it if another display is still free.
        #expect(BlackOutPolicy.canTurnOff(4, viewable: [1, 4], busy: [4]))
        // With a third display free, turning off 4 is still safe while 1 is busy.
        #expect(BlackOutPolicy.canTurnOff(4, viewable: [1, 2, 4], busy: [1]))
        #expect(!BlackOutPolicy.canTurnOff(4, viewable: [1, 2, 4], busy: [1, 2]))
    }

    @Test func replacementMainOnlyChosenWhenTurningOffMain() {
        let main = BlackOutPolicy.DisplayCandidate(id: 2, isMain: true, isViewable: true, isMirrorTarget: false, isBusy: false)
        let secondary = BlackOutPolicy.DisplayCandidate(id: 4, isMain: false, isViewable: true, isMirrorTarget: false, isBusy: false)
        #expect(BlackOutPolicy.replacementMain(turningOff: 4, among: [main, secondary]) == nil)
        #expect(BlackOutPolicy.replacementMain(turningOff: 2, among: [main, secondary]) == 4)
    }

    @Test func replacementMainSkipsUnviewableMirrorAndBusyDisplays() {
        let main = BlackOutPolicy.DisplayCandidate(id: 1, isMain: true, isViewable: true, isMirrorTarget: false, isBusy: true)
        let placeholder = BlackOutPolicy.DisplayCandidate(id: 2, isMain: false, isViewable: false, isMirrorTarget: false, isBusy: false)
        let mirror = BlackOutPolicy.DisplayCandidate(id: 3, isMain: false, isViewable: true, isMirrorTarget: true, isBusy: false)
        let busyOther = BlackOutPolicy.DisplayCandidate(id: 4, isMain: false, isViewable: true, isMirrorTarget: false, isBusy: true)
        let valid = BlackOutPolicy.DisplayCandidate(id: 5, isMain: false, isViewable: true, isMirrorTarget: false, isBusy: false)

        #expect(BlackOutPolicy.replacementMain(turningOff: 1, among: [main, placeholder, mirror, busyOther, valid]) == 5)
        #expect(BlackOutPolicy.replacementMain(turningOff: 1, among: [main, placeholder, mirror, busyOther]) == nil)
    }

    @Test func reconcileReasonPausesWhileAsleepOrSettling() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        // Asleep: never reconcile regardless of windows.
        #expect(BlackOutPolicy.reconcileReason(
            now: t0.addingTimeInterval(5),
            asleep: true,
            settleUntil: .distantPast,
            wakeWindowEnds: .distantPast,
            launchedAt: t0
        ) == nil)
        // Launch settle window (first 2s): hold off reconciliation.
        #expect(BlackOutPolicy.reconcileReason(
            now: t0.addingTimeInterval(1),
            asleep: false,
            settleUntil: t0.addingTimeInterval(2),
            wakeWindowEnds: .distantPast,
            launchedAt: t0
        ) == nil)
        // After launch settle, inside 10s launch window.
        #expect(BlackOutPolicy.reconcileReason(
            now: t0.addingTimeInterval(2),
            asleep: false,
            settleUntil: t0.addingTimeInterval(2),
            wakeWindowEnds: .distantPast,
            launchedAt: t0
        ) == .launch)
        // Wake settle window: hold off even though inside wake window.
        #expect(BlackOutPolicy.reconcileReason(
            now: t0.addingTimeInterval(101),
            asleep: false,
            settleUntil: t0.addingTimeInterval(103),
            wakeWindowEnds: t0.addingTimeInterval(130),
            launchedAt: t0
        ) == nil)
        // After wake settle, inside wake window.
        #expect(BlackOutPolicy.reconcileReason(
            now: t0.addingTimeInterval(103),
            asleep: false,
            settleUntil: t0.addingTimeInterval(103),
            wakeWindowEnds: t0.addingTimeInterval(130),
            launchedAt: t0
        ) == .wake)
        // Normal operation after both windows.
        #expect(BlackOutPolicy.reconcileReason(
            now: t0.addingTimeInterval(131),
            asleep: false,
            settleUntil: .distantPast,
            wakeWindowEnds: t0.addingTimeInterval(130),
            launchedAt: t0
        ) == .change)
    }

    @Test(arguments: [ReconcileReason.launch, .wake, .change])
    func displaysStillOffAreKept(reason: ReconcileReason) {
        #expect(BlackOutPolicy.reconcile(isOnline: false, reason: reason, keepOffAfterRestart: true, safeToTurnOff: true) == .keep)
    }

    @Test func wakeTurnsResurfacedDisplaysOffAgainWhenSafe() {
        #expect(BlackOutPolicy.reconcile(isOnline: true, reason: .wake, keepOffAfterRestart: false, safeToTurnOff: true) == .turnOffAgain)
        #expect(BlackOutPolicy.reconcile(isOnline: true, reason: .wake, keepOffAfterRestart: false, safeToTurnOff: false) == .keep)
    }

    @Test func launchHonoursKeepOffAfterRestart() {
        #expect(BlackOutPolicy.reconcile(isOnline: true, reason: .launch, keepOffAfterRestart: true, safeToTurnOff: true) == .turnOffAgain)
        #expect(BlackOutPolicy.reconcile(isOnline: true, reason: .launch, keepOffAfterRestart: false, safeToTurnOff: true) == .forget)
        #expect(BlackOutPolicy.reconcile(isOnline: true, reason: .launch, keepOffAfterRestart: true, safeToTurnOff: false) == .forget)
    }

    @Test func replugWhileRunningForgetsTheRecord() {
        #expect(BlackOutPolicy.reconcile(isOnline: true, reason: .change, keepOffAfterRestart: true, safeToTurnOff: true) == .forget)
    }

    @Test func recordsSurviveEncoding() throws {
        let record = OffDisplayRecord(uuid: "9A912210", lastDisplayID: 4, name: "ROG PG279Q",
                                      vendorID: 0x469, productID: 0x27EC, turnedOffAt: Date(timeIntervalSince1970: 1))
        let decoded = try JSONDecoder().decode([OffDisplayRecord].self, from: JSONEncoder().encode([record]))
        #expect(decoded == [record])
    }
}
