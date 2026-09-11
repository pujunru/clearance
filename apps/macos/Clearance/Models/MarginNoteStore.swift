import CoreData
import Foundation

struct MarginNote: Identifiable, Codable, Equatable {
    let id: UUID
    let documentKey: String
    let quote: String
    let prefix: String
    let suffix: String
    var text: String
    let createdAt: Date
    var updatedAt: Date
}

/// A stable, machine-readable representation of margin comments that can be pasted into an agent.
///
/// Source ranges use 1-based line and column numbers with an exclusive end position. UTF-16
/// offsets are included because they line up with AppKit, WebKit, and most editor APIs.
enum MarginNoteShareFormatter {
    private struct Payload: Encodable {
        let format = "clearance.agent-comments.v1"
        let documentURL: String
        let comments: [Comment]

        enum CodingKeys: String, CodingKey {
            case format
            case documentURL = "document_url"
            case comments
        }
    }

    private struct Comment: Encodable {
        let id: String
        let sourceRange: SourceRange?
        let anchor: Anchor
        let comment: String

        enum CodingKeys: String, CodingKey {
            case id
            case sourceRange = "source_range"
            case anchor
            case comment
        }
    }

    private struct SourceRange: Encodable {
        let start: Position
        let end: Position
        let resolution: String
    }

    private struct Position: Encodable {
        let line: Int
        let column: Int
        let utf16Offset: Int

        enum CodingKeys: String, CodingKey {
            case line, column
            case utf16Offset = "utf16_offset"
        }
    }

    private struct Anchor: Encodable {
        let selectedText: String
        let before: String
        let after: String

        enum CodingKeys: String, CodingKey {
            case selectedText = "selected_text"
            case before, after
        }
    }

