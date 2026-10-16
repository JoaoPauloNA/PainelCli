import Foundation
import Darwin

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
    authenticationProcessLauncher: { executable, arguments, environment, _, _ in
        authenticationCommand = (executable, arguments, environment)
        return Process()
    })
let syntheticAuthenticationStatus = try syntheticAuthService.authenticationStatus(for: originalRegistration)
require(syntheticAuthenticationStatus == .notAuthenticated,
        "isolated login status maps the synthetic nonzero command result to not authenticated")
let fakeAuthProcess = try syntheticAuthService.startAuthentication(for: originalRegistration)
var deletionDuringAuthenticationWasCalled = false
do {
    try codexInstallService.removeRegistration(entry: originalRegistration) {
        deletionDuringAuthenticationWasCalled = true
    }
    fatalError("active authentication lease must block trash")
} catch CLIInstallError.installationInProgress {
}
require(!deletionDuringAuthenticationWasCalled,
        "the active app-server login lease blocks UUID deletion")
require(authenticationStatusCommand?.1 == ["login", "status"] &&
        authenticationCommand?.1 == ["app-server", "--stdio"] &&
        authenticationCommand?.0 == originalInstallExecutable,
        "status and app-server login target only the Codex 0 executable with fixed arguments")
require(authenticationStatusCommand?.2["CODEX_HOME"] == originalInstallDirectory
            .appendingPathComponent("installation/codex-home").path &&
        authenticationCommand?.2["HOME"] == originalInstallDirectory
            .appendingPathComponent("installation/home").path &&
        authenticationCommand?.2["OPENAI_API_KEY"] == nil &&
        authenticationCommand?.2["NPM_TOKEN"] == nil,
        "browser login and status inherit the instance runtime environment without host credentials")
fakeAuthProcess.releaseOperationLock()
let browserLoginRequest = CLIAppServerLoginProtocol.startRequest()
let browserLoginObject = try JSONSerialization.jsonObject(with: browserLoginRequest!.dropLast()) as! [String: Any]
require((browserLoginObject["params"] as? [String: String])?["type"] == "chatgpt",
        "the app-server login request uses the browser OAuth route")
let initializeRequest = CLIAppServerLoginProtocol.message(
    id: 1, method: "initialize", params: ["capabilities": ["experimentalApi": true]])!
let initializeObject = try JSONSerialization.jsonObject(with: initializeRequest.dropLast()) as! [String: Any]
require(((initializeObject["params"] as? [String: Any])?["capabilities"] as? [String: Bool])?["experimentalApi"] == true,
        "the official app-server protocol explicitly negotiates its login contract")
let authResponse = ["result": ["type": "chatgpt",
                               "loginId": "synthetic-login",
                               "authUrl": "https://auth.openai.com/oauth/authorize?state=synthetic"]]
require(CLIAppServerLoginProtocol.authURL(from: authResponse)?.host == "auth.openai.com" &&
        CLIAppServerLoginProtocol.loginID(from: authResponse) == "synthetic-login" &&
        CLIAppServerLoginProtocol.authURL(from: ["result": ["type": "chatgpt",
                                                            "authUrl": "https://example.invalid/oauth/authorize"]]) == nil,
        "browser authorization accepts only the official HTTPS authentication host")
require(!CLIAuthenticationUIState.awaitingBrowserAuthorization(pageOpened: true)
            .displayText.contains("auth.openai.com"),
        "browser auth URLs are never shown in the app's visible status text")
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

// Logout is verified by the same UUID executable/environment before and after the command.
let logoutAuthFile = originalInstallDirectory.appendingPathComponent("installation/codex-home/auth.json")
try Data("synthetic-auth-only".utf8).write(to: logoutAuthFile, options: .atomic)
try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: logoutAuthFile.path)
var logoutAuthenticated = true
var logoutClearsCredentials = true
var logoutInvocations: [([String], [String: String])] = []
let logoutService = CLIInstallService(
    applicationSupportDirectory: testRoot.appendingPathComponent("install-support"),
    environment: installEnvironment, homeDirectory: hostHome,
    additionalSearchDirectories: [], knownExecutableOverrides: [:],
    processRunner: { _, arguments, environment in
        logoutInvocations.append((arguments, environment))
        if arguments == ["logout"] {
            if logoutClearsCredentials {
                logoutAuthenticated = false
                try? fileManager.removeItem(at: logoutAuthFile)
            }
            return 0
        }
        return logoutAuthenticated ? 0 : 1
    })
