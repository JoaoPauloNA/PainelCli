import Foundation
import Darwin
import CoreFoundation

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
    case nodeVersionUnsupported
    case alreadyInstalled
    case notInstalled
    case installationInProgress
    case incompleteInstallation
    case commandFailed(Int32)
    case commandTimedOut
    case authenticationPolicyBlocked
    case authenticationStorageUnavailable
    case logoutNotConfirmed
    case browserUnavailable
    case unsupportedAuthenticationMethod
    case authenticationStatusUnavailable
    case unsupportedClaudeVersion
    case claudeLogoutFailed(Int32)
    case claudeCleanupReceiptRequired

    var errorDescription: String? {
        switch self {
        case .unsupportedProvider:
            return "A instalação ainda não está disponível para este provedor."
        case .npmUnavailable:
            return "Não encontrei o npm no PATH deste app. Instale o Node.js e tente novamente."
        case .nodeUnavailable:
            return "Não encontrei o Node.js no PATH deste app; o npm não pode iniciar sem ele."
        case .nodeVersionUnsupported:
            return "A instalação npm oficial do Claude Code exige Node.js 22 ou posterior. Atualize o Node.js e tente novamente."
        case .alreadyInstalled:
            return "Este cadastro já possui uma instalação isolada."
        case .notInstalled:
            return "Este cadastro não possui uma instalação isolada para remover."
        case .installationInProgress:
            return "A instalação deste cadastro já está em andamento."
        case .incompleteInstallation:
            return "Os dados deste UUID não puderam ser validados com segurança; o cadastro foi mantido sem declarar a remoção concluída."
        case .commandFailed(let status):
            return "npm terminou com erro (código \(status)); este cadastro não foi marcado como instalado."
        case .commandTimedOut:
            return "npm excedeu 15 minutos; este cadastro não foi marcado como instalado."
        case .authenticationPolicyBlocked:
            return "A configuração deste cadastro não confirma um método de autenticação isolado compatível; login ou remoção bloqueados."
        case .authenticationStorageUnavailable:
            return "O login não pôde ser confirmado no arquivo privado deste cadastro."
        case .logoutNotConfirmed:
            return "A CLI não confirmou a saída deste cadastro; o estado do login continua indeterminado."
        case .browserUnavailable:
            return "Não encontrei o Safari para abrir o fluxo oficial de login."
        case .unsupportedAuthenticationMethod:
            return "Este cadastro usa um método de autenticação que o PainelCli não pode isolar com segurança."
        case .authenticationStatusUnavailable:
            return "A CLI não retornou um status de autenticação verificável para este cadastro."
        case .unsupportedClaudeVersion:
            return "A versão instalada não oferece o comando oficial de status de autenticação necessário."
        case .claudeLogoutFailed(let status):
            return "O logout oficial do Claude Code falhou (código \(status)); o pacote e o cadastro foram mantidos."
        case .claudeCleanupReceiptRequired:
            return "O logout oficial deste cadastro não foi comprovado antes da desinstalação. O cadastro e os dados foram mantidos; reinstale o pacote gerenciado e use Desinstalar para limpar a credencial com segurança."
        }
    }
}

enum CLIAuthenticationStatus: Equatable {
    case notAuthenticated
    case authenticated
}

enum ClaudeCLIAuthenticationStatus: Equatable {
    case notAuthenticated
    case authenticated
    case unsupportedMethod
}

struct ClaudeCLIAuthStatusDocument: Equatable {
    let authMethod: String
    let configDirectory: String

    static func parse(_ data: Data) -> ClaudeCLIAuthStatusDocument? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let authMethod = object["authMethod"] as? String,
              let configDirectory = object["configDirectory"] as? String,
              !configDirectory.isEmpty else { return nil }
        return ClaudeCLIAuthStatusDocument(authMethod: authMethod,
                                           configDirectory: configDirectory)
    }

    func status(expectedConfigDirectory: URL) -> ClaudeCLIAuthenticationStatus? {
        let expected = expectedConfigDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        let actualURL = URL(fileURLWithPath: configDirectory, isDirectory: true)
        guard actualURL.standardizedFileURL.resolvingSymlinksInPath().path == expected else { return nil }
        switch authMethod {
        case "none": return .notAuthenticated
        case "claude.ai": return .authenticated
        case "oauth_token", "api_key", "api_key_helper", "third_party": return .unsupportedMethod
        default: return nil
        }
    }
}

enum CLIAuthenticationUIState: Equatable {
    case checking
    case notAuthenticated
    case starting
    case awaitingBrowserAuthorization(pageOpened: Bool)
    case awaitingClaudeBrowser
    case loggingOut
    case authenticated
    case failed(String)
    case statusError(String)
    case cancelled

