import Foundation

/// A card made from a note (Put on Board, on the Mac and the iPhone): the note's title, and in its details the note's
/// first lines and a binders:// link back to it.
public enum NoteCards {
    /// How many of the note's lines, and how much of them, go into the card's details.
    public static let excerptLines = 6
    public static let excerptCharacters = 500

    /// binders://note/<id>: opens the note in its binder, on the Mac (and on the iPhone, from a card's details).
    public static func link(noteID: String) -> String {
        "binders://note/\(noteID)"
    }

    /// The note a binders://note link opens, or nil when it isn't one.
    public static func noteID(in url: URL) -> UUID? {
        guard url.scheme?.lowercased() == "binders", url.host?.lowercased() == "note" else { return nil }
        let id = url.pathComponents.first { $0 != "/" }
            ?? URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "id" }?.value
        return id.flatMap(UUID.init(uuidString:))
    }

    /// The card's title: the note's, or "Untitled note".
    public static func title(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled note" : String(trimmed.prefix(120))
    }

    /// The card's details: the lines after the note's title (at most `excerptLines`, about `excerptCharacters`), then the
    /// link back. A note with an agent's words in it that you haven't made yours gives only the link, and says why: what
    /// an agent wrote never becomes a card's brief without you reading it.
    public static func details(text: String, noteID: String, agent: AgentMark = AgentMark()) -> String {
        let back = "From the note: [open it](\(link(noteID: noteID)))"
        if let label = agent.label {
            return "\(label). Its words aren't copied onto the card; open the note to read them.\n\n\(back)"
        }
        let excerpt = self.excerpt(text)
        return excerpt.isEmpty ? back : "\(excerpt)\n\n\(back)"
    }

    /// The note's first lines after its title, without the blank ones around them.
    public static func excerpt(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        // The title is the first line with anything on it.
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        if !lines.isEmpty { lines.removeFirst() }
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        var kept = Array(lines.prefix(excerptLines))
        while let last = kept.last, last.trimmingCharacters(in: .whitespaces).isEmpty { kept.removeLast() }
        var excerpt = kept.joined(separator: "\n")
        var cut = lines.count > kept.count && lines.dropFirst(kept.count).contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if excerpt.count > excerptCharacters {
            // At a word, so nothing ends half-way through one.
            let head = excerpt.prefix(excerptCharacters)
            excerpt = String(head.lastIndex(where: \.isWhitespace).map { head[..<$0] } ?? head)
            cut = true
        }
        excerpt = excerpt.trimmingCharacters(in: .whitespacesAndNewlines)
        return cut && !excerpt.isEmpty ? excerpt + " …" : excerpt
    }
}
