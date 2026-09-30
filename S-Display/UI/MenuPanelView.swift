import SwiftUI

struct MenuPanelView: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("S-Display").font(.system(size: 17, weight: .bold))
                Spacer()
                Button {
                    model.registry.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh displays")
            }

            if !model.blackOut.isSupported {
                Label("Turning displays off isn't available on this Mac.", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
            }

            ForEach(model.registry.displays.filter(\.isViewable)) { display in
                DisplayCardView(model: model, display: display)
            }

            if !model.blackOut.offRecords.isEmpty {
                TurnedOffSection(model: model)
            }

            Divider()
            FooterView(model: model)
        }
        .padding(16)
        .frame(width: 420)
    }
}

private struct TurnedOffSection: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Turned off")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            ForEach(model.blackOut.offRecords) { record in
                let busy = model.blackOut.busy.contains(record.uuid)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Image(systemName: "display").foregroundStyle(.tertiary)
                        Text(record.name).font(.system(size: 14))
                        Spacer()
                        if busy { ProgressView().controlSize(.small) }
                        Button("Turn On") {
                            Task { await model.blackOut.turnOn(record) }
                        }
                        .controlSize(.small)
                        .disabled(busy)
                        Button {
                            model.blackOut.forget(record.uuid)
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.borderless)
                        .disabled(busy)
                        .help("Forget this display without turning it on")
                    }
                    if let error = model.blackOut.errors[record.uuid] {
                        Text(error)
                            .font(.system(size: 12))
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

private struct FooterView: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                Task { await model.blackOut.turnAllOn() }
            } label: {
                HStack {
                    Text("Turn all displays on")
                    Spacer()
                    Text("⌃⌥⌘0").foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)

            Text("⌃⌥⌘B turns off the display under the pointer.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Toggle("Keep turned-off displays off after restart", isOn: Binding(
                get: { model.blackOut.keepOffAfterRestart },
                set: { model.blackOut.keepOffAfterRestart = $0 }
            ))
            Toggle("Launch at login", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            ))
            if let error = model.launchAtLoginError {
                Text(error).font(.system(size: 12)).foregroundStyle(.red)
            }

            HStack {
                Button("Turn All On & Quit") { model.quit(turningDisplaysOn: true) }
                Spacer()
                Button("Quit") { model.quit(turningDisplaysOn: false) }
                    .keyboardShortcut("q")
            }
        }
        .toggleStyle(.checkbox)
        .font(.system(size: 13))
    }
}
