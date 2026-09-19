import AppKit
import SwiftUI

@main
struct RookmarkApp: App {
    @State private var model = OrganizerModel()

    var body: some Scene {
        WindowGroup("Rookmark") {
            ContentView(model: model)
                .frame(minWidth: 820, minHeight: 560)
                .task {
                    // Launched from a terminal via `swift run`, the process is not
                    // a foreground app until it asks to be.
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                    await model.scan()
                }
        }
        .windowResizability(.contentMinSize)
    }
}
