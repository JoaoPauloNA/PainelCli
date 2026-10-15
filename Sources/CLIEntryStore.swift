import Foundation

struct CLIEntry: Codable, Equatable, Identifiable {
    let id: UUID
    let provider: String
    let ordinal: Int

    var displayName: String { "\(provider) \(ordinal)" }
    var statusText: String { "Registro local · CLI não instalada pelo PainelCli" }
}

struct CLIEntryStore {
    private let fileManager: FileManager
    let fileURL: URL

    init(applicationSupportDirectory: URL, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.fileURL = applicationSupportDirectory
            .appendingPathComponent("PainelCli", isDirectory: true)
            .appendingPathComponent("cli-entries.json", isDirectory: false)
    }

    static func userStore(fileManager: FileManager = .default) throws -> CLIEntryStore {
        let supportDirectory = try fileManager.url(for: .applicationSupportDirectory,
                                                   in: .userDomainMask,
                                                   appropriateFor: nil,
                                                   create: true)
        return CLIEntryStore(applicationSupportDirectory: supportDirectory, fileManager: fileManager)
    }

    func load() throws -> [CLIEntry] {
        try loadDocument().entries
    }

    private func loadDocument() throws -> StoreDocument {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return StoreDocument(entries: [], highestOrdinals: [:])
        }
        let data = try Data(contentsOf: fileURL)
        if let topLevel = try? JSONSerialization.jsonObject(with: data), topLevel is [Any] {
            let entries = try JSONDecoder().decode([CLIEntry].self, from: data)
            try Self.validate(entries)
            return StoreDocument(entries: entries,
                                 highestOrdinals: Dictionary(grouping: entries, by: \.provider)
                                    .mapValues { $0.map(\.ordinal).max() ?? 0 })
        }
        let document = try JSONDecoder().decode(StoreDocument.self, from: data)
        try Self.validate(document.entries)
        for (provider, highest) in document.highestOrdinals {
            guard !provider.isEmpty, highest >= (document.entries.filter { $0.provider == provider }.map(\.ordinal).max() ?? 0) else {
                throw StoreError.invalidEntries
            }
        }
        return document
    }

    @discardableResult
    func add(provider: String) throws -> [CLIEntry] {
        let document = try loadDocument()
        let existing = document.entries
        let lastOrdinal = max(document.highestOrdinals[provider] ?? 0,
                              existing.filter { $0.provider == provider }.map(\.ordinal).max() ?? 0)
        guard lastOrdinal < Int.max else { throw StoreError.invalidEntries }
        let nextOrdinal = lastOrdinal + 1
        var updated = existing
        updated.append(CLIEntry(id: UUID(), provider: provider, ordinal: nextOrdinal))
        var highestOrdinals = document.highestOrdinals
        highestOrdinals[provider] = nextOrdinal
        try save(StoreDocument(entries: updated, highestOrdinals: highestOrdinals))
        return updated
    }

    @discardableResult
    func remove(id: UUID) throws -> [CLIEntry] {
        var document = try loadDocument()
        var updated = document.entries
        guard let index = updated.firstIndex(where: { $0.id == id }) else {
            throw StoreError.entryNotFound
        }
        updated.remove(at: index)
        document.entries = updated
        try save(document)
        return updated
    }

    private func save(_ document: StoreDocument) throws {
        try Self.validate(document.entries)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    private static func validate(_ entries: [CLIEntry]) throws {
        var ids = Set<UUID>()
        var providerOrdinals = Set<String>()
        for entry in entries {
            guard !entry.provider.isEmpty, entry.ordinal > 0,
                  ids.insert(entry.id).inserted,
                  providerOrdinals.insert("\(entry.provider)\u{0}\(entry.ordinal)").inserted else {
                throw StoreError.invalidEntries
            }
        }
    }

    enum StoreError: Error {
        case invalidEntries
        case entryNotFound
    }

    private struct StoreDocument: Codable {
        var entries: [CLIEntry]
        var highestOrdinals: [String: Int]
    }
}
