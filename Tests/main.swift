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

final class SyntheticNPMRunner {
    private let lock = NSLock()
    private let exitCode: Int32
    private let createsExecutable: Bool
    private let entered: DispatchSemaphore?
    private let release: DispatchSemaphore?
    private var storedInvocations: [(URL, [String], [String: String])] = []

    init(exitCode: Int32 = 0, createsExecutable: Bool = true,
         entered: DispatchSemaphore? = nil, release: DispatchSemaphore? = nil) {
        self.exitCode = exitCode
        self.createsExecutable = createsExecutable
        self.entered = entered
        self.release = release
    }

    var invocations: [(URL, [String], [String: String])] {
        lock.lock(); defer { lock.unlock() }
        return storedInvocations
    }

    func run(executable: URL, arguments: [String], environment: [String: String]) throws -> Int32 {
        lock.lock()
        storedInvocations.append((executable, arguments, environment))
        lock.unlock()
        if createsExecutable, let prefixIndex = arguments.firstIndex(of: "--prefix"),
           arguments.indices.contains(prefixIndex + 1) {
            let prefix = URL(fileURLWithPath: arguments[prefixIndex + 1], isDirectory: true)
            try createSyntheticExecutable(prefix.appendingPathComponent("node_modules/.bin/codex"))
        }
        entered?.signal()
        if let release { _ = release.wait(timeout: .now() + .seconds(10)) }
        return exitCode
    }
}

