import Foundation
import CryptoKit
import Darwin
import Security

enum CLIProxyProvider: String, Codable, CaseIterable, Identifiable {
    case codex = "codex"
    case claude = "claude"
    case antigravity = "antigravity"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .antigravity: return "Antigravity"
        }
    }
    var supported: Bool { self != .antigravity }
}

struct CLIProxyProfile: Codable, Equatable, Identifiable {
    let id: UUID
    let provider: CLIProxyProvider
    let ordinal: Int
    let createdAt: Date

    var displayName: String { "\(provider.title)CLI\(ordinal)" }

    init(id: UUID = UUID(), provider: CLIProxyProvider, ordinal: Int, createdAt: Date = Date()) {
        self.id = id
        self.provider = provider
        self.ordinal = ordinal
        self.createdAt = createdAt
    }
}

struct CLIProxyProfileStore {
    let rootURL: URL
    private let fileManager: FileManager
    private var profilesURL: URL { rootURL.appendingPathComponent("profiles.json") }

    init(applicationSupportDirectory: URL, fileManager: FileManager = .default) {
        self.rootURL = applicationSupportDirectory
            .appendingPathComponent("PainelCli", isDirectory: true)
            .appendingPathComponent("CLIProxy", isDirectory: true)
        self.fileManager = fileManager
    }

    static func userStore(fileManager: FileManager = .default) throws -> CLIProxyProfileStore {
        let support = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                          appropriateFor: nil, create: true)
        return CLIProxyProfileStore(applicationSupportDirectory: support, fileManager: fileManager)
    }

    func load() throws -> [CLIProxyProfile] {
        guard fileManager.fileExists(atPath: profilesURL.path) else { return [] }
        let data = try Data(contentsOf: profilesURL)
        let profiles = try JSONDecoder.cliProxy.decode([CLIProxyProfile].self, from: data)
        try Self.validate(profiles)
        return profiles.sorted { ($0.provider.rawValue, $0.ordinal) < ($1.provider.rawValue, $1.ordinal) }
    }

    @discardableResult
    func add(provider: CLIProxyProvider) throws -> [CLIProxyProfile] {
        guard provider.supported else { throw StoreError.providerUnavailable }
        var profiles = try load()
        var ordinal = 0
        let used = Set(profiles.filter { $0.provider == provider }.map(\.ordinal))
        while used.contains(ordinal) {
            guard ordinal < Int.max else { throw StoreError.invalidProfiles }
            ordinal += 1
        }
        profiles.append(CLIProxyProfile(provider: provider, ordinal: ordinal))
        try save(profiles)
        return profiles
    }

    @discardableResult
    func remove(id: UUID) throws -> [CLIProxyProfile] {
        var profiles = try load()
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { throw StoreError.profileNotFound }
        profiles.remove(at: index)
        try save(profiles)
        return profiles
    }

    private func save(_ profiles: [CLIProxyProfile]) throws {
        try Self.validate(profiles)
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rootURL.path)
        let data = try JSONEncoder.cliProxy.encode(profiles)
        try data.write(to: profilesURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: profilesURL.path)
    }

    private static func validate(_ profiles: [CLIProxyProfile]) throws {
        var ids = Set<UUID>()
        var names = Set<String>()
        for profile in profiles {
            guard profile.ordinal >= 0, ids.insert(profile.id).inserted,
                  names.insert("\(profile.provider.rawValue):\(profile.ordinal)").inserted else {
                throw StoreError.invalidProfiles
            }
        }
    }

    enum StoreError: Error { case invalidProfiles, profileNotFound, providerUnavailable }
}

private extension JSONEncoder {
    static var cliProxy: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var cliProxy: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

enum CLIProxyManagerError: LocalizedError {
    case checksumMismatch
    case engineNotInstalled, profileNotPrepared, alreadyRunning, notRunning, portUnavailable
    case processStartFailed, processOwnershipUnverified, healthCheckFailed, managementRequestFailed
    case secureStorageFailed, providerUnavailable
    case oauthAlreadyInProgress, oauthStartFailed, oauthStatusFailed, oauthCancelFailed

