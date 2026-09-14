import Foundation

/// The complete non-secret configuration used by the menu-bar application.
///
/// Passwords and API tokens deliberately do not appear in this type. The backup
/// implementation resolves credentials from the Keychain using `keychainService`.
public struct ImmichConfiguration: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var server: ServerSettings
    public var backups: [BackupTargetConfiguration]

    public init(
        schemaVersion: Int = ImmichConfiguration.currentSchemaVersion,
        server: ServerSettings,
        backups: [BackupTargetConfiguration]
    ) {
        self.schemaVersion = schemaVersion
        self.server = server
        self.backups = backups
    }

    public static func `default`(projectRoot: URL) -> ImmichConfiguration {
        let root = projectRoot.standardizedFileURL
        let r2ID = UUID(uuidString: "B11D3810-BEF3-4C46-8C93-04D6D4A3CFB9")!
        let usbID = UUID(uuidString: "35998B0D-CF48-4EA9-8E2E-6A5727C35B1E")!

        return ImmichConfiguration(
            server: ServerSettings(projectRootURL: root),
            backups: [
                BackupTargetConfiguration(
                    id: r2ID,
                    kind: .r2,
                    displayName: "Cloudflare R2",
                    enabled: false,
                    schedule: BackupSchedule(hour: 3, minute: 15),
                    retention: .standard,
                    repository: "",
                    tag: "immich-r2",
                    keychainService: "immich-backup"
                ),
                BackupTargetConfiguration(
                    id: usbID,
                    kind: .usb,
                    displayName: "USB backup",
                    enabled: false,
                    schedule: BackupSchedule(hour: 5, minute: 15),
                    retention: .standard,
                    repository: "/Volumes/MediaUSB/ImmichBackup/restic",
                    tag: "immich-usb",
                    keychainService: "immich-backup",
                    usbMountPath: "/Volumes/MediaUSB"
                ),
            ]
        )
    }

    /// Rejects malformed or unsafe settings before they can be persisted or used
    /// to construct commands. This intentionally does not require tools such as
    /// Docker to be installed; the server status reports unavailable tools.
    public func validate(fileManager: FileManager = .default) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ConfigurationError.unsupportedSchemaVersion(schemaVersion)
        }

        try server.validate(fileManager: fileManager)

        let identifiers = backups.map(\.id)
        guard Set(identifiers).count == identifiers.count else {
            throw ConfigurationError.duplicateBackupTargetID
        }
        let kinds = backups.map(\.kind)
        guard Set(kinds).count == kinds.count else {
            throw ConfigurationError.duplicateBackupTargetKind
        }

        for target in backups {
            try target.validate()
        }
    }
}

public struct ServerSettings: Codable, Equatable, Sendable {
    public var projectRootPath: String
    public var composeFilePath: String
    public var projectName: String
    public var localServerURL: String
    public var toolPaths: ToolPaths
    public var resourcePreset: ResourcePreset
    public var launchServerAtLogin: Bool

    public init(
        projectRootURL: URL,
        composeFileURL: URL? = nil,
        projectName: String = "immich",
        localServerURL: String = "http://localhost:2283",
        toolPaths: ToolPaths = .resolvingHomebrew(),
        resourcePreset: ResourcePreset = .balanced,
        launchServerAtLogin: Bool = false
    ) {
        let root = projectRootURL.standardizedFileURL
        self.projectRootPath = root.path
        self.composeFilePath = (composeFileURL ?? root.appendingPathComponent("docker-compose.yml"))
            .standardizedFileURL.path
        self.projectName = projectName
        self.localServerURL = localServerURL
        self.toolPaths = toolPaths
        self.resourcePreset = resourcePreset
        self.launchServerAtLogin = launchServerAtLogin
    }

    public var projectRootURL: URL {
        URL(fileURLWithPath: projectRootPath, isDirectory: true).standardizedFileURL
    }

    public var composeFileURL: URL {
        URL(fileURLWithPath: composeFilePath).standardizedFileURL
    }

    public var localURL: URL? {
        URL(string: localServerURL)
    }

    public mutating func setProjectRoot(_ url: URL) {
        let root = url.standardizedFileURL
        projectRootPath = root.path
        composeFilePath = root.appendingPathComponent("docker-compose.yml").path
    }

    public func validate(fileManager: FileManager = .default) throws {
        let root = projectRootURL
        var isDirectory: ObjCBool = false
        guard root.path.hasPrefix("/"),
              fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ConfigurationError.invalidProjectRoot(root.path)
        }

