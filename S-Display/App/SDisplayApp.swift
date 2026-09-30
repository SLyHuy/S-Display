import SwiftUI

@main
struct SDisplayApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuPanelView(model: model)
        } label: {
            // A single screen in the menu bar while S-Display has a display turned off.
            Image(systemName: model.blackOut.offRecords.isEmpty ? "display.2" : "display")
        }
        .menuBarExtraStyle(.window)
    }
}
