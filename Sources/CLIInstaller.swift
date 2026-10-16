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
    case alreadyInstalled
    case installationInProgress
    case incompleteInstallation
    case commandFailed(Int32)
    case commandTimedOut
    case authenticationPolicyBlocked
    case authenticationStorageUnavailable
    case browserUnavailable

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
        case .authenticationPolicyBlocked:
            return "A política local não confirma armazenamento de credenciais isolado em arquivo; login bloqueado."
        case .authenticationStorageUnavailable:
            return "O login não pôde ser confirmado no arquivo privado deste cadastro."
        case .browserUnavailable:
            return "Não encontrei o Safari para abrir o fluxo oficial de login."
        }
    }
}

enum CLIAuthenticationStatus: Equatable {
    case notAuthenticated
    case authenticated
}

enum CLIAuthenticationUIState: Equatable {
    case checking
    case notAuthenticated
    case starting
    case awaitingBrowserAuthorization(pageOpened: Bool)
    case awaitingUserCode(String, clipboardCopied: Bool, pageOpened: Bool)
    case authenticated
    case failed(String)
    case cancelled

    var displayText: String {
        switch self {
        case .checking: return "Verificando login isolado…"
        case .notAuthenticated: return "Login não configurado neste cadastro"
        case .starting: return "Iniciando login isolado…"
        case .awaitingBrowserAuthorization(let opened):
            return opened
                ? "Safari aberto. Conclua o login e a autorização."
                : "Safari não abriu. Cancele e escolha Código para tentar a alternativa."
        case .awaitingUserCode(let code, let clipboardCopied, let pageOpened):
            switch (clipboardCopied, pageOpened) {
            case (true, true): return "Código copiado. No Safari, cole e confirme: \(code)"
            case (false, true): return "Falha ao copiar. Digite o código no Safari: \(code)"
            case (true, false): return "Código copiado. Abra a página oficial e cole: \(code)"
            case (false, false): return "Falha ao copiar e abrir a página. Digite o código manualmente: \(code)"
            }
        case .authenticated: return "Autenticado neste cadastro"
        case .failed(let message): return "Falha no login isolado · \(message)"
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
typealias CLIAuthenticationProcessLauncher = (_ executable: URL, _ arguments: [String], _ environment: [String: String], _ input: Pipe, _ output: Pipe) throws -> Process

enum CLIAuthenticationMode: Equatable {
    case browser
    case deviceCode

    var appServerLoginType: String {
        switch self {
        case .browser: return "chatgpt"
        case .deviceCode: return "chatgptDeviceCode"
        }
    }
}

struct CLIAuthenticationSession {
    let process: Process
    let input: Pipe
    let output: Pipe
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

    static func startRequest(mode: CLIAuthenticationMode) -> Data? {
        message(id: 2, method: "account/login/start", params: ["type": mode.appServerLoginType])
    }

    static func authURL(from response: [String: Any]) -> URL? {
        guard let result = response["result"] as? [String: Any],
              result["type"] as? String == CLIAuthenticationMode.browser.appServerLoginType,
              let raw = result["authUrl"] as? String,
              let url = URL(string: raw), url.scheme == "https", url.host == "auth.openai.com" else { return nil }
        return url
    }

    static func loginID(from response: [String: Any]) -> String? {
        (response["result"] as? [String: Any])?["loginId"] as? String
    }

    static func devicePrompt(from response: [String: Any]) -> CLIDeviceCodePrompt? {
        guard let result = response["result"] as? [String: Any],
              result["type"] as? String == CLIAuthenticationMode.deviceCode.appServerLoginType,
              let rawURL = result["verificationUrl"] as? String,
              let url = URL(string: rawURL), url.scheme == "https",
              url.host == "auth.openai.com", url.path == "/codex/device",
              let code = result["userCode"] as? String, !code.isEmpty else { return nil }
        return CLIDeviceCodePrompt(verificationURL: url, code: code)
    }

    private static func encode(_ object: [String: Any]) -> Data? {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        data.append(0x0A)
        return data
    }
}

struct CLIDeviceCodePrompt: Equatable {
    let verificationURL: URL
    let code: String
}

struct CLIDeviceCodeHandoffResult: Equatable {
    let clipboardCopied: Bool
    let pageOpened: Bool
}

/// Claims one active CLI prompt and copies its code before handing the page to Safari.
/// The app invokes this on the main queue so cancellation and UI handoff are serialized.
final class CLIDeviceCodeHandoff {
    private let lock = NSLock()
    private var cancelled = false
    private var handledPrompt = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func handle(prompt: CLIDeviceCodePrompt,
                processIsRunning: Bool,
                copyCode: (String) -> Bool,
                openPage: (URL) -> Bool) -> CLIDeviceCodeHandoffResult? {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled, !handledPrompt, processIsRunning else { return nil }
        handledPrompt = true
        let copied = copyCode(prompt.code)
        let opened = openPage(prompt.verificationURL)
        return CLIDeviceCodeHandoffResult(clipboardCopied: copied, pageOpened: opened)
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
    private let authenticationProcessLauncher: CLIAuthenticationProcessLauncher

    init(applicationSupportDirectory: URL,
         fileManager: FileManager = .default,
         environment: [String: String] = ProcessInfo.processInfo.environment,
         homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
         additionalSearchDirectories: [URL]? = nil,
         knownExecutableOverrides: [CLIDiscoveryTarget: [URL]]? = nil,
         npmExecutableOverride: URL? = nil,
         nodeExecutableOverride: URL? = nil,
         processRunner: @escaping CLICommandRunner = CLIProcessExecutor.run,
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

    /// Starts the official CLI app-server with this registration's isolated environment.
    /// Browser and device-code login are distinct, explicit account/login/start requests.
    func startAuthentication(for entry: CLIEntry,
                             mode: CLIAuthenticationMode = .browser) throws -> CLIAuthenticationSession {
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
                "clientInfo": ["name": "PainelCli", "title": "PainelCli", "version": "0.0.0.27"],
                "capabilities": ["experimentalApi": true]
            ]) {
            input.fileHandleForWriting.write(initialize)
        }
        return CLIAuthenticationSession(process: process, input: input, output: output)
    }

    func openBrowserAuthenticationPage(for entry: CLIEntry, authURL: URL) throws -> Bool {
        guard authURL.scheme == "https", authURL.host == "auth.openai.com",
              authURL.path == "/oauth/authorize", fileManager.fileExists(atPath: Self.safariExecutablePath) else {
            throw CLIInstallError.browserUnavailable
        }
        return try openSafari(authURL)
    }

    func openDeviceAuthenticationPage(for entry: CLIEntry, verificationURL: URL) throws -> Bool {
        guard verificationURL.scheme == "https",
              verificationURL.host == "auth.openai.com",
              verificationURL.path == "/codex/device",
              fileManager.fileExists(atPath: Self.safariExecutablePath) else {
            throw CLIInstallError.browserUnavailable
        }
        return try openSafari(verificationURL)
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

    static func deviceCodePrompt(in output: String) -> CLIDeviceCodePrompt? {
        let clean = output.replacingOccurrences(of: "\u{001B}\\[[0-9;]*m", with: "", options: .regularExpression)
        let lines = clean.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard lines.contains("https://auth.openai.com/codex/device"),
              let marker = lines.firstIndex(where: { $0.contains("Enter this one-time code") }),
              marker + 1 < lines.count else { return nil }
        let code = lines[(marker + 1)...].first(where: { !$0.isEmpty }) ?? ""
        guard code.range(of: "^[A-Z0-9-]{6,24}$", options: .regularExpression) != nil,
              let url = URL(string: "https://auth.openai.com/codex/device") else { return nil }
        return CLIDeviceCodePrompt(verificationURL: url, code: code)
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

    private func hasPrivatePermissions(_ url: URL, allowingOwnerMode: Int16) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular ||
                attributes[.type] as? FileAttributeType == .typeDirectory,
              let permissions = attributes[.posixPermissions] as? NSNumber else { return false }
        let mode = permissions.int16Value
        return mode & 0o077 == 0 && mode & allowingOwnerMode == allowingOwnerMode
    }

    private static let codexExecutableRelativePath = "package/node_modules/.bin/codex"
    private static let safariExecutablePath = "/Applications/Safari.app/Contents/MacOS/Safari"

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
