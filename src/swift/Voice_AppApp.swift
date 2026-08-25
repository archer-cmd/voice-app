import SwiftUI
import AppKit

/// The app's starting point. It launches the voice engine when the window
/// appears and stops it cleanly when you quit. You normally won't edit this.
@main
struct DictationApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear { VoiceEngine.shared.go() }
        }
        .windowResizability(.contentSize)
    }
}

/// Stops the helper when the app quits so the microphone is always released.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        VoiceEngine.shared.stop()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
