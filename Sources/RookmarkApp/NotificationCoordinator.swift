import AppKit
import Foundation
import UserNotifications

/// Whether the user can actually see Rookmark at completion time. A
/// standalone enum so OrganizerModel can name the default without importing
/// AppKit itself. MainActor because NSApp is: in Swift 6 language mode a
/// nonisolated reader of it will not compile.
@MainActor
enum AppVisibility {
    /// Frontmost AND with a window on screen, because neither half alone
    /// answers the question this ping cares about: minimizing (or closing)
    /// the window leaves the application active while nothing of it is
    /// visible — exactly the "reads as hung" case the ping exists for — so
    /// `NSApp.isActive` on its own would sit silent through it. The
    /// occlusion state, not `isVisible`, is the on-screen test: a
    /// miniaturized window or one parked on another Space or full-screen
    /// window stays out of `.visible`, while a window merely behind others
    /// counts as seen.
    static var isOnScreen: Bool {
        NSApp.isActive && NSApp.windows.contains { $0.occlusionState.contains(.visible) }
    }
}

/// The seam between the model's "should I notify?" decision and the system.
/// The model decides; the coordinator delivers. Tests substitute a recorder,
/// so no test touches UNUserNotificationCenter or fires the permission prompt.
///
/// MainActor because every caller is: the model is @MainActor, so nothing
/// hops executors and no Sendable conformance is needed.
@MainActor
protocol NotificationPosting {
    /// Resolves whether completion alerts may be shown right now, prompting
    /// only while the system status is .notDetermined. The system keeps its
    /// prompt once-per-install by itself — any other status is answered
    /// immediately, no UI — so callers can re-check on every run and a user
    /// who switches Rookmark on in System Settings after a reflexive
    /// "Don't Allow" is picked up at the next Organize. A denial is an
    /// answer, not an error.
    func requestAuthorizationIfNeeded() async -> Bool
    /// Posts one notification. Delivery failures are swallowed: the ping is a
    /// nicety and must never surface as an app error.
    func post(title: String, body: String) async
}

/// Production poster. A value type with no stored state, so the model can
/// hold one from init without side effects; the system center is only reached
/// inside the methods.
@MainActor
struct SystemNotifier: NotificationPosting {
    /// Reused for every completion notification, so a second finish replaces
    /// the first in Notification Center instead of stacking beside it.
    private static let completionID = "rookmark.run.finished"

    func requestAuthorizationIfNeeded() async -> Bool {
        // A bare `swift run` has no bundle, and the center is unavailable
        // without a bundle identifier (the same condition RookmarkApp.swift
        // probes for the activation policy). Refuse quietly, don't trap.
        guard Bundle.main.bundleIdentifier != nil else { return false }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            // The prompt happens here and only here: .notDetermined is the
            // one status that presents UI, so this is once per install and
            // every later Organize falls through the other cases without one.
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

    func post(title: String, body: String) async {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: Self.completionID, content: content, trigger: nil
        )
        // try?: a notification that cannot be delivered is not a failure of
        // the run it reports on.
        _ = try? await UNUserNotificationCenter.current().add(request)
    }
}
