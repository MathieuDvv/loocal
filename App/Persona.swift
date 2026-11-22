import Foundation

/// A named system prompt with an icon. Up to three; the active one replaces the default
/// system prompt for every reply.
struct Persona: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var icon: String
    var prompt: String

    static let limit = 3
    /// Icons offered in the editor. Monochrome SF Symbols that read well at 18 pt.
    static let icons = ["sparkles", "brain.head.profile", "book.closed", "pencil.line", "briefcase", "heart", "leaf", "flame", "moon", "cup.and.saucer", "graduationcap", "theatermasks", "terminal", "globe", "music.note", "camera"]

    private static let key = "personas"

    static func load() -> [Persona] {
        guard let data = UserDefaults.standard.data(forKey: key), let list = try? JSONDecoder().decode([Persona].self, from: data) else { return [] }
        return Array(list.prefix(limit))
    }

    static func save(_ list: [Persona]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(Array(list.prefix(limit))), forKey: key)
    }
}

/// A file attached to the next message.
struct AttachedFile: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let text: String
}
