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

struct CLIInstallService {
    private let fileManager: FileManager
    private let supportDirectory: URL
    private let runner: CLICommandRunning
    private let environment: [String: String]

    init(applicationSupportDirectory: URL,
         fileManager: FileManager = .default,
         runner: CLICommandRunning = FoundationCLICommandRunner(),
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.fileManager = fileManager
        self.supportDirectory = applicationSupportDirectory
            .appendingPathComponent("PainelCli", isDirectory: true)
            .appendingPathComponent("Installations", isDirectory: true)
        self.runner = runner
        self.environment = environment
    }

    static func userService() throws -> CLIInstallService {
        let supportDirectory = try FileManager.default.url(for: .applicationSupportDirectory,
                                                           in: .userDomainMask,
                                                           appropriateFor: nil,
                                                           create: true)
        return CLIInstallService(applicationSupportDirectory: supportDirectory)
    }

    func installedExecutable(for provider: CLIProvider) -> URL? {
        let managed = installDirectory(for: provider).appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent(provider.executableName, isDirectory: false)
        if fileManager.isExecutableFile(atPath: managed.path) { return managed }
        return discoverExecutable(named: provider.executableName)
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
        var directories: [URL] = []
        if let path = environment["PATH"] {
            directories += path.split(separator: ":").map { URL(fileURLWithPath: String($0), isDirectory: true) }
        }
        directories += [URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
                        URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
                        URL(fileURLWithPath: "/usr/bin", isDirectory: true),
                        URL(fileURLWithPath: "/bin", isDirectory: true),
                        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                            .appendingPathComponent(".local/bin", isDirectory: true)]
        let nvmDirectory = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".nvm/versions/node", isDirectory: true)
        if let versions = try? fileManager.contentsOfDirectory(at: nvmDirectory,
                                                               includingPropertiesForKeys: nil) {
            directories += versions.sorted { $0.lastPathComponent > $1.lastPathComponent }
                .map { $0.appendingPathComponent("bin", isDirectory: true) }
        }
        var seen = Set<String>()
        for directory in directories where seen.insert(directory.standardizedFileURL.path).inserted {
            let candidate = directory.appendingPathComponent(name, isDirectory: false)
            if fileManager.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}
