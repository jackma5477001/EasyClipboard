import CoreData

@MainActor
protocol HistoryRepository: AnyObject {
    func load() throws -> [ClipboardEntry]
    func save(_ entries: [ClipboardEntry]) throws
}

@MainActor
final class PersistenceController: HistoryRepository {
    let container: NSPersistentContainer

    init(root: URL, inMemory: Bool = false) throws {
        container = NSPersistentContainer(name: "EasyClipboard")
        let description = NSPersistentStoreDescription()
        description.shouldMigrateStoreAutomatically = true
        description.shouldInferMappingModelAutomatically = true
        if inMemory {
            description.type = NSInMemoryStoreType
        } else {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            description.url = root.appendingPathComponent("History.sqlite")
        }
        container.persistentStoreDescriptions = [description]
        var failure: Error?
        container.loadPersistentStores { _, error in failure = error }
        if let failure { throw failure }
        container.viewContext.automaticallyMergesChangesFromParent = true
    }

    func load() throws -> [ClipboardEntry] {
        let request = NSFetchRequest<NSManagedObject>(entityName: "Item")
        request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
        return try container.viewContext.fetch(request).compactMap { object in
            guard let data = object.value(forKey: "payload") as? Data else { return nil }
            return try JSONDecoder().decode(ClipboardEntry.self, from: data)
        }
    }

    func save(_ entries: [ClipboardEntry]) throws {
        let context = container.viewContext
        do {
            let existing = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "Item"))
            let ids = Set(entries.map(\.id))
            var byID: [UUID: NSManagedObject] = [:]
            for object in existing {
                if let id = object.value(forKey: "identifier") as? UUID, ids.contains(id) { byID[id] = object }
                else { context.delete(object) }
            }
            for entry in entries {
                let object = byID[entry.id] ?? NSEntityDescription.insertNewObject(forEntityName: "Item", into: context)
                object.setValue(entry.id, forKey: "identifier")
                object.setValue(entry.timestamp, forKey: "timestamp")
                object.setValue(try JSONEncoder().encode(entry), forKey: "payload")
            }
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }
}
