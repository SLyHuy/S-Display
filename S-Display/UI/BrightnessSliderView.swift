import SwiftUI

/// Control Center–style capsule brightness slider (full-width, sun icon inside the left end).
/// External displays synced with the built-in display also show a clickable offset pill to reset calibration.
struct BrightnessSliderView: View {
    let service: BrightnessService
    let display: DisplayInfo
    let busy: Bool

    @Environment(\.colorScheme) private var colorScheme
    @State private var dragLevel: Double = 1
    @State private var isEditing = false

    private let trackHeight: CGFloat = 24
    private let knobInset: CGFloat = 2

    private var isProbing: Bool { service.probing.contains(display.uuid) }
    private var method: BrightnessMethod? { service.method(for: display) }
    private var isLeader: Bool { service.isSyncLeader(display) }
    private var currentLevel: Double {
        isEditing ? dragLevel : (service.brightness(for: display) ?? dragLevel)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Brightness").font(.system(size: 13, weight: .medium))
                if service.syncEnabled, service.hasSyncFollowers, isLeader {
                    Image(systemName: "link")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .help("Primary brightness source — adjusting \(display.name) also adjusts other displays.")
                }
                if method == .software {
                    Text("Software")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                        .help("This monitor didn't respond to DDC/CI; dimming with software gamma.")
                }
                Spacer()
                if !isLeader, service.syncEnabled,
                   let offsetLabel = BrightnessSync.offsetLabel(service.offset(for: display)) {
                    Button {
                        service.resetOffset(for: display)
                    } label: {
                        Text(verbatim: offsetLabel)
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Remembered offset relative to \(service.syncLeader?.name ?? "primary display") (\(offsetLabel)). Click to reset to 0%.")
                }
                Text(verbatim: isProbing ? "…" : BrightnessSync.percentLabel(currentLevel))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            capsuleSlider
                .help(sliderTooltip)
        }
        .disabled(busy || isProbing)
        .opacity(busy || isProbing ? 0.6 : 1)
        .onAppear {
            if let value = service.brightness(for: display) {
                dragLevel = value
            }
        }
    }

    private var capsuleSlider: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, trackHeight)
            let clamped = CGFloat(BrightnessSync.clamp(currentLevel))
            let usable = max(width - trackHeight, 0)
            let fillWidth = trackHeight + clamped * usable
            let knobSize = trackHeight - knobInset * 2

            ZStack(alignment: .leading) {
                // Background capsule track
                Capsule()
                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.15 : 0.11))
                    .overlay(
                        Capsule()
                            .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.08), lineWidth: 0.5)
                    )

                // Filled white brightness bar + circular knob at its right end
                Capsule()
                    .fill(colorScheme == .dark ? Color.white.opacity(0.92) : Color.white)
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.25 : 0.14), radius: 2, x: 0, y: 0.5)
                    .frame(width: fillWidth, height: trackHeight)
                    .overlay(alignment: .trailing) {
                        Circle()
                            .fill(Color.white)
                            .overlay(Circle().strokeBorder(Color.black.opacity(0.07), lineWidth: 0.5))
                            .shadow(color: .black.opacity(0.18), radius: 2, x: 0, y: 1)
                            .frame(width: knobSize, height: knobSize)
                            .padding(.trailing, knobInset)
                    }

                // Sun icon inside the left end of the pill (always over the white fill)
                Image(systemName: currentLevel < 0.05 ? "sun.min.fill" : "sun.max.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(white: 0.32))
                    .frame(width: trackHeight, height: trackHeight)
                    .allowsHitTesting(false)
            }
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { gesture in
                        guard !busy, !isProbing else { return }
                        if !isEditing {
                            isEditing = true
                            service.setEditing(true, for: display)
                        }
                        let level = normalizedValue(forX: gesture.location.x, width: width)
                        dragLevel = level
                        service.setBrightness(level, for: display, persist: false)
                    }
                    .onEnded { gesture in
                        guard !busy, !isProbing else { return }
                        let level = normalizedValue(forX: gesture.location.x, width: width)
                        dragLevel = level
                        service.setBrightness(level, for: display, persist: true)
                        isEditing = false
                        service.setEditing(false, for: display)
                    }
            )
        }
        .frame(height: trackHeight)
        .accessibilityRepresentation {
            Slider(
                value: Binding(
                    get: { currentLevel },
                    set: { service.setBrightness($0, for: display, persist: true) }
                ),
                in: 0 ... 1
            ) {
                Text("Brightness")
            }
        }
    }

    private func normalizedValue(forX x: CGFloat, width: CGFloat) -> Double {
        let usable = max(width - trackHeight, 1)
        return BrightnessSync.clamp(Double((x - trackHeight / 2) / usable))
    }

    private var sliderTooltip: String {
        let leaderName = service.syncLeader?.name ?? "primary display"
        let syncing = service.syncEnabled && service.hasSyncFollowers
        switch method {
        case .native:
            return syncing && isLeader
                ? "Adjusts \(display.name) and synced displays."
                : (syncing ? "Native hardware brightness. Drag to calibrate its offset from \(leaderName)." : "Native hardware brightness (DisplayServices).")
        case .ddc:
            return syncing && isLeader
                ? "Hardware backlight brightness (DDC/CI). Adjusting \(display.name) also adjusts other displays."
                : (syncing ? "Hardware backlight brightness (DDC/CI). Drag to calibrate its offset from \(leaderName)." : "Hardware backlight brightness (DDC/CI).")
        case .software:
            return syncing && isLeader
                ? "Software gamma dimming. Adjusting \(display.name) also adjusts other displays."
                : (syncing ? "Software gamma dimming. Drag to calibrate its offset from \(leaderName)." : "Software gamma dimming (DDC/CI unavailable on this connection).")
        case nil:
            return "Checking brightness support…"
        }
    }
}
