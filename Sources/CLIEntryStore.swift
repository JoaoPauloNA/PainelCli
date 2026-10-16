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

    var displayName: String {
        let title = CLIProvider(rawValue: provider)?.catalogTitle ??
            (provider == "GeminiCLI" ? "GeminiCLI (legado)" : provider)
        return "\(title) \(ordinal)"
    }
    var statusText: String {
        provider == "GeminiCLI"
            ? "Cadastro legado GeminiCLI · associação preservada"
            : "Cadastro manual · instalação isolada ainda indisponível"
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
        try values.encode(CLIEntryOrigin.manual, forKey: .origin)
        try values.encodeIfPresent(detectedPath, forKey: .detectedPath)
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
    let migrationNotice: String?
}

/// Returns only manual app-owned registrations whose installation and authentication
/// were both confirmed for that exact UUID. System discoveries never enter this list.
enum CLIProxyReadiness {
    static func readyEntries(_ entries: [CLIEntry], installedIDs: Set<UUID>,
                             authenticationStates: [UUID: CLIAuthenticationUIState]) -> [CLIEntry] {
        entries.filter { entry in
            guard entry.origin == .manual,
                  entry.provider == CLIProvider.codex.rawValue || entry.provider == CLIProvider.claude.rawValue,
                  installedIDs.contains(entry.id) else { return false }
            return authenticationStates[entry.id] == .authenticated
        }
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
        try loadDocument().entries.filter { $0.origin == .manual }
    }

    /// Reconciles current disk discoveries into a separate, unnumbered presentation model.
    /// The persisted `entries` array contains manual registrations only.
    func snapshot(discoveries: [CLIDiscovery]) throws -> CLIListSnapshot {
        var document = try loadDocument()
        let migrated = Self.migrateLegacyAutomaticEntries(in: &document)
        Self.migrateManualOrdinals(in: &document)
        let legacyGeminiCount = document.entries.filter {
            $0.origin == .manual && $0.provider == "GeminiCLI"
        }.count
        let migrationNeedsDecision = Self.migrateLegacyGeminiRegistrations(
            in: &document, discoveries: discoveries)
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
        let notice: String?
        if migrationNeedsDecision {
            notice = "Cadastro(s) GeminiCLI legado(s) preservado(s). Há uma CLI Gemini real ou colisão de ordinais; confirme o destino antes de migrar para Antigravity CLI."
        } else if legacyGeminiCount > 0 {
            notice = "Cadastro(s) do catálogo GeminiCLI migrado(s) para Antigravity CLI; IDs foram preservados e os ordinais seguiram a migração única de numeração. Nenhuma instalação, configuração ou credencial foi alterada."
        } else {
            notice = nil
        }
        return CLIListSnapshot(manualRegistrations: document.entries,
                               detectedInstallations: automatic,
                               migrationNotice: notice)
    }

    @discardableResult
    func add(provider: CLIProvider) throws -> [CLIEntry] {
        var document = try loadDocument()
        _ = Self.migrateLegacyAutomaticEntries(in: &document)
        Self.migrateManualOrdinals(in: &document)
        document.entries = document.entries.filter { $0.origin == .manual }
        document.highestOrdinals = Self.manualHighWater(document.entries,
                                                       preserving: document.highestOrdinals)
        let occupied = Set(document.entries
            .filter { $0.origin == .manual && $0.provider == provider.rawValue }
            .map(\.ordinal))
        var nextOrdinal = 0
        while occupied.contains(nextOrdinal) {
            guard nextOrdinal < Int.max else { throw StoreError.invalidEntries }
            nextOrdinal += 1
        }
        document.entries.append(CLIEntry(id: UUID(), provider: provider.rawValue, ordinal: nextOrdinal))
        document.highestOrdinals[provider.rawValue] = max(
            document.highestOrdinals[provider.rawValue] ?? 0, nextOrdinal)
        try save(document)
        return document.entries
    }

