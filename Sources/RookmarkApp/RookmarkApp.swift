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
                    NSApp.applicationIconImage = Self.appIcon
                    NSApp.activate(ignoringOtherApps: true)
                    await model.scan()
                }
        }
        .windowResizability(.contentMinSize)
    }

    /// A bare SwiftPM executable is not an .app bundle, so there is no
    /// CFBundleIconFile for the Dock to read. Setting it at launch is what
    /// gives the process its icon when run via `swift run`; a bundled release
    /// gets it from icon/Rookmark.icns instead.
    private static var appIcon: NSImage? {
        guard let url = Bundle.module.url(forResource: "AppIcon", withExtension: "png") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }
}