let verifiedLogoutResult = try logoutService.logout(for: originalRegistration)
require(verifiedLogoutResult == .notAuthenticated &&
        logoutInvocations.map(\.0) == [["login", "status"], ["logout"], ["login", "status"]] &&
        logoutInvocations.allSatisfy { $0.1["CODEX_HOME"] == logoutAuthFile.deletingLastPathComponent().path },
        "logout clears and verifies credentials through the same UUID-scoped CLI environment")
try Data("synthetic-still-authenticated".utf8).write(to: logoutAuthFile, options: .atomic)
try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: logoutAuthFile.path)
logoutAuthenticated = true
logoutClearsCredentials = false
do {
    _ = try logoutService.logout(for: originalRegistration)
    fatalError("logout must fail if isolated login status still reports authenticated")
} catch CLIInstallError.logoutNotConfirmed {
}
try fileManager.removeItem(at: logoutAuthFile)

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

// Uninstall removes only the managed package and manifest, retaining UUID data for reinstall.
let preservedConfig = originalInstallDirectory.appendingPathComponent("installation/codex-home/config.toml")
let retainedConfigText = "cli_auth_credentials_store = \"file\"\n# synthetic retained setting\ncustom_setting = \"keep\"\n"
try Data(retainedConfigText.utf8).write(to: preservedConfig, options: .atomic)
let historyDirectory = originalInstallDirectory.appendingPathComponent("installation/xdg/data/history", isDirectory: true)
try fileManager.createDirectory(at: historyDirectory, withIntermediateDirectories: true)
let historyFile = historyDirectory.appendingPathComponent("history.jsonl")
try Data("synthetic history sentinel".utf8).write(to: historyFile)
let preservedAuth = originalInstallDirectory.appendingPathComponent("installation/codex-home/auth.json")
try Data("synthetic credential sentinel".utf8).write(to: preservedAuth)
try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: preservedAuth.path)
let siblingRegistration = CLIEntry(id: UUID(), provider: CLIProvider.codex.rawValue, ordinal: 99)
_ = try codexInstallService.install(entry: siblingRegistration)
let globalCodexBeforeUninstall = try Data(contentsOf: syntheticCodex)
try codexInstallService.uninstall(entry: originalRegistration)
let configAfterUninstall = try String(contentsOf: preservedConfig, encoding: .utf8)
let historyAfterUninstall = try String(contentsOf: historyFile, encoding: .utf8)
let authAfterUninstall = try String(contentsOf: preservedAuth, encoding: .utf8)
let globalCodexAfterUninstall = try Data(contentsOf: syntheticCodex)
require(codexInstallService.registrationInstallStatus(for: originalRegistration) == .notInstalled &&
        !fileManager.fileExists(atPath: originalInstallDirectory.appendingPathComponent("installation/package").path) &&
        configAfterUninstall == retainedConfigText &&
        historyAfterUninstall == "synthetic history sentinel" &&
        authAfterUninstall == "synthetic credential sentinel" &&
        codexInstallService.registrationInstallStatus(for: siblingRegistration) == .installed &&
        globalCodexAfterUninstall == globalCodexBeforeUninstall,
        "uninstall removes only this UUID package, preserving its local data, a sibling UUID, and the global Codex")
let retainedAuthMode = try fileManager.attributesOfItem(atPath: preservedAuth.path)[.posixPermissions] as? NSNumber
require(retainedAuthMode?.intValue == 0o600,
        "uninstall retains restrictive auth-file permissions")
