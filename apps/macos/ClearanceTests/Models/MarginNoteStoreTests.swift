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

    func testSharePayloadIncludesExactSourceCoordinatesAndAnchorContext() throws {
        let markdown = """
        # Plan

        The agent should review this paragraph carefully.
        """
        let note = MarginNote(
            id: UUID(uuidString: "3DC1AF59-8441-45A7-A2D5-E271EA58A282")!,
            documentKey: "file:///tmp/plan.md",
            quote: "review this paragraph",
            prefix: "The agent should ",
            suffix: " carefully.",
            text: "What outcome should this review produce?",
            createdAt: .distantPast,
            updatedAt: .distantPast
        )

        let payload = MarginNoteShareFormatter.makePayload(
            documentURL: URL(fileURLWithPath: "/tmp/plan.md"),
            markdown: markdown,
            notes: [note]
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(payload.data(using: .utf8))) as? [String: Any])
        let comments = try XCTUnwrap(json["comments"] as? [[String: Any]])
        let comment = try XCTUnwrap(comments.first)
        let range = try XCTUnwrap(comment["source_range"] as? [String: Any])
        let start = try XCTUnwrap(range["start"] as? [String: Any])
        let end = try XCTUnwrap(range["end"] as? [String: Any])
        let anchor = try XCTUnwrap(comment["anchor"] as? [String: Any])

        XCTAssertEqual(json["format"] as? String, "clearance.agent-comments.v1")
        XCTAssertEqual(range["resolution"] as? String, "rendered-anchor")
        XCTAssertEqual(start["line"] as? Int, 3)
        XCTAssertEqual(start["column"] as? Int, 18)
        XCTAssertEqual(end["line"] as? Int, 3)
        XCTAssertEqual(end["column"] as? Int, 39)
        XCTAssertEqual(anchor["selected_text"] as? String, "review this paragraph")
        XCTAssertEqual(anchor["before"] as? String, "The agent should ")
        XCTAssertEqual(anchor["after"] as? String, " carefully.")
        XCTAssertEqual(comment["comment"] as? String, "What outcome should this review produce?")
    }

    func testSharePayloadLeavesAmbiguousRepeatedQuoteUnresolved() throws {
        let note = MarginNote(
            id: UUID(),
            documentKey: "file:///tmp/repeated.md",
            quote: "same text",
            prefix: "",
            suffix: "",
            text: "Which occurrence?",
            createdAt: .distantPast,
            updatedAt: .distantPast
        )

        let payload = MarginNoteShareFormatter.makePayload(
            documentURL: URL(fileURLWithPath: "/tmp/repeated.md"),
            markdown: "same text\nother\nsame text",
            notes: [note]
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(payload.data(using: .utf8))) as? [String: Any])
        let comments = try XCTUnwrap(json["comments"] as? [[String: Any]])

        XCTAssertNil(comments.first?["source_range"])
    }

    func testSharePayloadMapsRenderedMarkdownSelectionBackToRawSourceCoordinates() throws {
        let markdown = """
        ## Existing concepts

        - **The CEL filter engine** compiles filters.
        """
        let note = MarginNote(
            id: UUID(),
            documentKey: "file:///tmp/markdown.md",
            quote: "CEL",
            prefix: "Existing concepts\n\nThe ",
            suffix: " filter engine compiles filters.",
            text: "What is this?",
            createdAt: .distantPast,
            updatedAt: .distantPast
        )

        let payload = MarginNoteShareFormatter.makePayload(
            documentURL: URL(fileURLWithPath: "/tmp/markdown.md"),
            markdown: markdown,
            notes: [note]
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(payload.data(using: .utf8))) as? [String: Any])
        let comment = try XCTUnwrap((json["comments"] as? [[String: Any]])?.first)
        let range = try XCTUnwrap(comment["source_range"] as? [String: Any])
        let start = try XCTUnwrap(range["start"] as? [String: Any])
        let end = try XCTUnwrap(range["end"] as? [String: Any])

        XCTAssertEqual(range["resolution"] as? String, "rendered-anchor")
        XCTAssertEqual(start["line"] as? Int, 3)
        XCTAssertEqual(start["column"] as? Int, 9)
        XCTAssertEqual(end["line"] as? Int, 3)
        XCTAssertEqual(end["column"] as? Int, 12)
    }

    func testSharePayloadToleratesRenderedWhitespaceDifferencesWhenContextIsUnique() throws {
        let markdown = """
        ### Existing concepts

        - **The CEL filter engine** compiles a filter string.
        - Another CEL example appears elsewhere.
        """
        let note = MarginNote(
            id: UUID(),
            documentKey: "file:///tmp/markdown.md",
            quote: "CEL",
            prefix: "Existing concepts\n The ",
            suffix: " filter engine compiles a filter string.",
            text: "What is this?",
            createdAt: .distantPast,
            updatedAt: .distantPast
        )

        let payload = MarginNoteShareFormatter.makePayload(
            documentURL: URL(fileURLWithPath: "/tmp/markdown.md"),
            markdown: markdown,
            notes: [note]
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(payload.data(using: .utf8))) as? [String: Any])
        let comment = try XCTUnwrap((json["comments"] as? [[String: Any]])?.first)
        let range = try XCTUnwrap(comment["source_range"] as? [String: Any])

        XCTAssertEqual(range["resolution"] as? String, "rendered-context")
    }
}
