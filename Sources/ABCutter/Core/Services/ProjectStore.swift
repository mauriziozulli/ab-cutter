import Foundation

/// Reads and writes `.abcut` project files. These are plain JSON holding file
/// paths and sync decisions — no media is ever copied into them.
enum ProjectStore {
    static let fileExtension = "abcut"

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    static func save(_ project: ABProject, to url: URL) throws {
        let data = try encoder.encode(ProjectDocument(version: 1, project: project))
        try data.write(to: url, options: .atomic)
    }

    static func load(from url: URL) throws -> ABProject {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(ProjectDocument.self, from: data).project
    }

    private struct ProjectDocument: Codable {
        var version: Int
        var project: ABProject
    }
}