final class TestResultBox<Value> {
    private let lock = NSLock()
    private var stored: Value?
    func set(_ value: Value) { lock.lock(); stored = value; lock.unlock() }
    var value: Value? { lock.lock(); defer { lock.unlock() }; return stored }
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

// Codex installation tests inject a recorder instead of executing npm or Codex.
let fakeTools = testRoot.appendingPathComponent("fake-tools", isDirectory: true)
let syntheticNPM = fakeTools.appendingPathComponent("npm")
let syntheticNode = fakeTools.appendingPathComponent("node")
try createSyntheticExecutable(syntheticNPM)
try createSyntheticExecutable(syntheticNode)
let hostHome = testRoot.appendingPathComponent("host-home", isDirectory: true)
let hostCodexHome = hostHome.appendingPathComponent(".codex", isDirectory: true)
try fileManager.createDirectory(at: hostCodexHome, withIntermediateDirectories: true)
let hostMarker = hostCodexHome.appendingPathComponent("host-owned-marker")
try Data("synthetic host data".utf8).write(to: hostMarker)
let hostMarkerBefore = try Data(contentsOf: hostMarker)
let installEnvironment = ["PATH": localBin.path,
                          "HOME": hostHome.path,
                          "CODEX_HOME": hostCodexHome.path,
                          "OPENAI_API_KEY": "synthetic-host-api-key",
                          "NPM_TOKEN": "synthetic-npm-token",
                          "LANG": "en_US.UTF-8"]
let successfulNPMRunner = SyntheticNPMRunner()
let codexInstallService = CLIInstallService(
    applicationSupportDirectory: testRoot.appendingPathComponent("install-support"),
    environment: installEnvironment,
    homeDirectory: hostHome,
    additionalSearchDirectories: [],
    knownExecutableOverrides: [.codex: [syntheticCodex]],
    npmExecutableOverride: syntheticNPM,
    nodeExecutableOverride: syntheticNode,
    processRunner: { executable, arguments, environment in
        try successfulNPMRunner.run(executable: executable, arguments: arguments, environment: environment)
    })

let registrationStore = CLIEntryStore(applicationSupportDirectory: testRoot.appendingPathComponent("registration-store"))
let originalRegistration = try registrationStore.add(provider: .codex).last!
let detectedOriginal = discoveries.first(where: { $0.target == .codex })!
require(codexInstallService.registrationInstallStatus(for: originalRegistration) == .notInstalled &&
        detectedOriginal.discoveryURL == syntheticCodex,
        "a global/original Codex detection does not mark a manual UUID as installed")
let originalInstallDirectory = codexInstallService.registrationDirectory(for: originalRegistration)
let originalInstallExecutable = try codexInstallService.install(entry: originalRegistration)
require(codexInstallService.registrationInstallStatus(for: originalRegistration) == .installed &&
        fileManager.isExecutableFile(atPath: originalInstallExecutable.path),
        "the injected Codex package result marks only its registration as installed")
require(originalInstallDirectory.lastPathComponent == originalRegistration.id.uuidString,
        "the install directory is keyed by UUID, not the reusable ordinal")
let firstNPMInvocation = successfulNPMRunner.invocations[0]
require(firstNPMInvocation.0 == syntheticNPM &&
        firstNPMInvocation.1.contains("@openai/codex@latest") &&
        firstNPMInvocation.1.contains("https://registry.npmjs.org"),
        "installation uses fixed official npm package arguments")
let npmChildEnvironment = firstNPMInvocation.2
require(npmChildEnvironment["HOME"] != hostHome.path &&
        npmChildEnvironment["CODEX_HOME"] != hostCodexHome.path &&
        npmChildEnvironment["OPENAI_API_KEY"] == nil && npmChildEnvironment["NPM_TOKEN"] == nil &&
        npmChildEnvironment["NPM_CONFIG_USERCONFIG"] != nil &&
        npmChildEnvironment["NPM_CONFIG_GLOBALCONFIG"] != nil,
        "npm receives an instance-local HOME/config and no inherited credential variables")
let originalCodexConfig = originalInstallDirectory.appendingPathComponent("installation/codex-home/config.toml")
let originalCodexConfigText = try String(contentsOf: originalCodexConfig, encoding: .utf8)
require(originalCodexConfigText.contains("cli_auth_credentials_store = \"file\"") &&
        !fileManager.fileExists(atPath: originalInstallDirectory.appendingPathComponent(
            "installation/codex-home/auth.json").path),
        "each Codex home selects file credentials; installation performs no login")

var authenticationCommand: (URL, [String], [String: String])?
var authenticationStatusCommand: (URL, [String], [String: String])?
let syntheticAuthService = CLIInstallService(
    applicationSupportDirectory: testRoot.appendingPathComponent("install-support"),
    environment: installEnvironment,
    homeDirectory: hostHome,
    additionalSearchDirectories: [],
    knownExecutableOverrides: [:],
    processRunner: { executable, arguments, environment in
        authenticationStatusCommand = (executable, arguments, environment)
        return 1
    },
    authenticationProcessLauncher: { executable, arguments, environment in
        authenticationCommand = (executable, arguments, environment)
        return Process()
    })
let syntheticAuthenticationStatus = try syntheticAuthService.authenticationStatus(for: originalRegistration)
require(syntheticAuthenticationStatus == .notAuthenticated,
        "isolated login status maps the synthetic nonzero command result to not authenticated")
let fakeAuthProcess = try syntheticAuthService.startAuthentication(for: originalRegistration)
require(authenticationStatusCommand?.1 == ["login", "status"] &&
        authenticationCommand?.1 == ["login"] &&
        authenticationCommand?.0 == originalInstallExecutable,
        "status and browser login target only the Codex 0 executable with fixed arguments")
require(authenticationStatusCommand?.2["CODEX_HOME"] == originalInstallDirectory
            .appendingPathComponent("installation/codex-home").path &&
        authenticationCommand?.2["HOME"] == originalInstallDirectory
            .appendingPathComponent("installation/home").path &&
        authenticationCommand?.2["OPENAI_API_KEY"] == nil &&
        authenticationCommand?.2["NPM_TOKEN"] == nil,
        "login and status inherit the instance runtime environment without host credentials")
let browserLauncher = originalInstallDirectory.appendingPathComponent("browser-launcher/open")
let browserLauncherText = try String(contentsOf: browserLauncher, encoding: .utf8)
require(fileManager.isExecutableFile(atPath: browserLauncher.path) &&
        browserLauncherText.contains("https://auth.openai.com/*") &&
        browserLauncherText.contains("Google Chrome.app") &&
        browserLauncherText.contains("--user-data-dir=\"$profile\"") &&
        !browserLauncherText.contains("Safari"),
        "the scoped launcher accepts official login origins and opens a dedicated Chrome profile")
_ = fakeAuthProcess
require(CLIInstallService.authenticationPolicyAllowsFile(
            documents: ["cli_auth_credentials_store = \"file\"\nallowed_login_methods = [\"chatgpt\"]"],
            instanceConfig: "cli_auth_credentials_store = \"file\"\n"),
        "file credential storage and permitted ChatGPT auth satisfy the local preflight")
require(!CLIInstallService.authenticationPolicyAllowsFile(
            documents: ["cli_auth_credentials_store = \"keyring\""],
            instanceConfig: "cli_auth_credentials_store = \"file\"\n") &&
        !CLIInstallService.authenticationPolicyAllowsFile(
            documents: ["allowed_login_methods = [\"api\"]"],
            instanceConfig: "cli_auth_credentials_store = \"file\"\n") &&
        !CLIInstallService.authenticationPolicyAllowsFile(
            documents: ["allowed_chatgpt_workspaces = []"],
            instanceConfig: "cli_auth_credentials_store = \"file\"\n"),
        "keyring or a policy that blocks ChatGPT login prevents OAuth before authentication")
let statusWithoutAuthFileService = CLIInstallService(
    applicationSupportDirectory: testRoot.appendingPathComponent("install-support"),
    environment: installEnvironment,
    homeDirectory: hostHome,
    additionalSearchDirectories: [],
    knownExecutableOverrides: [:],
    processRunner: { _, _, _ in 0 })
do {
    _ = try statusWithoutAuthFileService.authenticationStatus(for: originalRegistration)
    fatalError("CLI status alone must not claim isolated authentication without its private file")
} catch CLIInstallError.authenticationStorageUnavailable {
}
let syntheticAuthFile = originalInstallDirectory.appendingPathComponent("installation/codex-home/auth.json")
try Data("synthetic-only-not-a-token".utf8).write(to: syntheticAuthFile, options: .atomic)
try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o600)],
                              ofItemAtPath: syntheticAuthFile.path)