        let compose = composeFileURL
        guard compose.path.hasPrefix(root.path + "/"),
              fileManager.fileExists(atPath: compose.path) else {
            throw ConfigurationError.invalidComposeFile(compose.path)
        }

        guard !projectName.isEmpty,
              projectName.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
            throw ConfigurationError.invalidProjectName(projectName)
        }

        guard let url = localURL,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else {
            throw ConfigurationError.invalidServerURL(localServerURL)
        }

        try toolPaths.validate()
        try resourcePreset.validate()
    }
}

public struct ToolPaths: Codable, Equatable, Sendable {
    public var colimaPath: String
    public var dockerPath: String
    public var resticPath: String

    public init(colimaPath: String, dockerPath: String, resticPath: String) {
        self.colimaPath = colimaPath
        self.dockerPath = dockerPath
        self.resticPath = resticPath
    }

    /// Prefers Apple Silicon Homebrew, then Intel Homebrew, then the system PATH
    /// locations commonly used by manually installed tools. Existence is checked
    /// at execution time so a new machine can still complete onboarding.
    public static func resolvingHomebrew(fileManager: FileManager = .default) -> ToolPaths {
        ToolPaths(
            colimaPath: resolve(["/opt/homebrew/bin/colima", "/usr/local/bin/colima", "/usr/bin/colima"], fileManager: fileManager),
            dockerPath: resolve(["/opt/homebrew/bin/docker", "/usr/local/bin/docker", "/usr/bin/docker"], fileManager: fileManager),
            resticPath: resolve(["/opt/homebrew/bin/restic", "/usr/local/bin/restic", "/usr/bin/restic"], fileManager: fileManager)
        )
    }

    public var colimaURL: URL { URL(fileURLWithPath: colimaPath) }
    public var dockerURL: URL { URL(fileURLWithPath: dockerPath) }
    public var resticURL: URL { URL(fileURLWithPath: resticPath) }

    public func validate() throws {
        for path in [colimaPath, dockerPath, resticPath] {
            guard path.hasPrefix("/"), !path.contains("\0") else {
                throw ConfigurationError.invalidToolPath(path)
            }
        }
    }

    private static func resolve(_ candidates: [String], fileManager: FileManager) -> String {
        candidates.first(where: { fileManager.isExecutableFile(atPath: $0) }) ?? candidates[0]
    }
}

public struct ResourcePreset: Codable, Equatable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var cpuCount: Int
    public var memoryGiB: Int

    public init(name: String, cpuCount: Int, memoryGiB: Int) {
        self.name = name
        self.cpuCount = cpuCount
        self.memoryGiB = memoryGiB
    }

    public static let compact = ResourcePreset(name: "Compact", cpuCount: 2, memoryGiB: 4)
    public static let balanced = ResourcePreset(name: "Balanced", cpuCount: 4, memoryGiB: 6)
    public static let performance = ResourcePreset(name: "Performance", cpuCount: 6, memoryGiB: 12)
    public static let allPresets = [compact, balanced, performance]

    public func validate() throws {
        guard !name.isEmpty, cpuCount > 0, cpuCount <= 128, memoryGiB > 0, memoryGiB <= 1_024 else {
            throw ConfigurationError.invalidResourcePreset
        }
    }
}

public enum BackupTargetKind: String, Codable, CaseIterable, Hashable, Sendable {
    case r2
    case usb
}