    static func makePayload(documentURL: URL, markdown: String, notes: [MarginNote]) -> String {
        let payload = Payload(
            documentURL: documentURL.absoluteString,
            comments: notes.map { note in
                Comment(
                    id: note.id.uuidString,
                    sourceRange: sourceRange(for: note, in: markdown),
                    anchor: Anchor(
                        selectedText: note.quote,
                        before: note.prefix,
                        after: note.suffix
                    ),
                    comment: note.text
                )
            }
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(payload),
              let json = String(data: data, encoding: .utf8) else {
            return "{\"format\":\"clearance.agent-comments.v1\",\"comments\":[]}"
        }
        return json
    }

    private static func sourceRange(for note: MarginNote, in markdown: String) -> SourceRange? {
        let projection = RenderedTextProjection(markdown: markdown)
        let projectedCandidates = ranges(of: note.quote, in: projection.text)
        let contextualProjectedCandidates = projectedCandidates.filter { range in
            let before = String(projection.text[..<range.lowerBound])
            let after = String(projection.text[range.upperBound...])
            return (note.prefix.isEmpty || before.hasSuffix(note.prefix)) &&
                (note.suffix.isEmpty || after.hasPrefix(note.suffix))
        }

        if contextualProjectedCandidates.count == 1,
           let range = contextualProjectedCandidates.first,
           let sourceRange = projection.sourceRange(for: range) {
            return SourceRange(
                start: position(for: sourceRange.lowerBound, in: markdown),
                end: position(for: sourceRange.upperBound, in: markdown),
                resolution: "rendered-anchor"
            )
        }

        if let range = bestContextualProjectionMatch(
            among: projectedCandidates,
            projection: projection,
            note: note
        ), let sourceRange = projection.sourceRange(for: range) {
            return SourceRange(
                start: position(for: sourceRange.lowerBound, in: markdown),
                end: position(for: sourceRange.upperBound, in: markdown),
                resolution: "rendered-context"
            )
        }

        let candidates = ranges(of: note.quote, in: markdown)
        guard !candidates.isEmpty else {
            return nil
        }

        let contextualCandidates = candidates.filter { range in
            let before = String(markdown[..<range.lowerBound])
            let after = String(markdown[range.upperBound...])
            return (note.prefix.isEmpty || before.hasSuffix(note.prefix)) &&
                (note.suffix.isEmpty || after.hasPrefix(note.suffix))
        }

        let selectedRange: Range<String.Index>
        let resolution: String
        if contextualCandidates.count == 1, let match = contextualCandidates.first {
            selectedRange = match
            resolution = "exact-anchor"
        } else if candidates.count == 1, let match = candidates.first {
            selectedRange = match
            resolution = "quote-only"
        } else {
            // A location that looks precise but points at the wrong repeated phrase is worse
            // than an explicit unresolved anchor. The quote and surrounding context remain in
            // the payload for an agent to locate it safely.
            return nil
        }

        return SourceRange(
            start: position(for: selectedRange.lowerBound, in: markdown),
            end: position(for: selectedRange.upperBound, in: markdown),
            resolution: resolution
        )
    }

    private static func ranges(of quote: String, in markdown: String) -> [Range<String.Index>] {
        guard !quote.isEmpty else {
            return []
        }

        var results: [Range<String.Index>] = []
        var searchStart = markdown.startIndex
        while let range = markdown.range(of: quote, range: searchStart..<markdown.endIndex) {
            results.append(range)
            searchStart = range.upperBound
        }
        return results
    }

    private static func bestContextualProjectionMatch(
        among candidates: [Range<String.Index>],
        projection: RenderedTextProjection,
        note: MarginNote
    ) -> Range<String.Index>? {
        let scored = candidates.map { range in
            let before = String(projection.text[..<range.lowerBound])
            let after = String(projection.text[range.upperBound...])
            return (range, contextScore(before: before, after: after, note: note))
        }.sorted { $0.1 > $1.1 }

        guard let best = scored.first,
              best.1 >= 16 else {
            return nil
        }

        // Only accept a fuzzy match when its surrounding text is decisively better than every
        // other occurrence of the same quote. This preserves the no-guessing guarantee.
        if let runnerUp = scored.dropFirst().first, best.1 - runnerUp.1 < 8 {
            return nil
        }
        return best.0
    }

    private static func contextScore(before: String, after: String, note: MarginNote) -> Int {
        commonSuffixLength(normalizedWhitespace(before), normalizedWhitespace(note.prefix)) +
            commonPrefixLength(normalizedWhitespace(after), normalizedWhitespace(note.suffix))
    }

    private static func normalizedWhitespace(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func commonSuffixLength(_ left: String, _ right: String) -> Int {
        let leftCharacters = Array(left)
        let rightCharacters = Array(right)
        var count = 0
        while count < leftCharacters.count,
              count < rightCharacters.count,
              leftCharacters[leftCharacters.count - count - 1] == rightCharacters[rightCharacters.count - count - 1] {
            count += 1
        }
        return count
    }

    private static func commonPrefixLength(_ left: String, _ right: String) -> Int {
        zip(left, right).prefix { $0 == $1 }.count
    }

    private static func position(for index: String.Index, in markdown: String) -> Position {
        let prefix = markdown[..<index]
        let line = prefix.reduce(into: 1) { count, character in
            if character == "\n" {
                count += 1
            }
        }
        let lineStart = prefix.lastIndex(of: "\n").map { markdown.index(after: $0) } ?? markdown.startIndex
        let column = markdown.distance(from: lineStart, to: index) + 1
        let utf16Offset = index.utf16Offset(in: markdown)
        return Position(line: line, column: column, utf16Offset: utf16Offset)
    }

    /// A deliberately small Markdown-to-rendered-text projection. It preserves an index back to
    /// the source for visible characters while dropping syntax that WebKit does not include in a
    /// rendered selection (headings, list markers, emphasis, and inline-code delimiters).
    private struct RenderedTextProjection {
        let text: String
        private let sourceIndices: [String.Index]
        private let markdown: String

        init(markdown: String) {
            self.markdown = markdown
            var characters: [Character] = []
            var indices: [String.Index] = []
            var index = markdown.startIndex
            var isLineStart = true

            func append(_ character: Character, at sourceIndex: String.Index) {
                characters.append(character)
                indices.append(sourceIndex)
            }

            while index < markdown.endIndex {
                if isLineStart, let contentStart = Self.contentStart(afterMarkdownPrefix: markdown, from: index) {
                    index = contentStart
                    isLineStart = false
                    continue
                }

                let character = markdown[index]
                if character == "\n" {
                    append(character, at: index)
                    index = markdown.index(after: index)
                    isLineStart = true
                    continue
                }

                if Self.isInlineDelimiter(at: index, in: markdown) {
                    index = markdown.index(after: index)
                    continue
                }

                append(character, at: index)
                index = markdown.index(after: index)
                isLineStart = false
            }

            text = String(characters)
            sourceIndices = indices
        }

        func sourceRange(for range: Range<String.Index>) -> Range<String.Index>? {
            let startOffset = text.distance(from: text.startIndex, to: range.lowerBound)
            let endOffset = text.distance(from: text.startIndex, to: range.upperBound)
            guard startOffset < sourceIndices.count, endOffset > startOffset else {
                return nil
            }

            let start = sourceIndices[startOffset]
            let finalVisibleCharacter = sourceIndices[endOffset - 1]
            var end = markdown.index(after: finalVisibleCharacter)

            // Include a closing emphasis/code delimiter immediately after the selected text, so a
            // range spanning `last *looked*` ends after the closing `*`, not inside the markup.
            while end < markdown.endIndex, "*_`".contains(markdown[end]) {
                end = markdown.index(after: end)
            }
            return start..<end
        }

        private static func contentStart(afterMarkdownPrefix markdown: String, from index: String.Index) -> String.Index? {
            var cursor = index
            while cursor < markdown.endIndex, markdown[cursor] == " " {
                cursor = markdown.index(after: cursor)
            }

            let headingStart = cursor
            while cursor < markdown.endIndex, markdown[cursor] == "#" {
                cursor = markdown.index(after: cursor)
            }
            if cursor > headingStart, cursor < markdown.endIndex, markdown[cursor] == " " {
                return markdown.index(after: cursor)
            }

            cursor = index
            while cursor < markdown.endIndex, markdown[cursor] == " " {
                cursor = markdown.index(after: cursor)
            }
            if cursor < markdown.endIndex, "-*+".contains(markdown[cursor]) {
                let afterMarker = markdown.index(after: cursor)
                if afterMarker < markdown.endIndex, markdown[afterMarker] == " " {
                    return markdown.index(after: afterMarker)
                }
            }
            return nil
        }

        private static func isInlineDelimiter(at index: String.Index, in markdown: String) -> Bool {
            "*_`".contains(markdown[index])
        }
    }
}

@objc(MarginNoteRecord)
private final class MarginNoteRecord: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var documentKey: String
    @NSManaged var quote: String
    @NSManaged var prefix: String
    @NSManaged var suffix: String
    @NSManaged var text: String
    @NSManaged var createdAt: Date
    @NSManaged var updatedAt: Date
}

@MainActor
final class MarginNoteStore: ObservableObject {
    @Published private(set) var revision = 0

