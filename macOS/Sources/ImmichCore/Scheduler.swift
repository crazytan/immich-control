import Foundation
import Darwin

public enum SchedulerError: LocalizedError, Equatable, Sendable {
    case invalidHelperPath(String)
    case unableToWriteAgent(String)
    case launchdRejected(String)
    case legacyMigrationRequired
    case managedRollbackFailed(String)
    case legacyRollbackFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidHelperPath(path): return "The background helper is unavailable: \(path)"
        case let .unableToWriteAgent(path): return "The LaunchAgent could not be written: \(path)"
        case let .launchdRejected(message): return "launchd could not load the scheduled job: \(message)"
        case .legacyMigrationRequired: return "Existing script backup schedules must be migrated before app-managed schedules can be enabled."
        case let .managedRollbackFailed(message): return "A schedule update failed and the previous schedules could not be restored: \(message)"
        case let .legacyRollbackFailed(message): return "The old backup schedules could not be restored: \(message)"
        }
    }
}

/// Per-user launchd integration. Its generated files contain only the helper
/// path, fixed argv, project root, and calendar settings; repositories and
/// credentials stay in configuration and Keychain respectively.
public final class BackupScheduler: @unchecked Sendable {
    public static let r2Label = "com.tan.immich-control.backup-r2"
    public static let usbLabel = "com.tan.immich-control.backup-usb"
    public static let serverLoginLabel = "com.tan.immich-control.server-login"

    public static let legacyR2Label = "com.tan.immich-r2-backup"
    public static let legacyUSBLabel = "com.tan.immich-usb-backup"

    public let launchAgentsDirectoryURL: URL
    public let logsDirectoryURL: URL
    private let fileManager: FileManager
    private let commandRunner: any CommandRunning
    private let configuredHelperURL: URL?

    public init(
        helperURL: URL? = nil,
        launchAgentsDirectoryURL: URL = BackupScheduler.defaultLaunchAgentsDirectory(),
        logsDirectoryURL: URL = BackupScheduler.defaultLogsDirectory(),
        fileManager: FileManager = .default,
        commandRunner: any CommandRunning = ProcessCommandRunner()
    ) {
        self.configuredHelperURL = helperURL?.standardizedFileURL
        self.launchAgentsDirectoryURL = launchAgentsDirectoryURL.standardizedFileURL
        self.logsDirectoryURL = logsDirectoryURL.standardizedFileURL
        self.fileManager = fileManager
        self.commandRunner = commandRunner
    }

