import Foundation
import Testing

struct OverridePlistTests {
    @Test func ladderFor1440pHas81Stops() {
        let ladder = OverridePlist.ladder(nativeWidth: 2560, nativeHeight: 1440)
        #expect(ladder.count == 81)
        #expect(ladder.first?.width == 2560 && ladder.first?.height == 1440)
        #expect(ladder.last?.width == 1280 && ladder.last?.height == 720)
        #expect(ladder.allSatisfy { $0.width % 16 == 0 })
        #expect(ladder.allSatisfy { abs(Double($0.width) / Double($0.height) - 16.0 / 9.0) < 0.01 })
    }

    @Test func ladderFor4KHas121Stops() {
        let ladder = OverridePlist.ladder(nativeWidth: 3840, nativeHeight: 2160)
        #expect(ladder.count == 121)
        #expect(ladder.first?.width == 3840 && ladder.first?.height == 2160)
        #expect(ladder.last?.width == 1920 && ladder.last?.height == 1080)
    }

    @Test func encodesBackingSizeAsBigEndianPair() {
        let entry = OverridePlist.encode(backingWidth: 5120, backingHeight: 2880)
        #expect([UInt8](entry) == [0x00, 0x00, 0x14, 0x00, 0x00, 0x00, 0x0B, 0x40])
        let decoded = OverridePlist.decode(entry)
        #expect(decoded?.backingWidth == 5120 && decoded?.backingHeight == 2880)
    }

    @Test func scaleResolutionsAreTwiceTheLooksLikeSize() {
        let entries = OverridePlist.scaleResolutions(nativeWidth: 2560, nativeHeight: 1440)
        #expect(entries.count == 81)
        let first = OverridePlist.decode(entries[0])
        #expect(first?.backingWidth == 5120 && first?.backingHeight == 2880)
    }

    @Test func overridePathUsesLowercaseHex() {
        #expect(OverridePlist.path(vendor: 0x469, product: 0x27EC)
            == "/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-469/DisplayProductID-27ec")
        #expect(OverridePlist.path(vendor: 0x1E6D, product: 0x5BC1)
            == "/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-1e6d/DisplayProductID-5bc1")
    }

    @Test func plistRoundTripKeepsOtherKeys() throws {
        let entries = OverridePlist.scaleResolutions(nativeWidth: 2560, nativeHeight: 1440)
        let existing: [String: Any] = ["DisplayProductName": "ROG PG279Q", "scale-resolutions": [Data([0, 0, 0, 1, 0, 0, 0, 1])]]
        let data = try OverridePlist.makePlist(merging: existing, scaleResolutions: entries)
        let plist = OverridePlist.read(data)
        #expect(plist?["DisplayProductName"] as? String == "ROG PG279Q")
        #expect(OverridePlist.scaleResolutions(in: plist) == entries)
    }
}
