import Foundation

struct Script: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var title: String
    var body: String
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), title: String, body: String, createdAt: Date = .now, updatedAt: Date? = nil) {
        self.id = id
        self.title = title
        self.body = body
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    /// Trimmed title, or "Untitled" when blank.
    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : trimmed
    }

    /// First non-blank line of the body, trimmed ("" if none).
    var firstLine: String {
        body.split(whereSeparator: \.isNewline)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
    }

    /// Title and body are both whitespace-only.
    var isBlank: Bool {
        title.allSatisfy(\.isWhitespace) && body.allSatisfy(\.isWhitespace)
    }
}
