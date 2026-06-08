import ArgumentParser
import Foundation
import LazyBookmarksKit

struct Eval: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run the pipeline N times and report variance statistics."
    )

    @Argument(help: "Path to the exported bookmarks HTML file.")
    var input: String

    @Option(help: "Number of runs (default: 5).")
    var runs: Int = 5

    @Option(name: .customLong("embedder"), help: "Embedding backend: 'sentence' or 'contextual'.")
    var embedder: String = "sentence"

    @Flag(help: "Enable Phase 2 clustering.")
    var cluster = false

    @Option(name: .customLong("confidence-floor"), help: "Minimum confidence (0-100).")
    var confidenceFloor: Int = 15

    @Option(name: .customLong("batch-size"), help: "Initial classification batch size.")
    var batchSize: Int = 6

    func run() async throws {
        let factory = SessionFactory()
        guard case .available = factory.availability() else {
            if case let .unavailable(reason) = factory.availability() {
                throw ValidationError(reason)
            }
            return
        }
        guard runs >= 2 else {
            throw ValidationError("--runs must be >= 2 to compute variance.")
        }

        let html = try String(contentsOfFile: input, encoding: .utf8)
        let embedderPref: EmbedderFactory.Preference = embedder == "contextual" ? .contextual : .sentence
        let clusteringConfig = ClusteringConfig(enabled: cluster)

        struct RunMetrics {
            var sortRate: Double
            var folderCount: Int
            var unsortedTotal: Int
            var modelChose: Int
            var belowFloor: Int
            var unmapped: Int
        }

        var metrics: [RunMetrics] = []
        let organizer = Organizer()

        for i in 1...runs {
            FileHandle.standardError.write(Data("Run \(i)/\(runs)...\n".utf8))
            let opts = Organizer.Options(
                taxonomyMode: .fresh,
                classifier: .init(initialBatchSize: batchSize, confidenceFloor: confidenceFloor),
                clustering: clusteringConfig,
                embedderPreference: embedderPref
            )
            let result = try await organizer.organize(html: html, options: opts)
            let total = result.bookmarks.count
            let placed = result.bookmarks.filter { ($0.assignedFolder ?? Taxonomy.unsorted) != Taxonomy.unsorted }.count
            let causes = result.unsortedCauses
            metrics.append(RunMetrics(
                sortRate: total > 0 ? Double(placed) / Double(total) * 100 : 0,
                folderCount: result.taxonomy.folders.count,
                unsortedTotal: total - placed,
                modelChose: causes.modelChoseUnsorted,
                belowFloor: causes.belowFloor,
                unmapped: causes.unmapped
            ))
        }

        func stats(_ values: [Double]) -> (mean: Double, stddev: Double, min: Double, max: Double) {
            guard !values.isEmpty else { return (0, 0, 0, 0) }
            let mean = values.reduce(0, +) / Double(values.count)
            let variance = values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)
            let stddev = sqrt(variance)
            return (mean, stddev, values.min()!, values.max()!)
        }

        let sortRates = metrics.map(\.sortRate)
        let folderCounts = metrics.map { Double($0.folderCount) }
        let unsortedTotals = metrics.map { Double($0.unsortedTotal) }
        let modelChoses = metrics.map { Double($0.modelChose) }
        let belowFloors = metrics.map { Double($0.belowFloor) }
        let unmappeds = metrics.map { Double($0.unmapped) }

        let s1 = stats(sortRates)
        let s2 = stats(folderCounts)
        let s3 = stats(unsortedTotals)
        let s4 = stats(modelChoses)
        let s5 = stats(belowFloors)
        let s6 = stats(unmappeds)

        let bookmarkCount = metrics.first.map { m -> Int in
            guard m.sortRate < 100 else { return m.unsortedTotal }
            return Int(round(Double(m.unsortedTotal) / (1.0 - m.sortRate / 100.0)))
        } ?? 0

        print("lazybm eval: \(runs) runs on \(input) (\(bookmarkCount) bookmarks)")
        print("")
        print(String(format: "%-20s%-10s%-10s%-10s%-10s%-10s", "Metric", "Mean", "StdDev", "Min", "Max", "Range"))
        print(String(repeating: "\u{2500}", count: 65))

        func row(_ label: String, _ s: (mean: Double, stddev: Double, min: Double, max: Double), decimal: Bool = true) {
            let fmt = decimal ? "%.1f" : "%.0f"
            let range = s.max - s.min
            print(String(format: "%-20s" + fmt + "%-10s" + fmt + "%-10s" + fmt + "%-10s" + fmt + "%-10s" + fmt + "%-10s",
                         label,
                         s.mean, "",
                         s.stddev, "",
                         s.min, "",
                         s.max, "",
                         range, ""))
        }

        func intRow(_ label: String, _ s: (mean: Double, stddev: Double, min: Double, max: Double)) {
            let range = s.max - s.min
            print(String(format: "%-20s%-10.0f%-10.1f%-10.0f%-10.0f%-10.0f",
                         label, s.mean, s.stddev, s.min, s.max, range))
        }

        row("Sort rate (%)", s1)
        intRow("Folder count", s2)
        intRow("Unsorted total", s3)
        intRow("  model-chose", s4)
        intRow("  below-floor", s5)
        intRow("  unmapped", s6)
    }
}