_ = try codexInstallService.install(entry: originalRegistration)
let configAfterReinstall = try String(contentsOf: preservedConfig, encoding: .utf8)
let historyAfterReinstall = try String(contentsOf: historyFile, encoding: .utf8)
let authAfterReinstall = try String(contentsOf: preservedAuth, encoding: .utf8)
require(codexInstallService.registrationInstallStatus(for: originalRegistration) == .installed &&
        configAfterReinstall.contains("custom_setting = \"keep\"") &&
        historyAfterReinstall == "synthetic history sentinel" &&
        authAfterReinstall == "synthetic credential sentinel",
        "reinstall restores the same UUID package while retaining its local data")
try codexInstallService.uninstall(entry: siblingRegistration)

// Trash removes both the UUID installation and row; ordinal reuse creates a clean UUID path.
let secondRegistration = try registrationStore.add(provider: .codex).last!
require(secondRegistration.ordinal == 1, "the second test registration gets ordinal 1")
_ = try codexInstallService.install(entry: secondRegistration)
let secondInstallDirectory = codexInstallService.registrationDirectory(for: secondRegistration)
try codexInstallService.removeRegistration(entry: secondRegistration) {
    _ = try registrationStore.remove(id: secondRegistration.id)
}
require(codexInstallService.registrationInstallStatus(for: originalRegistration) == .installed &&
        !fileManager.fileExists(atPath: secondInstallDirectory.path) &&
        fileManager.isExecutableFile(atPath: originalInstallExecutable.path),
        "trashing a sibling UUID removes only that installation and preserves the first")
try codexInstallService.removeRegistration(entry: originalRegistration) {
    _ = try registrationStore.remove(id: originalRegistration.id)
}
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
        !fileManager.fileExists(atPath: originalInstallDirectory.path) &&
        fileManager.isExecutableFile(atPath: reusedInstallExecutable.path) &&
        codexInstallService.registrationInstallStatus(for: originalRegistration) == .notInstalled &&
        codexInstallService.registrationInstallStatus(for: reusedOrdinalRegistration) == .installed &&
        reusedRuntime["CODEX_HOME"] != isolatedRuntime["CODEX_HOME"] &&
        reusedRuntime["HOME"] != isolatedRuntime["HOME"] &&
        reusedRuntime["XDG_CACHE_HOME"] != isolatedRuntime["XDG_CACHE_HOME"],
        "different UUIDs have separate surviving installations despite ordinal reuse and removal")

// The trash path removes every file owned by one manual UUID before saving its row deletion.
let globalCodexBeforeTrash = try Data(contentsOf: syntheticCodex)
let deleteEntry = try registrationStore.add(provider: .codex).last!
_ = try codexInstallService.install(entry: deleteEntry)
let deleteDirectory = codexInstallService.registrationDirectory(for: deleteEntry)
let deleteInstallation = deleteDirectory.appendingPathComponent("installation", isDirectory: true)
let fakeAuth = deleteInstallation.appendingPathComponent("codex-home/auth.json")
let fakeConfig = deleteInstallation.appendingPathComponent("codex-home/config.toml")
let fakeHistory = deleteInstallation.appendingPathComponent("xdg/data/history.jsonl")
let fakeCache = deleteInstallation.appendingPathComponent("xdg/cache/codex-cache")
try Data("synthetic-auth-data".utf8).write(to: fakeAuth)
try Data("synthetic-config-data".utf8).write(to: fakeConfig)
try Data("synthetic-history-data".utf8).write(to: fakeHistory)
try Data("synthetic-cache-data".utf8).write(to: fakeCache)
var trashObservedAbsentBeforeStoreSave = false
try codexInstallService.removeRegistration(entry: deleteEntry) {
    trashObservedAbsentBeforeStoreSave = !fileManager.fileExists(atPath: deleteDirectory.path) &&
        codexInstallService.registrationInstallStatus(for: deleteEntry) == .notInstalled
    _ = try registrationStore.remove(id: deleteEntry.id)
}
let storeAfterTrash = try registrationStore.load()
let globalCodexAfterTrash = try Data(contentsOf: syntheticCodex)
require(trashObservedAbsentBeforeStoreSave &&
        !fileManager.fileExists(atPath: deleteDirectory.path) &&
        !fileManager.fileExists(atPath: codexInstallService.registrationOperationLockURL(for: deleteEntry).path) &&
        !fileManager.fileExists(atPath: fakeAuth.path) &&
        !fileManager.fileExists(atPath: fakeConfig.path) &&
        !fileManager.fileExists(atPath: fakeHistory.path) &&
        !fileManager.fileExists(atPath: fakeCache.path) &&
        !storeAfterTrash.contains(where: { $0.id == deleteEntry.id }) &&
        codexInstallService.registrationInstallStatus(for: originalRegistration) == .notInstalled &&
        codexInstallService.registrationInstallStatus(for: reusedOrdinalRegistration) == .installed &&
        globalCodexAfterTrash == globalCodexBeforeTrash,
        "trash verifies complete UUID cleanup before deleting the row and preserves sibling/global installations")
