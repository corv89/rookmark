import AppKit
import Darwin
import Foundation

/// Stops a second copy of the app from running.
///
/// This is a data-integrity guard rather than a tidiness one. Both instances
/// would restore the same session and then write their own snapshot after every
/// batch, so whichever saved last would silently erase the other's
/// classification work — potentially half an hour of model time.
///
/// Uses an advisory lock on a file rather than a pid file: the kernel drops the
/// lock when the process dies, so a crash cannot strand a stale lock and leave
/// the app permanently unable to start.
enum SingleInstanceGuard {

    /// Held for the lifetime of the process. Closing it releases the lock, so it
    /// is deliberately never closed.
    private nonisolated(unsafe) static var lockDescriptor: Int32 = -1

    private static var lockURL: URL {
        let dir = URL.applicationSupportDirectory
            .appending(path: "Rookmark", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "instance.lock", directoryHint: .notDirectory)
    }

    /// True when this process now owns the lock; false when another instance holds it.
    static func claim() -> Bool {
        let descriptor = Darwin.open(lockURL.path(percentEncoded: false), O_CREAT | O_RDWR, 0o644)
        // If the lock file cannot be opened at all, start anyway: refusing to
        // launch over a locking problem is worse than the duplicate it prevents.
        guard descriptor >= 0 else { return true }

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return false
        }
        lockDescriptor = descriptor
        return true
    }

    /// Brings the instance that already holds the lock to the front, so a second
    /// launch behaves like clicking the app in the Dock rather than doing nothing.
    @MainActor
    static func activateRunningInstance() {
        guard let identifier = Bundle.main.bundleIdentifier else { return }
        let mine = ProcessInfo.processInfo.processIdentifier
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
        where app.processIdentifier != mine {
            app.activate()
            return
        }
    }
}
