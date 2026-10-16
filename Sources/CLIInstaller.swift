import Foundation
import Darwin

/// Providers offered for manual registration. Codex installation is UUID-scoped;
/// login and the other providers' installers remain unavailable.
enum CLIProvider: String, CaseIterable, Identifiable {
    case codex = "CodexCLI"
    case claude = "ClaudeCLI"
    case antigravity = "AntigravityCLI"

    var id: String { rawValue }

    var catalogTitle: String {
        switch self {
        case .codex: return "CodexCLI"
        case .claude: return "ClaudeCLI"
        case .antigravity: return "Antigravity CLI"
        }
    }

    var executableName: String {
        switch self {
        case .codex: return "codex"
        case .claude: return "claude"
        case .antigravity: return "agy"
        }
    }
}

/// The automatic inventory intentionally retains Gemini CLI as a separate real target,
/// even though Gemini is no longer offered for new manual registrations.
enum CLIDiscoveryTarget: String, Codable, CaseIterable, Hashable {
    case codex = "CodexCLI"
    case claude = "ClaudeCLI"
    case gemini = "GeminiCLI"
    case antigravity = "AntigravityCLI"

    var displayName: String {
        switch self {
        case .codex: return "CodexCLI"
        case .claude: return "ClaudeCLI"
        case .gemini: return "Gemini CLI"
        case .antigravity: return "Antigravity CLI"
        }
    }

    var executableName: String {
        switch self {
        case .codex: return "codex"
        case .claude: return "claude"
        case .gemini: return "gemini"
        case .antigravity: return "agy"
        }
    }

    var catalogProvider: CLIProvider? {
        switch self {
        case .codex: return .codex
        case .claude: return .claude
        case .gemini: return nil
        case .antigravity: return .antigravity
        }
    }

    init?(legacyProviderName: String) {
        switch legacyProviderName {
        case "CodexCLI": self = .codex
        case "ClaudeCLI": self = .claude
        case "GeminiCLI": self = .gemini
        case "AntigravityCLI": self = .antigravity
        default: return nil
        }
    }
}

struct CLIDiscovery: Equatable {
    let target: CLIDiscoveryTarget
    let executableURL: URL
    let discoveryURL: URL
    let isManaged: Bool

    var displayName: String { target.displayName }
}

enum CLIInstallError: Error, Equatable, LocalizedError {
    case unsupportedProvider
    case npmUnavailable
    case nodeUnavailable
    case alreadyInstalled
    case installationInProgress
    case incompleteInstallation
    case commandFailed(Int32)
    case commandTimedOut

    var errorDescription: String? {
        switch self {
        case .unsupportedProvider:
            return "A instalação ainda não está disponível para este provedor."
        case .npmUnavailable:
            return "Não encontrei o npm no PATH deste app. Instale o Node.js e tente novamente."
        case .nodeUnavailable:
            return "Não encontrei o Node.js no PATH deste app; o npm não pode iniciar sem ele."
        case .alreadyInstalled:
            return "Este cadastro já possui uma instalação isolada."
        case .installationInProgress:
            return "A instalação deste cadastro já está em andamento."
        case .incompleteInstallation:
            return "A instalação isolada não pôde ser validada; este cadastro continua não instalado."
        case .commandFailed(let status):
            return "npm terminou com erro (código \(status)); este cadastro não foi marcado como instalado."
        case .commandTimedOut:
            return "npm excedeu 15 minutos; este cadastro não foi marcado como instalado."
        }
    }
}

enum CLIRegistrationInstallStatus: Equatable {
    case unsupported
    case notInstalled
    case installing
    case installed
    case incomplete
    case failed(String)

    var canInstall: Bool {
        switch self {
        case .notInstalled, .failed: return true
        case .unsupported, .installing, .installed, .incomplete: return false
        }
    }

    var displayText: String {
        switch self {
        case .unsupported: return "Instalação ainda indisponível para este provedor"
        case .notInstalled: return "Cadastro manual · não instalado"
        case .installing: return "Instalação isolada em andamento · login não configurado"
        case .installed: return "Instalada isoladamente neste cadastro · login não configurado"
        case .incomplete: return "Instalação incompleta neste cadastro · remova e crie um registro novo"
        case .failed(let message): return "Falha na instalação isolada · \(message)"
        }
    }
}