    var errorDescription: String? {
        switch self {
        case .checksumMismatch: return "O SHA-256 do motor CLIProxyAPI não corresponde ao pacote do app."
        case .engineNotInstalled: return "Prepare o motor CLIProxyAPI antes de iniciar este perfil."
        case .profileNotPrepared: return "Prepare este perfil antes de ativá-lo."
        case .alreadyRunning: return "Este perfil já tem um processo CLIProxyAPI em execução."
        case .notRunning: return "Não há processo deste perfil que possa ser encerrado com segurança."
        case .portUnavailable: return "Não foi possível reservar uma porta local para este perfil."
        case .processStartFailed: return "O processo CLIProxyAPI não iniciou ou terminou antes de ficar saudável."
        case .processOwnershipUnverified: return "Há um processo associado a este perfil, mas não foi possível confirmar sua identidade."
        case .healthCheckFailed: return "O CLIProxyAPI não confirmou a saúde do processo deste perfil."
        case .managementRequestFailed: return "A API local de gerenciamento deste perfil não respondeu de forma válida."
        case .oauthAlreadyInProgress: return "Já existe um login CLIProxy em andamento para este provedor."
        case .oauthStartFailed: return "Não foi possível iniciar o login OAuth deste perfil CLIProxy."
        case .oauthStatusFailed: return "Não foi possível confirmar o estado do login OAuth."
        case .oauthCancelFailed: return "Não foi possível cancelar o login OAuth deste perfil."
        case .secureStorageFailed: return "Não foi possível criar armazenamento privado para este perfil CLIProxy."
        case .providerUnavailable: return "O login CLIProxy deste provedor ainda não está disponível."
        }
    }
}

enum CLIProxyAccountState: Equatable { case unauthenticated, authenticated, indeterminate }
enum CLIProxyProcessState: Equatable { case stopped, running, indeterminate }
struct CLIProxyOAuthLogin { let url: URL; let state: String }
enum CLIProxyOAuthState: Equatable { case pending, complete, failed }

enum CLIProxyConfiguration {
    static func yaml(port: Int, managementKey: String, clientKey: String, authDirectory: URL) -> String {
        """
        server:
          host: 127.0.0.1
          port: \(port)
        management:
          allow-remote: false
          secret-key: \(quote(managementKey))
          disable-control-panel: true
          disable-auto-update-panel: true
        access:
          api-keys:
            - \(quote(clientKey))
        oauth:
          auth-dir: \(quote(authDirectory.path))
        """
    }

    static func accountState(provider: CLIProxyProvider, files: [[String: Any]]) -> CLIProxyAccountState {
        guard provider.supported else { return .indeterminate }
        let providerName = provider == .codex ? "codex" : "claude"
        let matches = files.filter { ($0["provider"] as? String)?.lowercased() == providerName }
        guard !matches.isEmpty else { return .unauthenticated }
        return matches.contains(where: {
            ($0["status"] as? String)?.lowercased() == "active" &&
            ($0["disabled"] as? Bool) != true && ($0["unavailable"] as? Bool) != true
        })
            ? .authenticated : .indeterminate
    }

    private static func quote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "") + "\""
    }
}

final class CLIProxyManager {
    static let version = "v8.0.16-loopback"
    private let rootURL: URL
    private let fileManager: FileManager
    private let session: URLSession
    private let bundledEngineURL: URL?
    private var processes: [UUID: Process] = [:]
    private var clientKeys: [UUID: String] = [:]
    private var managementKeys: [UUID: String] = [:]
    private var oauthLeaseDescriptors: [UUID: Int32] = [:]
    private var activeOAuthStates: [UUID: String] = [:]
    private var engineVerificationSignature: String?
    private var engineVerificationResult = false
    private var profileStore: CLIProxyProfileStore

    init(applicationSupportDirectory: URL, fileManager: FileManager = .default,
         session: URLSession = .shared,
         bundledEngineURL: URL? = Bundle.main.url(forResource: "CLIProxyAPI", withExtension: nil)) {
        rootURL = applicationSupportDirectory.appendingPathComponent("PainelCli/CLIProxy", isDirectory: true)
        self.fileManager = fileManager
        self.session = session
        self.bundledEngineURL = bundledEngineURL
        profileStore = CLIProxyProfileStore(applicationSupportDirectory: applicationSupportDirectory,
                                            fileManager: fileManager)
    }

