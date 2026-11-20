import Foundation
import Testing

struct BrightnessLogicTests {
    @Test func syncedBrightnessFollowsLeaderHarmoniouslyWithOffset() {
        // Calibrated +20% brighter on secondary display:
        let offset = BrightnessSync.calibratedOffset(follower: 0.70, leader: 0.50)
        #expect(abs(offset - 0.20) < 0.0001)

        // Pressing MacBook brightness up (+6.25%) or dragging main display moves secondary by the exact same +6.25%.
        let up = BrightnessSync.syncedBrightness(leader: 0.5625, offset: offset)
        #expect(abs(up - 0.7625) < 0.0001)

        // Moving leader down (-12.5%) moves secondary by the exact same -12.5%.
        let down = BrightnessSync.syncedBrightness(leader: 0.375, offset: offset)
        #expect(abs(down - 0.575) < 0.0001)
    }

    @Test func syncedBrightnessClampsAtBoundsWithoutLosingOffset() {
        let positive = 0.25
        #expect(BrightnessSync.syncedBrightness(leader: 0.90, offset: positive) == 1.0)
        #expect(abs(BrightnessSync.syncedBrightness(leader: 0.70, offset: positive) - 0.95) < 0.0001)

        let negative = -0.30
        #expect(BrightnessSync.syncedBrightness(leader: 0.20, offset: negative) == 0.0)
        #expect(abs(BrightnessSync.syncedBrightness(leader: 0.60, offset: negative) - 0.30) < 0.0001)
    }

    @Test func calibratedOffsetSnapsTinyResidualsToZero() {
        #expect(BrightnessSync.calibratedOffset(follower: 0.502, leader: 0.500) == 0)
        #expect(BrightnessSync.calibratedOffset(follower: 0.498, leader: 0.500) == 0)
        #expect(abs(BrightnessSync.calibratedOffset(follower: 0.35, leader: 0.50) - (-0.15)) < 0.0001)
    }

    @Test func leaderPrefersBuiltInThenMainThenFirstViewable() {
        let placeholder = BrightnessSync.DisplayCandidate(uuid: "virt", isBuiltin: false, isMain: true, isViewable: false)
        let builtin = BrightnessSync.DisplayCandidate(uuid: "macbook", isBuiltin: true, isMain: false, isViewable: true)
        let extMain = BrightnessSync.DisplayCandidate(uuid: "lg", isBuiltin: false, isMain: true, isViewable: true)
        let extSecond = BrightnessSync.DisplayCandidate(uuid: "rog", isBuiltin: false, isMain: false, isViewable: true)

        // Built-in wins even when an external display is macOS Main.
        #expect(BrightnessSync.leaderUUID(in: [placeholder, extMain, builtin, extSecond]) == "macbook")

        // Without built-in (clamshell / Mac mini / BlackOut), external Main becomes leader.
        #expect(BrightnessSync.leaderUUID(in: [placeholder, extSecond, extMain]) == "lg")

        // Without built-in or Main flag, falls back to first viewable display.
        #expect(BrightnessSync.leaderUUID(in: [placeholder, extSecond]) == "rog")
        #expect(BrightnessSync.leaderUUID(in: [placeholder]) == nil)
    }

    @Test func pairOffsetKeysIsolateDifferentLeaders() {
        let macToRog = BrightnessSync.offsetKey(leader: "macbook", follower: "rog")
        let lgToRog = BrightnessSync.offsetKey(leader: "lg", follower: "rog")
        #expect(macToRog != lgToRog)
    }

    @Test func offsetAndPercentFormatting() {
        #expect(BrightnessSync.percentLabel(0.754) == "75%")
        #expect(BrightnessSync.percentLabel(1.2) == "100%")
        #expect(BrightnessSync.percentLabel(-0.1) == "0%")

        #expect(BrightnessSync.offsetLabel(0.0) == nil)
        #expect(BrightnessSync.offsetLabel(0.004) == nil)
        #expect(BrightnessSync.offsetLabel(0.15) == "+15%")
        #expect(BrightnessSync.offsetLabel(-0.20) == "-20%")
    }

