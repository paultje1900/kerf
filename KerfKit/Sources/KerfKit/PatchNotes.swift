import Foundation

/// One change people notice, from a file in the repository's `WhatsNew` folder. Every pull request
/// that changes what Kerf does adds one, so everyone sees what's new after an update, and who made it.
///
///     WhatsNew/2026-11-15-whats-new.json
///     { "symbol": "sparkles", "by": "paultje1900",
///       "title": { "en": "What's new", "nl": "Wat is er nieuw" },
///       "text": { "en": "…", "nl": "…" } }
public struct PatchNote: Equatable, Sendable, Identifiable {
    /// The file's name without `.json`: the date it was written, then a few words.
    public let id: String
    public let title: [String: String]
    public let text: [String: String]
    /// An SF Symbol.
    public let symbol: String?
    /// Who made it: a GitHub login.
    public let by: String?

    public init(id: String, title: [String: String], text: [String: String], symbol: String? = nil, by: String? = nil) {
        self.id = id
        self.title = title
        self.text = text
        self.symbol = symbol
        self.by = by
    }

    /// The language asked for, else English.
    public func title(in language: String) -> String { title[language] ?? title["en"] ?? "" }
    public func text(in language: String) -> String { text[language] ?? text["en"] ?? "" }

    private struct File: Decodable {
        let title: [String: String]
        let text: [String: String]
        let symbol: String?
        let by: String?
    }

    /// Nil for a name without a date in front, or a file without an English title and text.
    public static func parse(fileName: String, data: Data) -> PatchNote? {
        guard let id = id(fileName: fileName),
              let file = try? JSONDecoder().decode(File.self, from: data),
              file.title["en"]?.isEmpty == false, file.text["en"]?.isEmpty == false else { return nil }
        return PatchNote(id: id, title: file.title, text: file.text, symbol: file.symbol, by: file.by)
    }

    /// `2026-11-15-whats-new.json` → `2026-11-15-whats-new`; nil for anything else (the folder's README).
    public static func id(fileName: String) -> String? {
        let name = (fileName as NSString).lastPathComponent
        guard name.hasSuffix(".json") else { return nil }
        let id = String(name.dropLast(5))
        guard id.wholeMatch(of: /\d{4}-\d{2}-\d{2}-[a-z0-9-]+/) != nil else { return nil }
        return id
    }

    /// Newest first: the ids start with their date.
    public static func newestFirst(_ notes: [PatchNote]) -> [PatchNote] {
        notes.sorted { $0.id > $1.id }
    }
}

/// What a newer Kerf in the repository brings, from `git ls-tree --name-only <commit> WhatsNew/`.
public enum PatchNoteUpdate {
    /// The note files there that this build doesn't have: an update is ready when there are any.
    public static func newFiles(listing: String, installed: Set<String>) -> [String] {
        listing.split(whereSeparator: \.isNewline).map(String.init)
            .filter { path in PatchNote.id(fileName: path).map { !installed.contains($0) } ?? false }
            .sorted(by: >)
    }
}
