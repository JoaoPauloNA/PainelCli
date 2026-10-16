import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

func createSyntheticExecutable(_ url: URL, contents: String = "synthetic executable") throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try Data(contents.utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
}

func writeStoreDocument(_ store: CLIEntryStore, entries: [CLIEntry],
                        highestOrdinals: [String: Int], hiddenDiscoveries: [String] = [],
                        schemaVersion: Int = 1) throws {
    try FileManager.default.createDirectory(at: store.fileURL.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    let serializedEntries: [[String: Any]] = entries.map { entry in
        var value: [String: Any] = ["id": entry.id.uuidString,
                                    "provider": entry.provider,
                                    "ordinal": entry.ordinal,
                                    "origin": entry.origin.rawValue]
        if let detectedPath = entry.detectedPath { value["detectedPath"] = detectedPath }
        return value
    }
    let document: [String: Any] = [
        "entries": serializedEntries,
        "highestOrdinals": highestOrdinals,
        "hiddenDiscoveries": hiddenDiscoveries,
        "schemaVersion": schemaVersion
    ]
    try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        .write(to: store.fileURL, options: .atomic)
}

let fileManager = FileManager.default
let testRoot = fileManager.temporaryDirectory
    .appendingPathComponent("PainelCli-catalog-migration-test-\(UUID().uuidString)", isDirectory: true)
try fileManager.createDirectory(at: testRoot, withIntermediateDirectories: true)
defer { try? fileManager.removeItem(at: testRoot) }

// The catalog is exact and does not conflate the real Gemini executable with Antigravity.
require(CLIProvider.allCases.map(\.rawValue) == ["CodexCLI", "ClaudeCLI", "AntigravityCLI"],
        "catalog contains Codex, Claude, and Antigravity only")
require(CLIProvider.antigravity.catalogTitle == "Antigravity CLI" &&
        CLIProvider.antigravity.executableName == "agy",
        "Antigravity uses the official display name and executable")
require(CLIDiscoveryTarget.gemini.executableName == "gemini" &&
        CLIDiscoveryTarget.gemini.catalogProvider == nil &&
        CLIDiscoveryTarget.antigravity.executableName == "agy",
        "Gemini remains an independent detection target")

// Manual numbering starts at zero independently per provider. Detections never occupy ordinals.
let store = CLIEntryStore(applicationSupportDirectory: testRoot)
let codex1 = try store.add(provider: .codex)[0]
let codex2 = try store.add(provider: .codex).last!
let codex3 = try store.add(provider: .codex).last!
let claude1 = try store.add(provider: .claude).last!
require(codex1.displayName == "CodexCLI 0" && codex2.displayName == "CodexCLI 1" &&
        codex3.displayName == "CodexCLI 2" && claude1.displayName == "ClaudeCLI 0",
        "manual numbering starts at zero per provider")
let antigravity1 = try store.add(provider: .antigravity).last!
require(antigravity1.displayName == "Antigravity CLI 0", "catalog rows use the official Antigravity name")
let persistedRegistrations = try store.load()
require(persistedRegistrations.count == 5, "manual registrations persist")
let removedCodex = try store.remove(id: codex2.id)
require(!removedCodex.contains(where: { $0.id == codex2.id }), "manual row removal remains functional")
let nextCodex = try store.add(provider: .codex).last
require(nextCodex?.ordinal == 1,
        "manual allocation reuses the smallest available ordinal")
_ = try store.remove(id: codex1.id)
_ = try store.remove(id: codex3.id)
_ = try store.remove(id: nextCodex!.id)
let codexAfterDeleteAll = try store.add(provider: .codex).last
require(codexAfterDeleteAll?.ordinal == 0,
        "deleting every provider registration makes ordinal zero available again")

// Registration installs are hard-blocked before any path creation or process operation.
let isolationRoot = testRoot.appendingPathComponent("isolation-block", isDirectory: true)
let blockedService = CLIInstallService(applicationSupportDirectory: isolationRoot,
                                       environment: ["PATH": ""],
                                       homeDirectory: testRoot,
                                       additionalSearchDirectories: [],
                                       knownExecutableOverrides: [:])
for provider in CLIProvider.allCases {
    let entry = CLIEntry(id: UUID(), provider: provider.rawValue, ordinal: 1)
    do {
        try blockedService.install(entry: entry)
        fatalError("installation must remain blocked until per-registration isolation exists")
    } catch CLIInstallError.isolatedInstallationUnavailable {
    }
    require(!fileManager.fileExists(atPath: blockedService.installationDirectory(
        for: CLIDiscoveryTarget(rawValue: provider.rawValue)!).path),
        "blocked install does not create a shared provider directory")
}
require(!fileManager.fileExists(atPath: isolationRoot.path),
        "blocked install performs no filesystem writes")

// Synthetic executable files prove detection is path-only and preserves true CLI identity.
let discoveryHome = testRoot.appendingPathComponent("discovery-home", isDirectory: true)
let localBin = discoveryHome.appendingPathComponent(".local/bin", isDirectory: true)
let syntheticClaude = localBin.appendingPathComponent("claude")
let syntheticClaudeTarget = discoveryHome.appendingPathComponent(".local/share/claude/versions/test")
let syntheticAntigravity = localBin.appendingPathComponent("agy")
let syntheticGemini = localBin.appendingPathComponent("gemini")
let syntheticCodex = testRoot.appendingPathComponent(
    "ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
let shouldNotRunMarker = testRoot.appendingPathComponent("cli-execution-marker")
try createSyntheticExecutable(syntheticClaudeTarget)
try fileManager.createDirectory(at: localBin, withIntermediateDirectories: true)
try fileManager.createSymbolicLink(at: syntheticClaude, withDestinationURL: syntheticClaudeTarget)
try createSyntheticExecutable(syntheticAntigravity,
                              contents: "#!/bin/sh\ntouch \(shouldNotRunMarker.path)\n")
try createSyntheticExecutable(syntheticGemini)
try createSyntheticExecutable(syntheticCodex)
let discoveryService = CLIInstallService(
    applicationSupportDirectory: testRoot.appendingPathComponent("discovery-support"),
    environment: ["PATH": localBin.path],
    homeDirectory: discoveryHome,
    additionalSearchDirectories: [],
    knownExecutableOverrides: [.codex: [syntheticCodex]])
let discoveries = discoveryService.detectedInstallations()
require(Set(discoveries.map(\.target)) == Set(CLIDiscoveryTarget.allCases),
        "Codex, Claude, Gemini and Antigravity are detected distinctly")
require(discoveries.first(where: { $0.target == .antigravity })?.discoveryURL == syntheticAntigravity,
        "agy is identified only as Antigravity CLI")
require(discoveries.first(where: { $0.target == .gemini })?.discoveryURL == syntheticGemini,
        "gemini remains identified as Gemini CLI")
require(discoveries.first(where: { $0.target == .claude })?.executableURL == syntheticClaudeTarget &&
        discoveries.first(where: { $0.target == .claude })?.discoveryURL == syntheticClaude,
        "symlink discovery preserves executable target and stable alias")
require(!fileManager.fileExists(atPath: shouldNotRunMarker.path),
        "discovery never executes a synthetic CLI")

let detectedOnlyStore = CLIEntryStore(applicationSupportDirectory: testRoot.appendingPathComponent("detected-only"))
_ = try detectedOnlyStore.snapshot(discoveries: discoveries)
let codexAfterDetection = try detectedOnlyStore.add(provider: .codex).last
require(codexAfterDetection?.ordinal == 0, "automatic detections do not occupy manual ordinals")

// Catalog-origin Gemini registrations migrate only when no actual Gemini is detected and
// their one-time zero-based ordinals do not collide with existing Antigravity registrations.
let legacyMigrationStore = CLIEntryStore(applicationSupportDirectory: testRoot.appendingPathComponent("legacy-migration"))
let legacyGeminiID = UUID()
let oldCodexID = UUID()
let olderCodexID = UUID()
try writeStoreDocument(legacyMigrationStore, entries: [
    CLIEntry(id: legacyGeminiID, provider: "GeminiCLI", ordinal: 2),
    CLIEntry(id: oldCodexID, provider: "CodexCLI", ordinal: 9),
    CLIEntry(id: olderCodexID, provider: "CodexCLI", ordinal: 4)
], highestOrdinals: ["GeminiCLI": 4, "CodexCLI": 90],
   hiddenDiscoveries: [syntheticGemini.path], schemaVersion: 0)
let noRealGemini = discoveries.filter { $0.target != .gemini }
let migratedSnapshot = try legacyMigrationStore.snapshot(discoveries: noRealGemini)
let migratedGemini = migratedSnapshot.manualRegistrations.first(where: { $0.id == legacyGeminiID })
require(migratedGemini?.provider == CLIProvider.antigravity.rawValue &&
        migratedGemini?.ordinal == 0 && migratedGemini?.displayName == "Antigravity CLI 0",
        "unambiguous catalog registration changes label while preserving ID after one-time compaction")
require(migratedSnapshot.migrationNotice?.contains("IDs foram preservados") == true &&
        migratedSnapshot.manualRegistrations.first(where: { $0.id == oldCodexID })?.ordinal == 1 &&
        migratedSnapshot.manualRegistrations.first(where: { $0.id == olderCodexID })?.ordinal == 0,
        "successful migration is reported and other registrations remain intact")
let migratedAdded = try legacyMigrationStore.add(provider: .antigravity).last!
require(migratedAdded.ordinal == 1,
        "legacy high-water does not prevent using the smallest free ordinal")
let migratedAgain = try legacyMigrationStore.snapshot(discoveries: noRealGemini)
require(migratedAgain.manualRegistrations.first(where: { $0.id == oldCodexID })?.ordinal == 1 &&
        migratedAgain.manualRegistrations.first(where: { $0.id == olderCodexID })?.ordinal == 0 &&
        migratedAgain.manualRegistrations.first(where: { $0.id == legacyGeminiID })?.ordinal == 0,
        "schema migration does not renumber rows on refresh")
let migratedDocumentText = try String(contentsOf: legacyMigrationStore.fileURL, encoding: .utf8)
require(!migratedDocumentText.contains("hiddenDiscoveries") && migratedDocumentText.contains("schemaVersion"),
        "one-time schema version persists and legacy hidden state is removed")

// A real Gemini executable blocks conversion and leaves the complete legacy record intact.
let preserveLegacyStore = CLIEntryStore(applicationSupportDirectory: testRoot.appendingPathComponent("preserve-gemini"))
let preserveGeminiID = UUID()
try writeStoreDocument(preserveLegacyStore,
                       entries: [CLIEntry(id: preserveGeminiID, provider: "GeminiCLI", ordinal: 1)],
                       highestOrdinals: ["GeminiCLI": 1])
let preserveSnapshot = try preserveLegacyStore.snapshot(discoveries: discoveries)
require(preserveSnapshot.manualRegistrations.first?.id == preserveGeminiID &&
        preserveSnapshot.manualRegistrations.first?.provider == "GeminiCLI" &&
        preserveSnapshot.manualRegistrations.first?.ordinal == 1,
        "real Gemini detection preserves the legacy registration exactly")
require(preserveSnapshot.detectedInstallations.contains(where: { $0.target == .gemini }) &&
        preserveSnapshot.migrationNotice != nil,
        "actual Gemini remains detected and asks for an explicit migration decision")

// Existing Antigravity index collision also preserves all legacy rows, rather than renumbering.
let collisionStore = CLIEntryStore(applicationSupportDirectory: testRoot.appendingPathComponent("ordinal-collision"))
let collidingGeminiID = UUID()
let existingAntigravityID = UUID()
try writeStoreDocument(collisionStore, entries: [
    CLIEntry(id: collidingGeminiID, provider: "GeminiCLI", ordinal: 1),
    CLIEntry(id: existingAntigravityID, provider: CLIProvider.antigravity.rawValue, ordinal: 1)
], highestOrdinals: ["GeminiCLI": 1, CLIProvider.antigravity.rawValue: 1])
let collisionSnapshot = try collisionStore.snapshot(discoveries: noRealGemini)
require(collisionSnapshot.manualRegistrations.contains(where: {
    $0.id == collidingGeminiID && $0.provider == "GeminiCLI" && $0.ordinal == 1
}) && collisionSnapshot.migrationNotice != nil,
        "ordinal collision keeps the legacy provider and asks for a decision")
let nextAfterCollision = try collisionStore.add(provider: .antigravity).last
require(nextAfterCollision?.ordinal == 0,
        "future Antigravity registration uses the smallest unoccupied ordinal")

// Historical automatic Gemini rows migrate into their own discovery identity, never AGY.
let automaticMigrationStore = CLIEntryStore(applicationSupportDirectory: testRoot.appendingPathComponent("automatic-gemini"))
let automaticGeminiID = UUID()
try writeStoreDocument(automaticMigrationStore, entries: [
    CLIEntry(id: automaticGeminiID, provider: "GeminiCLI", ordinal: 1,
             origin: .automatic, detectedPath: syntheticGemini.path)
], highestOrdinals: ["GeminiCLI": 1])
let automaticMigrated = try automaticMigrationStore.snapshot(discoveries: discoveries)
require(automaticMigrated.detectedInstallations.first(where: { $0.target == .gemini })?.id == automaticGeminiID,
        "old automatic Gemini identity remains attached to the gemini executable")
require(!automaticMigrated.manualRegistrations.contains(where: { $0.id == automaticGeminiID }),
        "automatic Gemini detection never becomes an Antigravity manual registration")

// Legacy arrays and corrupt-file preservation remain supported.
let legacyArrayStore = CLIEntryStore(applicationSupportDirectory: testRoot.appendingPathComponent("legacy-array"))
try fileManager.createDirectory(at: legacyArrayStore.fileURL.deletingLastPathComponent(),
                                 withIntermediateDirectories: true)
let legacyArrayID = UUID()
let legacyArray = "[{\"id\":\"\(legacyArrayID.uuidString)\",\"provider\":\"CodexCLI\",\"ordinal\":2}]"
try Data(legacyArray.utf8).write(to: legacyArrayStore.fileURL)
let legacyArrayEntries = try legacyArrayStore.load()
require(legacyArrayEntries.first?.id == legacyArrayID,
        "legacy JSON-array registration remains readable")

let corruptStore = CLIEntryStore(applicationSupportDirectory: testRoot.appendingPathComponent("corrupt"))
try fileManager.createDirectory(at: corruptStore.fileURL.deletingLastPathComponent(),
                                 withIntermediateDirectories: true)
try Data("not-json".utf8).write(to: corruptStore.fileURL)
let corruptBytes = try Data(contentsOf: corruptStore.fileURL)
do {
    _ = try corruptStore.snapshot(discoveries: [])
    fatalError("corrupt store must not be replaced")
} catch {
    let bytesAfterFailedMigration = try Data(contentsOf: corruptStore.fileURL)
    require(bytesAfterFailedMigration == corruptBytes,
            "failed migration preserves the original file")
}

print("CLI catalog migration, discovery, and isolation-block tests passed")
