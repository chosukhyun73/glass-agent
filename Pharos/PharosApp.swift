import SwiftUI

@main
struct GlassAgentApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        print("[GlassAgent] App.init() start")
    }

    var body: some Scene {
        print("[GlassAgent] App.body evaluated")
        return WindowGroup {
            ContentView()
        }
    }
}
