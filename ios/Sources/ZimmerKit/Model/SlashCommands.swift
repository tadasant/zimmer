import Foundation

/// One entry of the composer's "/" typeahead: a skill a person may invoke by name, as the web
/// composer's `slash_command_controller.js` offers them.
///
/// The web composer reads the skills and commands found in the session's clone
/// (`ClaudeSkillsCacheService`), which no API route returns. What the app's token can read is
/// the skills catalog (`GET /api/v1/skills`), so the app offers the session's own catalog skills
/// that a person may invoke — what the web's new-session form offers, for the skills chosen.
public struct SlashCommand: Hashable, Sendable, Identifiable {
    public var name: String
    public var description: String?

    public var id: String { name }

    public init(name: String, description: String? = nil) {
        self.name = name
        self.description = description
    }

    /// How many the list shows at once, as the web's dropdown does; the rest are "+N more".
    public static let shownLimit = 10

    /// What `session` can invoke: the catalog skills chosen for it that a person may invoke
    /// (`user_invocable`), in the catalog's order. A session stores a skill by its id or name.
    public static func available(in skills: [CatalogItem], for session: SessionSummary) -> [SlashCommand] {
        let chosen = Set(session.catalogSkills ?? [])
        return skills.compactMap { item in
            let name = item.name ?? item.id
            guard item.userInvocable == true, chosen.contains(item.id) || chosen.contains(name) else { return nil }
            return SlashCommand(name: name, description: item.description)
        }
    }

    /// What follows a "/" being typed at the end of `draft`, or nil when none is. The web's
    /// rule: the "/" starts a line or follows a space, and nothing typed since it is a space.
    /// The web reads back from the cursor; the app reads back from the end of the draft.
    public static func query(in draft: String) -> String? {
        guard let slash = draft.lastIndex(where: { $0 == "/" || $0.isWhitespace }), draft[slash] == "/" else { return nil }
        if slash > draft.startIndex, !draft[draft.index(before: slash)].isWhitespace { return nil }
        return String(draft[draft.index(after: slash)...])
    }

    /// `commands` matching `query`, as the web filters them: the name or the description
    /// contains it, ignoring case. With a query, names that start with it come first, then
    /// shorter names, then alphabetical; with none, the list as it is.
    public static func matches(_ query: String, in commands: [SlashCommand]) -> [SlashCommand] {
        let needle = query.lowercased()
        guard !needle.isEmpty else { return commands }
        let found = commands.filter { "\($0.name) \($0.description ?? "")".lowercased().contains(needle) }
        return found.sorted { a, b in
            let aPrefix = a.name.lowercased().hasPrefix(needle)
            let bPrefix = b.name.lowercased().hasPrefix(needle)
            if aPrefix != bPrefix { return aPrefix }
            if a.name.count != b.name.count { return a.name.count < b.name.count }
            return a.name.lowercased() < b.name.lowercased()
        }
    }

    /// `draft` with the "/" being typed, and what follows it, replaced by the command and a
    /// space, as the web inserts it.
    public static func inserting(_ command: SlashCommand, into draft: String) -> String {
        guard let query = query(in: draft) else { return draft }
        return String(draft.dropLast(query.count + 1)) + "/\(command.name) "
    }
}