    deinit {
        for descriptor in oauthLeaseDescriptors.values {
            _ = flock(descriptor, LOCK_UN)
            close(descriptor)
        }
    }

    var store: CLIProxyProfileStore { profileStore }
    var engineURL: URL {
        rootURL.appendingPathComponent("engines/\(Self.version)/cli-proxy-api", isDirectory: false)
    }

    func engineInstalled() -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: engineURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue, fileManager.isExecutableFile(atPath: engineURL.path),
              let bundledEngineURL,
              let attributes = try? fileManager.attributesOfItem(atPath: engineURL.path),
              let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date,
              let identifier = attributes[.systemFileNumber] as? NSNumber else {
            engineVerificationSignature = nil
            engineVerificationResult = false
            return false
        }
        let signature = "\(size)-\(modified.timeIntervalSince1970)-\(identifier)"
        if signature == engineVerificationSignature { return engineVerificationResult }
        let digestURL = bundledEngineURL.appendingPathExtension("sha256")
        guard let expected = try? String(contentsOf: digestURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let binary = try? Data(contentsOf: engineURL, options: .mappedIfSafe) else {
            engineVerificationSignature = signature
            engineVerificationResult = false
            return false
        }
        let valid = Self.validatesBundledEngine(binary, expectedDigest: expected)
        engineVerificationSignature = signature
        engineVerificationResult = valid
        return valid
    }

    func isPrepared(profile: CLIProxyProfile) -> Bool {
        guard engineInstalled() else { return false }
        let instance = instanceURL(profile)
        return fileManager.fileExists(atPath: instance.appendingPathComponent("config.yaml").path) &&
            fileManager.fileExists(atPath: instance.appendingPathComponent("auths", isDirectory: true).path) &&
            fileManager.fileExists(atPath: instance.appendingPathComponent("client.key").path) &&
            fileManager.fileExists(atPath: instance.appendingPathComponent("management.key").path)
    }

