import Foundation
import FoundationModels

// MARK: - Phase 1: taxonomy generation (compile-time Generable)

@Generable
public struct GeneratedTaxonomy {
    @Guide(description: "Between 8 and 20 broad, non-overlapping topic folders.")
    public var folders: [GeneratedFolder]
}

@Generable
public struct GeneratedFolder {
    @Guide(description: "Short Title Case folder name, 1 to 3 words.")
    public var name: String
    @Guide(description: "One short sentence describing what belongs in this folder.")
    public var rationale: String
}

// MARK: - Phase 3: classification (runtime-constrained decoding)

public enum ConstrainedClassificationSchema {
    public static func make(allowedFolders: [String]) throws -> GenerationSchema {
        guard !allowedFolders.isEmpty else {
            throw SchemaError.emptyFolderSet
        }
        let folderList = allowedFolders.joined(separator: ", ")

        let idProp = DynamicGenerationSchema.Property(
            name: "id", description: "The item id exactly as given.",
            schema: DynamicGenerationSchema(type: String.self))
        let folderProp = DynamicGenerationSchema.Property(
            name: "folder", description: "Choose exactly one folder name from this list: \(folderList). Do not invent new names.",
            schema: DynamicGenerationSchema(type: String.self))
        let confProp = DynamicGenerationSchema.Property(
            name: "confidence", description: "Confidence 0-100.",
            schema: DynamicGenerationSchema(type: Int.self))

        let assignment = DynamicGenerationSchema(
            name: "Assignment",
            description: "A single bookmark classification.",
            properties: [idProp, folderProp, confProp])

        let root = DynamicGenerationSchema(
            name: "BatchResult",
            description: "Classification results for a batch.",
            properties: [
                .init(name: "assignments",
                      description: "One assignment per item.",
                      schema: DynamicGenerationSchema(arrayOf: assignment))
            ])

        return try GenerationSchema(root: root, dependencies: [])
    }

    public enum SchemaError: Error, Sendable {
        case emptyFolderSet
    }
}
