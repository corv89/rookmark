import Foundation

public enum FolderNameSanitizer {

    public static func sanitize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == " " }.map(String.init).joined()
        let words = s.split(separator: " ")
        guard !words.isEmpty else { return "" }
        let titled = words.map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
        return titled.joined(separator: " ")
    }

    public static func deduplicate(_ folders: [Taxonomy.Folder]) -> [Taxonomy.Folder] {
        var seen: Set<String> = []
        var result: [Taxonomy.Folder] = []
        for f in folders {
            let key = f.name.lowercased()
            guard seen.insert(key).inserted else { continue }
            result.append(f)
        }
        return result
    }
}