    var displayText: String {
        switch self {
        case .checking: return "Verificando login isolado…"
        case .notAuthenticated: return "Login não configurado neste cadastro"
        case .starting: return "Iniciando login isolado…"
        case .loggingOut: return "Saindo deste cadastro…"
        case .awaitingBrowserAuthorization(let opened):
            return opened
                ? "Safari aberto. Conclua o login e a autorização."
                : "Safari não abriu. Tente novamente para iniciar o login pelo navegador."
        case .awaitingClaudeBrowser: return "Aguardando autorização no navegador pelo fluxo oficial do Claude."
        case .authenticated: return "Autenticado neste cadastro"
        case .failed(let message): return "Falha no login isolado · \(message)"
        case .statusError(let message): return "Estado do login indeterminado · \(message)"
        case .cancelled: return "Login isolado cancelado"
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
struct CLICommandOutput: Equatable {
    let status: Int32
    let stdout: Data
}
typealias CLICommandOutputRunner = (_ executable: URL, _ arguments: [String], _ environment: [String: String]) throws -> CLICommandOutput
typealias CLIAuthenticationProcessLauncher = (_ executable: URL, _ arguments: [String], _ environment: [String: String], _ input: Pipe, _ output: Pipe) throws -> Process

final class CLIRegistrationOperationLock {
    private let lock = NSLock()
    private var descriptor: Int32?

    init(descriptor: Int32) { self.descriptor = descriptor }

    func release() {
        lock.lock()
        defer { lock.unlock() }
        guard let descriptor else { return }
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
        self.descriptor = nil
    }

    deinit { release() }
}

struct CLIAuthenticationSession {
    let process: Process
    let input: Pipe
    let output: Pipe
    private let operationLock: CLIRegistrationOperationLock

    init(process: Process, input: Pipe, output: Pipe,
         operationLock: CLIRegistrationOperationLock) {
        self.process = process
        self.input = input
        self.output = output
        self.operationLock = operationLock
    }

    func releaseOperationLock() { operationLock.release() }
}

enum CLIAppServerLoginProtocol {
    static func message(id: Int, method: String, params: [String: Any]) -> Data? {
        encode(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
    }

    static func notification(method: String, params: [String: Any]? = nil) -> Data? {
        var value: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let params { value["params"] = params }
        return encode(value)
    }

    static func startRequest() -> Data? {
        message(id: 2, method: "account/login/start", params: ["type": "chatgpt"])
    }

    static func authURL(from response: [String: Any]) -> URL? {
        guard let result = response["result"] as? [String: Any],
              result["type"] as? String == "chatgpt",
              let raw = result["authUrl"] as? String,
              let url = URL(string: raw), url.scheme == "https", url.host == "auth.openai.com" else { return nil }
        return url
    }

    static func loginID(from response: [String: Any]) -> String? {
        (response["result"] as? [String: Any])?["loginId"] as? String
    }

    private static func encode(_ object: [String: Any]) -> Data? {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        data.append(0x0A)
        return data
    }
}

private enum CLIProcessExecutor {
    static func start(executable: URL, arguments: [String], environment: [String: String], input: Pipe, output: Pipe) throws -> Process {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

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

    static func runCapturingOutput(executable: URL, arguments: [String],
                                   environment: [String: String]) throws -> CLICommandOutput {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        var data = Data()
        let drained = DispatchGroup()
        drained.enter()
        DispatchQueue.global(qos: .utility).async {
            while true {
                let chunk = output.fileHandleForReading.readData(ofLength: 4096)
                if chunk.isEmpty { break }
                data.append(chunk)
            }
            drained.leave()
        }
        guard exited.wait(timeout: .now() + .seconds(30)) == .success else {
            process.terminate()
            if exited.wait(timeout: .now() + .seconds(3)) != .success {
                _ = kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + .seconds(3))
            }
            throw CLIInstallError.commandTimedOut
        }
        drained.wait()
        return CLICommandOutput(status: process.terminationStatus, stdout: data)
    }
}

struct CLIInstallService {
    private struct ClaudeRuntimePaths {
        let root: URL
        init(root: URL) { self.root = root }
        var package: URL { root.appendingPathComponent("package", isDirectory: true) }
        var config: URL { root.appendingPathComponent("claude-config", isDirectory: true) }
        var home: URL { root.appendingPathComponent("home", isDirectory: true) }
        var npmHome: URL { root.appendingPathComponent("npm-home", isDirectory: true) }
        var npmCache: URL { root.appendingPathComponent("npm-cache", isDirectory: true) }
        var temp: URL { root.appendingPathComponent("tmp", isDirectory: true) }
        var xdgConfig: URL { root.appendingPathComponent("xdg/config", isDirectory: true) }
        var xdgCache: URL { root.appendingPathComponent("xdg/cache", isDirectory: true) }
        var xdgData: URL { root.appendingPathComponent("xdg/data", isDirectory: true) }
        var npmUserConfig: URL { root.appendingPathComponent("npm-user.npmrc") }
        var npmGlobalConfig: URL { root.appendingPathComponent("npm-global.npmrc") }
    }

    private struct ClaudeCleanupReceipt: Codable {
        let schemaVersion: Int
        let registrationID: UUID
        let configDirectory: String
        let logoutVerified: Bool
    }

    private let fileManager: FileManager
    private let applicationDirectory: URL
    private let environment: [String: String]
    private let homeDirectory: URL
    private let additionalSearchDirectories: [URL]?
    private let knownExecutableOverrides: [CLIDiscoveryTarget: [URL]]?
    private let npmExecutableOverride: URL?
    private let nodeExecutableOverride: URL?
    private let processRunner: CLICommandRunner
    private let outputRunner: CLICommandOutputRunner
    private let authenticationProcessLauncher: CLIAuthenticationProcessLauncher
    private let safariAvailableOverride: Bool?

    init(applicationSupportDirectory: URL,
         fileManager: FileManager = .default,
         environment: [String: String] = ProcessInfo.processInfo.environment,
         homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
         additionalSearchDirectories: [URL]? = nil,
         knownExecutableOverrides: [CLIDiscoveryTarget: [URL]]? = nil,
         npmExecutableOverride: URL? = nil,
         nodeExecutableOverride: URL? = nil,
         processRunner: @escaping CLICommandRunner = CLIProcessExecutor.run,
         outputRunner: @escaping CLICommandOutputRunner = CLIProcessExecutor.runCapturingOutput,
         safariAvailableOverride: Bool? = nil,
         authenticationProcessLauncher: @escaping CLIAuthenticationProcessLauncher = CLIProcessExecutor.start) {
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
        self.outputRunner = outputRunner
        self.safariAvailableOverride = safariAvailableOverride
        self.authenticationProcessLauncher = authenticationProcessLauncher
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
        guard entry.provider == CLIProvider.codex.rawValue || entry.provider == CLIProvider.claude.rawValue else {
            return .unsupported
        }
        let root = installationRoot(for: entry)
        guard fileManager.fileExists(atPath: root.appendingPathComponent("install.json").path) else {
            let contents = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
            let hasPackage = fileManager.fileExists(atPath: root.appendingPathComponent("package").path)
            return contents.contains(where: { $0.hasPrefix(".stage-") }) || hasPackage
                ? .incomplete : .notInstalled
        }
        guard let data = try? Data(contentsOf: root.appendingPathComponent("install.json")),
              let manifest = try? JSONDecoder().decode(InstallManifest.self, from: data),
              manifest.registrationID == entry.id,
              manifest.provider == entry.provider,
              isSafeRegistrationDirectory(registrationDirectory(for: entry)),
              isOwnedRealDirectory(root),
              root.resolvingSymlinksInPath().standardizedFileURL == root.standardizedFileURL,
              isOwnedRegularFile(root.appendingPathComponent("install.json")),
              hasPrivatePermissions(root, allowingOwnerMode: 0o700),
              (try? symlinksStayInside(root)) == true,
              fileManager.isExecutableFile(atPath: root.appendingPathComponent(manifest.executableRelativePath).path) else {
            return .incomplete
        }
        if entry.provider == CLIProvider.codex.rawValue {
            guard manifest.package == "@openai/codex@latest",
                  manifest.executableRelativePath == Self.codexExecutableRelativePath,
                  let config = try? String(contentsOf: root.appendingPathComponent("codex-home/config.toml"),
                                           encoding: .utf8),
                  config.contains("cli_auth_credentials_store = \"file\"") else { return .incomplete }
        } else {
            guard manifest.package == "@anthropic-ai/claude-code@latest",
                  manifest.executableRelativePath == Self.claudeExecutableRelativePath,
                  let version = manifest.version,
                  Self.isSupportedClaudeVersion(version),
                  isOwnedRealDirectory(root.appendingPathComponent("claude-config", isDirectory: true)),
                  hasPrivatePermissions(root.appendingPathComponent("claude-config", isDirectory: true), allowingOwnerMode: 0o700),
                  isOwnedRealDirectory(root.appendingPathComponent("home", isDirectory: true)),
                  hasPrivatePermissions(root.appendingPathComponent("home", isDirectory: true), allowingOwnerMode: 0o700),
                  claudeExecutableResolvesInsideRegistration(root.appendingPathComponent(manifest.executableRelativePath),
                                                             registrationRoot: root) else { return .incomplete }
        }
        return .installed
    }

    /// Installs the official npm Codex package into a temporary directory owned by one UUID,
    /// then atomically publishes that directory after validating the executable and manifest.
    /// It never invokes Codex or starts authentication.
    @discardableResult
    func install(entry: CLIEntry) throws -> URL {
        if entry.provider == CLIProvider.claude.rawValue { return try installClaude(entry: entry) }
        guard entry.provider == CLIProvider.codex.rawValue else { throw CLIInstallError.unsupportedProvider }
        let directory = registrationDirectory(for: entry)
        if fileManager.fileExists(atPath: directory.path) {
            guard isSafeRegistrationDirectory(directory),
                  try symlinksStayInside(directory) else {
                throw CLIInstallError.incompleteInstallation
            }
        }

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
        let operationLock = try acquireRegistrationLock(for: entry)
        defer { operationLock.release() }

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
        if fileManager.fileExists(atPath: finalRoot.path) {
            try copyRetainedRegistrationData(from: finalRoot, to: stage)
        }
        for directory in [packagePrefix, codexHome, npmHome, npmCache, tempDirectory,
                          runtimeHome,
                          xdg.appendingPathComponent("config", isDirectory: true),
                          xdg.appendingPathComponent("cache", isDirectory: true),
                          xdg.appendingPathComponent("data", isDirectory: true)] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try setPrivatePermissions(directory)
        }

        if !fileManager.fileExists(atPath: npmUserConfig.path) {
            try Data().write(to: npmUserConfig, options: .atomic)
        }
        if !fileManager.fileExists(atPath: npmGlobalConfig.path) {
            try Data().write(to: npmGlobalConfig, options: .atomic)
        }
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
        try enforceFileCredentialStore(in: config)
        try setPrivatePermissions(config, mode: 0o600)
        let retainedAuthFile = codexHome.appendingPathComponent("auth.json")
        if fileManager.fileExists(atPath: retainedAuthFile.path) {
            try setPrivatePermissions(retainedAuthFile, mode: 0o600)
        }
        let manifest = InstallManifest(registrationID: entry.id, provider: entry.provider,
                                       package: "@openai/codex@latest",
                                       executableRelativePath: Self.codexExecutableRelativePath)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: stage.appendingPathComponent("install.json"), options: .atomic)
        let backupRoot = registrationDirectory.appendingPathComponent(".uninstalled-\(UUID().uuidString)",
                                                                      isDirectory: true)
        let hasRetainedRoot = fileManager.fileExists(atPath: finalRoot.path)
        if hasRetainedRoot { try fileManager.moveItem(at: finalRoot, to: backupRoot) }
        do {
            try fileManager.moveItem(at: stage, to: finalRoot)
        } catch {
            if hasRetainedRoot, fileManager.fileExists(atPath: backupRoot.path) {
                try? fileManager.moveItem(at: backupRoot, to: finalRoot)
            }
            throw error
        }
        if hasRetainedRoot { try fileManager.removeItem(at: backupRoot) }
        published = true
        return finalRoot.appendingPathComponent(Self.codexExecutableRelativePath)
    }

    /// Claude logout is completed and verified before removing its package so later trash
    /// can safely delete the UUID config without requiring a reinstall. Codex data is unchanged.
    func uninstall(entry: CLIEntry) throws {
        guard entry.provider == CLIProvider.codex.rawValue || entry.provider == CLIProvider.claude.rawValue else {
            throw CLIInstallError.unsupportedProvider
        }
        let operationLock = try acquireRegistrationLock(for: entry)
        defer { operationLock.release() }
        guard registrationInstallStatus(for: entry) == .installed else {
            throw CLIInstallError.incompleteInstallation
        }
        if entry.provider == CLIProvider.claude.rawValue {
            _ = try logoutClaudeWhileLocked(for: entry)
            try writeClaudeCleanupReceipt(for: entry)
        }
        try removeManagedPackageAndManifest(for: entry)
    }

    /// Permanently removes all data owned by this manual UUID and saves its row deletion
    /// while holding the same lock used by install, login, logout, and ordinary uninstall.
    /// The optional removal closure runs only after the UUID directory is confirmed absent.
    func removeRegistration(entry: CLIEntry, removeRecord: () throws -> Void) throws {
        guard entry.origin == .manual,
              entry.provider == CLIProvider.codex.rawValue || entry.provider == CLIProvider.claude.rawValue else {
            throw CLIInstallError.unsupportedProvider
        }
        let operationLock = try acquireRegistrationLock(for: entry)
        defer { operationLock.release() }

        let directory = registrationDirectory(for: entry)
        if fileManager.fileExists(atPath: directory.path) {
            guard isSafeRegistrationDirectory(directory),
                  try symlinksStayInside(directory) else {
                throw CLIInstallError.incompleteInstallation
            }
        }

        if entry.provider == CLIProvider.claude.rawValue {
            let root = installationRoot(for: entry)
            let config = root.appendingPathComponent("claude-config", isDirectory: true)
            switch registrationInstallStatus(for: entry) {
            case .installed:
                _ = try logoutClaudeWhileLocked(for: entry)
            case .installing:
                throw CLIInstallError.installationInProgress
            case .unsupported:
                throw CLIInstallError.unsupportedProvider
            case .failed:
                throw CLIInstallError.incompleteInstallation
            case .incomplete, .notInstalled:
                if fileManager.fileExists(atPath: config.path),
                   !hasVerifiedClaudeCleanupReceipt(for: entry) {
                    throw CLIInstallError.claudeCleanupReceiptRequired
                }
            }
        }

        switch registrationInstallStatus(for: entry) {
        case .installed, .incomplete, .notInstalled:
            break
        case .installing:
            throw CLIInstallError.installationInProgress
        case .unsupported:
            throw CLIInstallError.unsupportedProvider
        case .failed:
            throw CLIInstallError.incompleteInstallation
        }

        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
        guard !fileManager.fileExists(atPath: directory.path),
              registrationInstallStatus(for: entry) == .notInstalled else {
            throw CLIInstallError.incompleteInstallation
        }
        let lockRegistryDescriptor = try acquireLockRegistry()
        defer { releaseLockRegistry(lockRegistryDescriptor) }
        let lockURL = registrationOperationLockURL(for: entry)
        if unlink(lockURL.path) != 0 && errno != ENOENT {
            throw CLIInstallError.installationInProgress
        }
        operationLock.release()
        try removeRecord()
    }

    private func removeManagedPackageAndManifest(for entry: CLIEntry) throws {
        let root = installationRoot(for: entry)
        if fileManager.fileExists(atPath: root.path) {
            guard isRealDirectory(root) else { throw CLIInstallError.incompleteInstallation }
            let package = root.appendingPathComponent("package", isDirectory: true)
            let manifest = root.appendingPathComponent("install.json")
            if fileManager.fileExists(atPath: package.path) {
                guard isRealDirectory(package) else { throw CLIInstallError.incompleteInstallation }
                try fileManager.removeItem(at: package)
            }
            if fileManager.fileExists(atPath: manifest.path) {
                guard isRegularFile(manifest) else { throw CLIInstallError.incompleteInstallation }
                try fileManager.removeItem(at: manifest)
            }
        }
        guard registrationInstallStatus(for: entry) == .notInstalled else {
            throw CLIInstallError.incompleteInstallation
        }
    }

    private func claudeCleanupReceiptURL(for entry: CLIEntry) -> URL {
        installationRoot(for: entry).appendingPathComponent(".claude-cleanup-receipt.json")
    }

    private func writeClaudeCleanupReceipt(for entry: CLIEntry) throws {
        let paths = ClaudeRuntimePaths(root: installationRoot(for: entry))
        let receipt = ClaudeCleanupReceipt(schemaVersion: 1, registrationID: entry.id,
                                           configDirectory: paths.config.standardizedFileURL.path,
                                           logoutVerified: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let receiptURL = claudeCleanupReceiptURL(for: entry)
        try encoder.encode(receipt).write(to: receiptURL, options: .atomic)
        try setPrivatePermissions(receiptURL, mode: 0o600)
        guard hasVerifiedClaudeCleanupReceipt(for: entry) else {
            throw CLIInstallError.incompleteInstallation
        }
    }

    /// This receipt is written only after the managed CLI logged out successfully and
    /// a fresh status query returned `none` for the exact UUID config directory.
    private func hasVerifiedClaudeCleanupReceipt(for entry: CLIEntry) -> Bool {
        let root = installationRoot(for: entry)
        let receiptURL = claudeCleanupReceiptURL(for: entry)
        guard isOwnedRealDirectory(root), hasPrivatePermissions(root, allowingOwnerMode: 0o700),
              isOwnedRegularFile(receiptURL), hasPrivatePermissions(receiptURL, allowingOwnerMode: 0o600),
              let data = try? Data(contentsOf: receiptURL),
              let receipt = try? JSONDecoder().decode(ClaudeCleanupReceipt.self, from: data) else {
            return false
        }
        let expectedConfig = ClaudeRuntimePaths(root: root).config.standardizedFileURL.path
        return receipt.schemaVersion == 1 && receipt.registrationID == entry.id &&
            receipt.configDirectory == expectedConfig && receipt.logoutVerified
    }

    func claudeAuthenticationStatus(for entry: CLIEntry) throws -> ClaudeCLIAuthenticationStatus {
        guard entry.provider == CLIProvider.claude.rawValue,
              registrationInstallStatus(for: entry) == .installed else {
            throw CLIInstallError.incompleteInstallation
        }
        let paths = ClaudeRuntimePaths(root: installationRoot(for: entry))
        let result = try outputRunner(managedExecutableURL(for: entry), ["auth", "status", "--json"],
                                      claudeRuntimeEnvironment(entry: entry, rootOverride: nil,
                                                               npm: nil, node: nil,
                                                               npmUserConfig: paths.npmUserConfig,
                                                               npmGlobalConfig: paths.npmGlobalConfig,
                                                               installationPhase: false))
        guard let document = ClaudeCLIAuthStatusDocument.parse(result.stdout),
              let status = document.status(expectedConfigDirectory: paths.config) else {
            throw CLIInstallError.authenticationStatusUnavailable
        }
        return status
    }

    func logoutClaude(for entry: CLIEntry) throws -> ClaudeCLIAuthenticationStatus {
        guard entry.provider == CLIProvider.claude.rawValue else { throw CLIInstallError.unsupportedProvider }
        let operationLock = try acquireRegistrationLock(for: entry)
        defer { operationLock.release() }
        return try logoutClaudeWhileLocked(for: entry)
    }

    private func logoutClaudeWhileLocked(for entry: CLIEntry) throws -> ClaudeCLIAuthenticationStatus {
        guard registrationInstallStatus(for: entry) == .installed else {
            throw CLIInstallError.incompleteInstallation
        }
        let before = try claudeAuthenticationStatus(for: entry)
        guard before != .unsupportedMethod else { throw CLIInstallError.authenticationPolicyBlocked }
        let paths = ClaudeRuntimePaths(root: installationRoot(for: entry))
        let result = try outputRunner(managedExecutableURL(for: entry), ["auth", "logout"],
                                      claudeRuntimeEnvironment(entry: entry, rootOverride: nil,
                                                               npm: nil, node: nil,
                                                               npmUserConfig: paths.npmUserConfig,
                                                               npmGlobalConfig: paths.npmGlobalConfig,
                                                               installationPhase: false))
        guard result.status == 0 else { throw CLIInstallError.claudeLogoutFailed(result.status) }
        let after = try claudeAuthenticationStatus(for: entry)
        guard after == .notAuthenticated else { throw CLIInstallError.logoutNotConfirmed }
        return after
    }

    func startClaudeAuthentication(for entry: CLIEntry) throws -> CLIAuthenticationSession {
        let operationLock = try acquireRegistrationLock(for: entry)
        guard registrationInstallStatus(for: entry) == .installed else {
            operationLock.release()
            throw CLIInstallError.incompleteInstallation
        }
        do {
            guard safariAvailableOverride ?? fileManager.isExecutableFile(atPath: Self.safariExecutablePath) else {
                operationLock.release()
                throw CLIInstallError.browserUnavailable
            }
            let status = try claudeAuthenticationStatus(for: entry)
            guard status == .notAuthenticated else {
                operationLock.release()
                throw status == .authenticated ? CLIInstallError.alreadyInstalled : CLIInstallError.authenticationPolicyBlocked
            }
            let paths = ClaudeRuntimePaths(root: installationRoot(for: entry))
            let input = Pipe()
            let output = Pipe()
            var runtime = claudeRuntimeEnvironment(entry: entry, rootOverride: nil,
                                                   npm: nil, node: nil,
                                                   npmUserConfig: paths.npmUserConfig,
                                                   npmGlobalConfig: paths.npmGlobalConfig,
                                                   installationPhase: false)
            // Prefer Safari without changing the user's Launch Services default.
            runtime["BROWSER"] = Self.safariExecutablePath
            let process = try authenticationProcessLauncher(managedExecutableURL(for: entry),
                                                            ["auth", "login"], runtime, input, output)
            return CLIAuthenticationSession(process: process, input: input, output: output,
                                            operationLock: operationLock)
        } catch {
            operationLock.release()
            throw error
        }
    }

    func isolatedClaudeRuntimeEnvironment(for entry: CLIEntry) throws -> [String: String] {
        guard entry.provider == CLIProvider.claude.rawValue,
              registrationInstallStatus(for: entry) == .installed else {
            throw CLIInstallError.incompleteInstallation
        }
        let paths = ClaudeRuntimePaths(root: installationRoot(for: entry))
        return claudeRuntimeEnvironment(entry: entry, rootOverride: nil,
                                        npm: nil, node: nil,
                                        npmUserConfig: paths.npmUserConfig,
                                        npmGlobalConfig: paths.npmGlobalConfig,
                                        installationPhase: false)
    }

    /// Installs the official npm Claude Code package into a UUID-owned prefix. npm/node
    /// are prerequisites supplied by the user; this flow never installs them globally.
    @discardableResult
    private func installClaude(entry: CLIEntry) throws -> URL {
        let directory = registrationDirectory(for: entry)
        if fileManager.fileExists(atPath: directory.path) {
            guard isSafeRegistrationDirectory(directory), try symlinksStayInside(directory) else {
                throw CLIInstallError.incompleteInstallation
            }
        }
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
        let nodeVersion = try outputRunner(node, ["--version"], ["PATH": node.deletingLastPathComponent().path])
        guard nodeVersion.status == 0, Self.isSupportedNodeVersion(nodeVersion.stdout) else {
            throw CLIInstallError.nodeVersionUnsupported
        }

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try setPrivatePermissions(directory)
        let operationLock = try acquireRegistrationLock(for: entry)
        defer { operationLock.release() }
        switch registrationInstallStatus(for: entry) {
        case .installed: throw CLIInstallError.alreadyInstalled
        case .installing: throw CLIInstallError.installationInProgress
        case .incomplete: throw CLIInstallError.incompleteInstallation
        case .unsupported: throw CLIInstallError.unsupportedProvider
        case .notInstalled, .failed: break
        }

        let stage = directory.appendingPathComponent(".stage-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: stage, withIntermediateDirectories: false)
        try setPrivatePermissions(stage)
        var published = false
        defer { if !published { try? fileManager.removeItem(at: stage) } }

        let paths = ClaudeRuntimePaths(root: stage)
        let finalRoot = installationRoot(for: entry)
        let hasRetainedRoot = fileManager.fileExists(atPath: finalRoot.path)
        if hasRetainedRoot { try copyRetainedRegistrationData(from: finalRoot, to: stage) }
        for path in [paths.package, paths.config, paths.home, paths.npmHome, paths.npmCache,
                     paths.temp, paths.xdgConfig, paths.xdgCache, paths.xdgData] {
            try fileManager.createDirectory(at: path, withIntermediateDirectories: true)
            try setPrivatePermissions(path)
        }
        for config in [paths.npmUserConfig, paths.npmGlobalConfig] {
            try Data().write(to: config, options: .atomic)
            try setPrivatePermissions(config, mode: 0o600)
        }
        let installEnvironment = claudeRuntimeEnvironment(entry: entry, rootOverride: stage,
                                                         npm: npm, node: node,
                                                         npmUserConfig: paths.npmUserConfig,
                                                         npmGlobalConfig: paths.npmGlobalConfig,
                                                         installationPhase: true)
        let arguments = ["install", "--prefix", paths.package.path,
                         "--userconfig", paths.npmUserConfig.path,
                         "--globalconfig", paths.npmGlobalConfig.path,
                         "--registry", "https://registry.npmjs.org", "--no-audit", "--no-fund",
                         "--no-save", "--no-package-lock", "@anthropic-ai/claude-code@latest"]
        let installStatus = try processRunner(npm, arguments, installEnvironment)
        guard installStatus == 0 else { throw CLIInstallError.commandFailed(installStatus) }

        let executable = stage.appendingPathComponent(Self.claudeExecutableRelativePath)
        guard claudeExecutableResolvesInsideRegistration(executable, registrationRoot: stage) else {
            throw CLIInstallError.incompleteInstallation
        }
        guard try symlinksStayInside(stage) else { throw CLIInstallError.incompleteInstallation }
        let versionResult = try outputRunner(executable, ["--version"],
                                             claudeRuntimeEnvironment(entry: entry, rootOverride: stage,
                                                                      npm: nil, node: nil,
                                                                      npmUserConfig: paths.npmUserConfig,
                                                                      npmGlobalConfig: paths.npmGlobalConfig,
                                                                      installationPhase: false))
        guard versionResult.status == 0,
              let version = Self.parseClaudeVersion(versionResult.stdout),
              Self.isSupportedClaudeVersion(version) else { throw CLIInstallError.unsupportedClaudeVersion }
        let manifest = InstallManifest(registrationID: entry.id, provider: entry.provider,
                                       package: "@anthropic-ai/claude-code@latest",
                                       executableRelativePath: Self.claudeExecutableRelativePath,
                                       version: version)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: stage.appendingPathComponent("install.json"), options: .atomic)
        let backupRoot = directory.appendingPathComponent(".uninstalled-\(UUID().uuidString)",
                                                          isDirectory: true)
        if hasRetainedRoot { try fileManager.moveItem(at: finalRoot, to: backupRoot) }
        do {
            try fileManager.moveItem(at: stage, to: finalRoot)
        } catch {
            if hasRetainedRoot, fileManager.fileExists(atPath: backupRoot.path) {
                try? fileManager.moveItem(at: backupRoot, to: finalRoot)
            }
            throw error
        }
        if hasRetainedRoot { try fileManager.removeItem(at: backupRoot) }
        published = true
        return finalRoot.appendingPathComponent(Self.claudeExecutableRelativePath)
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

    /// Checks credentials using only this UUID's executable and environment. CLI output is
    /// discarded; callers receive only the documented exit-status result.
    func authenticationStatus(for entry: CLIEntry) throws -> CLIAuthenticationStatus {
        guard registrationInstallStatus(for: entry) == .installed else {
            throw CLIInstallError.incompleteInstallation
        }
        try validateAuthenticationPolicy(for: entry)
        let executable = managedExecutableURL(for: entry)
        let status = try processRunner(executable, ["login", "status"],
                                       isolatedRuntimeEnvironment(for: entry))
        guard status == 0 else { return .notAuthenticated }
        let codexHome = installationRoot(for: entry).appendingPathComponent("codex-home", isDirectory: true)
        let authFile = codexHome.appendingPathComponent("auth.json")
        guard hasPrivatePermissions(codexHome, allowingOwnerMode: 0o700),
              hasPrivatePermissions(authFile, allowingOwnerMode: 0o600) else {
            throw CLIInstallError.authenticationStorageUnavailable
        }
        return .authenticated
    }

    /// Clears only the Codex credentials selected by this registration's CODEX_HOME,
    /// then requires the same isolated CLI to confirm that it is signed out.
    func logout(for entry: CLIEntry) throws -> CLIAuthenticationStatus {
        guard entry.provider == CLIProvider.codex.rawValue else { throw CLIInstallError.unsupportedProvider }
        let operationLock = try acquireRegistrationLock(for: entry)
        defer { operationLock.release() }
        guard registrationInstallStatus(for: entry) == .installed else {
            throw CLIInstallError.incompleteInstallation
        }
        let before = try authenticationStatus(for: entry)
        guard before == .authenticated else { return .notAuthenticated }
        let exitCode = try processRunner(managedExecutableURL(for: entry), ["logout"],
                                         isolatedRuntimeEnvironment(for: entry))
        guard exitCode == 0 else { throw CLIInstallError.commandFailed(exitCode) }
        let after = try authenticationStatus(for: entry)
        guard after == .notAuthenticated else { throw CLIInstallError.logoutNotConfirmed }
        return after
    }

    /// Starts the official CLI app-server with this registration's isolated environment.
    /// Starts the browser OAuth flow through the official Codex app-server.
    func startAuthentication(for entry: CLIEntry) throws -> CLIAuthenticationSession {
        let operationLock = try acquireRegistrationLock(for: entry)
        guard registrationInstallStatus(for: entry) == .installed else {
            throw CLIInstallError.incompleteInstallation
        }
        try validateAuthenticationPolicy(for: entry)
        guard fileManager.fileExists(atPath: Self.safariExecutablePath) else {
            throw CLIInstallError.browserUnavailable
        }
        let input = Pipe()
        let output = Pipe()
        let process = try authenticationProcessLauncher(managedExecutableURL(for: entry),
                                                        ["app-server", "--stdio"],
                                                        isolatedRuntimeEnvironment(for: entry), input, output)
        if let initialize = CLIAppServerLoginProtocol.message(
            id: 1, method: "initialize", params: [
                "clientInfo": ["name": "PainelCli", "title": "PainelCli", "version": "0.0.0.29"],
                "capabilities": ["experimentalApi": true]
            ]) {
            input.fileHandleForWriting.write(initialize)
        }
        return CLIAuthenticationSession(process: process, input: input, output: output,
                                        operationLock: operationLock)
    }

    func openBrowserAuthenticationPage(for entry: CLIEntry, authURL: URL) throws -> Bool {
        guard authURL.scheme == "https", authURL.host == "auth.openai.com",
              authURL.path == "/oauth/authorize", fileManager.fileExists(atPath: Self.safariExecutablePath) else {
            throw CLIInstallError.browserUnavailable
        }
        return try openSafari(authURL)
    }

    private func openSafari(_ url: URL) throws -> Bool {
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-a", "/Applications/Safari.app", url.absoluteString]
        open.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        open.standardInput = FileHandle.nullDevice
        open.standardOutput = FileHandle.nullDevice
        open.standardError = FileHandle.nullDevice
        try open.run()
        open.waitUntilExit()
        return open.terminationStatus == 0
    }

    /// Admin-enforced credential policies outrank the instance config. Inspect only the
    /// relevant auth keys from system/managed files and macOS managed preferences; never
    /// emit their contents. Cloud requirements do not control these local auth settings.
    private func validateAuthenticationPolicy(for entry: CLIEntry) throws {
        var policyDocuments: [String] = []
        for path in ["/etc/codex/requirements.toml", "/etc/codex/managed_config.toml"] {
            if let contents = try? String(contentsOfFile: path, encoding: .utf8) {
                policyDocuments.append(contents)
            }
        }
        for key in ["config_toml_base64", "requirements_toml_base64"] {
            if let encoded = CFPreferencesCopyAppValue(key as CFString,
                                                       "com.openai.codex" as CFString) as? String,
               let data = Data(base64Encoded: encoded),
               let decoded = String(data: data, encoding: .utf8) {
                policyDocuments.append(decoded)
            }
        }

        let instanceConfig = installationRoot(for: entry).appendingPathComponent("codex-home/config.toml")
        guard let config = try? String(contentsOf: instanceConfig, encoding: .utf8),
              Self.authenticationPolicyAllowsFile(documents: policyDocuments, instanceConfig: config) else {
            throw CLIInstallError.authenticationPolicyBlocked
        }
    }

    static func authenticationPolicyAllowsFile(documents: [String], instanceConfig: String) -> Bool {
        guard rootSetting("cli_auth_credentials_store", in: instanceConfig) == "file" else { return false }
        for document in documents {
            if let store = rootSetting("cli_auth_credentials_store", in: document), store != "file" {
                return false
            }
            if let methods = rootSetting("allowed_login_methods", in: document),
               !methods.contains("\"chatgpt\"") {
                return false
            }
            if let workspaces = rootSetting("allowed_chatgpt_workspaces", in: document),
               workspaces.trimmingCharacters(in: .whitespacesAndNewlines) == "[]" {
                return false
            }
        }
        return true
    }

    private static func rootSetting(_ key: String, in document: String) -> String? {
        var inRootTable = true
        for line in document.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { inRootTable = false; continue }
            guard inRootTable, let equal = trimmed.firstIndex(of: "=") else { continue }
            let name = trimmed[..<equal].trimmingCharacters(in: .whitespaces)
            guard name == key else { continue }
            let raw = trimmed[trimmed.index(after: equal)...]
                .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first?
                .trimmingCharacters(in: .whitespaces) ?? ""
            if raw.first == "\"", let end = raw.dropFirst().firstIndex(of: "\"") {
                return String(raw[raw.index(after: raw.startIndex)..<end])
            }
            return raw
        }
        return nil
    }

    func registrationDirectory(for entry: CLIEntry) -> URL {
        applicationDirectory.appendingPathComponent("Registrations", isDirectory: true)
            .appendingPathComponent(entry.id.uuidString, isDirectory: true)
    }

    func managedExecutableURL(for entry: CLIEntry) -> URL {
        installationRoot(for: entry).appendingPathComponent(entry.provider == CLIProvider.claude.rawValue
            ? Self.claudeExecutableRelativePath : Self.codexExecutableRelativePath)
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

    private func claudeRuntimeEnvironment(entry: CLIEntry, rootOverride: URL?, npm: URL?, node: URL?,
                                          npmUserConfig: URL, npmGlobalConfig: URL,
                                          installationPhase: Bool) -> [String: String] {
        let paths = ClaudeRuntimePaths(root: rootOverride ?? installationRoot(for: entry))
        var path = [paths.package.appendingPathComponent("node_modules/.bin").path]
        if installationPhase, let npm, let node {
            path = [npm.deletingLastPathComponent().path, node.deletingLastPathComponent().path] + path
        }
        let hostPath = (environment["PATH"] ?? "/usr/bin:/bin")
            .split(separator: ":").map(String.init)
        path += hostPath.filter { directory in
            !fileManager.isExecutableFile(atPath: URL(fileURLWithPath: directory)
                .appendingPathComponent("claude").path)
        }
        var result = ["PATH": path.joined(separator: ":"),
                      "HOME": installationPhase ? paths.npmHome.path : paths.home.path,
                      "CLAUDE_CONFIG_DIR": paths.config.path,
                      "CLAUDE_CODE_TMPDIR": paths.temp.path,
                      "TMPDIR": paths.temp.path,
                      "XDG_CONFIG_HOME": paths.xdgConfig.path,
                      "XDG_CACHE_HOME": paths.xdgCache.path,
                      "XDG_DATA_HOME": paths.xdgData.path,
                      "DISABLE_UPDATES": "1",
                      "DISABLE_AUTOUPDATER": "1"]
        if installationPhase {
            result["NPM_CONFIG_CACHE"] = paths.npmCache.path
            result["NPM_CONFIG_PREFIX"] = paths.package.path
            result["NPM_CONFIG_USERCONFIG"] = npmUserConfig.path
            result["NPM_CONFIG_GLOBALCONFIG"] = npmGlobalConfig.path
            result["CI"] = "1"
        }
        for key in ["LANG", "LC_ALL", "TERM"] {
            if let value = environment[key] { result[key] = value }
        }
        return result
    }

    private func claudeExecutableResolvesInsideRegistration(_ executable: URL,
                                                            registrationRoot: URL) -> Bool {
        let root = registrationRoot.standardizedFileURL.resolvingSymlinksInPath().path
        let resolved = executable.standardizedFileURL.resolvingSymlinksInPath()
        var info = stat()
        return resolved.path.hasPrefix(root + "/") &&
            lstat(resolved.path, &info) == 0 &&
            (info.st_mode & S_IFMT) == S_IFREG && info.st_uid == getuid() &&
            fileManager.isExecutableFile(atPath: resolved.path)
    }

    private static func parseClaudeVersion(_ data: Data) -> String? {
        guard let output = String(data: data, encoding: .utf8) else { return nil }
        let version = output.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespaces).first ?? ""
        let components = version.split(separator: ".")
        guard components.count == 3, components.allSatisfy({ Int($0) != nil }) else { return nil }
        return version
    }

    private static func isSupportedNodeVersion(_ data: Data) -> Bool {
        guard let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let major = Int(value.drop(while: { !$0.isNumber }).prefix(while: \.isNumber)) else { return false }
        return major >= 22
    }

    private static func isSupportedClaudeVersion(_ version: String) -> Bool {
        let components = version.split(separator: ".").compactMap { Int($0) }
        guard components.count == 3 else { return false }
        let minimum = [2, 1, 268]
        for index in 0..<3 {
            if components[index] != minimum[index] { return components[index] > minimum[index] }
        }
        return true
    }

    private func setPrivatePermissions(_ url: URL, mode: Int16 = 0o700) throws {
        try fileManager.setAttributes([.posixPermissions: NSNumber(value: mode)],
                                      ofItemAtPath: url.path)
    }

    func registrationOperationLockURL(for entry: CLIEntry) -> URL {
        applicationDirectory.appendingPathComponent("RegistrationLocks", isDirectory: true)
            .appendingPathComponent("\(entry.id.uuidString).lock", isDirectory: false)
    }

    private func acquireLockRegistry() throws -> Int32 {
        let lockDirectory = applicationDirectory.appendingPathComponent("RegistrationLocks", isDirectory: true)
        try fileManager.createDirectory(at: lockDirectory, withIntermediateDirectories: true)
        guard isOwnedRealDirectory(lockDirectory),
              lockDirectory.resolvingSymlinksInPath().standardizedFileURL == lockDirectory.standardizedFileURL else {
            throw CLIInstallError.incompleteInstallation
        }
        try setPrivatePermissions(lockDirectory)
        let url = lockDirectory.appendingPathComponent("registry.lock")
        let descriptor = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw CLIInstallError.installationInProgress }
        var lockInfo = stat()
        guard fstat(descriptor, &lockInfo) == 0,
              (lockInfo.st_mode & S_IFMT) == S_IFREG, lockInfo.st_uid == getuid() else {
            _ = close(descriptor)
            throw CLIInstallError.installationInProgress
        }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            _ = close(descriptor)
            throw CLIInstallError.installationInProgress
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            _ = close(descriptor)
            throw CLIInstallError.installationInProgress
        }
        return descriptor
    }

    private func releaseLockRegistry(_ descriptor: Int32) {
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
    }

    private func acquireRegistrationLock(for entry: CLIEntry) throws -> CLIRegistrationOperationLock {
        let registryDescriptor = try acquireLockRegistry()
        defer { releaseLockRegistry(registryDescriptor) }
        let url = registrationOperationLockURL(for: entry)
        let descriptor = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw CLIInstallError.installationInProgress }
        var lockInfo = stat()
        guard fstat(descriptor, &lockInfo) == 0,
              (lockInfo.st_mode & S_IFMT) == S_IFREG, lockInfo.st_uid == getuid() else {
            _ = close(descriptor)
            throw CLIInstallError.installationInProgress
        }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            _ = close(descriptor)
            throw CLIInstallError.installationInProgress
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            _ = close(descriptor)
            throw CLIInstallError.installationInProgress
        }
        return CLIRegistrationOperationLock(descriptor: descriptor)
    }

    private func symlinksStayInside(_ root: URL) throws -> Bool {
        let rootPath = root.standardizedFileURL.path
        guard let enumerator = fileManager.enumerator(at: root,
                                                     includingPropertiesForKeys: nil,
                                                     options: []) else { return false }
        for case let item as URL in enumerator {
            var info = stat()
            guard lstat(item.path, &info) == 0, info.st_uid == getuid() else { return false }
            guard (info.st_mode & S_IFMT) == S_IFLNK else { continue }
            let rawTarget = try fileManager.destinationOfSymbolicLink(atPath: item.path)
            let target = rawTarget.hasPrefix("/")
                ? URL(fileURLWithPath: rawTarget)
                : item.deletingLastPathComponent().appendingPathComponent(rawTarget)
            let resolvedPath = target.standardizedFileURL.resolvingSymlinksInPath().path
            if resolvedPath == rootPath || resolvedPath.hasPrefix(rootPath + "/") { continue }
            // Browser profile IPC can leave links to its Unix socket outside the UUID.
            // Allow unlinking that reference only; directory removal never follows it.
            var targetInfo = stat()
            guard stat(target.path, &targetInfo) == 0,
                  (targetInfo.st_mode & S_IFMT) == S_IFSOCK,
                  targetInfo.st_uid == getuid() else { return false }
        }
        return true
    }

    private func isSafeRegistrationDirectory(_ directory: URL) -> Bool {
        let registrations = applicationDirectory.appendingPathComponent("Registrations", isDirectory: true)
        let paths = [applicationDirectory, registrations, directory]
        return paths.allSatisfy {
            isOwnedRealDirectory($0) &&
                $0.resolvingSymlinksInPath().standardizedFileURL == $0.standardizedFileURL
        }
    }

    private func copyRetainedRegistrationData(from source: URL, to destination: URL) throws {
        guard isRealDirectory(source) else { throw CLIInstallError.incompleteInstallation }
        for name in ["codex-home", "claude-config", "home", "xdg", "npm-home", "npm-cache", "tmp"] {
            let from = source.appendingPathComponent(name, isDirectory: true)
            guard fileManager.fileExists(atPath: from.path) else { continue }
            guard isRealDirectory(from) else { throw CLIInstallError.incompleteInstallation }
            try fileManager.copyItem(at: from, to: destination.appendingPathComponent(name, isDirectory: true))
        }
        for name in ["npm-user.npmrc", "npm-global.npmrc"] {
            let from = source.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: from.path) else { continue }
            guard isRegularFile(from) else { throw CLIInstallError.incompleteInstallation }
            try fileManager.copyItem(at: from, to: destination.appendingPathComponent(name))
            try setPrivatePermissions(destination.appendingPathComponent(name), mode: 0o600)
        }
    }

    private func enforceFileCredentialStore(in config: URL) throws {
        let existing = (try? String(contentsOf: config, encoding: .utf8)) ?? ""
        var lines = existing.components(separatedBy: .newlines)
        var found = false
        var inRootTable = true
        for index in lines.indices {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { inRootTable = false; continue }
            if inRootTable,
               trimmed.split(separator: "=", maxSplits: 1).first.map({
                   $0.trimmingCharacters(in: .whitespaces) == "cli_auth_credentials_store"
               }) == true {
                lines[index] = "cli_auth_credentials_store = \"file\""
                found = true
            }
        }
        if !found {
            let firstTable = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") }) ?? lines.endIndex
            lines.insert("cli_auth_credentials_store = \"file\"", at: firstTable)
        }
        let content = lines.joined(separator: "\n").trimmingCharacters(in: .newlines) + "\n"
        try Data(content.utf8).write(to: config, options: .atomic)
    }

    private func isRealDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    private func isOwnedRealDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 &&
            (info.st_mode & S_IFMT) == S_IFDIR && info.st_uid == getuid()
    }

    private func isRegularFile(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }

    private func isOwnedRegularFile(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 &&
            (info.st_mode & S_IFMT) == S_IFREG && info.st_uid == getuid()
    }

    private func hasPrivatePermissions(_ url: URL, allowingOwnerMode: Int16) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular ||
                attributes[.type] as? FileAttributeType == .typeDirectory,
              let permissions = attributes[.posixPermissions] as? NSNumber else { return false }
        let mode = permissions.int16Value
        return mode & 0o077 == 0 && mode & allowingOwnerMode == allowingOwnerMode
    }

    private static let codexExecutableRelativePath = "package/node_modules/.bin/codex"
    private static let claudeExecutableRelativePath = "package/node_modules/.bin/claude"
    private static let safariExecutablePath = "/Applications/Safari.app/Contents/MacOS/Safari"

    private struct InstallManifest: Codable {
        let registrationID: UUID
        let provider: String
        let package: String
        let executableRelativePath: String
        let version: String?

        init(registrationID: UUID, provider: String, package: String,
             executableRelativePath: String, version: String? = nil) {
            self.registrationID = registrationID
            self.provider = provider
            self.package = package
            self.executableRelativePath = executableRelativePath
            self.version = version
        }
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
