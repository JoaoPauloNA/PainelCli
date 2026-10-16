import Foundation

/// Providers offered for manual registration. Installation and account login remain
/// unavailable until each registration can own an isolated installation and profile.
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
    case isolatedInstallationUnavailable

    var errorDescription: String? {
        "Instalação bloqueada até que cada cadastro tenha diretório e perfil isolados."
    }
}

struct CLIInstallService {
    private let fileManager: FileManager
    private let supportDirectory: URL
    private let environment: [String: String]
    private let homeDirectory: URL
    private let additionalSearchDirectories: [URL]?
    private let knownExecutableOverrides: [CLIDiscoveryTarget: [URL]]?

    init(applicationSupportDirectory: URL,
         fileManager: FileManager = .default,
         environment: [String: String] = ProcessInfo.processInfo.environment,
         homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
         additionalSearchDirectories: [URL]? = nil,
         knownExecutableOverrides: [CLIDiscoveryTarget: [URL]]? = nil) {
        self.fileManager = fileManager
        self.supportDirectory = applicationSupportDirectory
            .appendingPathComponent("PainelCli", isDirectory: true)
            .appendingPathComponent("Installations", isDirectory: true)
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

    /// The current backend does not support per-registration isolation, so installation is
    /// a hard failure before filesystem writes, runtime discovery, or process execution.
    func install(entry: CLIEntry) throws {
        _ = entry
        throw CLIInstallError.isolatedInstallationUnavailable
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
        supportDirectory.appendingPathComponent(target.rawValue, isDirectory: true)
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
