import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

let fileManager = FileManager.default
let testRoot = fileManager.temporaryDirectory.appendingPathComponent("PainelCli-store-test-\(UUID().uuidString)", isDirectory: true)
let store = CLIEntryStore(applicationSupportDirectory: testRoot)
defer { try? fileManager.removeItem(at: testRoot) }

let first = try store.add(provider: "CodexCLI")
require(first.count == 1 && first[0].displayName == "CodexCLI 1", "first entry/index")
let second = try store.add(provider: "CodexCLI")
require(second.count == 2 && second[0] == first[0] && second[1].displayName == "CodexCLI 2", "duplicate provider and stable index")
let third = try store.add(provider: "ClaudeCLI")
require(third.count == 3 && third[2].displayName == "ClaudeCLI 1", "independent provider index")
require(Set(third.map(\.id)).count == 3, "unique entry IDs")
let loaded = try store.load()
require(loaded == third, "persistence reload")

let removed = try store.remove(id: second[1].id)
require(removed.map(\.id) == [first[0].id, third[2].id], "remove one duplicate only")
let afterRemoval = try store.add(provider: "CodexCLI")
require(afterRemoval.last?.ordinal == 3, "provider numbering is not reused after removal")
do {
    _ = try store.remove(id: UUID())
    fatalError("removing an unknown entry should fail")
} catch CLIEntryStore.StoreError.entryNotFound {
} catch {
    fatalError("unknown entry should have a specific store error")
}

let legacyRoot = testRoot.appendingPathComponent("legacy", isDirectory: true)
let legacyStore = CLIEntryStore(applicationSupportDirectory: legacyRoot)
try fileManager.createDirectory(at: legacyStore.fileURL.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
let legacyID = UUID()
let legacyArray = "[{\"id\":\"\(legacyID.uuidString)\",\"provider\":\"CodexCLI\",\"ordinal\":2}]"
try Data(legacyArray.utf8).write(to: legacyStore.fileURL)
let legacyEntries = try legacyStore.load()
require(legacyEntries.count == 1 && legacyEntries[0].id == legacyID && legacyEntries[0].origin == .manual,
        "legacy entry array remains readable and defaults to manual")
let migrated = try legacyStore.add(provider: "CodexCLI")
require(migrated.last?.ordinal == 3, "legacy entries migrate with numbering intact")

let legacyDocumentStore = CLIEntryStore(applicationSupportDirectory: testRoot.appendingPathComponent("legacy-document"))
try fileManager.createDirectory(at: legacyDocumentStore.fileURL.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
let legacyDocument = """
{"entries":[{"id":"\(UUID().uuidString)","provider":"ClaudeCLI","ordinal":4}],"highestOrdinals":{"ClaudeCLI":4}}
"""
try Data(legacyDocument.utf8).write(to: legacyDocumentStore.fileURL)
let migratedDocument = try legacyDocumentStore.add(provider: "ClaudeCLI")
require(migratedDocument.last?.ordinal == 5 && migratedDocument.last?.origin == .manual,
        "prior document format migrates with ordinals and defaults intact")

final class SimulatedRunner: CLICommandRunning {
    let expectedProvider: CLIProvider
    let expectedExecutable: URL
    let expectedInstallDirectory: URL
    let fileManager: FileManager
    private(set) var calls = 0

    init(provider: CLIProvider, executable: URL, installDirectory: URL, fileManager: FileManager) {
        expectedProvider = provider
        expectedExecutable = executable
        expectedInstallDirectory = installDirectory
        self.fileManager = fileManager
    }

    func run(executable: URL, arguments: [String], environment: [String: String]) throws {
        calls += 1
        let plan = CLIInstallPlan(provider: expectedProvider, npmURL: expectedExecutable,
                                  installDirectory: expectedInstallDirectory)
        require(executable == expectedExecutable, "uses resolved npm executable")
        require(arguments == plan.arguments, "fixed install package and arguments")
        require(environment["npm_config_registry"] == "https://registry.npmjs.org/", "public npm registry")
        require(environment["npm_config_userconfig"] == expectedInstallDirectory.appendingPathComponent(".npmrc").path,
                "isolated npm user config")
        require(environment["PATH"]?.contains(expectedExecutable.deletingLastPathComponent().path) == true,
                "controlled npm runtime path")
        require(environment["NPM_TOKEN"] == nil && environment["ANTHROPIC_API_KEY"] == nil,
                "secrets are not passed to npm")
        let executableOutput = expectedInstallDirectory.appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent(expectedProvider.executableName)
        try fileManager.createDirectory(at: executableOutput.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        try Data("synthetic executable".utf8).write(to: executableOutput)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableOutput.path)
    }
}

let runtimeDirectory = testRoot.appendingPathComponent("runtime", isDirectory: true)
try fileManager.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true)
let fakeNode = runtimeDirectory.appendingPathComponent("node")
let fakeNpm = runtimeDirectory.appendingPathComponent("npm")
for runtime in [fakeNode, fakeNpm] {
    try Data("synthetic runtime".utf8).write(to: runtime)
    try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runtime.path)
}
let installRoot = testRoot.appendingPathComponent("installer", isDirectory: true)
let provider = CLIProvider.claude
let installDirectory = installRoot.appendingPathComponent("PainelCli/Installations/\(provider.rawValue)",
                                                          isDirectory: true)