public struct BackupTargetConfiguration: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var kind: BackupTargetKind
    public var displayName: String
    public var enabled: Bool
    public var schedule: BackupSchedule
    public var retention: RetentionPolicy
    /// Repository locations are not credentials. R2 credentials are held in Keychain.
    public var repository: String
    public var tag: String
    public var keychainService: String
    public var usbMountPath: String?
    public var usbVolumeUUID: String?

    public init(
        id: UUID = UUID(),
        kind: BackupTargetKind,
        displayName: String,
        enabled: Bool,
        schedule: BackupSchedule,
        retention: RetentionPolicy,
        repository: String,
        tag: String,
        keychainService: String,
        usbMountPath: String? = nil,
        usbVolumeUUID: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.enabled = enabled
        self.schedule = schedule
        self.retention = retention
        self.repository = repository
        self.tag = tag
        self.keychainService = keychainService
        self.usbMountPath = usbMountPath
        self.usbVolumeUUID = usbVolumeUUID
    }

    public func validate() throws {
        guard !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !tag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !keychainService.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConfigurationError.invalidBackupTarget(id)
        }

        try schedule.validate()
        try retention.validate()

        switch kind {
        case .r2:
            guard !enabled || Self.isSafeR2Repository(repository) else {
                throw ConfigurationError.invalidBackupRepository(id)
            }
        case .usb:
            if enabled {
                guard repository.hasPrefix("/"),
                      let mountPath = usbMountPath,
                      mountPath.hasPrefix("/Volumes/"),
                      let volumeUUID = usbVolumeUUID,
                      !volumeUUID.isEmpty,
                      Self.repository(repository, isDescendantOf: mountPath) else {
                    throw ConfigurationError.invalidUSBTarget(id)
                }
            }
        }
    }

    private static func isSafeR2Repository(_ repository: String) -> Bool {
        guard repository.hasPrefix("s3:"),
              let endpoint = URL(string: String(repository.dropFirst(3))),
              let scheme = endpoint.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              endpoint.host != nil,
              endpoint.user == nil,
              endpoint.password == nil,
              endpoint.query == nil,
              endpoint.fragment == nil else {
            return false
        }
        return true
    }

    private static func repository(_ repository: String, isDescendantOf mountPath: String) -> Bool {
        let mount = URL(fileURLWithPath: mountPath, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath().path
        let destination = URL(fileURLWithPath: repository, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath().path
        return destination.hasPrefix(mount + "/")
    }
}

public struct BackupSchedule: Codable, Equatable, Sendable {
    public var hour: Int
    public var minute: Int
    /// Calendar weekday values (1 is Sunday through 7 is Saturday). Empty means disabled.
    public var weekdays: [Int]

    public init(hour: Int, minute: Int, weekdays: [Int] = Array(1...7)) {
        self.hour = hour
        self.minute = minute
        self.weekdays = weekdays
    }

    public func validate() throws {
        guard (0...23).contains(hour),
              (0...59).contains(minute),
              weekdays.allSatisfy({ (1...7).contains($0) }),
              Set(weekdays).count == weekdays.count else {
            throw ConfigurationError.invalidSchedule
        }
    }
}

public struct RetentionPolicy: Codable, Equatable, Sendable {
    public var keepDaily: Int
    public var keepWeekly: Int
    public var keepMonthly: Int
    public var keepYearly: Int

    public init(keepDaily: Int, keepWeekly: Int, keepMonthly: Int, keepYearly: Int) {
        self.keepDaily = keepDaily
        self.keepWeekly = keepWeekly
        self.keepMonthly = keepMonthly
        self.keepYearly = keepYearly
    }

    public static let standard = RetentionPolicy(keepDaily: 7, keepWeekly: 5, keepMonthly: 12, keepYearly: 3)

    public func validate() throws {
        let values = [keepDaily, keepWeekly, keepMonthly, keepYearly]
        guard values.allSatisfy({ (0...10_000).contains($0) }), values.contains(where: { $0 > 0 }) else {
            throw ConfigurationError.invalidRetentionPolicy
        }
    }
}

public enum ConfigurationError: LocalizedError, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case invalidProjectRoot(String)
    case invalidComposeFile(String)
    case invalidProjectName(String)
    case invalidServerURL(String)
    case invalidToolPath(String)
    case invalidResourcePreset
    case duplicateBackupTargetID
    case duplicateBackupTargetKind
    case invalidBackupTarget(UUID)
    case invalidBackupRepository(UUID)
    case invalidUSBTarget(UUID)
    case invalidSchedule
    case invalidRetentionPolicy

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let version): return "This configuration uses unsupported schema version \(version)."
        case .invalidProjectRoot(let path): return "The Immich project folder is unavailable: \(path)"
        case .invalidComposeFile(let path): return "The Docker Compose file is unavailable: \(path)"
        case .invalidProjectName: return "The Compose project name may only contain letters, numbers, dashes, and underscores."
        case .invalidServerURL: return "The local Immich URL must be an HTTP or HTTPS URL."
        case .invalidToolPath: return "A tool path must be an absolute path."
        case .invalidResourcePreset: return "The selected CPU and memory preset is invalid."
        case .duplicateBackupTargetID: return "Each backup destination needs a unique identifier."
        case .duplicateBackupTargetKind: return "Only one configuration is allowed for each backup destination."
        case .invalidBackupTarget: return "A backup destination is missing a required setting."
        case .invalidBackupRepository: return "The cloud backup repository must use an S3 URL."
        case .invalidUSBTarget: return "The USB backup needs an absolute repository, volume mount path, and volume UUID."
        case .invalidSchedule: return "The backup schedule is invalid."
        case .invalidRetentionPolicy: return "The backup retention policy is invalid."
        }
    }
}

