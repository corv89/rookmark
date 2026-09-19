import RookmarkKit
import Testing

@testable import RookmarkApp

/// The completion notification, tested through the decision seam: the model
/// decides *whether* to ping (finished vs paused/failed, on screen vs not,
/// authorized vs not) against a recorder, so no test touches
/// UNUserNotificationCenter or triggers the system permission prompt. The
/// fixtures are built so `acceptedCount` and `sortedCount` disagree —
/// `accepted` defaults to true, so a row the model parked in Unsorted still
/// counts as accepted — and every expected body pins the *sorted* count.
@Suite("Completion notification")
@MainActor
struct CompletionNotificationTests {

    /// Records instead of delivering. `granted` is what the system would
    /// answer right now. The once-only property of the prompt lives in the
    /// production conformer (it presents UI only while the real status is
    /// .notDetermined), not in the model — so all this asserts is what the
    /// model actually controls: when the seam is consulted, and whether the
    /// latest answer governs.
    @MainActor
    private final class Recorder: NotificationPosting {
        var granted = false
        private(set) var authorizationChecks = 0
        private(set) var posts: [String] = []   // "title|body"

        func requestAuthorizationIfNeeded() async -> Bool {
            authorizationChecks += 1
            return granted
        }

        func post(title: String, body: String) async {
            posts.append("\(title)|\(body)")
        }
    }

    /// Two sorted rows and one the model left in Unsorted — which still
    /// counts as accepted (the default), so acceptedCount is 3 while the
    /// sorted count is 2. The expected body pins the 2: the notification
    /// reports bookmarks *sorted*, and Unsorted is by definition not sorted.
    /// (The original fixture made one row do double duty — Unsorted AND
    /// unaccepted — leaving both counts at 2, which would have passed under
    /// either reading.)
    private static func rows() -> [OrganizerModel.Row] {
        [
            .init(id: "a", title: "A", url: "https://a.example",
                  folder: "Development", confidence: 90, modelChoice: nil),
            .init(id: "b", title: "B", url: "https://b.example",
                  folder: "Reading", confidence: 80, modelChoice: nil),
            .init(id: "c", title: "C", url: "https://c.example",
                  folder: Taxonomy.unsorted, confidence: 30,
                  modelChoice: "Development"),
        ]
    }

    private static let finishedBody =
        "2 of 3 bookmarks sorted. Review and export when ready."

    private func model(_ recorder: Recorder, visible: Bool) -> OrganizerModel {
        OrganizerModel(notifications: recorder, isAppVisible: { visible })
    }

    // MARK: authorization — at the first Organize, never at launch

    @Test("constructing the model asks nothing")
    func launchDoesNotAsk() {
        let recorder = Recorder()
        _ = model(recorder, visible: true)
        #expect(recorder.authorizationChecks == 0)
    }

    @Test("every Organize consults the seam; the system keeps its prompt to once")
    func organizeChecksAuthorization() async {
        let recorder = Recorder()
        recorder.granted = true
        let model = model(recorder, visible: true)
        await model.organize()          // classify early-returns: no taxonomy, nothing armed
        await model.organize()
        #expect(recorder.authorizationChecks == 2)
    }

    @Test("an authorization flipped on after a reflexive denial is honored at the next Organize")
    func laterGrantIsHonored() async {
        let recorder = Recorder()
        let model = model(recorder, visible: false)
        model.updateRows(Self.rows())
        await model.organize()                  // asked, denied
        await model.updatePhase(.finished)
        #expect(recorder.posts.isEmpty)
        recorder.granted = true                 // granted in System Settings, back in Rookmark
        await model.organize()
        await model.updatePhase(.finished)
        #expect(recorder.posts == ["Rookmark|\(Self.finishedBody)"])
    }

    // MARK: the decision

    @Test("finishing in the background posts exactly one notification with the sorted count")
    func backgroundFinishPosts() async {
        let recorder = Recorder()
        recorder.granted = true
        let model = model(recorder, visible: false)
        model.updateRows(Self.rows())
        await model.organize()                  // authorization granted
        await model.updatePhase(.finished)
        #expect(recorder.posts == ["Rookmark|\(Self.finishedBody)"])
    }

    @Test("a paused-then-resumed run still posts when it finally finishes")
    func resumedFinishPosts() async {
        let recorder = Recorder()
        recorder.granted = true
        let model = model(recorder, visible: false)
        model.updateRows(Self.rows())
        await model.organize()
        await model.updatePhase(.paused)        // the pause itself: no ping
        #expect(recorder.posts.isEmpty)
        await model.updatePhase(.finished)      // the resumed leg completes
        #expect(recorder.posts == ["Rookmark|\(Self.finishedBody)"])
    }

    @Test("finishing while Rookmark is on screen posts nothing")
    func onScreenFinishIsSilent() async {
        let recorder = Recorder()
        recorder.granted = true
        let model = model(recorder, visible: true)
        model.updateRows(Self.rows())
        await model.organize()
        await model.updatePhase(.finished)
        #expect(recorder.posts.isEmpty)
    }

    @Test("denied permission means no ping, and the run carries on")
    func denialIsSilentButHarmless() async {
        let recorder = Recorder()
        recorder.granted = false
        let model = model(recorder, visible: false)
        model.updateRows(Self.rows())
        await model.organize()                  // asked once, denied
        await model.updatePhase(.finished)
        #expect(recorder.posts.isEmpty)
        #expect(model.phase == .finished, "the run completed normally without permission")
    }

    @Test("a failed run does not post")
    func failureIsSilent() async {
        let recorder = Recorder()
        recorder.granted = true
        let model = model(recorder, visible: false)
        model.updateRows(Self.rows())
        await model.organize()
        await model.updatePhase(.failed("model unavailable"))
        #expect(recorder.posts.isEmpty)
    }

    // MARK: the copy — the numerator is the sorted count, from either side

    @Test("the other direction too: a declined row in a folder is sorted without being accepted")
    func declinedButSortedStillCounts() async {
        // Mirror image of the shared fixture: three rows, all in real
        // folders, one declined. sortedCount 3, acceptedCount 2 — the
        // expected "3 of 3" is unreachable via acceptedCount, exactly as the
        // shared fixture's "2 of 3" is unreachable via sortedCount's rival
        // reading. Both fixtures must fail under the swapped formula.
        let recorder = Recorder()
        recorder.granted = true
        let model = model(recorder, visible: false)
        model.updateRows([
            .init(id: "a", title: "A", url: "https://a.example",
                  folder: "Development", confidence: 90, modelChoice: nil),
            .init(id: "b", title: "B", url: "https://b.example",
                  folder: "Reading", confidence: 80, modelChoice: nil,
                  accepted: false),
            .init(id: "c", title: "C", url: "https://c.example",
                  folder: "Development", confidence: 70, modelChoice: nil),
        ])
        await model.organize()
        await model.updatePhase(.finished)
        #expect(recorder.posts == ["Rookmark|3 of 3 bookmarks sorted. Review and export when ready."])
    }
}