let authenticatedWithPrivateFile = try statusWithoutAuthFileService.authenticationStatus(for: originalRegistration)
require(authenticatedWithPrivateFile == .authenticated,
        "an isolated successful CLI status requires a private per-instance auth file")
try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o644)],
                              ofItemAtPath: syntheticAuthFile.path)
do {
    _ = try statusWithoutAuthFileService.authenticationStatus(for: originalRegistration)
    fatalError("a world-readable auth file must not confirm isolated authentication")
} catch CLIInstallError.authenticationStorageUnavailable {
}
try fileManager.removeItem(at: syntheticAuthFile)
let isolatedRuntime = try codexInstallService.isolatedRuntimeEnvironment(for: originalRegistration)
require(isolatedRuntime["CODEX_HOME"] == originalInstallDirectory.appendingPathComponent(
            "installation/codex-home").path &&
        isolatedRuntime["HOME"] == originalInstallDirectory.appendingPathComponent("installation/home").path &&
        isolatedRuntime["OPENAI_API_KEY"] == nil,
        "future Codex runtime environment is registration-local and excludes inherited API credentials")
let hostMarkerAfterFirstInstall = try Data(contentsOf: hostMarker)
let originalCodexAfterFirstInstall = try Data(contentsOf: syntheticCodex)
require(hostMarkerAfterFirstInstall == hostMarkerBefore &&
        originalCodexAfterFirstInstall == Data("synthetic executable".utf8),
        "installation leaves the original Codex executable and host CODEX_HOME untouched")

// Removing a row keeps installations intact; reusing ordinal zero creates a distinct UUID path.
let secondRegistration = try registrationStore.add(provider: .codex).last!
require(secondRegistration.ordinal == 1, "the second test registration gets ordinal 1")
_ = try codexInstallService.install(entry: secondRegistration)
let secondInstallDirectory = codexInstallService.registrationDirectory(for: secondRegistration)
_ = try registrationStore.remove(id: secondRegistration.id)
require(codexInstallService.registrationInstallStatus(for: originalRegistration) == .installed &&
        fileManager.isExecutableFile(atPath: originalInstallExecutable.path),
        "removing another manual row does not delete the first registration's install")
_ = try registrationStore.remove(id: originalRegistration.id)
let reusedOrdinalRegistration = try registrationStore.add(provider: .codex).last!
require(reusedOrdinalRegistration.ordinal == 0 && reusedOrdinalRegistration.id != originalRegistration.id,
        "reusing ordinal zero creates a new registration UUID")
require(codexInstallService.registrationInstallStatus(for: reusedOrdinalRegistration) == .notInstalled,
        "the new ordinal-zero row does not inherit the prior UUID's installation")
