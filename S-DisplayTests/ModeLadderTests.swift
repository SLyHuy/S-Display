import Foundation
import Testing

struct ModeLadderTests {
    private func cg(_ w: Int, _ h: Int, scale: Int = 2, hz: Double = 60, usable: Bool = true, id: Int32 = 1) -> RawMode {
        RawMode(width: w, height: h, pixelWidth: w * scale, pixelHeight: h * scale, refreshRate: hz,
                usableForDesktop: usable, source: .coreGraphics(ioModeID: id))
    }

    private func sky(_ w: Int, _ h: Int, hz: Double = 60, usable: Bool = true, number: Int32 = 99) -> RawMode {
        RawMode(width: w, height: h, pixelWidth: w * 2, pixelHeight: h * 2, refreshRate: hz,
                usableForDesktop: usable, source: .skyLight(modeNumber: number))
    }

    /// Roughly what macOS 27 reports for the ROG PG279Q (1440p over HDMI).
    private var rogModes: [RawMode] {
        [
            cg(2560, 1440, scale: 1), cg(1920, 1080, scale: 1),
            cg(960, 540), cg(1024, 576), cg(1280, 720),
            cg(640, 360, usable: false),
            sky(1344, 756), sky(1600, 900), sky(1920, 1080), sky(2048, 1152),
            sky(2560, 1440, hz: 50), sky(2560, 1440, hz: 60),
        ]
    }

    @Test func nativeSizeIsLargest1xMode() {
        let native = ModeLadder.nativeSize(of: rogModes)
        #expect(native?.width == 2560 && native?.height == 1440)
    }

    @Test func stopsIncludeHiddenSkyLightSizesFromHalfToNative() {
        let stops = ModeLadder.stops(from: rogModes, preferredRefresh: 60)
        #expect(stops.map(\.width) == [1280, 1344, 1600, 1920, 2048, 2560])
        #expect(stops.last?.mode.refreshRate == 60)
        #expect(stops.allSatisfy { $0.mode.isHiDPI })
    }

    @Test func stopsSkipOtherAspectRatiosAndUnusableModes() {
        let modes = rogModes + [cg(1600, 1200), cg(2304, 1296, usable: false)]
        let stops = ModeLadder.stops(from: modes, preferredRefresh: 60)
        #expect(!stops.contains { $0.height == 1200 })
        #expect(!stops.contains { $0.width == 2304 })
    }

    @Test func refreshPrefersCurrentRateThenHighest() {
        let modes = [cg(3840, 2160, scale: 1, hz: 144), cg(1920, 1080, hz: 60, id: 1), cg(1920, 1080, hz: 144, id: 2)]
        #expect(ModeLadder.stops(from: modes, preferredRefresh: 60).first?.mode.refreshRate == 60)
        #expect(ModeLadder.stops(from: modes, preferredRefresh: nil).first?.mode.refreshRate == 144)
    }

    @Test func coreGraphicsWinsOverSkyLightAtSameRate() {
        let modes = [cg(2560, 1440, scale: 1), sky(1920, 1080), cg(1920, 1080)]
        let stop = ModeLadder.stops(from: modes, preferredRefresh: 60).first
        guard case .coreGraphics = stop?.mode.source else {
            Issue.record("expected the CoreGraphics mode")
            return
        }
    }

    @Test func higherRateSkyLightTwinBeatsLowRateCoreGraphicsMode() {
        let modes = [cg(3840, 2160, scale: 1, hz: 144), cg(1920, 1080, hz: 60), sky(1920, 1080, hz: 144)]
        let stop = ModeLadder.stops(from: modes, preferredRefresh: 144).first
        #expect(stop?.mode.refreshRate == 144)
    }

    @Test func currentIndexMatchesOnlyHiDPIModes() {
        let stops = ModeLadder.stops(from: rogModes, preferredRefresh: 60)
        #expect(ModeLadder.index(of: sky(1920, 1080), in: stops) == 3)
        #expect(ModeLadder.index(of: cg(2560, 1440, scale: 1), in: stops) == nil)
    }

    @Test func recommendedSizeTargets110PointsPerInch() {
        let stops = ModeLadder.stops(from: rogModes, preferredRefresh: 60)
        // 27" 16:9 is 600 mm wide: 600 / 25.4 × 110 ≈ 2598 → 2560.
        let index = ModeLadder.recommendedIndex(in: stops, physicalWidthMM: 600)
        #expect(index.map { stops[$0].width } == 2560)
        #expect(ModeLadder.recommendedIndex(in: stops, physicalWidthMM: nil) == nil)
    }

    @Test func textScaleIsRelativeToNative1x() {
        let stop = ModeStop(mode: cg(2304, 1296))
        #expect(ModeLadder.textScalePercent(of: stop, nativeWidth: 2560) == 111)
        #expect(ModeLadder.textScalePercent(of: ModeStop(mode: cg(1920, 1080)), nativeWidth: 3840) == 200)
    }
}