let freshOrdinalEntry = try registrationStore.add(provider: .codex).last!
require(freshOrdinalEntry.ordinal == deleteEntry.ordinal && freshOrdinalEntry.id != deleteEntry.id &&
        codexInstallService.registrationInstallStatus(for: freshOrdinalEntry) == .notInstalled &&
        !fileManager.fileExists(atPath: codexInstallService.registrationDirectory(for: freshOrdinalEntry).path),
        "reusing an ordinal allocates a new UUID with no inherited local login or installation")
_ = try registrationStore.remove(id: freshOrdinalEntry.id)

// A failed persistent save keeps the row and leaves a retryable not-installed state.
let saveFailureEntry = try registrationStore.add(provider: .codex).last!
_ = try codexInstallService.install(entry: saveFailureEntry)
do {
    try codexInstallService.removeRegistration(entry: saveFailureEntry) {
        throw NSError(domain: "SyntheticStoreFailure", code: 1)
    }
    fatalError("synthetic store save failure must be surfaced")
} catch {
}
let storeAfterSaveFailure = try registrationStore.load()
require(storeAfterSaveFailure.contains(where: { $0.id == saveFailureEntry.id }) &&
        codexInstallService.registrationInstallStatus(for: saveFailureEntry) == .notInstalled &&
        !fileManager.fileExists(atPath: codexInstallService.registrationOperationLockURL(for: saveFailureEntry).path) &&
        !fileManager.fileExists(atPath: codexInstallService.registrationDirectory(for: saveFailureEntry).path),
        "failed row persistence keeps the registration visible and the UUID data fully removed for retry")
try codexInstallService.removeRegistration(entry: saveFailureEntry) {
    _ = try registrationStore.remove(id: saveFailureEntry.id)
}

// A symlink escape blocks the whole removal before following or deleting its target.
let symlinkEntry = try registrationStore.add(provider: .codex).last!
let symlinkRegistrationDirectory = codexInstallService.registrationDirectory(for: symlinkEntry)
let outsideUUIDData = testRoot.appendingPathComponent("outside-uuid-data", isDirectory: true)
try fileManager.createDirectory(at: symlinkRegistrationDirectory, withIntermediateDirectories: true)
try fileManager.createDirectory(at: outsideUUIDData, withIntermediateDirectories: true)
let outsideSentinel = outsideUUIDData.appendingPathComponent("preserve-me")
try Data("outside data".utf8).write(to: outsideSentinel)
try fileManager.createSymbolicLink(at: symlinkRegistrationDirectory.appendingPathComponent("installation"),
                                   withDestinationURL: outsideUUIDData)
do {
    try codexInstallService.removeRegistration(entry: symlinkEntry) {
        _ = try registrationStore.remove(id: symlinkEntry.id)
    }
    fatalError("symlink escape must reject UUID deletion")
} catch CLIInstallError.incompleteInstallation {
}
let storeAfterSymlinkFailure = try registrationStore.load()
let outsideDataAfterAttempt = try String(contentsOf: outsideSentinel, encoding: .utf8)
require(storeAfterSymlinkFailure.contains(where: { $0.id == symlinkEntry.id }) &&
        outsideDataAfterAttempt == "outside data",
        "external symlink targets are untouched and the registration remains available")
try fileManager.removeItem(at: symlinkRegistrationDirectory)
_ = try registrationStore.remove(id: symlinkEntry.id)

