import Foundation

enum CLIEntryOrigin: String, Codable {
    // Kept for decoding old documents. New stored entries are always manual.
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
    var statusText: String { "Registro manual · CLI ainda não instalada" }

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
        try values.encode(CLIEntryOrigin.manual, forKey: .origin)
    }
}

struct CLIAutomaticInstallation: Codable, Equatable, Identifiable {
    let id: UUID
    let target: CLIDiscoveryTarget
    let executableURL: URL
    let discoveryURL: URL
    let isManaged: Bool

    var displayName: String { target.displayName }
}

struct CLIListSnapshot: Equatable {
    let manualRegistrations: [CLIEntry]
    let detectedInstallations: [CLIAutomaticInstallation]
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
        try loadDocument().entries.filter { $0.origin == .manual }
    }

    /// Reconciles current disk discoveries into a separate, unnumbered presentation model.
    /// The persisted `entries` array contains manual registrations only.
    func snapshot(discoveries: [CLIDiscovery]) throws -> CLIListSnapshot {
        var document = try loadDocument()
        let migrated = Self.migrateLegacyAutomaticEntries(in: &document)
        document.highestOrdinals = Self.manualHighWater(document.entries,
                                                       preserving: document.highestOrdinals)

        var seen = Set<String>()
        let automatic = discoveries.sorted {
            ($0.target.rawValue, $0.discoveryURL.path) < ($1.target.rawValue, $1.discoveryURL.path)
        }.compactMap { discovery -> CLIAutomaticInstallation? in
            let path = Self.normalizedPath(discovery.discoveryURL.path)
            let key = Self.automaticKey(target: discovery.target, path: path)
            guard seen.insert(key).inserted else { return nil }
            let id = document.automaticIDs[key] ?? migrated[key] ?? UUID()
            document.automaticIDs[key] = id
            return CLIAutomaticInstallation(id: id, target: discovery.target,
                                            executableURL: discovery.executableURL,
                                            discoveryURL: discovery.discoveryURL,
                                            isManaged: discovery.isManaged)
        }

        try save(document)
        return CLIListSnapshot(manualRegistrations: document.entries,
                               detectedInstallations: automatic)
    }

    @discardableResult
    func add(provider: String) throws -> [CLIEntry] {
        var document = try loadDocument()
        _ = Self.migrateLegacyAutomaticEntries(in: &document)
        document.entries = document.entries.filter { $0.origin == .manual }
        document.highestOrdinals = Self.manualHighWater(document.entries,
                                                       preserving: document.highestOrdinals)
        let lastOrdinal = document.highestOrdinals[provider] ?? 0
        guard lastOrdinal < Int.max else { throw StoreError.invalidEntries }
        let nextOrdinal = lastOrdinal + 1
        document.entries.append(CLIEntry(id: UUID(), provider: provider, ordinal: nextOrdinal))
        document.highestOrdinals[provider] = nextOrdinal
        try save(document)
        return document.entries
    }

    /// Compatibility entry point for the pre-split UI. It now updates migration state only;
    /// callers should use `snapshot(discoveries:)` to display automatic installations.
    @discardableResult
    func reconcile(discoveries: [CLIDetection]) throws -> [CLIEntry] {
        var document = try loadDocument()
        _ = Self.migrateLegacyAutomaticEntries(in: &document)
        document.highestOrdinals = Self.manualHighWater(document.entries,
                                                       preserving: document.highestOrdinals)
        try save(document)
        return document.entries
    }

    @discardableResult
    func remove(id: UUID, suppressingDiscoveryPaths: [String] = []) throws -> [CLIEntry] {
        var document = try loadDocument()
        _ = Self.migrateLegacyAutomaticEntries(in: &document)
        document.entries = document.entries.filter { $0.origin == .manual }
        guard let index = document.entries.firstIndex(where: { $0.id == id }) else {
            throw StoreError.entryNotFound
        }
        document.entries.remove(at: index)
        // Keep the legacy argument source-compatible, but never suppress automatic discovery.
        _ = suppressingDiscoveryPaths
        try save(document)
        return document.entries
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
            guard !provider.isEmpty,
                  highest >= (document.entries.filter { $0.provider == provider }.map(\.ordinal).max() ?? 0) else {
                throw StoreError.invalidEntries
            }
        }
        return document
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

    private static func migrateLegacyAutomaticEntries(in document: inout StoreDocument) -> [String: UUID] {
        var migrated: [String: UUID] = [:]
        var manual: [CLIEntry] = []
        for entry in document.entries {
            guard entry.origin == .automatic else {
                manual.append(entry)
                continue
            }
            if let path = entry.detectedPath,
               let target = CLIDiscoveryTarget(legacyProviderName: entry.provider) {
                let key = automaticKey(target: target, path: normalizedPath(path))
                migrated[key] = entry.id
                document.automaticIDs[key] = entry.id
            }
        }
        document.entries = manual
        // Legacy suppression entries are deliberately discarded during encoding.
        return migrated
    }

    private static func manualHighWater(_ entries: [CLIEntry], preserving old: [String: Int]) -> [String: Int] {
        var result = old
        for entry in entries where entry.origin == .manual {
            result[entry.provider] = max(result[entry.provider] ?? 0, entry.ordinal)
        }
        return result
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

    private static func automaticKey(target: CLIDiscoveryTarget, path: String) -> String {
        "\(target.rawValue)\u{0}\(path)"
    }

    enum StoreError: Error {
        case invalidEntries
        case entryNotFound
    }

    private struct StoreDocument: Codable, Equatable {
        var entries: [CLIEntry]
        var highestOrdinals: [String: Int]
        var automaticIDs: [String: UUID]

        private enum CodingKeys: String, CodingKey {
            case entries, highestOrdinals, automaticIDs, hiddenDiscoveries
        }

        init(entries: [CLIEntry], highestOrdinals: [String: Int], automaticIDs: [String: UUID] = [:]) {
            self.entries = entries
            self.highestOrdinals = highestOrdinals
            self.automaticIDs = automaticIDs
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            entries = try values.decode([CLIEntry].self, forKey: .entries)
            highestOrdinals = try values.decode([String: Int].self, forKey: .highestOrdinals)
            automaticIDs = try values.decodeIfPresent([String: UUID].self, forKey: .automaticIDs) ?? [:]
            // `hiddenDiscoveries` is accepted for migration and intentionally never retained.
        }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(entries.filter { $0.origin == .manual }, forKey: .entries)
            try values.encode(highestOrdinals, forKey: .highestOrdinals)
            try values.encode(automaticIDs, forKey: .automaticIDs)
        }
    }
}