    public static func defaultLaunchAgentsDirectory() -> URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    }

    public static func defaultLogsDirectory(fileManager: FileManager = .default) -> URL {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return support.appendingPathComponent("ImmichControl/Logs", isDirectory: true)
    }

    public func agentURL(for kind: BackupTargetKind) -> URL {
        launchAgentsDirectoryURL.appendingPathComponent("\(label(for: kind)).plist", isDirectory: false)
    }

    public var serverLoginAgentURL: URL {
        launchAgentsDirectoryURL.appendingPathComponent("\(Self.serverLoginLabel).plist", isDirectory: false)
    }

    public func hasLegacySchedules() -> Bool {
        legacyAgentURLs.contains { fileManager.fileExists(atPath: $0.path) }
    }

    /// Installs or removes the app-managed backup schedules to exactly match the
    /// saved configuration. This never touches the legacy script launch agents.
    public func syncBackupSchedules(
        configuration: ImmichConfiguration,
        helperURL: URL? = nil
    ) async throws {
        try configuration.validate(fileManager: fileManager)
        guard !hasLegacySchedules() else { throw SchedulerError.legacyMigrationRequired }
        let helper = try resolvedHelperURL(helperURL)
        var snapshots: [BackupTargetKind: AgentSnapshot] = [:]
        for kind in BackupTargetKind.allCases {
            snapshots[kind] = try await snapshot(label: label(for: kind), at: agentURL(for: kind))
        }

        do {
            for kind in BackupTargetKind.allCases {
                let agentURL = agentURL(for: kind)
                guard let target = configuration.backups.first(where: { $0.kind == kind }),
                      target.enabled,
                      !target.schedule.weekdays.isEmpty else {
                    try await unloadAndRemoveAgent(label: label(for: kind), at: agentURL)
                    continue
                }
                let data = try backupAgentData(target: target, root: configuration.server.projectRootURL, helper: helper)
                try await replaceLoadedAgent(label: label(for: kind), at: agentURL, data: data)
            }
        } catch {
            do {
                for kind in BackupTargetKind.allCases.reversed() {
                    guard let snapshot = snapshots[kind] else { continue }
                    try await restore(snapshot, label: label(for: kind), at: agentURL(for: kind))
                }
            } catch {
                throw SchedulerError.managedRollbackFailed(error.localizedDescription)
            }
            throw error
        }
    }

    /// Manages the separate start-at-login agent. Enabling deliberately only
    /// writes the plist: launchd discovers it on the next login and the current
    /// server state is not changed as a side effect of opening Settings.
    public func setServerLoginEnabled(_ enabled: Bool, helperURL: URL? = nil, projectRootURL: URL? = nil) async throws {
        if enabled {
            let helper = try resolvedHelperURL(helperURL)
            let root = projectRootURL?.standardizedFileURL ?? configuredProjectRoot()
            let data = try serverLoginAgentData(root: root, helper: helper)
            try write(data, to: serverLoginAgentURL)
        } else {
            try await unloadAndRemoveAgent(label: Self.serverLoginLabel, at: serverLoginAgentURL)
        }
    }

    /// The configuration-aware convenience used by Settings avoids any chance
    /// that a stale root supplied by a caller becomes the login server target.
    public func setServerLoginEnabled(_ enabled: Bool, configuration: ImmichConfiguration, helperURL: URL? = nil) async throws {
        try configuration.validate(fileManager: fileManager)
        try await setServerLoginEnabled(enabled, helperURL: helperURL, projectRootURL: configuration.server.projectRootURL)
    }

    public func disableManagedSchedules() async throws {
        try await unloadAndRemoveAgent(label: Self.r2Label, at: agentURL(for: .r2))
        try await unloadAndRemoveAgent(label: Self.usbLabel, at: agentURL(for: .usb))
    }

    /// Explicit, reversible migration from the two shell-script agents. The old
    /// plists are moved aside before app schedules are bootstrapped, preventing
    /// duplicate executions. If loading a replacement fails, the original files
    /// and jobs are restored.
    public func migrateLegacySchedules(
        configuration: ImmichConfiguration,
        helperURL: URL? = nil
    ) async throws {
        try configuration.validate(fileManager: fileManager)
        let helper = try resolvedHelperURL(helperURL)
        let legacy = legacyAgentURLs.filter { fileManager.fileExists(atPath: $0.path) }
        guard !legacy.isEmpty else {
            try await syncBackupSchedules(configuration: configuration, helperURL: helper)
            return
        }

        var originals: [URL: AgentSnapshot] = [:]
        for url in legacy {
            originals[url] = try await snapshot(label: legacyLabel(for: url), at: url)
        }
        var unloadedLegacy: [URL] = []
        var movedLegacy: [URL] = []
        do {
            for url in legacy {
                if try await unloadLegacyAgent(at: url) { unloadedLegacy.append(url) }
            }
            for url in legacy {
                let disabledURL = url.appendingPathExtension("immich-control-disabled")
                if fileManager.fileExists(atPath: disabledURL.path) {
                    try fileManager.removeItem(at: disabledURL)
                }
                try fileManager.moveItem(at: url, to: disabledURL)
                movedLegacy.append(url)
            }
            try await syncBackupSchedules(configuration: configuration, helperURL: helper)
        } catch {
            do {
                try await disableManagedSchedules()
                for url in movedLegacy.reversed() {
                    let disabledURL = url.appendingPathExtension("immich-control-disabled")
                    if fileManager.fileExists(atPath: disabledURL.path) {
                        try fileManager.moveItem(at: disabledURL, to: url)
                    }
                }
                for url in unloadedLegacy {
                    guard let original = originals[url], original.wasLoaded else { continue }
                    try await bootstrap(label: legacyLabel(for: url), at: url)
                }
            } catch {
                throw SchedulerError.legacyRollbackFailed(error.localizedDescription)
            }
            throw error
        }
    }

    private var legacyAgentURLs: [URL] {
        [Self.legacyR2Label, Self.legacyUSBLabel].map {
            launchAgentsDirectoryURL.appendingPathComponent("\($0).plist", isDirectory: false)
        }
    }

    private func configuredProjectRoot() -> URL {
        // This overload exists for settings code that configured the scheduler
        // with a helper only. It is never used by the configuration-aware path.
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true).standardizedFileURL
    }

    private func resolvedHelperURL(_ override: URL?) throws -> URL {
        let helper = (override ?? configuredHelperURL)?.standardizedFileURL
        guard let helper, helper.path.hasPrefix("/"), fileManager.isExecutableFile(atPath: helper.path) else {
            throw SchedulerError.invalidHelperPath((override ?? configuredHelperURL)?.path ?? "(not configured)")
        }
        return helper
    }

    private func label(for kind: BackupTargetKind) -> String {
        kind == .r2 ? Self.r2Label : Self.usbLabel
    }

    private func legacyLabel(for url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    private func backupAgentData(target: BackupTargetConfiguration, root: URL, helper: URL) throws -> Data {
        let arguments = [helper.path, "--root", root.path, "backup", target.kind.rawValue]
        var plist: [String: Any] = basePlist(
            label: label(for: target.kind),
            arguments: arguments,
            logStem: target.kind.rawValue
        )
        plist["StartCalendarInterval"] = calendarIntervals(for: target.schedule)
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    private func serverLoginAgentData(root: URL, helper: URL) throws -> Data {
        var plist = basePlist(
            label: Self.serverLoginLabel,
            arguments: [helper.path, "--root", root.path, "server", "start"],
            logStem: "server-login"
        )
        plist["RunAtLoad"] = true
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    private func basePlist(label: String, arguments: [String], logStem: String) -> [String: Any] {
        let log = logsDirectoryURL.appendingPathComponent("\(logStem).log", isDirectory: false).path
        return [
            "Label": label,
            "ProgramArguments": arguments,
            "ProcessType": "Background",
            "LowPriorityIO": true,
            "StandardOutPath": log,
            "StandardErrorPath": log,
        ]
    }

    private func calendarIntervals(for schedule: BackupSchedule) -> [[String: Int]] {
        schedule.weekdays.map { weekday in
            // Immich settings use Calendar's 1...7 weekday values (Sunday...Saturday).
            // launchd uses 0...6 (Sunday...Saturday).
            ["Hour": schedule.hour, "Minute": schedule.minute, "Weekday": (weekday - 1) % 7]
        }
    }

    private func replaceLoadedAgent(label: String, at url: URL, data: Data) async throws {
        let original = try await snapshot(label: label, at: url)
        _ = try await unloadAgent(label: label, at: url)
        do {
            try write(data, to: url)
            try await bootstrap(label: label, at: url)
        } catch {
            try? await restore(original, label: label, at: url)
            throw error
        }
    }

    private func unloadAndRemoveAgent(label: String, at url: URL) async throws {
        _ = try await unloadAgent(label: label, at: url)
        guard fileManager.fileExists(atPath: url.path) else { return }
        do { try fileManager.removeItem(at: url) }
        catch { throw SchedulerError.unableToWriteAgent(url.path) }
    }

    @discardableResult
    private func unloadLegacyAgent(at url: URL) async throws -> Bool {
        try await unloadAgent(label: legacyLabel(for: url), at: url)
    }

    private func snapshot(label: String, at url: URL) async throws -> AgentSnapshot {
        AgentSnapshot(
            data: fileManager.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil,
            wasLoaded: try await isAgentLoaded(label: label)
        )
    }

    private func restore(_ snapshot: AgentSnapshot, label: String, at url: URL) async throws {
        _ = try await unloadAgent(label: label, at: url)
        if let data = snapshot.data {
            try write(data, to: url)
            if snapshot.wasLoaded { try await bootstrap(label: label, at: url) }
        } else if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    @discardableResult
    private func unloadAgent(label: String, at url: URL) async throws -> Bool {
        guard try await isAgentLoaded(label: label) else { return false }
        let result = try await commandRunner.run(launchctlCommand(arguments: ["bootout", "gui/\(getuid())", url.path]), timeout: 20)
        guard result.succeeded else { throw SchedulerError.launchdRejected(result.conciseFailureMessage) }
        guard !(try await isAgentLoaded(label: label)) else {
            throw SchedulerError.launchdRejected("launchd kept \(label) loaded after bootout")
        }
        return true
    }

    private func isAgentLoaded(label: String) async throws -> Bool {
        let result = try await commandRunner.run(launchctlCommand(arguments: ["print", "gui/\(getuid())/\(label)"]), timeout: 20)
        if result.succeeded { return true }
        let diagnostic = (result.standardError + "\n" + result.standardOutput).lowercased()
        if diagnostic.contains("could not find service") ||
            diagnostic.contains("service not found") ||
            diagnostic.contains("no such process") ||
            diagnostic.contains("not loaded") {
            return false
        }
        throw SchedulerError.launchdRejected(result.conciseFailureMessage)
    }

    private func write(_ data: Data, to url: URL) throws {
        do {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.createDirectory(at: logsDirectoryURL, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            throw SchedulerError.unableToWriteAgent(url.path)
        }
    }

    private func bootstrap(label: String, at url: URL) async throws {
        let result = try await commandRunner.run(launchctlCommand(arguments: ["bootstrap", "gui/\(getuid())", url.path]), timeout: 20)
        guard result.succeeded else { throw SchedulerError.launchdRejected(result.conciseFailureMessage) }
    }

    private func launchctlCommand(arguments: [String]) -> Command {
        Command(executable: URL(fileURLWithPath: "/bin/launchctl"), arguments: arguments)
    }
}

private struct AgentSnapshot {
    let data: Data?
    let wasLoaded: Bool
}
