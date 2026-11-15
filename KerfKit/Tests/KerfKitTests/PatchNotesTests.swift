import Foundation
import Testing
@testable import KerfKit

struct PatchNotesTests {
    private static let note = #"""
    {"symbol":"sparkles","by":"JJWindt","title":{"en":"Merged pull requests","nl":"Gemergede pull requests"},"text":{"en":"Yours stay a while.","nl":"Die van jou blijven even staan."}}
    """#

    @Test func readsANote() throws {
        let note = try #require(PatchNote.parse(fileName: "2026-11-12-merged-pulls.json", data: Data(Self.note.utf8)))
        #expect(note.id == "2026-11-12-merged-pulls")
        #expect(note.title(in: "nl") == "Gemergede pull requests")
        #expect(note.text(in: "en") == "Yours stay a while.")
        #expect(note.symbol == "sparkles")
        #expect(note.by == "JJWindt")
    }

    @Test func anotherLanguageFallsBackToEnglish() throws {
        let note = try #require(PatchNote.parse(fileName: "2026-11-12-merged-pulls.json", data: Data(Self.note.utf8)))
        #expect(note.title(in: "de") == "Merged pull requests")
    }

    @Test func onlyDatedJSONWithEnglishCounts() {
        #expect(PatchNote.id(fileName: "WhatsNew/2026-11-15-whats-new.json") == "2026-11-15-whats-new")
        #expect(PatchNote.id(fileName: "README.md") == nil)
        #expect(PatchNote.id(fileName: "whats-new.json") == nil)
        #expect(PatchNote.id(fileName: "2026-11-15-Whats New.json") == nil)
        let dutchOnly = #"{"title":{"nl":"Nieuw"},"text":{"nl":"Iets"}}"#
        #expect(PatchNote.parse(fileName: "2026-11-15-x.json", data: Data(dutchOnly.utf8)) == nil)
        #expect(PatchNote.parse(fileName: "2026-11-15-x.json", data: Data("not json".utf8)) == nil)
    }

    @Test func newestFirst() {
        let notes = ["2026-11-12-b", "2026-11-15-a", "2026-11-13-c"].map { PatchNote(id: $0, title: [:], text: [:]) }
        #expect(PatchNote.newestFirst(notes).map(\.id) == ["2026-11-15-a", "2026-11-13-c", "2026-11-12-b"])
    }

    @Test func anUpdateIsTheNotesThisBuildLacks() {
        let listing = "WhatsNew/2026-11-12-merged-pulls.json\nWhatsNew/2026-11-16-timers.json\nWhatsNew/README.md\nWhatsNew/2026-11-17-mixer.json\n"
        #expect(PatchNoteUpdate.newFiles(listing: listing, installed: ["2026-11-12-merged-pulls"])
            == ["WhatsNew/2026-11-17-mixer.json", "WhatsNew/2026-11-16-timers.json"])
        #expect(PatchNoteUpdate.newFiles(listing: listing, installed: ["2026-11-12-merged-pulls", "2026-11-16-timers", "2026-11-17-mixer"]).isEmpty)
        #expect(PatchNoteUpdate.newFiles(listing: "", installed: []).isEmpty)
    }
}