    private let container: NSPersistentContainer

    init(inMemory: Bool = false) {
        container = NSPersistentContainer(
            name: "MarginNotes",
            managedObjectModel: Self.makeManagedObjectModel()
        )

        let description: NSPersistentStoreDescription
        if inMemory {
            description = NSPersistentStoreDescription()
            description.type = NSInMemoryStoreType
        } else {
            let applicationSupportURL = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            let databaseDirectoryURL = applicationSupportURL
                .appendingPathComponent("Clearance", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: databaseDirectoryURL,
                withIntermediateDirectories: true
            )
            description = NSPersistentStoreDescription(
                url: databaseDirectoryURL.appendingPathComponent("MarginNotes.sqlite")
            )
            description.type = NSSQLiteStoreType
        }

        description.shouldAddStoreAsynchronously = false
        container.persistentStoreDescriptions = [description]

        var loadingError: Error?
        container.loadPersistentStores { _, error in
            loadingError = error
        }
        if let loadingError {
            assertionFailure("Failed to load margin note database: \(loadingError)")
        }
        container.viewContext.automaticallyMergesChangesFromParent = true
    }

    func notes(for documentURL: URL) -> [MarginNote] {
        let request = NSFetchRequest<MarginNoteRecord>(entityName: "MarginNoteRecord")
        request.predicate = NSPredicate(format: "documentKey == %@", Self.documentKey(for: documentURL))
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
        guard let records = try? container.viewContext.fetch(request) else {
            return []
        }
        var notes: [MarginNote] = []
        for record in records {
            notes.append(Self.note(from: record))
        }
        return notes
    }