/// Persists non-secret settings in Application Support. It does not alter the
/// existing deployment scripts, .env file, launch agents, or server state.
public final class ImmichConfigurationStore: @unchecked Sendable {
    public let fileURL: URL
    public let installationRoot: URL?
    private let lock = NSLock()
    private let fileManager: FileManager

    public init(
        fileURL: URL = ImmichConfigurationStore.defaultURL(),
        installationRoot: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL.standardizedFileURL
        self.installationRoot = installationRoot?.standardizedFileURL
        self.fileManager = fileManager
    }

    public static func defaultURL(fileManager: FileManager = .default) -> URL {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return support.appendingPathComponent("ImmichControl", isDirectory: true)
            .appendingPathComponent("Configuration.json", isDirectory: false)
    }

    public func load() throws -> ImmichConfiguration {
        lock.lock()
        defer { lock.unlock() }

        if fileManager.fileExists(atPath: fileURL.path) {
            let configuration = try decoder().decode(ImmichConfiguration.self, from: Data(contentsOf: fileURL))
            try configuration.validate(fileManager: fileManager)
            return configuration
        }

        let root = installationRoot ?? LegacyConfigurationImporter.findInstallationRoot(fileManager: fileManager)
        let configuration = try LegacyConfigurationImporter.importConfiguration(from: root, fileManager: fileManager)
        try write(configuration)
        return configuration
    }

    public func save(_ configuration: ImmichConfiguration) throws {
        lock.lock()
        defer { lock.unlock() }
        try configuration.validate(fileManager: fileManager)
        try write(configuration)
    }

    @discardableResult
    public func update(_ transform: (inout ImmichConfiguration) throws -> Void) throws -> ImmichConfiguration {
        lock.lock()
        defer { lock.unlock() }

        let current: ImmichConfiguration
        if fileManager.fileExists(atPath: fileURL.path) {
            current = try decoder().decode(ImmichConfiguration.self, from: Data(contentsOf: fileURL))
        } else {
            let root = installationRoot ?? LegacyConfigurationImporter.findInstallationRoot(fileManager: fileManager)
            current = try LegacyConfigurationImporter.importConfiguration(from: root, fileManager: fileManager)
        }

        var updated = current
        try transform(&updated)
        try updated.validate(fileManager: fileManager)
        try write(updated)
        return updated
    }

    /// Re-reads safe deployment metadata. Existing saved settings are left alone
    /// unless a caller explicitly saves the returned value.
    public func importLegacyConfiguration(from root: URL) throws -> ImmichConfiguration {
        try LegacyConfigurationImporter.importConfiguration(from: root, fileManager: fileManager)
    }

    private func write(_ configuration: ImmichConfiguration) throws {
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try encoder().encode(configuration)
        try data.write(to: fileURL, options: .atomic)
    }

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private func decoder() -> JSONDecoder {
        JSONDecoder()
    }
}

/// Imports only deployment metadata that is safe to keep in application
/// settings. It never reads Keychain values or parses .env, which may contain
/// database credentials.
public enum LegacyConfigurationImporter {
    public static func findInstallationRoot(fileManager: FileManager = .default) -> URL {
        let currentDirectory = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        let conventional = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("server/immich-app", isDirectory: true)
        let candidates = [currentDirectory, conventional]
        return candidates.first(where: {
            fileManager.fileExists(atPath: $0.appendingPathComponent("docker-compose.yml").path)
        }) ?? conventional
    }

