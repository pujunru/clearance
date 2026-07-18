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
