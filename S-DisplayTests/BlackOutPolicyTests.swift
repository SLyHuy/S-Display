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

    @Test(arguments: [ReconcileReason.launch, .wake, .change])
    func displaysStillOffAreKept(reason: ReconcileReason) {
        #expect(BlackOutPolicy.reconcile(isOnline: false, reason: reason, keepOffAfterRestart: true, safeToTurnOff: true) == .keep)
    }

    @Test func wakeTurnsResurfacedDisplaysOffAgainWhenSafe() {
        #expect(BlackOutPolicy.reconcile(isOnline: true, reason: .wake, keepOffAfterRestart: false, safeToTurnOff: true) == .turnOffAgain)
        #expect(BlackOutPolicy.reconcile(isOnline: true, reason: .wake, keepOffAfterRestart: false, safeToTurnOff: false) == .forget)
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