typealias CLICommandRunner = (_ executable: URL, _ arguments: [String], _ environment: [String: String]) throws -> Int32

private enum CLIProcessExecutor {
    static func run(executable: URL, arguments: [String], environment: [String: String]) throws -> Int32 {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        let processExited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in processExited.signal() }
        try process.run()
        let outputDrain = DispatchGroup()
        outputDrain.enter()
        DispatchQueue.global(qos: .utility).async {
            while !output.fileHandleForReading.readData(ofLength: 4096).isEmpty {}
            outputDrain.leave()
        }
        guard processExited.wait(timeout: .now() + .seconds(15 * 60)) == .success else {
            process.terminate()
            if processExited.wait(timeout: .now() + .seconds(5)) != .success {
                _ = kill(process.processIdentifier, SIGKILL)
                _ = processExited.wait(timeout: .now() + .seconds(5))
            }
            throw CLIInstallError.commandTimedOut
        }
        outputDrain.wait()
        return process.terminationStatus
    }
}

struct CLIInstallService {
    private let fileManager: FileManager
    private let applicationDirectory: URL
    private let environment: [String: String]
    private let homeDirectory: URL
    private let additionalSearchDirectories: [URL]?
    private let knownExecutableOverrides: [CLIDiscoveryTarget: [URL]]?
    private let npmExecutableOverride: URL?
    private let nodeExecutableOverride: URL?
    private let processRunner: CLICommandRunner

    init(applicationSupportDirectory: URL,
         fileManager: FileManager = .default,
         environment: [String: String] = ProcessInfo.processInfo.environment,
         homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
         additionalSearchDirectories: [URL]? = nil,
         knownExecutableOverrides: [CLIDiscoveryTarget: [URL]]? = nil,
         npmExecutableOverride: URL? = nil,
         nodeExecutableOverride: URL? = nil,
         processRunner: @escaping CLICommandRunner = CLIProcessExecutor.run) {
        self.fileManager = fileManager
        self.applicationDirectory = applicationSupportDirectory
            .appendingPathComponent("PainelCli", isDirectory: true)
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.additionalSearchDirectories = additionalSearchDirectories
        self.knownExecutableOverrides = knownExecutableOverrides
        self.npmExecutableOverride = npmExecutableOverride
        self.nodeExecutableOverride = nodeExecutableOverride
        self.processRunner = processRunner
    }

    static func userService() throws -> CLIInstallService {
        let supportDirectory = try FileManager.default.url(for: .applicationSupportDirectory,
                                                           in: .userDomainMask,
                                                           appropriateFor: nil,
                                                           create: true)
        return CLIInstallService(applicationSupportDirectory: supportDirectory)
    }

    /// Reports only this registration's UUID-scoped installation. A matching executable in
    /// PATH, ChatGPT.app, or another registration never changes this result.
    func registrationInstallStatus(for entry: CLIEntry) -> CLIRegistrationInstallStatus {
        guard entry.provider == CLIProvider.codex.rawValue else { return .unsupported }
        let root = installationRoot(for: entry)
        guard fileManager.fileExists(atPath: root.appendingPathComponent("install.json").path) else {
            let contents = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
            return contents.contains(where: { $0.hasPrefix(".stage-") }) ? .incomplete : .notInstalled
        }
        guard let data = try? Data(contentsOf: root.appendingPathComponent("install.json")),
              let manifest = try? JSONDecoder().decode(InstallManifest.self, from: data),
              manifest.registrationID == entry.id,
              manifest.provider == entry.provider,
              manifest.package == "@openai/codex@latest",
              manifest.executableRelativePath == Self.codexExecutableRelativePath,
              let config = try? String(contentsOf: root.appendingPathComponent("codex-home/config.toml"),
                                       encoding: .utf8),
              config.contains("cli_auth_credentials_store = \"file\""),
              fileManager.isExecutableFile(atPath: root.appendingPathComponent(
                manifest.executableRelativePath).path) else {
            return .incomplete
        }
        return .installed
    }

