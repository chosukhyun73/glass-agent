import SwiftUI

@main
struct PharosApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        print("[Pharos] PharosApp.init() start")
    }

    var body: some Scene {
        print("[Pharos] PharosApp.body evaluated")
        return WindowGroup {
            ContentView()
        }
    }
}
