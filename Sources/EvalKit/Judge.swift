import Foundation
import LazyBookmarksKit

public struct LocalLLMJudge: Sendable {
    public var baseURL: String
    public var model: String

    public init(baseURL: String = "http://localhost:1234/v1", model: String = "qwen") {
        self.baseURL = baseURL
        self.model = model
    }

    public func judge(title: String, domain: String, folder: String) async throws -> Verdict {
        let prompt = """
        You are a bookmark categorization judge. Given a bookmark title, domain, and assigned folder, \
        determine if the placement is correct. Respond with exactly "accept" or "reject".

        Title: \(title)
        Domain: \(domain)
        Folder: \(folder)

        Is this bookmark correctly placed in this folder?
        """

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "user", "content": prompt]
            ],
            "temperature": 0,
            "max_tokens": 10
        ]

        let url = URL(string: "\(baseURL)/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw JudgeError.invalidResponse
        }

        let trimmed = content.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("accept") { return .accept }
        if trimmed.contains("reject") { return .reject }
        throw JudgeError.ambiguousResponse(content)
    }

    public func judgeAll(
        decisions: [Classifier.Decision],
        bookmarks: [Bookmark],
        progress: ((Int, Int) -> Void)? = nil
    ) async throws -> [Label] {
        let bookmarkMap = Dictionary(uniqueKeysWithValues: bookmarks.map { ($0.id, $0) })
        var labels: [Label] = []

        for (i, d) in decisions.enumerated() where d.folder != Taxonomy.unsorted {
            guard let b = bookmarkMap[d.bookmarkID] else { continue }
            do {
                let verdict = try await judge(title: b.title, domain: b.domain, folder: d.folder)
                labels.append(Label(
                    bookmarkID: d.bookmarkID,
                    folder: d.folder,
                    verdict: verdict,
                    source: "judge-local"
                ))
            } catch {
                continue
            }
            progress?(i + 1, decisions.count)
        }

        return labels
    }
}

public func cohensKappa(
    human: [LabelKey: Label],
    judge: [LabelKey: Label]
) -> (kappa: Double, agreement: Double, sharedKeys: Int) {
    let shared = human.keys.filter { judge[$0] != nil }
    guard !shared.isEmpty else { return (0, 0, 0) }

    var agree = 0
    var humanAccept = 0, humanReject = 0
    var judgeAccept = 0, judgeReject = 0

    for key in shared {
        let h = human[key]!.verdict
        let j = judge[key]!.verdict
        if h == j { agree += 1 }
        if h == .accept { humanAccept += 1 } else { humanReject += 1 }
        if j == .accept { judgeAccept += 1 } else { judgeReject += 1 }
    }

    let n = Double(shared.count)
    let po = Double(agree) / n

    let pe = (Double(humanAccept) / n * Double(judgeAccept) / n) +
             (Double(humanReject) / n * Double(judgeReject) / n)

    guard pe < 1.0 else { return (1.0, po, shared.count) }
    let kappa = (po - pe) / (1.0 - pe)

    return (kappa, po, shared.count)
}

public enum JudgeError: Error, Sendable {
    case invalidResponse
    case ambiguousResponse(String)
}
