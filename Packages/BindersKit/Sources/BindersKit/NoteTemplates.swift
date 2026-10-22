import Foundation

/// A starting point for a note: Markdown with {{date}}, {{time}}, {{today}} (the date as the day's note is titled, for
/// [[{{today}}]]) and {{binder}} filled in when it's used.
public struct NoteTemplate: Equatable, Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let body: String
    /// The folder a note made from it is filed in, from the top of its binder ("Social posts", "Marketing/Social
    /// posts"), made if it's missing; nil for wherever you are.
    public let folder: String?
    /// A note started from it has Distill on (`NoteProperties.distill`): the Spec template's do.
    public let distill: Bool

    public init(name: String, body: String, folder: String? = nil, distill: Bool = false) {
        self.name = name
        self.body = body
        self.folder = folder.flatMap { FolderTree.components($0).isEmpty ? nil : FolderTree.components($0).joined(separator: FolderTree.separator) }
        self.distill = distill
    }

    /// A template as its file has it: front matter at the top naming a folder (`folder: Social posts`, or
    /// `binders_folder:`) files its notes there, and `binders_distill: true` turns Distill on for the notes it starts;
    /// neither is part of them, and any other front matter stays in the note.
    public static func parse(name: String, file text: String) -> NoteTemplate {
        let parsed = Frontmatter.parse(text)
        let folderKey = parsed.entries.first { ["folder", TeamFiles.folderPathKey].contains($0.key) }?.key
        let distillKey = parsed.entries.first { $0.key == NoteProperties.distillKey }?.key
        guard folderKey != nil || distillKey != nil else { return NoteTemplate(name: name, body: text) }
        let others = parsed.entries.filter { $0.key != folderKey && $0.key != distillKey }.flatMap(\.lines)
        let body = String(parsed.body.drop(while: { $0.isNewline }))
        return NoteTemplate(name: name, body: others.isEmpty ? body : "---\n" + others.joined(separator: "\n") + "\n---\n" + body,
                            folder: folderKey.flatMap { parsed.fields[$0] },
                            distill: NoteProperties.distills(distillKey.flatMap { parsed.fields[$0] }))
    }

    /// One of yours, from its file: as `parse(name:file:)` reads it.
    public init(name: String, file text: String) {
        self = NoteTemplate.parse(name: name, file: text)
    }

    /// What its file holds: the body, with the folder and Distill at the top when it has them.
    public var fileText: String {
        Frontmatter.render(folder.map { [("folder", $0)] } ?? [], extraLines: distill ? [NoteProperties.distillLine] : [], body: body)
    }

    /// A note kept as a template, as its file is written: with the front matter that turns Distill on when the note has it.
    public static func file(body: String, distill: Bool) -> String {
        NoteTemplate(name: "", body: body, distill: distill).fileText
    }

    /// The note it starts, for a day and a binder.
    public func filled(date: Date, binder: String, locale: Locale = .current) -> String {
        let long = date.formatted(Date.FormatStyle(date: .complete, time: .omitted, locale: locale))
        let time = date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale))
        // Local: ISO 8601 alone would give the date in UTC.
        let today = date.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
        return body.replacingOccurrences(of: "{{date}}", with: long)
            .replacingOccurrences(of: "{{time}}", with: time)
            .replacingOccurrences(of: "{{today}}", with: today)
            .replacingOccurrences(of: "{{binder}}", with: binder)
    }

    /// The ones Binders comes with.
    public static let builtIn: [NoteTemplate] = [
        NoteTemplate(name: "1:1", body: """
        # 1:1 · {{date}}

        ## How things are going
        -\u{20}

        ## Updates
        -\u{20}

        ## Blockers
        -\u{20}

        ## Action items
        - [ ]\u{20}
        """),
        NoteTemplate(name: "Project kickoff", body: """
        # Kickoff:\u{20}

        Started {{date}} in {{binder}}.

        ## Goal
        What does done look like?

        ## Scope
        - In:\u{20}
        - Out:\u{20}

        ## People
        -\u{20}

        ## Risks
        -\u{20}

        ## Next steps
        - [ ]\u{20}
        """),
        NoteTemplate(name: "Interview", body: """
        # Interview:\u{20}

        {{date}} · Role:\u{20}

        ## Background
        -\u{20}

        ## Strengths
        -\u{20}

        ## Concerns
        -\u{20}

        ## Their questions
        -\u{20}

        ## Decision
        - [ ] Send feedback
        """),
        NoteTemplate(name: "Reading notes", body: """
        # Reading notes:\u{20}

        Source:\u{20}
        Read {{date}}

        ## Main claim

        ## Key points
        -\u{20}

        ## Evidence and numbers
        -\u{20}

        ## What I think

        ## Open questions
        -\u{20}

        ## To do
        - [ ]\u{20}
        """),
        NoteTemplate(name: "Spec", body: """
        # Spec:\u{20}

        Written {{date}} in {{binder}}. Each section below becomes work items when you Distill this note.

        ## Goal
        What does done look like, and for whom?

        ## Scope
        - In:\u{20}
        - Out:\u{20}

        ## Requirements
        -\u{20}

        ## Design
        -\u{20}

        ## Rollout
        -\u{20}

        ## Open questions
        -\u{20}
        """, distill: true),
        NoteTemplate(name: "Weekly review", body: """
        # Week of {{date}}

        ## What got done
        -\u{20}

        ## What didn't, and why
        -\u{20}

        ## Next week
        - [ ]\u{20}

        ## Notes
        """),
    ]

    /// The "## " headings of a note, in order: its sections, when it follows a template.
    public static func sections(of text: String) -> [String] {
        text.components(separatedBy: "\n").compactMap { line in
            guard line.hasPrefix("## ") else { return nil }
            let heading = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
            return heading.isEmpty ? nil : heading
        }
    }
}