    func installEngine() throws {
        try createPrivateDirectory(rootURL)
        let lockPath = rootURL.appendingPathComponent("engine-install.lock").path
        let lockDescriptor = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard lockDescriptor >= 0, flock(lockDescriptor, LOCK_EX) == 0 else {
            if lockDescriptor >= 0 { close(lockDescriptor) }
            throw CLIProxyManagerError.engineNotInstalled
        }
        defer { _ = flock(lockDescriptor, LOCK_UN); close(lockDescriptor) }
        if engineInstalled() { return }
        guard let bundledEngineURL,
              let values = try? bundledEngineURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else {
            throw CLIProxyManagerError.engineNotInstalled
        }
        let bundledDigestURL = bundledEngineURL.appendingPathExtension("sha256")
        guard let digestValues = try? bundledDigestURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              digestValues.isRegularFile == true, digestValues.isSymbolicLink != true else {
            throw CLIProxyManagerError.checksumMismatch
        }
        guard let expectedDigest = try? String(contentsOf: bundledDigestURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              expectedDigest.count == 64,
              let binary = try? Data(contentsOf: bundledEngineURL, options: .mappedIfSafe),
              Self.sha256(binary) == expectedDigest.lowercased() else {
            throw CLIProxyManagerError.checksumMismatch
        }
        try createPrivateDirectory(rootURL.appendingPathComponent("engines", isDirectory: true))
        let destinationDirectory = engineURL.deletingLastPathComponent()
        try createPrivateDirectory(destinationDirectory)
        let staging = destinationDirectory.appendingPathComponent(".engine-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: staging) }
        try binary.write(to: staging, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staging.path)
        if fileManager.fileExists(atPath: engineURL.path) { try fileManager.removeItem(at: engineURL) }
        try fileManager.moveItem(at: staging, to: engineURL)
    }

    func prepare(profile: CLIProxyProfile) throws {
        guard profile.provider.supported else { throw CLIProxyManagerError.providerUnavailable }
        guard engineInstalled() else { throw CLIProxyManagerError.engineNotInstalled }
        let instance = instanceURL(profile)
        let authDirectory = instance.appendingPathComponent("auths", isDirectory: true)
        let home = instance.appendingPathComponent("home", isDirectory: true)
        let temp = instance.appendingPathComponent("tmp", isDirectory: true)
        for directory in [instance, authDirectory, home, temp] { try createPrivateDirectory(directory) }
        let clientKey = try loadOrCreateSecret(named: "client.key", profile: profile)
        let managementKey = try loadOrCreateSecret(named: "management.key", profile: profile)
        let port = try loadOrChoosePort(profile)
        try writeConfiguration(profile: profile, port: port, managementKey: managementKey, clientKey: clientKey)
        try savePort(port, profile: profile)
    }

    func start(profile: CLIProxyProfile) throws {
        guard profile.provider.supported else { throw CLIProxyManagerError.providerUnavailable }
        guard engineInstalled() else { throw CLIProxyManagerError.engineNotInstalled }
        let configURL = instanceURL(profile).appendingPathComponent("config.yaml")
        guard fileManager.fileExists(atPath: configURL.path) else { throw CLIProxyManagerError.profileNotPrepared }
        switch processState(profile: profile) {
        case .running: throw CLIProxyManagerError.alreadyRunning
        case .indeterminate: throw CLIProxyManagerError.processOwnershipUnverified
        case .stopped: break
        }
        let secrets = try loadSecrets(profile)
        let port = try chooseAvailablePort()
        try writeConfiguration(profile: profile, port: port,
                               managementKey: secrets.management, clientKey: secrets.client)
        try savePort(port, profile: profile)
        let process = Process()
        process.executableURL = engineURL
        process.arguments = ["--config", configURL.path]
        process.currentDirectoryURL = instanceURL(profile)
        process.environment = [
            "HOME": instanceURL(profile).appendingPathComponent("home", isDirectory: true).path,
            "TMPDIR": instanceURL(profile).appendingPathComponent("tmp", isDirectory: true).path,
            "PATH": "/usr/bin:/bin"
        ]
        let sink = FileHandle.nullDevice
        process.standardOutput = sink
        process.standardError = sink
        do { try process.run() } catch { throw CLIProxyManagerError.processStartFailed }
        processes[profile.id] = process
        guard let processStart = Self.processStartSignature(process.processIdentifier) else {
            process.terminate()
            processes.removeValue(forKey: profile.id)
            throw CLIProxyManagerError.processStartFailed
        }
        try saveProcessRecord(ProcessRecord(pid: process.processIdentifier, engine: engineURL.path,
                                            config: configURL.path, startedAt: processStart), profile: profile)
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if !process.isRunning { processes.removeValue(forKey: profile.id); throw CLIProxyManagerError.processStartFailed }
            if health(profile: profile) { return }
            Thread.sleep(forTimeInterval: 0.15)
        }
        process.terminate()
        processes.removeValue(forKey: profile.id)
        throw CLIProxyManagerError.healthCheckFailed
    }

    func stop(profile: CLIProxyProfile) throws {
        if let state = activeOAuthStates[profile.id] {
            try cancelOAuth(profile: profile, state: state)
        }
        if let process = processes[profile.id] {
            guard process.isRunning else { processes.removeValue(forKey: profile.id); return }
            process.terminate()
            let deadline = Date().addingTimeInterval(5)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
            guard !process.isRunning else { throw CLIProxyManagerError.processOwnershipUnverified }
            processes.removeValue(forKey: profile.id)
            return
        }
        guard let record = try? loadProcessRecord(profile) else { return }
        guard kill(record.pid, 0) == 0 else {
            removeProcessRecord(profile)
            return
        }
        guard Self.processIdentityMatches(record) else { throw CLIProxyManagerError.processOwnershipUnverified }
        guard kill(record.pid, SIGTERM) == 0 else { throw CLIProxyManagerError.processOwnershipUnverified }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline && Self.processIdentityMatches(record) { Thread.sleep(forTimeInterval: 0.1) }
        guard !Self.processIdentityMatches(record) else { throw CLIProxyManagerError.processOwnershipUnverified }
        removeProcessRecord(profile)
    }

    func isRunning(profile: CLIProxyProfile) -> Bool {
        processState(profile: profile) == .running
    }

    func processState(profile: CLIProxyProfile) -> CLIProxyProcessState {
        if let process = processes[profile.id] {
            if !process.isRunning { processes.removeValue(forKey: profile.id); return .stopped }
            return health(profile: profile) ? .running : .indeterminate
        }
        guard let record = try? loadProcessRecord(profile) else { return .stopped }
        guard kill(record.pid, 0) == 0 else { removeProcessRecord(profile); return .stopped }
        guard Self.processIdentityMatches(record) else { return .indeterminate }
        return health(profile: profile) ? .running : .indeterminate
    }

    func health(profile: CLIProxyProfile) -> Bool {
        guard let port = try? loadPort(profile) else { return false }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/healthz")!, timeoutInterval: 0.8)
        request.httpMethod = "GET"
        let semaphore = DispatchSemaphore(value: 0)
        var healthy = false
        session.dataTask(with: request) { _, response, _ in
            if let response = response as? HTTPURLResponse { healthy = response.statusCode == 200 }
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 1)
        guard healthy else { return false }
        if processes[profile.id] != nil { return processes[profile.id]?.isRunning == true }
        guard let record = try? loadProcessRecord(profile) else { return false }
        return Self.processIdentityMatches(record)
    }

    func accountState(profile: CLIProxyProfile) -> CLIProxyAccountState {
        guard isRunning(profile: profile),
              let response = try? managementRequest(profile: profile, route: "credentials", method: "GET"),
              let files = response["files"] as? [[String: Any]] else { return .indeterminate }
        return CLIProxyConfiguration.accountState(provider: profile.provider, files: files)
    }

    func endpoint(profile: CLIProxyProfile) throws -> URL {
        let port = try loadPort(profile)
        return URL(string: "http://127.0.0.1:\(port)/v1")!
    }

    func clientKey(profile: CLIProxyProfile) throws -> String { try loadSecrets(profile).client }

    func removeProfileData(profile: CLIProxyProfile) throws {
        try stop(profile: profile)
        let directory = instanceURL(profile)
        guard fileManager.fileExists(atPath: directory.path) else { return }
        let resolvedRoot = rootURL.appendingPathComponent("instances", isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath().path + "/"
        let resolvedDirectory = directory.standardizedFileURL.resolvingSymlinksInPath().path
        guard resolvedDirectory.hasPrefix(resolvedRoot), resolvedDirectory == resolvedRoot + profile.id.uuidString else {
            throw CLIProxyManagerError.secureStorageFailed
        }
        try fileManager.removeItem(at: directory)
        processes.removeValue(forKey: profile.id)
        clientKeys.removeValue(forKey: profile.id)
        managementKeys.removeValue(forKey: profile.id)
    }

    func stopAllOwnedProcesses() {
        for (id, process) in processes where process.isRunning {
            _ = id
            process.terminate()
        }
    }

    private var instancesURL: URL { rootURL.appendingPathComponent("instances", isDirectory: true) }
    private func instanceURL(_ profile: CLIProxyProfile) -> URL {
        instancesURL.appendingPathComponent(profile.id.uuidString, isDirectory: true)
    }

    private func createPrivateDirectory(_ url: URL) throws {
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        } catch { throw CLIProxyManagerError.secureStorageFailed }
    }

    private func loadOrCreateSecret(named name: String, profile: CLIProxyProfile) throws -> String {
        let url = instanceURL(profile).appendingPathComponent(name)
        if let data = try? Data(contentsOf: url), let value = String(data: data, encoding: .utf8),
           value.count >= 32 { return value }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw CLIProxyManagerError.secureStorageFailed
        }
        let value = Data(bytes).base64EncodedString()
        try Data(value.utf8).write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return value
    }

