import Foundation
import XCTest
@testable import Clearance

@MainActor
final class MarginNoteStoreTests: XCTestCase {
    func testNotesAreStoredPerDocumentAndCanBeEditedAndDeleted() throws {
        let store = MarginNoteStore(inMemory: true)
        let firstURL = URL(fileURLWithPath: "/tmp/first.md")
        let secondURL = URL(fileURLWithPath: "/tmp/second.md")

        let created = try XCTUnwrap(store.addNote(
            documentURL: firstURL,
            quote: "cumulative rewards",
            prefix: "max ",
            suffix: " over time",
            text: "Meaning total sum"
        ))

        XCTAssertEqual(store.notes(for: firstURL), [created])
        XCTAssertTrue(store.notes(for: secondURL).isEmpty)

        store.updateNote(id: created.id, text: "Updated explanation")
        XCTAssertEqual(store.notes(for: firstURL).first?.text, "Updated explanation")

        store.deleteNote(id: created.id)
        XCTAssertTrue(store.notes(for: firstURL).isEmpty)
    }

    func testEmptyQuoteOrNoteIsNotStored() {
        let store = MarginNoteStore(inMemory: true)
        let documentURL = URL(fileURLWithPath: "/tmp/notes.md")

        XCTAssertNil(store.addNote(
            documentURL: documentURL,
            quote: "   ",
            prefix: "",
            suffix: "",
            text: "Note"
        ))
        XCTAssertNil(store.addNote(
            documentURL: documentURL,
            quote: "Selection",
            prefix: "",
            suffix: "",
            text: "  "
        ))
        XCTAssertTrue(store.notes(for: documentURL).isEmpty)
    }
}