let runner = SimulatedRunner(provider: provider, executable: fakeNpm,
                             installDirectory: installDirectory, fileManager: fileManager)
let installer = CLIInstallService(applicationSupportDirectory: installRoot,
                                  fileManager: fileManager, runner: runner,
                                  environment: ["PATH": runtimeDirectory.path, "HOME": testRoot.path,
                                                "NPM_TOKEN": "synthetic-secret", "ANTHROPIC_API_KEY": "synthetic-secret"],
                                  homeDirectory: testRoot, additionalSearchDirectories: [],
                                  knownExecutableOverrides: [:])
try installer.install(provider: provider)
require(runner.calls == 1, "single simulated installer invocation")
require(installer.installedExecutable(for: provider)?.lastPathComponent == "claude",
        "installed state requires expected executable")
do {
    try installer.install(provider: provider)
    fatalError("existing installation must not be overwritten")
} catch CLIInstallError.alreadyInstalled {
} catch {
    fatalError("existing installation is distinguished")
}
require(runner.calls == 1, "detected install prevents repeated invocation")

let plan = CLIInstallPlan(provider: .gemini, npmURL: fakeNpm,
                          installDirectory: testRoot.appendingPathComponent("gemini"))
require(plan.arguments.last == "@google/gemini-cli", "Gemini uses official fixed package")
require(CLIInstallPlan(provider: .codex, npmURL: fakeNpm,
                       installDirectory: testRoot.appendingPathComponent("codex")).arguments.last == "@openai/codex",
        "Codex uses official fixed package")

func createSyntheticExecutable(_ url: URL) throws {
    try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("synthetic executable".utf8).write(to: url)
    try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
}