let reusedInstallExecutable = try codexInstallService.install(entry: reusedOrdinalRegistration)
let reusedInstallDirectory = codexInstallService.registrationDirectory(for: reusedOrdinalRegistration)
let reusedRuntime = try codexInstallService.isolatedRuntimeEnvironment(for: reusedOrdinalRegistration)
require(originalInstallDirectory != secondInstallDirectory &&
        originalInstallDirectory != reusedInstallDirectory && secondInstallDirectory != reusedInstallDirectory &&
        fileManager.isExecutableFile(atPath: originalInstallExecutable.path) &&
        fileManager.isExecutableFile(atPath: reusedInstallExecutable.path) &&
        codexInstallService.registrationInstallStatus(for: originalRegistration) == .installed &&
        codexInstallService.registrationInstallStatus(for: reusedOrdinalRegistration) == .installed &&
        reusedRuntime["CODEX_HOME"] != isolatedRuntime["CODEX_HOME"] &&
        reusedRuntime["HOME"] != isolatedRuntime["HOME"] &&
        reusedRuntime["XDG_CACHE_HOME"] != isolatedRuntime["XDG_CACHE_HOME"],
        "different UUIDs have separate surviving installations despite ordinal reuse and removal")
let hostMarkerAfterRepeatedInstalls = try Data(contentsOf: hostMarker)
let originalCodexAfterRepeatedInstalls = try Data(contentsOf: syntheticCodex)
require(hostMarkerAfterRepeatedInstalls == hostMarkerBefore &&
        originalCodexAfterRepeatedInstalls == Data("synthetic executable".utf8),
        "multiple isolated installs leave global Codex state untouched")

// Providers without an implemented installer remain unavailable and write nothing.
let unsupportedSupport = testRoot.appendingPathComponent("unsupported-support")
let unsupportedService = CLIInstallService(applicationSupportDirectory: unsupportedSupport,
                                           environment: installEnvironment,
                                           homeDirectory: hostHome,
                                           additionalSearchDirectories: [],
                                           knownExecutableOverrides: [:],
                                           npmExecutableOverride: syntheticNPM,
                                           nodeExecutableOverride: syntheticNode,
                                           processRunner: { _, _, _ in fatalError("unsupported providers must not run npm") })
for provider in [CLIProvider.claude, .antigravity] {
    let unsupportedEntry = CLIEntry(id: UUID(), provider: provider.rawValue, ordinal: 0)
    require(unsupportedService.registrationInstallStatus(for: unsupportedEntry) == .unsupported,
            "Claude and Antigravity do not display a false installed state")
    do {
        _ = try unsupportedService.install(entry: unsupportedEntry)
        fatalError("unsupported provider installation should be rejected")
    } catch CLIInstallError.unsupportedProvider {
    }
}
require(!fileManager.fileExists(atPath: unsupportedSupport.path),
        "unsupported provider has no installation writes")

let missingNPMRoot = testRoot.appendingPathComponent("missing-npm-support")
let missingNPMService = CLIInstallService(applicationSupportDirectory: missingNPMRoot,
                                         environment: ["PATH": ""],
                                         homeDirectory: hostHome,
                                         additionalSearchDirectories: [],
                                         knownExecutableOverrides: [:])
let missingNPMEntry = CLIEntry(id: UUID(), provider: CLIProvider.codex.rawValue, ordinal: 0)
do {
    _ = try missingNPMService.install(entry: missingNPMEntry)
    fatalError("missing npm prerequisite must be reported")
} catch CLIInstallError.npmUnavailable {
}
require(!fileManager.fileExists(atPath: missingNPMService.registrationDirectory(for: missingNPMEntry).path),
        "missing npm is reported before per-registration writes")

let missingNodeRoot = testRoot.appendingPathComponent("missing-node-support")
let missingNodeService = CLIInstallService(applicationSupportDirectory: missingNodeRoot,
                                           environment: ["PATH": ""],
                                           homeDirectory: hostHome,
                                           additionalSearchDirectories: [],
                                           knownExecutableOverrides: [:],
                                           npmExecutableOverride: syntheticNPM)
let missingNodeEntry = CLIEntry(id: UUID(), provider: CLIProvider.codex.rawValue, ordinal: 0)
do {
    _ = try missingNodeService.install(entry: missingNodeEntry)
    fatalError("missing Node.js prerequisite must be reported")
} catch CLIInstallError.nodeUnavailable {
}
require(!fileManager.fileExists(atPath: missingNodeService.registrationDirectory(for: missingNodeEntry).path),
        "missing Node.js is reported before per-registration writes")

