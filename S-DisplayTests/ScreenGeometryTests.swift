import Foundation
import Testing

struct ScreenGeometryTests {
    @Test func a27Inch4KPanelIs163PPI() {
        let size = ScreenGeometry.physicalSize(diagonalInches: 27, pixelWidth: 3840, pixelHeight: 2160)
        #expect(abs(size.width - 597.7) < 0.5)
        #expect(abs(size.height - 336.2) < 0.5)
        #expect(Int((3840 / (size.width / 25.4)).rounded()) == 163)
        #expect(abs(ScreenGeometry.diagonalInches(widthMM: size.width, heightMM: size.height) - 27) < 0.001)
    }

    @Test func parsesTypedDiagonals() {
        #expect(ScreenGeometry.parseDiagonal("27") == 27)
        #expect(ScreenGeometry.parseDiagonal(" 31,5 ") == 31.5)
        #expect(ScreenGeometry.parseDiagonal("27\"") == 27)
        #expect(ScreenGeometry.parseDiagonal("27 inch") == 27)
        #expect(ScreenGeometry.parseDiagonal("abc") == nil)
        #expect(ScreenGeometry.parseDiagonal("5") == nil)
    }

    @Test func labelsDropTrailingZero() {
        #expect(ScreenGeometry.label(27) == "27\"")
        #expect(ScreenGeometry.label(31.5) == "31.5\"")
        #expect(ScreenGeometry.label(31.75) == "31.8\"")
    }

    @Test func recommendedSizeFor27Inch4KIs2560() {
        let size = ScreenGeometry.physicalSize(diagonalInches: 27, pixelWidth: 3840, pixelHeight: 2160)
        let widths = [1920, 2048, 2304, 2560, 3008, 3200, 3360, 3840]
        let stops = widths.map { ModeStop(mode: RawMode(width: $0, height: $0 * 9 / 16, pixelWidth: $0 * 2, pixelHeight: $0 * 9 / 8,
                                                        refreshRate: 60, usableForDesktop: true, source: .coreGraphics(ioModeID: 1))) }
        let index = ModeLadder.recommendedIndex(in: stops, physicalWidthMM: size.width)
        #expect(index.map { stops[$0].width } == 2560)
    }
}