    /// Installs the official npm Codex package into a temporary directory owned by one UUID,
    /// then atomically publishes that directory after validating the executable and manifest.
    /// It never invokes Codex or starts authentication.
    @discardableResult
    func install(entry: CLIEntry) throws -> URL {
        guard entry.provider == CLIProvider.codex.rawValue else { throw CLIInstallError.unsupportedProvider }
        switch registrationInstallStatus(for: entry) {
        case .installed: throw CLIInstallError.alreadyInstalled
        case .installing: throw CLIInstallError.installationInProgress
        case .incomplete: throw CLIInstallError.incompleteInstallation
        case .unsupported: throw CLIInstallError.unsupportedProvider
        case .notInstalled, .failed: break
        }
        guard let npm = npmExecutable(), fileManager.isExecutableFile(atPath: npm.path) else {
            throw CLIInstallError.npmUnavailable
        }
        guard let node = nodeExecutable(), fileManager.isExecutableFile(atPath: node.path) else {
            throw CLIInstallError.nodeUnavailable
        }

        let registrationDirectory = registrationDirectory(for: entry)
        try fileManager.createDirectory(at: registrationDirectory, withIntermediateDirectories: true)
        try setPrivatePermissions(registrationDirectory)

        let lockURL = registrationDirectory.appendingPathComponent(".install.lock")
        let lockDescriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard lockDescriptor >= 0 else { throw CLIInstallError.installationInProgress }
        defer { _ = flock(lockDescriptor, LOCK_UN); _ = close(lockDescriptor) }
        guard flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw CLIInstallError.installationInProgress
        }

        // Re-check after acquiring the per-UUID lock so concurrent clicks cannot duplicate work.
        switch registrationInstallStatus(for: entry) {
        case .installed: throw CLIInstallError.alreadyInstalled
        case .installing: throw CLIInstallError.installationInProgress
        case .incomplete: throw CLIInstallError.incompleteInstallation
        case .unsupported: throw CLIInstallError.unsupportedProvider
        case .notInstalled, .failed: break
        }

        let stage = registrationDirectory.appendingPathComponent(".stage-\(UUID().uuidString)",
                                                                 isDirectory: true)
        let finalRoot = installationRoot(for: entry)
        guard !fileManager.fileExists(atPath: finalRoot.path) else {
            throw CLIInstallError.incompleteInstallation
        }
        try fileManager.createDirectory(at: stage, withIntermediateDirectories: false)
        try setPrivatePermissions(stage)
        var published = false
        defer {
            if !published { try? fileManager.removeItem(at: stage) }
        }