let discoveryHome = testRoot.appendingPathComponent("discovery-home", isDirectory: true)
let syntheticClaude = discoveryHome.appendingPathComponent(".local/bin/claude")
let syntheticClaudeTarget = discoveryHome.appendingPathComponent(".local/share/claude/versions/2.1.test")
let syntheticAntigravity = discoveryHome.appendingPathComponent(".local/bin/agy")
let syntheticBundledCodex = testRoot.appendingPathComponent("ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
try createSyntheticExecutable(syntheticClaudeTarget)
try fileManager.createDirectory(at: syntheticClaude.deletingLastPathComponent(), withIntermediateDirectories: true)
try fileManager.createSymbolicLink(at: syntheticClaude, withDestinationURL: syntheticClaudeTarget)
try createSyntheticExecutable(syntheticAntigravity)
try createSyntheticExecutable(syntheticBundledCodex)
let discoveryService = CLIInstallService(
    applicationSupportDirectory: testRoot.appendingPathComponent("discovery-support"),
    fileManager: fileManager,
    environment: ["PATH": "", "HOME": discoveryHome.path],
    homeDirectory: discoveryHome,
    knownExecutableOverrides: [.codex: [syntheticBundledCodex]])
let discovered = discoveryService.detectedExecutables()
require(Set(discovered.map(\.provider)) == [.codex, .claude], "detect PATH/home and known ChatGPT executable without running it")
require(discovered.first(where: { $0.provider == .codex })?.executableURL.path == syntheticBundledCodex.path,
        "known bundled Codex location is reported")
require(discovered.first(where: { $0.provider == .claude })?.executableURL.path == syntheticClaudeTarget.path &&
        discovered.first(where: { $0.provider == .claude })?.discoveryURL.path == syntheticClaude.path,
        "symlink target is inspected while the stable user-facing path is retained")
require(discovered.allSatisfy { !$0.isManaged }, "external discoveries remain distinct from app-managed installs")

let discoveredInstallations = discoveryService.detectedInstallations()
let agy = discoveredInstallations.first(where: { $0.target == .antigravity })
require(agy?.discoveryURL.path == syntheticAntigravity.path && agy?.displayName == "Antigravity",
        "agy is discovered as an uninstalled-catalog Antigravity target")
require(CLIProvider.allCases.map(\.rawValue) == ["CodexCLI", "ClaudeCLI", "GeminiCLI"],
        "Antigravity remains outside the installable catalog")

let reconciliationStore = CLIEntryStore(applicationSupportDirectory: testRoot.appendingPathComponent("reconciliation"))
let manualCodex = try reconciliationStore.add(provider: CLIProvider.codex.rawValue)[0]
let firstSnapshot = try reconciliationStore.snapshot(discoveries: discoveredInstallations)
require(firstSnapshot.manualRegistrations == [manualCodex], "manual registration remains independent")
require(firstSnapshot.detectedInstallations.count == 3,
        "automatic installations are always present alongside a manual registration")
require(firstSnapshot.detectedInstallations.map(\.target).contains(.codex) &&
        firstSnapshot.detectedInstallations.map(\.target).contains(.antigravity),
        "detections are represented separately from manual registrations")
let stableSnapshot = try reconciliationStore.snapshot(discoveries: discoveredInstallations)
require(stableSnapshot.detectedInstallations == firstSnapshot.detectedInstallations,
        "repeated discovery keeps automatic IDs stable and has no ordinal field")
let automaticID = firstSnapshot.detectedInstallations.first(where: { $0.target == .claude })!.id
do {
    _ = try reconciliationStore.remove(id: automaticID)
    fatalError("automatic installations cannot be removed as registrations")
} catch CLIEntryStore.StoreError.entryNotFound {
}
let manualClaude = try reconciliationStore.add(provider: CLIProvider.claude.rawValue).last!
require(manualClaude.ordinal == 1, "manual registration starts its own ordinal sequence")
let snapshotWithDuplicates = try reconciliationStore.snapshot(discoveries: discoveredInstallations)
require(snapshotWithDuplicates.manualRegistrations.map(\.provider) == ["CodexCLI", "ClaudeCLI"],
        "manual registrations can duplicate providers independently from detections")
require(snapshotWithDuplicates.detectedInstallations == firstSnapshot.detectedInstallations,
        "adding a manual registration never promotes or hides a detection")
_ = try reconciliationStore.remove(id: manualClaude.id,
                                   suppressingDiscoveryPaths: [syntheticClaude.path])
let afterManualRemoval = try reconciliationStore.snapshot(discoveries: discoveredInstallations)
require(afterManualRemoval.detectedInstallations == firstSnapshot.detectedInstallations,
        "removing a manual registration cannot suppress automatic discovery")
let afterUninstall = try reconciliationStore.snapshot(discoveries: [])
require(afterUninstall.detectedInstallations.isEmpty && afterUninstall.manualRegistrations == [manualCodex],
        "automatic presentation follows current disk state and disappears after uninstall")
let rediscovered = try reconciliationStore.snapshot(discoveries: discoveredInstallations)
require(rediscovered.detectedInstallations == firstSnapshot.detectedInstallations,
        "a rediscovered executable regains the same stable identity")

let migrationStore = CLIEntryStore(applicationSupportDirectory: testRoot.appendingPathComponent("migration"))
try fileManager.createDirectory(at: migrationStore.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
let migratedManualID = UUID()
let migratedAutomaticID = UUID()
let migrationJSON = """
{"entries":[{"id":"\(migratedManualID.uuidString)","provider":"ClaudeCLI","ordinal":2},{"id":"\(migratedAutomaticID.uuidString)","provider":"ClaudeCLI","ordinal":3,"origin":"automatic","detectedPath":"\(syntheticClaude.path)"}],"highestOrdinals":{"ClaudeCLI":3},"hiddenDiscoveries":["\(syntheticClaude.path)"]}
"""
try Data(migrationJSON.utf8).write(to: migrationStore.fileURL)
let migratedSnapshot = try migrationStore.snapshot(discoveries: discoveredInstallations)
require(migratedSnapshot.manualRegistrations.count == 1 &&
        migratedSnapshot.manualRegistrations[0].id == migratedManualID &&
        migratedSnapshot.manualRegistrations[0].ordinal == 2,
        "legacy automatic records are removed while manual IDs and ordinals survive")
require(migratedSnapshot.detectedInstallations.first(where: { $0.target == .claude })?.id == migratedAutomaticID,
        "legacy automatic identity migrates into the detection identity map")
let migratedBytes = try String(contentsOf: migrationStore.fileURL, encoding: .utf8)
require(!migratedBytes.contains("hiddenDiscoveries") && !migratedBytes.contains("automatic\""),
        "legacy hide state and automatic rows are cleared from persistence")
let afterMigrationAdd = try migrationStore.add(provider: "ClaudeCLI")
require(afterMigrationAdd.last?.ordinal == 4,
        "legacy high-water value is retained to avoid reusing a previously issued number")

func XCTUnwrapForTests<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else { fatalError(message) }
    return value
}

func tryOptionalEmpty(_ entries: [CLIEntry], provider: CLIProvider) -> Bool {
    entries.filter { $0.provider == provider.rawValue }.count == 1
}

try Data("not-json".utf8).write(to: store.fileURL, options: .atomic)
let corruptBytes = try Data(contentsOf: store.fileURL)
do {
    _ = try store.add(provider: "CodexCLI")
    fatalError("corrupt file should block add")
} catch CLIEntryStore.StoreError.invalidEntries {
    fatalError("decode errors should retain their original decoding error")
} catch {
    let bytesAfterFailedAdd = try Data(contentsOf: store.fileURL)
    require(bytesAfterFailedAdd == corruptBytes, "corrupt file is preserved")
}

let blocker = testRoot.appendingPathComponent("file-blocker")
try Data("block".utf8).write(to: blocker)
let failingStore = CLIEntryStore(applicationSupportDirectory: blocker)
do {
    _ = try failingStore.add(provider: "GeminiCLI")
    fatalError("unwritable target should fail")
} catch {
    require(!fileManager.fileExists(atPath: failingStore.fileURL.path), "failed write does not report persisted entry")
}

print("CLIEntryStore and simulated installer tests passed")
