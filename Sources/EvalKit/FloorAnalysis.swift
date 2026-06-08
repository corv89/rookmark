import Foundation
import LazyBookmarksKit

public struct ConfidenceBin: Sendable, Equatable {
    public var floor: Int
    public var ceiling: Int
    public var placed: Int
    public var accepted: Int
    public var precision: Double

    public init(floor: Int, ceiling: Int, placed: Int, accepted: Int, precision: Double) {
        self.floor = floor
        self.ceiling = ceiling
        self.placed = placed
        self.accepted = accepted
        self.precision = precision
    }
}

public struct FloorPoint: Sendable, Equatable {
    public var floor: Int
    public var yield: Double
    public var precision: Double
    public var coverage: Double

    public init(floor: Int, yield: Double, precision: Double, coverage: Double) {
        self.floor = floor
        self.yield = yield
        self.precision = precision
        self.coverage = coverage
    }
}

public enum FloorAnalysis {

    public static func calibrate(
        decisions: [Classifier.Decision],
        labels: [LabelKey: Label],
        bins: [Int] = [0, 10, 20, 30, 40, 50, 60, 70, 80, 90]
    ) -> [ConfidenceBin] {
        var result: [ConfidenceBin] = []

        for i in 0..<bins.count {
            let lo = bins[i]
            let hi = i + 1 < bins.count ? bins[i + 1] : 101

            var placed = 0
            var accepted = 0

            for d in decisions {
                let effectiveFolder: String?
                if d.folder != Taxonomy.unsorted {
                    effectiveFolder = d.folder
                } else if let chosen = d.modelChosenFolder, chosen != Taxonomy.unsorted {
                    effectiveFolder = chosen
                } else {
                    effectiveFolder = nil
                }

                guard let folder = effectiveFolder,
                      d.confidence >= lo && d.confidence < hi else { continue }

                placed += 1
                let key = LabelKey(bookmarkID: d.bookmarkID, folder: folder)
                if let label = labels[key], label.verdict == .accept {
                    accepted += 1
                }
            }

            let precision = placed > 0 ? Double(accepted) / Double(placed) : 0
            result.append(ConfidenceBin(
                floor: lo,
                ceiling: min(hi, 100),
                placed: placed,
                accepted: accepted,
                precision: precision
            ))
        }

        return result
    }

    public static func floorSweep(
        decisions: [Classifier.Decision],
        labels: [LabelKey: Label],
        floors: [Int] = [0, 5, 10, 15, 20, 25, 30, 35, 40]
    ) -> [FloorPoint] {
        let total = decisions.count
        guard total > 0 else { return [] }

        return floors.map { threshold in
            var placed = 0
            var accepted = 0

            for d in decisions {
                let folder: String
                if d.confidence >= threshold {
                    if d.folder != Taxonomy.unsorted {
                        folder = d.folder
                    } else if let chosen = d.modelChosenFolder, chosen != Taxonomy.unsorted {
                        folder = chosen
                    } else {
                        continue
                    }
                } else {
                    continue
                }

                placed += 1
                let key = LabelKey(bookmarkID: d.bookmarkID, folder: folder)
                if let label = labels[key], label.verdict == .accept {
                    accepted += 1
                }
            }

            let yield = Double(accepted) / Double(total)
            let precision = placed > 0 ? Double(accepted) / Double(placed) : 0
            let coverage = Double(placed) / Double(total)

            return FloorPoint(
                floor: threshold,
                yield: yield,
                precision: precision,
                coverage: coverage
            )
        }
    }
}
