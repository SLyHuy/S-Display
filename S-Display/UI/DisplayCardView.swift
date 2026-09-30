import SwiftUI

struct DisplayCardView: View {
    let model: AppModel
    let display: DisplayInfo

    @State private var editingSize = false
    @State private var sizeText = ""

    private var busy: Bool { model.isBusy(display.uuid) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if editingSize { customSizeEditor }
            if display.isMirrorTarget {
                Text("Mirroring another display. Change the size on that display.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                ScaleSliderView(display: display, busy: busy) { stop in
                    Task { await model.resolution.apply(stop, to: display) }
                }
                sharpnessRow
            }
            if let error = model.error(for: display.uuid) {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "display")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(display.name).font(.system(size: 15, weight: .semibold))
                    if display.isMain {
                        Text("Main")
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
                HStack(spacing: 4) {
                    Text("\(display.nativeWidth)×\(display.nativeHeight) ·")
                    sizeMenu
                    Text(trailingDetails)
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }
            Spacer()
            if busy { ProgressView().controlSize(.small) }
            Toggle("On", isOn: Binding(
                get: { true },
                set: { isOn in
                    if !isOn { Task { await model.blackOut.turnOff(display) } }
                }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .disabled(busy || !model.blackOut.isSupported || !model.blackOut.canTurnOff(display))
            .help(model.blackOut.canTurnOff(display)
                ? "Turn \(display.name) off (BlackOut)"
                : "The last visible display can't be turned off")
        }
    }

    /// Screen size picker: EDID value, common sizes, or a custom diagonal.
    private var sizeMenu: some View {
        Menu {
            Button {
                model.setScreenSize(nil, for: display)
            } label: {
                let edid = display.edidDiagonalInches.map { " (\(ScreenGeometry.label($0)))" } ?? ""
                if display.hasCustomSize { Text("Automatic from EDID\(edid)") } else { Label("Automatic from EDID\(edid)", systemImage: "checkmark") }
            }
            Divider()
            ForEach(ScreenGeometry.presetDiagonals, id: \.self) { inches in
                Button {
                    model.setScreenSize(inches, for: display)
                } label: {
                    if display.hasCustomSize, let current = display.diagonalInches, abs(current - inches) < 0.05 {
                        Label(ScreenGeometry.label(inches), systemImage: "checkmark")
                    } else {
                        Text(ScreenGeometry.label(inches))
                    }
                }
            }
            Divider()
            Button("Custom…") {
                sizeText = display.diagonalInches.map { String(format: "%.1f", $0) } ?? ""
                editingSize = true
            }
        } label: {
            Text(display.diagonalInches.map(ScreenGeometry.label) ?? "Size?")
                .underline(display.hasCustomSize)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Screen size (diagonal). Change it if your monitor reports the wrong size; it sets PPI and the Recommended UI size.")
    }

    private var customSizeEditor: some View {
        HStack(spacing: 8) {
            Text("Diagonal")
                .font(.system(size: 13))
            TextField("27", text: $sizeText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 64)
                .onSubmit(saveCustomSize)
            Text("inches").font(.system(size: 13)).foregroundStyle(.secondary)
            Spacer()
            Button("Cancel") { editingSize = false }
            Button("Save", action: saveCustomSize)
                .keyboardShortcut(.defaultAction)
                .disabled(ScreenGeometry.parseDiagonal(sizeText) == nil)
        }
        .controlSize(.small)
    }

    private func saveCustomSize() {
        guard let inches = ScreenGeometry.parseDiagonal(sizeText) else { return }
        model.setScreenSize(inches, for: display)
        editingSize = false
    }

    private var trailingDetails: String {
        var parts: [String] = []
        if let ppi = display.pixelsPerInch { parts.append("\(ppi) PPI") }
        if let current = display.current, current.refreshRate > 0 { parts.append("\(Int(current.refreshRate.rounded())) Hz") }
        return parts.isEmpty ? "" : "· " + parts.joined(separator: " · ")
    }

    private var sharpnessRow: some View {
        let installed = model.hiDPI.isInstalled(display)
        return HStack(spacing: 10) {
            Image(systemName: installed ? "checkmark.seal.fill" : "wand.and.stars")
                .font(.system(size: 16))
                .foregroundStyle(installed ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
            VStack(alignment: .leading, spacing: 2) {
                Text(installed ? "Flexible HiDPI is on" : "Flexible HiDPI")
                    .font(.system(size: 13, weight: .medium))
                Text(installed
                    ? "\(display.stops.count) sharp sizes on the slider."
                    : "Adds \(model.hiDPI.ladderCount(for: display)) sharp sizes. Needs your admin password.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            // Both directions write to /Library/Displays, so both ask for the password (hence the ellipsis).
            Button(installed ? "Disable…" : "Enable…") {
                Task {
                    if installed {
                        await model.hiDPI.remove(for: display)
                    } else {
                        await model.hiDPI.install(for: display)
                    }
                }
            }
            .disabled(busy)
        }
    }
}