// Nonzero or incomplete npm results leave no published install and can be retried honestly.
let failureRoot = testRoot.appendingPathComponent("failed-install-support")
let failureRunner = SyntheticNPMRunner(exitCode: 7)
let failureService = CLIInstallService(applicationSupportDirectory: failureRoot,
                                       environment: installEnvironment,
                                       homeDirectory: hostHome,
                                       additionalSearchDirectories: [],
                                       knownExecutableOverrides: [:],
                                       npmExecutableOverride: syntheticNPM,
                                       nodeExecutableOverride: syntheticNode,
                                       processRunner: { executable, arguments, environment in
    try failureRunner.run(executable: executable, arguments: arguments, environment: environment)
})
let failedEntry = CLIEntry(id: UUID(), provider: CLIProvider.codex.rawValue, ordinal: 0)
do {
    _ = try failureService.install(entry: failedEntry)
    fatalError("failed npm invocation must not publish an installation")
} catch CLIInstallError.commandFailed(7) {
}
require(failureService.registrationInstallStatus(for: failedEntry) == .notInstalled &&
        !fileManager.fileExists(atPath: failureService.managedExecutableURL(for: failedEntry).path),
        "a partial npm output after failure is removed and never reported as installed")
let incompleteRunner = SyntheticNPMRunner(createsExecutable: false)
let incompleteService = CLIInstallService(applicationSupportDirectory: testRoot.appendingPathComponent("incomplete-install-support"),
                                          environment: installEnvironment,
                                          homeDirectory: hostHome,
                                          additionalSearchDirectories: [],
                                          knownExecutableOverrides: [:],
                                          npmExecutableOverride: syntheticNPM,
                                          nodeExecutableOverride: syntheticNode,
                                          processRunner: { executable, arguments, environment in
    try incompleteRunner.run(executable: executable, arguments: arguments, environment: environment)
})
let incompleteEntry = CLIEntry(id: UUID(), provider: CLIProvider.codex.rawValue, ordinal: 0)
do {
    _ = try incompleteService.install(entry: incompleteEntry)
    fatalError("npm success without the executable must not publish an installation")
} catch CLIInstallError.incompleteInstallation {
}
require(incompleteService.registrationInstallStatus(for: incompleteEntry) == .notInstalled,
        "npm exit zero without a Codex executable is not a successful install")

// A per-UUID OS file lock prevents concurrent duplicate npm commands.
let installEntered = DispatchSemaphore(value: 0)
let releaseInstall = DispatchSemaphore(value: 0)
let concurrentRunner = SyntheticNPMRunner(entered: installEntered, release: releaseInstall)
let concurrentService = CLIInstallService(applicationSupportDirectory: testRoot.appendingPathComponent("concurrent-support"),
                                          environment: installEnvironment,
                                          homeDirectory: hostHome,
                                          additionalSearchDirectories: [],
                                          knownExecutableOverrides: [:],
                                          npmExecutableOverride: syntheticNPM,
                                          nodeExecutableOverride: syntheticNode,
                                          processRunner: { executable, arguments, environment in
    try concurrentRunner.run(executable: executable, arguments: arguments, environment: environment)
})
let concurrentEntry = CLIEntry(id: UUID(), provider: CLIProvider.codex.rawValue, ordinal: 0)
let concurrentResult = TestResultBox<Bool>()
let completed = DispatchGroup()
completed.enter()
DispatchQueue.global(qos: .userInitiated).async {
    do { _ = try concurrentService.install(entry: concurrentEntry); concurrentResult.set(true) }
    catch { concurrentResult.set(false) }
    completed.leave()
}
require(installEntered.wait(timeout: .now() + .seconds(5)) == .success,
        "the first isolated npm install reached the injected runner")
do {
    _ = try concurrentService.install(entry: concurrentEntry)
    fatalError("a second same-UUID install must be rejected while the first is active")
} catch CLIInstallError.installationInProgress {
}
releaseInstall.signal()
require(completed.wait(timeout: .now() + .seconds(5)) == .success && concurrentResult.value == true &&
        concurrentRunner.invocations.count == 1,
        "same-UUID concurrent clicks result in exactly one npm invocation")

