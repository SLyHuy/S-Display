import SwiftUI

/// UI-size slider over a display's HiDPI stops. Applies only when the knob is released (after a short
/// debounce), since every mode switch makes the display blink.
struct ScaleSliderView: View {
    let display: DisplayInfo
    let busy: Bool
    let apply: (ModeStop) -> Void

    @State private var index: Double = 0
    @State private var isEditing = false
    @State private var pendingApply: Task<Void, Never>?

    private var stops: [ModeStop] { display.stops }

    private var selected: ModeStop? {
        stops.indices.contains(Int(index)) ? stops[Int(index)] : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("UI size").font(.system(size: 13, weight: .medium))
                Spacer()
                Text(verbatim: readout)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if stops.count >= 2 {
                Slider(value: $index, in: 0 ... Double(stops.count - 1), step: 1) { editing in
                    isEditing = editing
                    if !editing { scheduleApply() }
                }
                HStack {
                    Text("Larger text")
                    Spacer()
                    if let recommended = display.recommendedStopIndex, recommended != display.currentStopIndex {
                        Button("Recommended") {
                            index = Double(recommended)
                            scheduleApply()
                        }
                        .buttonStyle(.link)
                        .help("About 110 points per inch, what macOS aims for on external displays")
                    }
                    Spacer()
                    Text("More space")
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            } else {
                Text("No HiDPI sizes yet. Enable Flexible HiDPI below.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            if let current = display.current, display.currentStopIndex == nil {
                Text("Now \(current.width)×\(current.height) at 1x (not HiDPI). Pick a size to make text sharper.")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(busy)
        .onAppear(perform: syncFromDisplay)
        .onChange(of: display.current) { syncFromDisplay() }
        .onChange(of: display.stops) { syncFromDisplay() }
    }

    private var readout: String {
        guard let stop = selected else { return "" }
        let text = ModeLadder.textScalePercent(of: stop, nativeWidth: display.nativeWidth)
        return "\(stop.width)×\(stop.height) · text \(text)%"
    }

    private func syncFromDisplay() {
        guard !isEditing, !stops.isEmpty else { return }
        if let current = display.currentStopIndex {
            index = Double(current)
        } else if let current = display.current {
            // Not on a HiDPI stop (e.g. native 1x): park the knob on the closest size without applying it.
            let nearest = stops.indices.min { abs(stops[$0].width - current.width) < abs(stops[$1].width - current.width) }
            index = Double(nearest ?? 0)
        }
    }

    private func scheduleApply() {
        pendingApply?.cancel()
        guard let stop = selected else { return }
        let alreadyThere = display.currentStopIndex.map { stops[$0] == stop } ?? false
        guard !alreadyThere else { return }
        pendingApply = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            apply(stop)
        }
    }
}
