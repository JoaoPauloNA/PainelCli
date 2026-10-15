import Foundation

enum CLIEntryOrigin: String, Codable {
    case manual
    case automatic
}

struct CLIEntry: Codable, Equatable, Identifiable {
    let id: UUID
    let provider: String
    let ordinal: Int
    var origin: CLIEntryOrigin = .manual
    var detectedPath: String? = nil

    var displayName: String { "\(provider) \(ordinal)" }
    var statusText: String {
        origin == .automatic ? "Encontrada automaticamente" : "Registro manual · CLI ainda não instalada"
    }

    private enum CodingKeys: String, CodingKey { case id, provider, ordinal, origin, detectedPath }

    init(id: UUID, provider: String, ordinal: Int,
         origin: CLIEntryOrigin = .manual, detectedPath: String? = nil) {
        self.id = id
        self.provider = provider
        self.ordinal = ordinal
        self.origin = origin
        self.detectedPath = detectedPath
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        provider = try values.decode(String.self, forKey: .provider)
        ordinal = try values.decode(Int.self, forKey: .ordinal)
        origin = try values.decodeIfPresent(CLIEntryOrigin.self, forKey: .origin) ?? .manual
        detectedPath = try values.decodeIfPresent(String.self, forKey: .detectedPath)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(provider, forKey: .provider)
        try values.encode(ordinal, forKey: .ordinal)
        try values.encode(origin, forKey: .origin)
        try values.encodeIfPresent(detectedPath, forKey: .detectedPath)
    }
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
                                    .mapValues { $0.map(\.ordinal).max() ?? 0 },
                                 hiddenDiscoveries: [])
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
        var document = try loadDocument()
        let existing = document.entries
        if let automaticIndex = existing.firstIndex(where: {
            $0.provider == provider && $0.origin == .automatic
        }) {
            document.entries[automaticIndex].origin = .manual
            document.entries[automaticIndex].detectedPath = nil
            try save(document)
            return document.entries
        }
        let lastOrdinal = max(document.highestOrdinals[provider] ?? 0,
                              existing.filter { $0.provider == provider }.map(\.ordinal).max() ?? 0)
        guard lastOrdinal < Int.max else { throw StoreError.invalidEntries }
        let nextOrdinal = lastOrdinal + 1
        var updated = existing
        updated.append(CLIEntry(id: UUID(), provider: provider, ordinal: nextOrdinal))
        var highestOrdinals = document.highestOrdinals
        highestOrdinals[provider] = nextOrdinal
        try save(StoreDocument(entries: updated, highestOrdinals: highestOrdinals,
                               hiddenDiscoveries: document.hiddenDiscoveries))
        return updated
    }

    @discardableResult
    func reconcile(discoveries: [CLIDetection]) throws -> [CLIEntry] {
        var document = try loadDocument()
        let original = document
        let currentPaths = Set(discoveries.map { Self.normalizedPath($0.discoveryURL.path) })
        let manualProviders = Set(document.entries.filter { $0.origin == .manual }.map(\.provider))

        document.entries.removeAll { entry in
            guard entry.origin == .automatic else { return false }
            guard let path = entry.detectedPath else { return true }
            return !currentPaths.contains(Self.normalizedPath(path)) || manualProviders.contains(entry.provider)
        }

        let existingAutomatic = Set(document.entries.compactMap { entry -> String? in
            guard entry.origin == .automatic, let path = entry.detectedPath else { return nil }
            return "\(entry.provider)\u{0}\(Self.normalizedPath(path))"
        })
        var knownAutomatic = existingAutomatic
        for detection in discoveries.sorted(by: {
            ($0.provider.rawValue, $0.executableURL.path) < ($1.provider.rawValue, $1.executableURL.path)
        }) {
            let path = Self.normalizedPath(detection.discoveryURL.path)
            let key = "\(detection.provider.rawValue)\u{0}\(path)"
            guard !manualProviders.contains(detection.provider.rawValue),
                  !document.hiddenDiscoveries.contains(path),
                  knownAutomatic.insert(key).inserted else { continue }
            let highest = document.highestOrdinals[detection.provider.rawValue] ?? 0
            guard highest < Int.max else { throw StoreError.invalidEntries }
            let ordinal = highest + 1
            document.entries.append(CLIEntry(id: UUID(), provider: detection.provider.rawValue,
                                             ordinal: ordinal, origin: .automatic, detectedPath: path))
            document.highestOrdinals[detection.provider.rawValue] = ordinal
        }

        guard document != original else { return document.entries }
        try save(document)
        return document.entries
    }

    @discardableResult
    func remove(id: UUID, suppressingDiscoveryPaths: [String] = []) throws -> [CLIEntry] {
        var document = try loadDocument()
        var updated = document.entries
        guard let index = updated.firstIndex(where: { $0.id == id }) else {
            throw StoreError.entryNotFound
        }
        let removed = updated.remove(at: index)
        for path in suppressingDiscoveryPaths {
            document.hiddenDiscoveries.insert(Self.normalizedPath(path))
        }
        if removed.origin == .automatic, let path = removed.detectedPath {
            document.hiddenDiscoveries.insert(Self.normalizedPath(path))
        }
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
            let validDetection = entry.origin == .automatic
                ? entry.detectedPath?.isEmpty == false
                : entry.detectedPath == nil
            guard !entry.provider.isEmpty, entry.ordinal > 0,
                  validDetection,
                  ids.insert(entry.id).inserted,
                  providerOrdinals.insert("\(entry.provider)\u{0}\(entry.ordinal)").inserted else {
                throw StoreError.invalidEntries
            }
        }
    }

    private static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    enum StoreError: Error {
        case invalidEntries
        case entryNotFound
    }

    private struct StoreDocument: Codable, Equatable {
        var entries: [CLIEntry]
        var highestOrdinals: [String: Int]
        var hiddenDiscoveries: Set<String>

        private enum CodingKeys: String, CodingKey { case entries, highestOrdinals, hiddenDiscoveries }

        init(entries: [CLIEntry], highestOrdinals: [String: Int], hiddenDiscoveries: Set<String> = []) {
            self.entries = entries
            self.highestOrdinals = highestOrdinals
            self.hiddenDiscoveries = hiddenDiscoveries
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            entries = try values.decode([CLIEntry].self, forKey: .entries)
            highestOrdinals = try values.decode([String: Int].self, forKey: .highestOrdinals)
            hiddenDiscoveries = try values.decodeIfPresent(Set<String>.self, forKey: .hiddenDiscoveries) ?? []
        }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(entries, forKey: .entries)
            try values.encode(highestOrdinals, forKey: .highestOrdinals)
            try values.encode(hiddenDiscoveries, forKey: .hiddenDiscoveries)
        }
    }
}