let partialEntry = try registrationStore.add(provider: .codex).last!
_ = try codexInstallService.install(entry: partialEntry)
let partialDirectory = codexInstallService.registrationDirectory(for: partialEntry)
let partialOutside = testRoot.appendingPathComponent("partial-outside", isDirectory: true)
try fileManager.createDirectory(at: partialOutside, withIntermediateDirectories: true)
let partialSentinel = partialOutside.appendingPathComponent("preserve-me")
try Data("partial outside data".utf8).write(to: partialSentinel)
try fileManager.createSymbolicLink(
    at: partialDirectory.appendingPathComponent("installation/codex-home/external-link"),
    withDestinationURL: partialOutside)
do {
    try codexInstallService.removeRegistration(entry: partialEntry) {
        _ = try registrationStore.remove(id: partialEntry.id)
    }
    fatalError("partial installation data with an external symlink must block deletion")
} catch CLIInstallError.incompleteInstallation {
}
let partialExecutable = codexInstallService.managedExecutableURL(for: partialEntry)
let partialRowStillPresent = try registrationStore.load().contains(where: { $0.id == partialEntry.id })
let partialSentinelValue = try String(contentsOf: partialSentinel, encoding: .utf8)
require(partialRowStillPresent && fileManager.isExecutableFile(atPath: partialExecutable.path) &&
        partialSentinelValue == "partial outside data",
        "failed partial cleanup retains the row and managed package without touching external data")
try fileManager.removeItem(at: partialDirectory.appendingPathComponent("installation/codex-home/external-link"))
try codexInstallService.removeRegistration(entry: partialEntry) {
    _ = try registrationStore.remove(id: partialEntry.id)
}

// A concurrent operation lock prevents both filesystem cleanup and row deletion.
let lockEntry = try registrationStore.add(provider: .codex).last!
let operationLockURL = codexInstallService.registrationOperationLockURL(for: lockEntry)
try fileManager.createDirectory(at: operationLockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
let externalLockDescriptor = open(operationLockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
require(externalLockDescriptor >= 0 && flock(externalLockDescriptor, LOCK_EX | LOCK_NB) == 0,
        "synthetic competing operation obtains the UUID lock")
var rowRemovalCalledUnderContention = false
do {
    try codexInstallService.removeRegistration(entry: lockEntry) {
        rowRemovalCalledUnderContention = true
        _ = try registrationStore.remove(id: lockEntry.id)
    }
    fatalError("busy UUID lock must block trash")
} catch CLIInstallError.installationInProgress {
}
_ = flock(externalLockDescriptor, LOCK_UN)
_ = close(externalLockDescriptor)
let storeAfterLockFailure = try registrationStore.load()
require(!rowRemovalCalledUnderContention &&
        storeAfterLockFailure.contains(where: { $0.id == lockEntry.id }),
        "a competing UUID operation leaves both registration and files untouched")
_ = try registrationStore.remove(id: lockEntry.id)

// Uninstalled rows can still own data from a previous Desinstalar action; trash clears it.
let residualEntry = try registrationStore.add(provider: .codex).last!
let residualDirectory = codexInstallService.registrationDirectory(for: residualEntry)
let residualConfig = residualDirectory.appendingPathComponent("installation/codex-home/config.toml")
let residualLogin = residualDirectory.appendingPathComponent("installation/codex-home/auth.json")
try fileManager.createDirectory(at: residualConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
try Data("synthetic residual config".utf8).write(to: residualConfig)
try Data("synthetic residual login".utf8).write(to: residualLogin)
require(codexInstallService.registrationInstallStatus(for: residualEntry) == .notInstalled,
        "retained data after ordinary uninstall does not imply an installed CLI")
try codexInstallService.removeRegistration(entry: residualEntry) {
    _ = try registrationStore.remove(id: residualEntry.id)
}
let storeAfterResidualTrash = try registrationStore.load()
require(!fileManager.fileExists(atPath: residualDirectory.path) &&
        !storeAfterResidualTrash.contains(where: { $0.id == residualEntry.id }),
        "trash of a noninstalled registration also deletes its residual UUID data")

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
