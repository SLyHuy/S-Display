import Foundation

enum ScreenGeometry {
    /// Common monitor diagonals offered in the size menu.
    static let presetDiagonals: [Double] = [21.5, 23.8, 24, 27, 28, 31.5, 32, 34, 38, 40, 43]

    /// Width and height in millimetres of a panel with this diagonal and pixel aspect ratio.
    static func physicalSize(diagonalInches: Double, pixelWidth: Int, pixelHeight: Int) -> (width: Double, height: Double) {
        let diagonalPixels = (Double(pixelWidth * pixelWidth + pixelHeight * pixelHeight)).squareRoot()
        let millimetresPerPixel = diagonalInches * 25.4 / diagonalPixels
        return (Double(pixelWidth) * millimetresPerPixel, Double(pixelHeight) * millimetresPerPixel)
    }

    static func diagonalInches(widthMM: Double, heightMM: Double) -> Double {
        (widthMM * widthMM + heightMM * heightMM).squareRoot() / 25.4
    }

    /// Accepts "27", "27.5", "27,5" or `27"`; nil unless it is a plausible monitor size.
    static func parseDiagonal(_ text: String) -> Double? {
        let cleaned = text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "inches", with: "")
            .replacingOccurrences(of: "inch", with: "")
            .replacingOccurrences(of: "in", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard let value = Double(cleaned), (10 ... 100).contains(value) else { return nil }
        return value
    }

    /// `27"`, `31.5"`.
    static func label(_ inches: Double) -> String {
        let rounded = (inches * 10).rounded() / 10
        return rounded == rounded.rounded() ? "\(Int(rounded))\"" : String(format: "%.1f\"", rounded)
    }
}