    @Test func softwareGammaNeverGoesPitchBlack() {
        #expect(abs(BrightnessSync.softwareGammaGain(for: 0.0) - BrightnessSync.softwareGammaFloor) < 0.0001)
        #expect(abs(BrightnessSync.softwareGammaGain(for: 1.0) - 1.0) < 0.0001)
        let mid = BrightnessSync.softwareGammaGain(for: 0.5)
        #expect(mid > BrightnessSync.softwareGammaFloor && mid < 1.0)
    }

    @Test func ddcPacketsHaveValidChecksums() {
        let get = DDCProtocol.getLuminancePacket()
        #expect(get == [0x82, 0x01, 0x10, 0xAC])

        // Set brightness to 75 (0x004B): 0x6E ^ 0x51 ^ 0x84 ^ 0x03 ^ 0x10 ^ 0x00 ^ 0x4B = 0xE3
        let set75 = DDCProtocol.setLuminancePacket(value: 75)
        #expect(set75 == [0x84, 0x03, 0x10, 0x00, 0x4B, 0xE3])
    }

    @Test func ddcLuminanceReplyParsesRealMonitorAndRejectsGarbage() {
        // Real reply captured from LG UltraFine (100 / 100):
        let lgReply: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x64, 0xA4, 0x00]
        let parsed = DDCProtocol.parseLuminanceReply(lgReply)
        #expect(parsed?.current == 100)
        #expect(parsed?.max == 100)

        // Bad checksum rejected:
        var badChecksum = lgReply
        badChecksum[10] ^= 0x01
        #expect(DDCProtocol.parseLuminanceReply(badChecksum) == nil)

        // Unsupported VCP result code (0x01) rejected:
        var unsupported = lgReply
        unsupported[3] = 0x01
        unsupported[10] ^= 0x01
        #expect(DDCProtocol.parseLuminanceReply(unsupported) == nil)

        // Garbage bytes from an empty/off pipe rejected:
        let garbage: [UInt8] = [0x6E, 0x3F, 0xA1, 0x3F, 0x00, 0x00, 0x00, 0x00, 0xAD, 0x3F, 0xE3, 0x85]
        #expect(DDCProtocol.parseLuminanceReply(garbage) == nil)
    }

    @Test func ddcValueRoundTrips() {
        #expect(DDCProtocol.ddcValue(for: 0.75, max: 100) == 75)
        #expect(DDCProtocol.ddcValue(for: 0.5, max: 255) == 128)
        #expect(abs(DDCProtocol.normalizedValue(current: 75, max: 100) - 0.75) < 0.0001)
    }

    @Test func portTokenExtractionAndMatching() {
        let loc0 = "IOService:/AppleARMPE/arm-io@10F00000/AppleSoCIO/dispext0@B0000000/IOMobileFramebufferShim"
        let token0 = DDCProtocol.portToken(from: loc0)
        #expect(token0 == "dispext0")

        let proxy0 = "IOService:/AppleARMPE/arm-io@10F00000/AppleSoCIO/dcpext0@B2E00000/AppleASCWrapV6/dispext0:dcpav-service-epic:0/DCPAVServiceProxy"
        let proxy1 = "IOService:/AppleARMPE/arm-io@10F00000/AppleSoCIO/dcpext1@92E00000/AppleASCWrapV6/dispext1:dcpav-service-epic:0/DCPAVServiceProxy"

        #expect(DDCProtocol.servicePath(proxy0, matchesPortToken: "dispext0"))
        #expect(!DDCProtocol.servicePath(proxy1, matchesPortToken: "dispext0"))
        #expect(DDCProtocol.servicePath(proxy1, matchesPortToken: "dispext1"))
        #expect(DDCProtocol.portToken(from: "IOService:/AppleARMPE/arm-io/disp0@1234/IOMFB") == "disp0")
    }

    @Test func edidIdentityParsing() {
        let lgHeader: [UInt8] = [0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x1E, 0x6D, 0xC1, 0x5B, 0x07, 0xFB, 0x07, 0x00]
        let id = DDCProtocol.parseEDIDIdentity(lgHeader)
        #expect(id?.vendor == 0x1E6D)
        #expect(id?.product == 0x5BC1)
        #expect(id?.serial == 523_015)

        let invalid: [UInt8] = [UInt8](repeating: 0, count: 16)
        #expect(DDCProtocol.parseEDIDIdentity(invalid) == nil)
    }
}