        let packagePrefix = stage.appendingPathComponent("package", isDirectory: true)
        let codexHome = stage.appendingPathComponent("codex-home", isDirectory: true)
        let npmHome = stage.appendingPathComponent("npm-home", isDirectory: true)
        let npmCache = stage.appendingPathComponent("npm-cache", isDirectory: true)
        let tempDirectory = stage.appendingPathComponent("tmp", isDirectory: true)
        let runtimeHome = stage.appendingPathComponent("home", isDirectory: true)
        let xdg = stage.appendingPathComponent("xdg", isDirectory: true)
        let npmUserConfig = stage.appendingPathComponent("npm-user.npmrc")
        let npmGlobalConfig = stage.appendingPathComponent("npm-global.npmrc")
        for directory in [packagePrefix, codexHome, npmHome, npmCache, tempDirectory,
                          runtimeHome,
                          xdg.appendingPathComponent("config", isDirectory: true),
                          xdg.appendingPathComponent("cache", isDirectory: true),
                          xdg.appendingPathComponent("data", isDirectory: true)] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try setPrivatePermissions(directory)
        }

        try Data().write(to: npmUserConfig, options: .atomic)
        try Data().write(to: npmGlobalConfig, options: .atomic)
        try setPrivatePermissions(npmUserConfig, mode: 0o600)
        try setPrivatePermissions(npmGlobalConfig, mode: 0o600)

        let isolatedEnvironment = npmEnvironment(npm: npm, node: node, home: npmHome, codexHome: codexHome,
                                                 cache: npmCache, temp: tempDirectory,
                                                 packagePrefix: packagePrefix,
                                                 userConfig: npmUserConfig,
                                                 globalConfig: npmGlobalConfig)
        let arguments = ["install", "--prefix", packagePrefix.path,
                         "--userconfig", npmUserConfig.path,
                         "--globalconfig", npmGlobalConfig.path,
                         "--registry", "https://registry.npmjs.org",
                         "--no-save", "--no-package-lock", "@openai/codex@latest"]
        let exitCode = try processRunner(npm, arguments, isolatedEnvironment)
        guard exitCode == 0 else { throw CLIInstallError.commandFailed(exitCode) }

        let executable = stage.appendingPathComponent(Self.codexExecutableRelativePath)
        guard fileManager.isExecutableFile(atPath: executable.path) else {
            throw CLIInstallError.incompleteInstallation
        }
        // Reassert the isolated credential backend after package lifecycle scripts finish.
        let config = codexHome.appendingPathComponent("config.toml")
        try Data("cli_auth_credentials_store = \"file\"\n".utf8).write(to: config, options: .atomic)
        try setPrivatePermissions(config, mode: 0o600)
        let manifest = InstallManifest(registrationID: entry.id, provider: entry.provider,
                                       package: "@openai/codex@latest",
                                       executableRelativePath: Self.codexExecutableRelativePath)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: stage.appendingPathComponent("install.json"), options: .atomic)
        try fileManager.moveItem(at: stage, to: finalRoot)
        published = true
        return finalRoot.appendingPathComponent(Self.codexExecutableRelativePath)
    }

    /// Runtime variables are assembled from an allowlist. This keeps HOME, CODEX_HOME,
    /// XDG state and auth-file storage scoped to the registration without touching the host.
    func isolatedRuntimeEnvironment(for entry: CLIEntry) throws -> [String: String] {
        guard registrationInstallStatus(for: entry) == .installed else {
            throw CLIInstallError.incompleteInstallation
        }
        let root = installationRoot(for: entry)
        let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
        let instanceHome = root.appendingPathComponent("home", isDirectory: true)
        let xdg = root.appendingPathComponent("xdg", isDirectory: true)
        let temp = root.appendingPathComponent("tmp", isDirectory: true)
        let localBin = root.appendingPathComponent(Self.codexExecutableRelativePath).deletingLastPathComponent()
        var safePath = [localBin.path]
        safePath += searchDirectories().filter { directory in
            let codexOnPath = fileManager.isExecutableFile(atPath: directory.appendingPathComponent("codex").path)
            let nodeOnPath = fileManager.isExecutableFile(atPath: directory.appendingPathComponent("node").path)
            return !codexOnPath || nodeOnPath
        }.map(\.path)
        var result = ["PATH": safePath.joined(separator: ":"),
                      "HOME": instanceHome.path,
                      "CODEX_HOME": codexHome.path,
                      "XDG_CONFIG_HOME": xdg.appendingPathComponent("config").path,
                      "XDG_CACHE_HOME": xdg.appendingPathComponent("cache").path,
                      "XDG_DATA_HOME": xdg.appendingPathComponent("data").path,
                      "TMPDIR": temp.path]
        for key in ["LANG", "LC_ALL", "TERM"] {
            if let value = environment[key] { result[key] = value }
        }
        return result
    }

    func registrationDirectory(for entry: CLIEntry) -> URL {
        applicationDirectory.appendingPathComponent("Registrations", isDirectory: true)
            .appendingPathComponent(entry.id.uuidString, isDirectory: true)
    }

    func managedExecutableURL(for entry: CLIEntry) -> URL {
        installationRoot(for: entry).appendingPathComponent(Self.codexExecutableRelativePath)
    }

    /// Inspects executable bits and paths only. No discovered CLI is invoked or authenticated.
    func detectedInstallations() -> [CLIDiscovery] {
        CLIDiscoveryTarget.allCases.flatMap(detectedInstallations(for:))
    }

    func detectedInstallations(for target: CLIDiscoveryTarget) -> [CLIDiscovery] {
        let managed = installationDirectory(for: target)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent(target.executableName, isDirectory: false)
        var candidates = [managed]
        candidates += searchDirectories().map { $0.appendingPathComponent(target.executableName) }
        candidates += knownExecutables(for: target)

        var seen = Set<String>()
        return candidates.compactMap { candidate in
            guard fileManager.isExecutableFile(atPath: candidate.path) else { return nil }
            let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
            guard seen.insert(resolved.path).inserted else { return nil }
            let managedPath = managed.resolvingSymlinksInPath().standardizedFileURL.path
            return CLIDiscovery(target: target, executableURL: resolved,
                                discoveryURL: candidate.standardizedFileURL,
                                isManaged: resolved.path == managedPath)
        }
    }

    func installationDirectory(for target: CLIDiscoveryTarget) -> URL {
        applicationDirectory.appendingPathComponent("Installations", isDirectory: true)
            .appendingPathComponent(target.rawValue, isDirectory: true)
    }

    private func installationRoot(for entry: CLIEntry) -> URL {
        registrationDirectory(for: entry).appendingPathComponent("installation", isDirectory: true)
    }

    private func npmExecutable() -> URL? {
        if let npmExecutableOverride { return npmExecutableOverride }
        return searchDirectories().map { $0.appendingPathComponent("npm", isDirectory: false) }
            .first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    private func nodeExecutable() -> URL? {
        if let nodeExecutableOverride { return nodeExecutableOverride }
        return searchDirectories().map { $0.appendingPathComponent("node", isDirectory: false) }
            .first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    private func npmEnvironment(npm: URL, node: URL, home: URL, codexHome: URL, cache: URL, temp: URL,
                                packagePrefix: URL, userConfig: URL, globalConfig: URL) -> [String: String] {
        let originalPath = environment["PATH"] ?? "/usr/bin:/bin"
        let toolPaths = [npm.deletingLastPathComponent().path, node.deletingLastPathComponent().path]
        var result = ["PATH": (toolPaths + [originalPath]).joined(separator: ":"),
                      "HOME": home.path,
                      "CODEX_HOME": codexHome.path,
                      "NPM_CONFIG_CACHE": cache.path,
                      "NPM_CONFIG_PREFIX": packagePrefix.path,
                      "NPM_CONFIG_USERCONFIG": userConfig.path,
                      "NPM_CONFIG_GLOBALCONFIG": globalConfig.path,
                      "TMPDIR": temp.path,
                      "CI": "1"]
        for key in ["LANG", "LC_ALL"] {
            if let value = environment[key] { result[key] = value }
        }
        return result
    }

    private func setPrivatePermissions(_ url: URL, mode: Int16 = 0o700) throws {
        try fileManager.setAttributes([.posixPermissions: NSNumber(value: mode)],
                                      ofItemAtPath: url.path)
    }

    private static let codexExecutableRelativePath = "package/node_modules/.bin/codex"

    private struct InstallManifest: Codable {
        let registrationID: UUID
        let provider: String
        let package: String
        let executableRelativePath: String
    }

    private func knownExecutables(for target: CLIDiscoveryTarget) -> [URL] {
        if let knownExecutableOverrides { return knownExecutableOverrides[target] ?? [] }
        guard target == .codex else { return [] }
        let appRelativePath = "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
        return [URL(fileURLWithPath: "/Applications/ChatGPT.app", isDirectory: true)
                    .appendingPathComponent(appRelativePath),
                homeDirectory.appendingPathComponent("Applications/ChatGPT.app", isDirectory: true)
                    .appendingPathComponent(appRelativePath)]
    }

    private func searchDirectories() -> [URL] {
        var directories: [URL] = []
        if let path = environment["PATH"] {
            directories += path.split(separator: ":").map { URL(fileURLWithPath: String($0), isDirectory: true) }
        }
        if let additionalSearchDirectories {
            directories += additionalSearchDirectories
        } else {
            directories += [URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
                            URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
                            URL(fileURLWithPath: "/opt/local/bin", isDirectory: true),
                            URL(fileURLWithPath: "/usr/bin", isDirectory: true),
                            URL(fileURLWithPath: "/bin", isDirectory: true),
                            URL(fileURLWithPath: "/usr/sbin", isDirectory: true),
                            URL(fileURLWithPath: "/sbin", isDirectory: true),
                            homeDirectory.appendingPathComponent(".local/bin", isDirectory: true),
                            homeDirectory.appendingPathComponent(".npm-global/bin", isDirectory: true),
                            homeDirectory.appendingPathComponent("bin", isDirectory: true)]
            let nvmDirectory = homeDirectory.appendingPathComponent(".nvm/versions/node", isDirectory: true)
            if let versions = try? fileManager.contentsOfDirectory(at: nvmDirectory,
                                                                   includingPropertiesForKeys: nil) {
                directories += versions.sorted { $0.lastPathComponent > $1.lastPathComponent }
                    .map { $0.appendingPathComponent("bin", isDirectory: true) }
            }
        }
        var seen = Set<String>()
        return directories.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
}
