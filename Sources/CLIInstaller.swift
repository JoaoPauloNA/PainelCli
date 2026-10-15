import Foundation

enum CLIProvider: String, CaseIterable {
    case codex = "CodexCLI"
    case claude = "ClaudeCLI"
    case gemini = "GeminiCLI"

    var npmPackage: String {
        switch self {
        case .codex: return "@openai/codex"
        case .claude: return "@anthropic-ai/claude-code"
        case .gemini: return "@google/gemini-cli"
        }
    }

    var executableName: String {
        switch self {
        case .codex: return "codex"
        case .claude: return "claude"
        case .gemini: return "gemini"
        }
    }
}

struct CLIInstallPlan: Equatable {
    let provider: CLIProvider
    let npmURL: URL
    let installDirectory: URL

    var arguments: [String] {
        ["install", "--global", "--prefix", installDirectory.path,
         "--registry=https://registry.npmjs.org/",
         "--userconfig=\(installDirectory.appendingPathComponent(".npmrc").path)",
         "--cache=\(installDirectory.appendingPathComponent("npm-cache", isDirectory: true).path)",
         "--no-audit", "--no-fund", "--logs-max=0", "--loglevel=error", provider.npmPackage]
    }

    var executableURL: URL { npmURL }
}

protocol CLICommandRunning {
    func run(executable: URL, arguments: [String], environment: [String: String]) throws
}

struct FoundationCLICommandRunner: CLICommandRunning {
    func run(executable: URL, arguments: [String], environment: [String: String]) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw CLIInstallError.commandFailed
        }
    }
}

enum CLIInstallError: Error {
    case runtimeMissing
    case alreadyInstalled(String)
    case commandFailed
}

struct CLIDetection: Equatable {
    let provider: CLIProvider
    let executableURL: URL
    let isManaged: Bool
}

struct CLIInstallService {
    private let fileManager: FileManager
    private let supportDirectory: URL
    private let runner: CLICommandRunning
    private let environment: [String: String]
    private let homeDirectory: URL
    private let additionalSearchDirectories: [URL]?
    private let knownExecutableOverrides: [CLIProvider: [URL]]?

    init(applicationSupportDirectory: URL,
         fileManager: FileManager = .default,
         runner: CLICommandRunning = FoundationCLICommandRunner(),
         environment: [String: String] = ProcessInfo.processInfo.environment,
         homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
         additionalSearchDirectories: [URL]? = nil,
         knownExecutableOverrides: [CLIProvider: [URL]]? = nil) {
        self.fileManager = fileManager
        self.supportDirectory = applicationSupportDirectory
            .appendingPathComponent("PainelCli", isDirectory: true)
            .appendingPathComponent("Installations", isDirectory: true)
        self.runner = runner
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.additionalSearchDirectories = additionalSearchDirectories
        self.knownExecutableOverrides = knownExecutableOverrides
    }

    static func userService() throws -> CLIInstallService {
        let supportDirectory = try FileManager.default.url(for: .applicationSupportDirectory,
                                                           in: .userDomainMask,
                                                           appropriateFor: nil,
                                                           create: true)
        return CLIInstallService(applicationSupportDirectory: supportDirectory)
    }

    func installedExecutable(for provider: CLIProvider) -> URL? {
        detectedExecutables(for: provider).first?.executableURL
    }

    func detectedExecutables() -> [CLIDetection] {
        CLIProvider.allCases.flatMap(detectedExecutables(for:))
    }

    func detectedExecutables(for provider: CLIProvider) -> [CLIDetection] {
        let managed = installDirectory(for: provider).appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent(provider.executableName, isDirectory: false)
        var candidates = [managed]
        candidates += searchDirectories().map { $0.appendingPathComponent(provider.executableName) }
        candidates += knownExecutables(for: provider)

        var seen = Set<String>()
        return candidates.compactMap { candidate in
            guard fileManager.isExecutableFile(atPath: candidate.path) else { return nil }
            let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
            guard seen.insert(resolved.path).inserted else { return nil }
            let managedPath = managed.resolvingSymlinksInPath().standardizedFileURL.path
            return CLIDetection(provider: provider, executableURL: resolved, isManaged: resolved.path == managedPath)
        }
    }

    func install(provider: CLIProvider) throws {
        if let found = installedExecutable(for: provider) {
            let managed = installDirectory(for: provider).appendingPathComponent("bin", isDirectory: true)
                .appendingPathComponent(provider.executableName)
            if found.standardizedFileURL != managed.standardizedFileURL {
                throw CLIInstallError.alreadyInstalled(found.path)
            }
            throw CLIInstallError.alreadyInstalled(found.path)
        }
        guard let npmURL = discoverExecutable(named: "npm"),
              discoverExecutable(named: "node") != nil else {
            throw CLIInstallError.runtimeMissing
        }

        let directory = installDirectory(for: provider)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let emptyUserConfig = directory.appendingPathComponent(".npmrc")
        try Data().write(to: emptyUserConfig, options: .atomic)
        let plan = CLIInstallPlan(provider: provider, npmURL: npmURL, installDirectory: directory)
        let processEnvironment = sanitizedEnvironment(npmDirectory: npmURL.deletingLastPathComponent(),
                                                     cacheDirectory: directory.appendingPathComponent("npm-cache", isDirectory: true),
                                                     userConfig: emptyUserConfig)
        try runner.run(executable: plan.executableURL, arguments: plan.arguments,
                       environment: processEnvironment)
        let executable = directory.appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent(provider.executableName, isDirectory: false)
        guard fileManager.isExecutableFile(atPath: executable.path) else {
            throw CLIInstallError.commandFailed
        }
    }

    func installDirectory(for provider: CLIProvider) -> URL {
        supportDirectory.appendingPathComponent(provider.rawValue, isDirectory: true)
    }

    private func knownExecutables(for provider: CLIProvider) -> [URL] {
        if let knownExecutableOverrides { return knownExecutableOverrides[provider] ?? [] }
        guard provider == .codex else { return [] }
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

    private func sanitizedEnvironment(npmDirectory: URL, cacheDirectory: URL, userConfig: URL) -> [String: String] {
        let inheritedPath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        var result = ["PATH": "\(npmDirectory.path):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                      "HOME": environment["HOME"] ?? NSHomeDirectory(),
                      "npm_config_registry": "https://registry.npmjs.org/",
                      "npm_config_cache": cacheDirectory.path,
                      "npm_config_userconfig": userConfig.path,
                      "npm_config_update_notifier": "false"]
        // Add only executable search paths; never pass npm auth or arbitrary variables through.
        for component in inheritedPath.split(separator: ":").map(String.init) {
            if component == "/opt/homebrew/bin" || component == "/usr/local/bin" ||
                component == "/usr/bin" || component == "/bin" || component == "/usr/sbin" || component == "/sbin" {
                continue
            }
            result["PATH", default: ""] += ":\(component)"
        }
        return result
    }

    private func discoverExecutable(named name: String) -> URL? {
        for directory in searchDirectories() {
            let candidate = directory.appendingPathComponent(name, isDirectory: false)
            if fileManager.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}
