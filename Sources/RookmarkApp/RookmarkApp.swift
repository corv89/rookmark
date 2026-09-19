import AppKit
import SwiftUI

@main
struct RookmarkApp: App {
    @State private var model = OrganizerModel()

    init() {
        // Before any window or state exists, so a duplicate launch cannot read
        // the session and start racing the instance that already owns it.
        if !SingleInstanceGuard.claim() {
            MainActor.assumeIsolated { SingleInstanceGuard.activateRunningInstance() }
            exit(0)
        }
    }

    var body: some Scene {
        WindowGroup("Rookmark") {
            ContentView(model: model)
                .task {
                    // Only needed when run as a bare executable via `swift run`:
                    // without a bundle the process starts as an accessory and
                    // never comes to the front. A bundled launch is already
                    // .regular, and calling this after the window exists is what
                    // is suspected of disturbing toolbar safe-area setup.
                    if Bundle.main.bundleIdentifier == nil {
                        NSApp.setActivationPolicy(.regular)
                        NSApp.applicationIconImage = Self.appIcon
                        NSApp.activate()
                    }
                    await model.scan()
                }
        }
        // Minimum size belongs to the scene. Putting a .frame on the root view
        // wraps the whole hierarchy in a fixed-size container, which stops the
        // toolbar's safe area reaching the scroll views inside it.
        .defaultSize(width: 1180, height: 760)
        // .contentSize would grow the window to whatever the list wants, which
        // opened it several thousand points tall. .contentMinSize keeps the user
        // in charge of the size and only enforces a floor.
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
