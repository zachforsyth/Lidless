import SwiftUI

@main
struct LidlessApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environmentObject(state)
                .environmentObject(state.screenAwake)
                .environmentObject(state.lidLock)
        } label: {
            MenuBarIcon(state: state, screenAwake: state.screenAwake)
        }
        .menuBarExtraStyle(.window)
        // No `Settings` scene: it doesn't reliably surface in an LSUIElement app
        // (issue #22). `AppState.showSettings()` presents it via AppKit instead.
    }
}

/// Filled when either keep-awake mode is on.
private struct MenuBarIcon: View {
    @ObservedObject var state: AppState
    @ObservedObject var screenAwake: ScreenAwakeController

    var body: some View {
        Image(state.isEnabled || screenAwake.isOn ? "MenubarLaptopActive" : "MenubarLaptop")
    }
}