    @discardableResult
    func addNote(
        documentURL: URL,
        quote: String,
        prefix: String,
        suffix: String,
        text: String
    ) -> MarginNote? {
        let trimmedQuote = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuote.isEmpty, !trimmedText.isEmpty else {
            return nil
        }

        let now = Date()
        let note = MarginNote(
            id: UUID(),
            documentKey: Self.documentKey(for: documentURL),
            quote: trimmedQuote,
            prefix: prefix,
            suffix: suffix,
            text: trimmedText,
            createdAt: now,
            updatedAt: now
        )
        let record = MarginNoteRecord(context: container.viewContext)
        Self.apply(note, to: record)
        save()
        return note
    }

    func updateNote(id: UUID, text: String) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty,
              let record = record(withID: id) else {
            return
        }
        record.text = trimmedText
        record.updatedAt = Date()
        save()
    }

    func deleteNote(id: UUID) {
        guard let record = record(withID: id) else {
            return
        }
        container.viewContext.delete(record)
        save()
    }

    nonisolated static func documentKey(for documentURL: URL) -> String {
        if documentURL.isFileURL {
            return documentURL.standardizedFileURL.resolvingSymlinksInPath().absoluteString
        }
        return documentURL.absoluteString
    }

    private func record(withID id: UUID) -> MarginNoteRecord? {
        let request = NSFetchRequest<MarginNoteRecord>(entityName: "MarginNoteRecord")
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return try? container.viewContext.fetch(request).first
    }

    private func save() {
        guard container.viewContext.hasChanges else {
            return
        }
        do {
            try container.viewContext.save()
            revision += 1
        } catch {
            assertionFailure("Failed to save margin note: \(error)")
        }
    }

    private static func apply(_ note: MarginNote, to record: MarginNoteRecord) {
        record.id = note.id
        record.documentKey = note.documentKey
        record.quote = note.quote
        record.prefix = note.prefix
        record.suffix = note.suffix
        record.text = note.text
        record.createdAt = note.createdAt
        record.updatedAt = note.updatedAt
    }

    private static func note(from record: MarginNoteRecord) -> MarginNote {
        MarginNote(
            id: record.id,
            documentKey: record.documentKey,
            quote: record.quote,
            prefix: record.prefix,
            suffix: record.suffix,
            text: record.text,
            createdAt: record.createdAt,
            updatedAt: record.updatedAt
        )
    }

    private static func makeManagedObjectModel() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()
        let entity = NSEntityDescription()
        entity.name = "MarginNoteRecord"
        entity.managedObjectClassName = NSStringFromClass(MarginNoteRecord.self)

        entity.properties = [
            attribute("id", type: .UUIDAttributeType, optional: false),
            attribute("documentKey", type: .stringAttributeType, optional: false),
            attribute("quote", type: .stringAttributeType, optional: false),
            attribute("prefix", type: .stringAttributeType, optional: false),
            attribute("suffix", type: .stringAttributeType, optional: false),
            attribute("text", type: .stringAttributeType, optional: false),
            attribute("createdAt", type: .dateAttributeType, optional: false),
            attribute("updatedAt", type: .dateAttributeType, optional: false)
        ]
        entity.uniquenessConstraints = [["id"]]
        model.entities = [entity]
        return model
    }

    private static func attribute(
        _ name: String,
        type: NSAttributeType,
        optional: Bool
    ) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = type
        attribute.isOptional = optional
        return attribute
    }
}