    public static func importConfiguration(
        from root: URL,
        fileManager: FileManager = .default
    ) throws -> ImmichConfiguration {
        let normalizedRoot = root.standardizedFileURL
        let compose = normalizedRoot.appendingPathComponent("docker-compose.yml")
        guard fileManager.fileExists(atPath: compose.path) else {
            throw ConfigurationError.invalidProjectRoot(normalizedRoot.path)
        }

        var configuration = ImmichConfiguration.default(projectRoot: normalizedRoot)
        let r2Script = normalizedRoot.appendingPathComponent("backup-immich-r2.sh")
        let usbScript = normalizedRoot.appendingPathComponent("backup-immich-usb.sh")
        let localSettings = readLocalSettings(normalizedRoot.appendingPathComponent("immich.local.json"))
        let r2Schedule = readLegacySchedule(normalizedRoot.appendingPathComponent("com.tan.immich-r2-backup.plist"))
        let usbSchedule = readLegacySchedule(normalizedRoot.appendingPathComponent("com.tan.immich-usb-backup.plist"))

        if let cpuCount = localSettings?.cpuCount, let memoryGiB = localSettings?.memoryGiB,
           cpuCount > 0, memoryGiB > 0 {
            configuration.server.resourcePreset = ResourcePreset(name: "Balanced", cpuCount: cpuCount, memoryGiB: memoryGiB)
        }

        let r2ScriptContents = readText(r2Script)
        if let index = configuration.backups.firstIndex(where: { $0.kind == .r2 }) {
            let repository = r2ScriptContents.flatMap { constant("RESTIC_REPOSITORY", in: $0) }
                ?? localSettings?.r2Repository
                ?? configuration.backups[index].repository
            configuration.backups[index].repository = repository
            configuration.backups[index].tag = r2ScriptContents.flatMap { constant("RESTIC_TAG", in: $0) }
                ?? configuration.backups[index].tag
            configuration.backups[index].schedule = r2Schedule ?? configuration.backups[index].schedule
            configuration.backups[index].enabled = repository.hasPrefix("s3:")
        }

        let usbScriptContents = readText(usbScript)
        if let index = configuration.backups.firstIndex(where: { $0.kind == .usb }) {
            let scriptMount = usbScriptContents.flatMap { constant("USB_MOUNT", in: $0) }
            let mount = scriptMount ?? localSettings?.usbMountPath ?? configuration.backups[index].usbMountPath
            let scriptRepository = usbScriptContents.flatMap { constant("RESTIC_REPOSITORY", in: $0) }
                .flatMap { value in value.contains("${USB_MOUNT}") ? mount.map { value.replacingOccurrences(of: "${USB_MOUNT}", with: $0) } : value }
            let repository = scriptRepository ?? localSettings?.usbRepository ?? configuration.backups[index].repository
            let volumeUUID = usbScriptContents.flatMap { constant("USB_VOLUME_UUID", in: $0) }
                ?? localSettings?.usbVolumeUUID
                ?? configuration.backups[index].usbVolumeUUID
            configuration.backups[index].usbMountPath = mount
            configuration.backups[index].usbVolumeUUID = volumeUUID
            configuration.backups[index].repository = repository
            configuration.backups[index].tag = usbScriptContents.flatMap { constant("RESTIC_TAG", in: $0) }
                ?? configuration.backups[index].tag
            configuration.backups[index].schedule = usbSchedule ?? configuration.backups[index].schedule
            configuration.backups[index].enabled = repository.hasPrefix("/") && !(volumeUUID ?? "").isEmpty
        }

        try configuration.validate(fileManager: fileManager)
        return configuration
    }

    private static func readText(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    private static func readLocalSettings(_ url: URL) -> LegacyLocalSettings? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LegacyLocalSettings.self, from: data)
    }

    /// Preserves the old schedule when the deployment kept its launch-agent
    /// templates beside Compose. This is metadata only; no job is loaded,
    /// unloaded, or otherwise changed while importing.
    private static func readLegacySchedule(_ url: URL) -> BackupSchedule? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let rawInterval = plist["StartCalendarInterval"] else {
            return nil
        }
        let intervals: [[String: Any]]
        if let one = rawInterval as? [String: Any] {
            intervals = [one]
        } else if let many = rawInterval as? [[String: Any]] {
            intervals = many
        } else {
            return nil
        }
        guard let first = intervals.first,
              let hour = first["Hour"] as? Int,
              let minute = first["Minute"] as? Int,
              (0...23).contains(hour),
              (0...59).contains(minute) else {
            return nil
        }
        let weekdays = intervals.compactMap { interval -> Int? in
            guard let launchdWeekday = interval["Weekday"] as? Int, (0...6).contains(launchdWeekday) else {
                return nil
            }
            return launchdWeekday + 1
        }
        let schedule = BackupSchedule(hour: hour, minute: minute, weekdays: weekdays.isEmpty ? Array(1...7) : weekdays)
        do {
            try schedule.validate()
            return schedule
        } catch {
            return nil
        }
    }

    /// Extracts quoted readonly shell constants from the legacy scripts. Callers
    /// only request an allow-listed set of non-secret names.
    private static func constant(_ name: String, in script: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let pattern = "(?m)^\\s*(?:readonly\\s+)?\(escaped)\\s*=\\s*\\\"([^\\\"]*)\\\"\\s*$"
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: script, range: NSRange(script.startIndex..., in: script)),
              let range = Range(match.range(at: 1), in: script) else {
            return nil
        }
        return String(script[range])
    }
}

private struct LegacyLocalSettings: Decodable {
    let r2Repository: String?
    let usbRepository: String?
    let usbMountPath: String?
    let usbVolumeUUID: String?
    let cpuCount: Int?
    let memoryGiB: Int?
}
