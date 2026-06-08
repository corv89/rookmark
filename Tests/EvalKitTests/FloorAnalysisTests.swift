import Testing
@testable import EvalKit
import LazyBookmarksKit

@Suite("FloorAnalysis")
struct FloorAnalysisTests {

    @Test("calibrate bins items by confidence")
    func calibrateBins() {
        let decisions = [
            Classifier.Decision(bookmarkID: "1", folder: "News", confidence: 5),
            Classifier.Decision(bookmarkID: "2", folder: "News", confidence: 15),
            Classifier.Decision(bookmarkID: "3", folder: "News", confidence: 25),
            Classifier.Decision(bookmarkID: "4", folder: "News", confidence: 85),
        ]
        let labels: [LabelKey: Label] = [
            LabelKey(bookmarkID: "1", folder: "News"): .init(bookmarkID: "1", folder: "News", verdict: .reject),
            LabelKey(bookmarkID: "2", folder: "News"): .init(bookmarkID: "2", folder: "News", verdict: .accept),
            LabelKey(bookmarkID: "3", folder: "News"): .init(bookmarkID: "3", folder: "News", verdict: .accept),
            LabelKey(bookmarkID: "4", folder: "News"): .init(bookmarkID: "4", folder: "News", verdict: .accept),
        ]
        let bins = FloorAnalysis.calibrate(decisions: decisions, labels: labels, bins: [0, 10, 20, 80])
        #expect(bins.count == 4)
        #expect(bins[0].placed == 1)
        #expect(bins[0].accepted == 0)
        #expect(bins[0].precision == 0)
        #expect(bins[3].placed == 1)
        #expect(bins[3].accepted == 1)
        #expect(bins[3].precision == 1.0)
    }

    @Test("calibrate uses modelChosenFolder for below-floor items")
    func calibrateModelChosenFolder() {
        let decisions = [
            Classifier.Decision(bookmarkID: "1", folder: Taxonomy.unsorted, confidence: 8, modelChosenFolder: "Cooking"),
            Classifier.Decision(bookmarkID: "2", folder: Taxonomy.unsorted, confidence: 12, modelChosenFolder: "News"),
        ]
        let labels: [LabelKey: Label] = [
            LabelKey(bookmarkID: "1", folder: "Cooking"): .init(bookmarkID: "1", folder: "Cooking", verdict: .accept),
            LabelKey(bookmarkID: "2", folder: "News"): .init(bookmarkID: "2", folder: "News", verdict: .reject),
        ]
        let bins = FloorAnalysis.calibrate(decisions: decisions, labels: labels, bins: [0, 10, 20])
        #expect(bins[0].placed == 1)
        #expect(bins[0].accepted == 1)
        #expect(bins[1].placed == 1)
        #expect(bins[1].accepted == 0)
    }

    @Test("floorSweep simulates threshold changes")
    func floorSweep() {
        let decisions = [
            Classifier.Decision(bookmarkID: "1", folder: "News", confidence: 5),
            Classifier.Decision(bookmarkID: "2", folder: "News", confidence: 15),
            Classifier.Decision(bookmarkID: "3", folder: "Cooking", confidence: 25),
            Classifier.Decision(bookmarkID: "4", folder: "Cooking", confidence: 50),
        ]
        let labels: [LabelKey: Label] = [
            LabelKey(bookmarkID: "1", folder: "News"): .init(bookmarkID: "1", folder: "News", verdict: .reject),
            LabelKey(bookmarkID: "2", folder: "News"): .init(bookmarkID: "2", folder: "News", verdict: .accept),
            LabelKey(bookmarkID: "3", folder: "Cooking"): .init(bookmarkID: "3", folder: "Cooking", verdict: .accept),
            LabelKey(bookmarkID: "4", folder: "Cooking"): .init(bookmarkID: "4", folder: "Cooking", verdict: .accept),
        ]
        let sweep = FloorAnalysis.floorSweep(decisions: decisions, labels: labels, floors: [0, 10, 20, 30])

        #expect(sweep.count == 4)
        #expect(sweep[0].floor == 0)
        #expect(abs(sweep[0].coverage - 1.0) < 0.001)
        #expect(abs(sweep[0].yield - 0.75) < 0.001)

        #expect(sweep[2].floor == 20)
        #expect(abs(sweep[2].coverage - 0.5) < 0.001)
    }

    @Test("floorSweep with empty decisions returns empty")
    func floorSweepEmpty() {
        let sweep = FloorAnalysis.floorSweep(decisions: [], labels: [:])
        #expect(sweep.isEmpty)
    }

    @Test("floorSweep uses modelChosenFolder for unsorted items")
    func floorSweepModelChosen() {
        let decisions = [
            Classifier.Decision(bookmarkID: "1", folder: Taxonomy.unsorted, confidence: 8, modelChosenFolder: "News"),
            Classifier.Decision(bookmarkID: "2", folder: "Cooking", confidence: 50),
        ]
        let labels: [LabelKey: Label] = [
            LabelKey(bookmarkID: "1", folder: "News"): .init(bookmarkID: "1", folder: "News", verdict: .accept),
            LabelKey(bookmarkID: "2", folder: "Cooking"): .init(bookmarkID: "2", folder: "Cooking", verdict: .accept),
        ]
        let sweep = FloorAnalysis.floorSweep(decisions: decisions, labels: labels, floors: [0, 10])
        #expect(sweep[0].yield == 1.0)
        #expect(sweep[1].yield == 0.5)
    }
}