let detectedOnlyStore = CLIEntryStore(applicationSupportDirectory: testRoot.appendingPathComponent("detected-only"))
_ = try detectedOnlyStore.snapshot(discoveries: discoveries)
let codexAfterDetection = try detectedOnlyStore.add(provider: .codex).last
require(codexAfterDetection?.ordinal == 0, "automatic detections do not occupy manual ordinals")

// Exact live-store UI sequence: remove 0 while 1 and 2 remain, then add again without
// recreating the store. A Codex detection is present throughout and never takes an ordinal.
let dynamicStore = CLIEntryStore(applicationSupportDirectory: testRoot.appendingPathComponent("dynamic-gap"))
let syntheticCodexDiscoveries = discoveries.filter { $0.target == .codex }
let initialDynamicSnapshot = try dynamicStore.snapshot(discoveries: syntheticCodexDiscoveries)
require(initialDynamicSnapshot.detectedInstallations.count == 1 &&
        initialDynamicSnapshot.detectedInstallations[0].target == .codex,
        "the dynamic sequence starts with a detected Codex installation")
let initialDetectionID = initialDynamicSnapshot.detectedInstallations[0].id
let dynamic0 = try dynamicStore.add(provider: .codex).last!
let dynamic1 = try dynamicStore.add(provider: .codex).last!
let dynamic2 = try dynamicStore.add(provider: .codex).last!
require(dynamic0.displayName == "CodexCLI 0" && dynamic1.displayName == "CodexCLI 1" &&
        dynamic2.displayName == "CodexCLI 2" &&
        Set([dynamic0.id, dynamic1.id, dynamic2.id]).count == 3,
        "three distinct manual registrations receive labels 0, 1, and 2")
let afterRemovingZero = try dynamicStore.remove(id: dynamic0.id)
require(!afterRemovingZero.contains(where: { $0.id == dynamic0.id }) &&
        afterRemovingZero.first(where: { $0.id == dynamic1.id })?.ordinal == 1 &&
        afterRemovingZero.first(where: { $0.id == dynamic1.id })?.displayName == "CodexCLI 1" &&
        afterRemovingZero.first(where: { $0.id == dynamic2.id })?.ordinal == 2 &&
        afterRemovingZero.first(where: { $0.id == dynamic2.id })?.displayName == "CodexCLI 2",
        "removing zero leaves the IDs and ordinals of registrations 1 and 2 intact")
let dynamicReplacement = try dynamicStore.add(provider: .codex).last!
require(dynamicReplacement.ordinal == 0 && dynamicReplacement.displayName == "CodexCLI 0" &&
        dynamicReplacement.id != dynamic0.id && dynamicReplacement.id != dynamic1.id &&
        dynamicReplacement.id != dynamic2.id,
        "the same live store assigns the freed zero to a new UUID instead of ordinal 3")
let dynamicReload = try dynamicStore.load().filter { $0.provider == CLIProvider.codex.rawValue }
require(dynamicReload.count == 3 &&
        dynamicReload.first(where: { $0.id == dynamicReplacement.id })?.ordinal == 0 &&
        dynamicReload.first(where: { $0.id == dynamic1.id })?.ordinal == 1 &&
        dynamicReload.first(where: { $0.id == dynamic2.id })?.ordinal == 2,
        "persisted and reloaded registrations retain the replacement and prior identities")
let refreshedDynamicSnapshot = try dynamicStore.snapshot(discoveries: syntheticCodexDiscoveries)
require(refreshedDynamicSnapshot.detectedInstallations.count == 1 &&
        refreshedDynamicSnapshot.detectedInstallations[0].id == initialDetectionID &&
        refreshedDynamicSnapshot.detectedInstallations[0].discoveryURL == syntheticCodex &&
        refreshedDynamicSnapshot.manualRegistrations.count == 3 &&
        refreshedDynamicSnapshot.manualRegistrations.first(where: { $0.id == dynamicReplacement.id })?.displayName == "CodexCLI 0" &&
        refreshedDynamicSnapshot.manualRegistrations.first(where: { $0.id == dynamic1.id })?.displayName == "CodexCLI 1" &&
        refreshedDynamicSnapshot.manualRegistrations.first(where: { $0.id == dynamic2.id })?.displayName == "CodexCLI 2",
        "snapshot refresh retains the manual labels while keeping detection separate")

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

print("CLI catalog migration, discovery, and isolated Codex installer tests passed")
