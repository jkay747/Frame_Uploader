import AppKit
import SwiftUI

@main
struct FrameUploaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var coordinator = UploadCoordinator()

    init() {
        AppSettings.registerDefaults()
    }

    var body: some Scene {
        Window("Frame Uploader", id: "main") {
            ContentView()
                .environmentObject(coordinator)
                .frame(minWidth: 820, minHeight: 540)
        }
        .defaultSize(width: 1040, height: 700)

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
