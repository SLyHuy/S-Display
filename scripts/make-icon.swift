#!/usr/bin/env swift
// Renders the S-Display app icon with SwiftUI and writes the AppIcon asset catalog.
// Usage: swift scripts/make-icon.swift [output-dir]   (default: S-Display/Assets.xcassets)

import AppKit
import SwiftUI

// MARK: - Artwork (1024 × 1024 canvas, macOS icon grid: 824 pt squircle, 100 pt margin)

struct Monitor: View {
    let screen: AnyView
    let bezel: Color
    let standTint: Color
    var showsStand = true

    var body: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .fill(bezel)
                .frame(width: 470, height: 300)
                .overlay(
                    screen
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .padding(16)
                )
                .shadow(color: .black.opacity(0.45), radius: 24, y: 14)
            // Neck and foot
            Rectangle()
                .fill(standTint)
                .frame(width: 70, height: 46)
                .opacity(showsStand ? 1 : 0)
            Capsule()
                .fill(standTint)
                .frame(width: 200, height: 20)
                .opacity(showsStand ? 1 : 0)
        }
    }
}

struct IconArt: View {
    var body: some View {
        ZStack {
            // Background squircle
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(red: 0.09, green: 0.36, blue: 0.26), Color(red: 0.02, green: 0.10, blue: 0.07)],
                    startPoint: .top, endPoint: .bottom
                ))
                .overlay(
                    // Soft light from the top
                    RoundedRectangle(cornerRadius: 185, style: .continuous)
                        .fill(RadialGradient(
                            colors: [Color.white.opacity(0.18), .clear],
                            center: UnitPoint(x: 0.5, y: -0.05), startRadius: 0, endRadius: 620
                        ))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 185, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 3)
                )
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.35), radius: 18, y: 12)

            // Back monitor: turned off (BlackOut)
            Monitor(
                screen: AnyView(
                    ZStack {
                        Color(red: 0.02, green: 0.05, blue: 0.04)
                        PowerGlyph()
                            .stroke(Color.white.opacity(0.22), style: StrokeStyle(lineWidth: 16, lineCap: .round))
                            .frame(width: 86, height: 86)
                    }
                ),
                bezel: Color(red: 0.21, green: 0.29, blue: 0.26),
                standTint: .clear,
                showsStand: false
            )
            .scaleEffect(0.84)
            .offset(x: -96, y: -92)

            // Front monitor: lit and sharp (HiDPI)
            Monitor(
                screen: AnyView(
                    ZStack {
                        LinearGradient(
                            colors: [
                                Color(red: 0.62, green: 1.00, blue: 0.72),
                                Color(red: 0.16, green: 0.82, blue: 0.52),
                                Color(red: 0.02, green: 0.55, blue: 0.47),
                            ],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                        // Fine pixel grid: the "HiDPI" texture
                        PixelGrid(spacing: 14)
                            .stroke(Color.white.opacity(0.07), lineWidth: 1.5)
                        Text("S")
                            .font(.system(size: 210, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                            .shadow(color: .white.opacity(0.65), radius: 18)
                            .shadow(color: Color(red: 0.02, green: 0.25, blue: 0.18).opacity(0.55), radius: 6, y: 6)
                        // Glass sheen
                        LinearGradient(colors: [Color.white.opacity(0.28), .clear], startPoint: .top, endPoint: .center)
                    }
                ),
                bezel: Color(red: 0.94, green: 0.97, blue: 0.95),
                standTint: Color(red: 0.80, green: 0.87, blue: 0.83)
            )
            .offset(x: 70, y: 96)
        }
        .frame(width: 1024, height: 1024)
    }
}

struct PowerGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        path.addArc(center: center, radius: rect.width / 2, startAngle: .degrees(-60), endAngle: .degrees(240), clockwise: false)
        path.move(to: CGPoint(x: rect.midX, y: rect.minY - rect.height * 0.08))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.midY))
        return path
    }
}

struct PixelGrid: Shape {
    let spacing: CGFloat
    func path(in rect: CGRect) -> Path {
        var path = Path()
        var x = rect.minX
        while x <= rect.maxX { path.move(to: CGPoint(x: x, y: rect.minY)); path.addLine(to: CGPoint(x: x, y: rect.maxY)); x += spacing }
        var y = rect.minY
        while y <= rect.maxY { path.move(to: CGPoint(x: rect.minX, y: y)); path.addLine(to: CGPoint(x: rect.maxX, y: y)); y += spacing }
        return path
    }
}

// MARK: - Export

@MainActor
func render(pixels: Int) -> Data? {
    let renderer = ImageRenderer(content: IconArt())
    renderer.scale = CGFloat(pixels) / 1024
    guard let cgImage = renderer.cgImage else { return nil }
    return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
}

@MainActor
func main() throws {
    let catalog = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "S-Display/Assets.xcassets")
    let iconSet = catalog.appendingPathComponent("AppIcon.appiconset")
    try FileManager.default.createDirectory(at: iconSet, withIntermediateDirectories: true)
    try Data(#"{"info":{"author":"xcode","version":1}}"#.utf8).write(to: catalog.appendingPathComponent("Contents.json"))

    var images: [[String: String]] = []
    for points in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let pixels = points * scale
            let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
            guard let png = render(pixels: pixels) else { throw CocoaError(.fileWriteUnknown) }
            try png.write(to: iconSet.appendingPathComponent(name))
            images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
        }
    }
    let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
    try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
        .write(to: iconSet.appendingPathComponent("Contents.json"))
    print("wrote \(images.count) icon sizes to \(iconSet.path)")
}

MainActor.assumeIsolated {
    do { try main() } catch { print("error: \(error)"); exit(1) }
}
