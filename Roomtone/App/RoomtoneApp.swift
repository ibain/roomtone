import SwiftUI

@main
struct RoomtoneApp: App {
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        WindowGroup("Roomtone") {
            ContentView()
                .environmentObject(appModel)
                .frame(minWidth: 880, minHeight: 560)
                .task {
                    // Mic only at launch. Screen/system audio uses Apple's picker on Start.
                    _ = await CapturePermissions.requestMicrophoneAccess()
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsView()
                .environmentObject(appModel)
        }
    }
}