    private func loadSecrets(_ profile: CLIProxyProfile) throws -> (client: String, management: String) {
        if let client = clientKeys[profile.id], let management = managementKeys[profile.id] {
            return (client, management)
        }
        let dir = instanceURL(profile)
        guard let client = try? String(contentsOf: dir.appendingPathComponent("client.key"), encoding: .utf8),
              let management = try? String(contentsOf: dir.appendingPathComponent("management.key"), encoding: .utf8) else {
            throw CLIProxyManagerError.secureStorageFailed
        }
        clientKeys[profile.id] = client
        managementKeys[profile.id] = management
        return (client, management)
    }

    private func loadOrChoosePort(_ profile: CLIProxyProfile) throws -> Int {
        if let existing = try? loadPort(profile), existing > 0 { return existing }
        for _ in 0..<64 {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { continue }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = 0
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard result == 0 else { close(fd); continue }
            var bound = sockaddr_in()
            var size = socklen_t(MemoryLayout<sockaddr_in>.size)
            let got = withUnsafeMutablePointer(to: &bound) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
            }
            close(fd)
            if got == 0 { return Int(UInt16(bigEndian: bound.sin_port)) }
        }
        throw CLIProxyManagerError.portUnavailable
    }

    private func savePort(_ port: Int, profile: CLIProxyProfile) throws {
        let url = instanceURL(profile).appendingPathComponent("port")
        try Data(String(port).utf8).write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func loadPort(_ profile: CLIProxyProfile) throws -> Int {
        let url = instanceURL(profile).appendingPathComponent("port")
        guard let value = try? String(contentsOf: url, encoding: .utf8), let port = Int(value), (1...65535).contains(port) else {
            throw CLIProxyManagerError.profileNotPrepared
        }
        return port
    }

    private func writeConfiguration(profile: CLIProxyProfile, port: Int,
                                    managementKey: String, clientKey: String) throws {
        let instance = instanceURL(profile)
        let authDirectory = instance.appendingPathComponent("auths", isDirectory: true)
        let config = CLIProxyConfiguration.yaml(port: port, managementKey: managementKey,
                                                clientKey: clientKey, authDirectory: authDirectory)
        let configURL = instance.appendingPathComponent("config.yaml")
        try Data(config.utf8).write(to: configURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
    }

    private func chooseAvailablePort() throws -> Int {
        try loadOrChoosePort(CLIProxyProfile(provider: .codex, ordinal: 0))
    }

    private func processRecordURL(_ profile: CLIProxyProfile) -> URL {
        instanceURL(profile).appendingPathComponent("process.json")
    }

    private struct ProcessRecord: Codable { let pid: Int32; let engine: String; let config: String; let startedAt: String }

    private func loadProcessRecord(_ profile: CLIProxyProfile) throws -> ProcessRecord {
        let data = try Data(contentsOf: processRecordURL(profile))
        return try JSONDecoder.cliProxy.decode(ProcessRecord.self, from: data)
    }

    private func saveProcessRecord(_ record: ProcessRecord, profile: CLIProxyProfile) throws {
        let data = try JSONEncoder.cliProxy.encode(record)
        try data.write(to: processRecordURL(profile), options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: processRecordURL(profile).path)
    }

    private func removeProcessRecord(_ profile: CLIProxyProfile) { try? fileManager.removeItem(at: processRecordURL(profile)) }

    private static func processIdentityMatches(_ record: ProcessRecord) -> Bool {
        guard record.pid > 1, kill(record.pid, 0) == 0 else { return false }
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-p", String(record.pid), "-o", "lstart=", "-o", "command="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice
        do { try ps.run() } catch { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        guard ps.terminationStatus == 0, let output = String(data: data, encoding: .utf8) else { return false }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = processStartSignature(record.pid) else { return false }
        return trimmed.contains(record.engine) && trimmed.contains(record.config) && start == record.startedAt
    }

    private static func processStartSignature(_ pid: Int32) -> String? {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-p", String(pid), "-o", "lstart="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice
        do { try ps.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        guard ps.terminationStatus == 0, let value = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func beginOAuth(profile: CLIProxyProfile) throws -> CLIProxyOAuthLogin {
        guard profile.provider.supported else { throw CLIProxyManagerError.providerUnavailable }
        guard processState(profile: profile) == .running else { throw CLIProxyManagerError.notRunning }
        try acquireOAuthLease(profile: profile)
        do {
            let provider = profile.provider == .codex ? "codex" : "claude"
            let response = try managementRequest(profile: profile, route: "oauth/auth-url", method: "GET",
                                                  query: [URLQueryItem(name: "provider", value: provider)])
            guard response["status"] as? String == "ok",
                  let state = response["state"] as? String, !state.isEmpty, state.count <= 512,
                  let rawURL = response["url"] as? String,
                  let url = Self.validOAuthURL(rawURL, provider: profile.provider) else {
                throw CLIProxyManagerError.oauthStartFailed
            }
            activeOAuthStates[profile.id] = state
            return CLIProxyOAuthLogin(url: url, state: state)
        } catch {
            releaseOAuthLease(profile: profile)
            throw error
        }
    }

    func oauthState(profile: CLIProxyProfile, state: String) throws -> CLIProxyOAuthState {
        guard activeOAuthStates[profile.id] == state else { throw CLIProxyManagerError.oauthStatusFailed }
        let response = try managementRequest(profile: profile, route: "oauth/status", method: "GET",
                                              query: [URLQueryItem(name: "state", value: state)])
        switch response["status"] as? String {
        case "wait": return .pending
        case "ok": activeOAuthStates.removeValue(forKey: profile.id); releaseOAuthLease(profile: profile); return .complete
        case "error": activeOAuthStates.removeValue(forKey: profile.id); releaseOAuthLease(profile: profile); return .failed
        default: throw CLIProxyManagerError.oauthStatusFailed
        }
    }

    func cancelOAuth(profile: CLIProxyProfile, state: String) throws {
        guard activeOAuthStates[profile.id] == state else { throw CLIProxyManagerError.oauthCancelFailed }
        let response = try managementRequest(profile: profile, route: "oauth/session", method: "DELETE",
                                              query: [URLQueryItem(name: "state", value: state)])
        guard response["status"] as? String == "ok" else { throw CLIProxyManagerError.oauthCancelFailed }
        activeOAuthStates.removeValue(forKey: profile.id)
        releaseOAuthLease(profile: profile)
    }

    func acquireOAuthLease(profile: CLIProxyProfile) throws {
        if oauthLeaseDescriptors[profile.id] != nil { throw CLIProxyManagerError.oauthAlreadyInProgress }
        let provider = profile.provider == .codex ? "codex" : "claude"
        try createPrivateDirectory(rootURL)
        let path = rootURL.appendingPathComponent("oauth-\(provider).lock").path
        let descriptor = open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw CLIProxyManagerError.oauthAlreadyInProgress }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw CLIProxyManagerError.oauthAlreadyInProgress
        }
        oauthLeaseDescriptors[profile.id] = descriptor
    }

    func releaseOAuthLease(profile: CLIProxyProfile) {
        guard let descriptor = oauthLeaseDescriptors.removeValue(forKey: profile.id) else { return }
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    private func managementRequest(profile: CLIProxyProfile, route: String, method: String,
                                   query: [URLQueryItem] = [], key: String? = nil) throws -> [String: Any] {
        let port = try loadPort(profile)
        var components = URLComponents(string: "http://127.0.0.1:\(port)/v8/management/\(route)")
        components?.queryItems = query.isEmpty ? nil : query
        guard let url = components?.url else {
            throw CLIProxyManagerError.managementRequestFailed
        }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = method
        let authorizationKey = try key ?? loadSecrets(profile).management
        request.setValue("Bearer \(authorizationKey)", forHTTPHeaderField: "Authorization")
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<[String: Any], Error>!
        session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            guard error == nil, let response = response as? HTTPURLResponse,
                  response.statusCode == 200, let data,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                result = .failure(CLIProxyManagerError.managementRequestFailed); return
            }
            result = .success(object)
        }.resume()
        guard semaphore.wait(timeout: .now() + 6) == .success else { throw CLIProxyManagerError.managementRequestFailed }
        return try result.get()
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func validatesBundledEngine(_ data: Data, expectedDigest: String) -> Bool {
        expectedDigest.count == 64 && sha256(data) == expectedDigest.lowercased()
    }

    static func validOAuthURL(_ rawURL: String, provider: CLIProxyProvider) -> URL? {
        guard provider.supported, let url = URL(string: rawURL),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https", components.user == nil, components.password == nil,
              components.port == nil || components.port == 443,
              components.host?.lowercased() == (provider == .codex ? "auth.openai.com" : "claude.ai") else {
            return nil
        }
        return url
    }
}