    @discardableResult
    func remove(id: UUID, suppressingDiscoveryPaths: [String] = []) throws -> [CLIEntry] {
        var document = try loadDocument()
        _ = Self.migrateLegacyAutomaticEntries(in: &document)
        Self.migrateManualOrdinals(in: &document)
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
            return StoreDocument(entries: [], highestOrdinals: [:], schemaVersion: 1)
        }
        let data = try Data(contentsOf: fileURL)
        if let topLevel = try? JSONSerialization.jsonObject(with: data), topLevel is [Any] {
            let entries = try JSONDecoder().decode([CLIEntry].self, from: data)
            try Self.validate(entries)
            return StoreDocument(entries: entries,
                                 highestOrdinals: Dictionary(grouping: entries, by: \.provider)
                                    .mapValues { $0.map(\.ordinal).max() ?? 0 },
                                 schemaVersion: 0)
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

    /// Converts only registrations made under the retired Gemini catalog label when a real
    /// Gemini executable is absent and no Antigravity ordinal would collide. A real Gemini
    /// installation or an index collision keeps every legacy row intact and asks for a decision.
    private static func migrateLegacyGeminiRegistrations(in document: inout StoreDocument,
                                                           discoveries: [CLIDiscovery]) -> Bool {
        let legacyEntries = document.entries.filter {
            $0.origin == .manual && $0.provider == "GeminiCLI"
        }
        guard !legacyEntries.isEmpty else { return false }

        let realGeminiInstalled = discoveries.contains { $0.target == .gemini }
        let antigravityOrdinals = Set(document.entries
            .filter { $0.origin == .manual && $0.provider == CLIProvider.antigravity.rawValue }
            .map(\.ordinal))
        let hasOrdinalCollision = legacyEntries.contains { antigravityOrdinals.contains($0.ordinal) }
        guard !realGeminiInstalled, !hasOrdinalCollision else { return true }

        for index in document.entries.indices where document.entries[index].provider == "GeminiCLI"
            && document.entries[index].origin == .manual {
            let legacy = document.entries[index]
            document.entries[index] = CLIEntry(id: legacy.id,
                                                provider: CLIProvider.antigravity.rawValue,
                                                ordinal: legacy.ordinal,
                                                origin: legacy.origin,
                                                detectedPath: legacy.detectedPath)
        }
        let oldHighWater = document.highestOrdinals["GeminiCLI"] ?? legacyEntries.map(\.ordinal).max() ?? 0
        document.highestOrdinals[CLIProvider.antigravity.rawValue] = max(
            document.highestOrdinals[CLIProvider.antigravity.rawValue] ?? 0,
            oldHighWater)
        return false
    }

    private static func manualHighWater(_ entries: [CLIEntry], preserving old: [String: Int]) -> [String: Int] {
        var result = old
        for entry in entries where entry.origin == .manual {
            result[entry.provider] = max(result[entry.provider] ?? 0, entry.ordinal)
        }
        return result
    }

    /// Compacts pre-zero-based manual registrations once, independently per provider.
    /// Sorting by old ordinal and then UUID makes the migration deterministic while keeping
    /// each registration's identity and metadata attached to its row.
    private static func migrateManualOrdinals(in document: inout StoreDocument) {
        guard document.schemaVersion < 1 else { return }
        let manualIndices = document.entries.indices.filter {
            document.entries[$0].origin == .manual
        }
        let grouped = Dictionary(grouping: manualIndices, by: { document.entries[$0].provider })
        for indices in grouped.values {
            let ordered = indices.sorted { lhs, rhs in
                let left = document.entries[lhs]
                let right = document.entries[rhs]
                if left.ordinal != right.ordinal { return left.ordinal < right.ordinal }
                return left.id.uuidString < right.id.uuidString
            }
            for (ordinal, index) in ordered.enumerated() {
                let entry = document.entries[index]
                document.entries[index] = CLIEntry(id: entry.id,
                                                    provider: entry.provider,
                                                    ordinal: ordinal,
                                                    origin: entry.origin,
                                                    detectedPath: entry.detectedPath)
            }
        }
        document.schemaVersion = 1
    }

    private static func validate(_ entries: [CLIEntry]) throws {
        var ids = Set<UUID>()
        var providerOrdinals = Set<String>()
        for entry in entries {
            let validDetection = entry.origin == .automatic
                ? entry.detectedPath?.isEmpty == false
                : entry.detectedPath == nil
            guard !entry.provider.isEmpty, entry.ordinal >= 0,
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
        var schemaVersion: Int

        private enum CodingKeys: String, CodingKey {
            case entries, highestOrdinals, automaticIDs, hiddenDiscoveries, schemaVersion
        }

        init(entries: [CLIEntry], highestOrdinals: [String: Int], automaticIDs: [String: UUID] = [:],
             schemaVersion: Int = 0) {
            self.entries = entries
            self.highestOrdinals = highestOrdinals
            self.automaticIDs = automaticIDs
            self.schemaVersion = schemaVersion
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            entries = try values.decode([CLIEntry].self, forKey: .entries)
            highestOrdinals = try values.decode([String: Int].self, forKey: .highestOrdinals)
            automaticIDs = try values.decodeIfPresent([String: UUID].self, forKey: .automaticIDs) ?? [:]
            schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
            // `hiddenDiscoveries` is accepted for migration and intentionally never retained.
        }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(entries.filter { $0.origin == .manual }, forKey: .entries)
            try values.encode(highestOrdinals, forKey: .highestOrdinals)
            try values.encode(automaticIDs, forKey: .automaticIDs)
            try values.encode(schemaVersion, forKey: .schemaVersion)
        }
    }
}
