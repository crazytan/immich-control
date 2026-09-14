import Foundation

/// Runs the existing Restic backup layout without going through a shell script.
/// Configuration values become argv entries or environment values only; no
/// source/eval/interpolation path exists for project or credential settings.
public final class BackupCoordinator: @unchecked Sendable {
    public static let dumpTimeout: TimeInterval = 15 * 60
    public static let backupTimeout: TimeInterval = 12 * 60 * 60

    public let configuration: ImmichConfiguration
    public let statusStore: StatusStore
    public let operationLock: OperationLock
    public let activityStore: BackupActivityStore
    public let recoveryStore: BackupRecoveryStore

    private let commandRunner: any CommandRunning
    /// Used by injected test doubles. The production path operates only on the
    /// `immich_server` container so PostgreSQL remains available for pg_dump.
    private let injectedServerController: (any ServerControlling)?
    private let keychain: any SecretStoring
    private let usbInspector: any USBInspecting
    private let clock: any BackupClock
    private let fileManager: FileManager

    public init(
        configuration: ImmichConfiguration,
        commandRunner: any CommandRunning = ProcessCommandRunner(),
        serverController: (any ServerControlling)? = nil,
        statusStore: StatusStore = StatusStore(),
        operationLock: OperationLock = OperationLock(),
        activityStore: BackupActivityStore = BackupActivityStore(),
        recoveryStore: BackupRecoveryStore = BackupRecoveryStore(),
        keychain: any SecretStoring = KeychainStore(),
        usbInspector: any USBInspecting = SystemUSBInspector(),
        clock: any BackupClock = SystemBackupClock(),
        fileManager: FileManager = .default
    ) {
        self.configuration = configuration
        self.commandRunner = commandRunner
        self.injectedServerController = serverController
        self.statusStore = statusStore
        self.operationLock = operationLock
        self.activityStore = activityStore
        self.recoveryStore = recoveryStore
        self.keychain = keychain
        self.usbInspector = usbInspector
        self.clock = clock
        self.fileManager = fileManager
    }

    public func run(targetID: UUID, online: Bool = false) async -> BackupExecutionResult {
        guard let target = configuration.backups.first(where: { $0.id == targetID }) else {
            return result(targetID: targetID, outcome: .error, message: BackupError.targetNotFound.localizedDescription, startedAt: clock.now())
        }
        return await run(target: target, online: online)
    }

    /// `online` is intentionally opt-in for a potentially long initial upload;
    /// ordinary scheduled runs stop Immich to keep DB and assets consistent.
    public func run(target: BackupTargetConfiguration, online: Bool = false) async -> BackupExecutionResult {
        let startedAt = clock.now()
        guard target.enabled else {
            return result(targetID: target.id, outcome: .skipped, message: "\(target.displayName) backup is disabled.", startedAt: startedAt)
        }
        do {
            try target.validate()
        } catch {
            return result(targetID: target.id, outcome: .error, message: error.localizedDescription, startedAt: startedAt)
        }

        // This deliberately happens before acquiring the global lock or asking
        // Docker about its state. An absent USB drive is a skip, never a command
        // or an accidental write to another mounted volume.
        switch usbPreflight(target) {
        case .notApplicable, .ready:
            break
        case let .skipped(message):
            return result(targetID: target.id, outcome: .skipped, message: message, startedAt: startedAt)
        case let .failed(message):
            return result(targetID: target.id, outcome: .error, message: message, startedAt: startedAt)
        }

        do {
            let handle = try await operationLock.acquire(timeout: 30)
            defer { handle.release() }
            return await executeLocked(target: target, online: online, startedAt: startedAt)
        } catch {
            return result(targetID: target.id, outcome: .error, message: error.localizedDescription, startedAt: startedAt)
        }
    }

    /// Call this from a helper start-up or a foreground recovery action. It is
    /// safe only when the persisted record belongs to the current project root.
    /// SIGKILL cannot run this immediately, so the following invocation is the
    /// recovery point; SIGINT/SIGTERM use normal cancellation cleanup instead.
    @discardableResult
    public func recoverInterruptedServer() async -> String? {
        do {
            let handle = try await operationLock.acquire(timeout: 30)
            defer { handle.release() }
            return await recoverInterruptedServerWhileLocked()
        } catch {
            return error.localizedDescription
        }
    }

    private func executeLocked(target: BackupTargetConfiguration, online: Bool, startedAt: Date) async -> BackupExecutionResult {
        if let recoveryError = await recoverInterruptedServerWhileLocked() {
            return result(targetID: target.id, outcome: .error, message: recoveryError, startedAt: startedAt)
        }
        if let stale = try? activityStore.takeStaleActivity() {
            _ = try? statusStore.record(
                targetID: stale.targetID,
                outcome: .error,
                message: "Backup helper was interrupted during \(stale.stage.rawValue).",
                startedAt: stale.startedAt,
                finishedAt: clock.now()
            )
        }

        do {
            try activityStore.begin(BackupActivity(
                targetID: target.id,
                projectRootPath: configuration.server.projectRootPath,
                startedAt: startedAt,
                stage: .preparing
            ))
        } catch {
            return result(targetID: target.id, outcome: .error, message: error.localizedDescription, startedAt: startedAt)
        }
        defer { try? activityStore.clear() }

        var stoppedServer = false
        var primaryMessage: String?
        do {
            try throwIfCancelled()
            if !online, try await isServerContainerRunning() {
                try recoveryStore.markServerStopped(
                    for: target.id,
                    projectRootPath: configuration.server.projectRootPath,
                    at: clock.now()
                )
                stoppedServer = true
                try await stopServerWhileLocked()
            }

            try throwIfCancelled()
            try activityStore.update(stage: .database)
            try await createFreshDatabaseDump()

            try throwIfCancelled()
            try activityStore.update(stage: .snapshot)
            try await ensureUSBRepositoryIfNeeded(target)
            try await runResticBackup(target)
        } catch is CancellationError {
            primaryMessage = "Backup was cancelled."
        } catch {
            primaryMessage = error.localizedDescription
        }

        if stoppedServer {
            // Progress persistence must never be allowed to strand Immich after
            // a disk-full or permission failure in Application Support.
            try? activityStore.update(stage: .restarting)
            do {
                try await restoreServerAfterBackup()
            } catch {
                let restart = BackupError.restartFailed(error.localizedDescription).localizedDescription
                let message = primaryMessage.map { "\($0) \(restart)" } ?? restart
                return result(targetID: target.id, outcome: .error, message: message, startedAt: startedAt)
            }
            do {
                try recoveryStore.clear()
            } catch {
                let message = "Immich was restarted, but the backup recovery record could not be cleared: \(error.localizedDescription)"
                return result(targetID: target.id, outcome: .error, message: message, startedAt: startedAt)
            }
        }

        if let primaryMessage {
            return result(targetID: target.id, outcome: .error, message: primaryMessage, startedAt: startedAt)
        }

        do {
            try throwIfCancelled()
            if clock.weekday(at: clock.now()) == 1 {
                try activityStore.update(stage: .maintenance)
                try await runRetentionAndCheck(target)
            }
            return result(targetID: target.id, outcome: .success, message: "\(target.displayName) backup completed.", startedAt: startedAt)
        } catch is CancellationError {
            return result(targetID: target.id, outcome: .error, message: "Backup was cancelled during maintenance.", startedAt: startedAt)
        } catch {
            return result(targetID: target.id, outcome: .error, message: error.localizedDescription, startedAt: startedAt)
        }
    }

    @discardableResult
    private func recoverInterruptedServerWhileLocked() async -> String? {
        guard let pending = try? recoveryStore.pendingRecovery() else { return nil }
        guard pending.projectRootPath == nil || pending.projectRootPath == configuration.server.projectRootPath else {
            return "A previously interrupted backup belongs to another project folder; its server was not started automatically."
        }
        do {
            try await startServerWhileLocked()
        } catch {
            _ = try? statusStore.record(
                targetID: pending.targetID,
                outcome: .error,
                message: "Immich remains stopped after an interrupted backup: \(error.localizedDescription)",
                startedAt: pending.startedAt,
                finishedAt: clock.now()
            )
            return error.localizedDescription
        }
        do {
            try recoveryStore.clear()
        } catch {
            _ = try? statusStore.record(
                targetID: pending.targetID,
                outcome: .error,
                message: "Immich was restarted after an interrupted backup, but its recovery record could not be cleared: \(error.localizedDescription)",
                startedAt: pending.startedAt,
                finishedAt: clock.now()
            )
            return error.localizedDescription
        }
        _ = try? statusStore.record(
            targetID: pending.targetID,
            outcome: .error,
            message: "Recovered Immich after an interrupted backup.",
            startedAt: pending.startedAt,
            finishedAt: clock.now()
        )
        return nil
    }

    private func usbPreflight(_ target: BackupTargetConfiguration) -> USBPreflight {
        guard target.kind == .usb else { return .notApplicable }
        guard let mount = target.usbMountPath, let uuid = target.usbVolumeUUID else {
            return .failed(BackupError.missingUSBConfiguration.localizedDescription)
        }
        switch usbInspector.inspect(mountPath: URL(fileURLWithPath: mount, isDirectory: true), expectedVolumeUUID: uuid) {
        case .ready: return .ready
        case .unavailable: return .skipped("USB backup skipped: the expected backup volume is not connected.")
        case let .wrongVolume(actualUUID): return .failed(BackupError.usbWrongVolume(actualUUID: actualUUID).localizedDescription)
        case .notWritable: return .failed(BackupError.usbNotWritable.localizedDescription)
        }
    }

    private func createFreshDatabaseDump() async throws {
        let root = configuration.server.projectRootURL
        let env = try DotEnvParser.parse(url: root.appendingPathComponent(".env"))
        guard let database = env["DB_DATABASE_NAME"], !database.isEmpty else {
            throw BackupError.missingDatabaseSetting("DB_DATABASE_NAME")
        }
        guard let username = env["DB_USERNAME"], !username.isEmpty else {
            throw BackupError.missingDatabaseSetting("DB_USERNAME")
        }
        guard let pipelineRunner = commandRunner as? any CommandPipelining else {
            throw BackupError.databaseDumpFailed("The configured command runner cannot stream a database dump.")
        }

        let directory = root.appendingPathComponent("library/backups", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent("restic-\(UUID().uuidString).sql.gz.partial", isDirectory: false)
        let latest = directory.appendingPathComponent("restic-latest.sql.gz", isDirectory: false)
        defer { try? fileManager.removeItem(at: temporary) }

        let dump = Command(
            executable: configuration.server.toolPaths.dockerURL,
            arguments: [
                "--context", "colima", "exec", "immich_postgres", "pg_dump",
                "--clean", "--if-exists", "--dbname=\(database)", "--username=\(username)",
            ],
            currentDirectoryURL: root,
            clearedEnvironmentKeys: ["DOCKER_HOST", "DOCKER_CONTEXT"]
        )
        let gzip = Command(executable: URL(fileURLWithPath: "/usr/bin/gzip"), arguments: ["-c"], currentDirectoryURL: root)
        let pipeline = CommandPipeline(commands: [dump, gzip], standardOutputFileURL: temporary)
        let pipelineResult = try await pipelineRunner.runPipeline(pipeline, timeout: Self.dumpTimeout)
        guard pipelineResult.succeeded else {
            let detail = pipelineResult.commandResults
                .filter { !$0.succeeded }
                .map(\.conciseFailureMessage)
                .first(where: { !$0.isEmpty }) ?? "database dump command failed"
            throw BackupError.databaseDumpFailed(detail)
        }
        guard fileManager.fileExists(atPath: temporary.path) else {
            throw BackupError.databaseDumpFailed("The database dump produced no file.")
        }
        do {
            if fileManager.fileExists(atPath: latest.path) {
                _ = try fileManager.replaceItemAt(latest, withItemAt: temporary, backupItemName: nil, options: .usingNewMetadataOnly)
            } else {
                try fileManager.moveItem(at: temporary, to: latest)
            }
        } catch {
            throw BackupError.databaseDumpFailed("The fresh database dump could not replace the previous dump.")
        }
    }

    private func ensureUSBRepositoryIfNeeded(_ target: BackupTargetConfiguration) async throws {
        guard target.kind == .usb else { return }
        let repository = URL(fileURLWithPath: target.repository, isDirectory: true).standardizedFileURL
        let config = repository.appendingPathComponent("config", isDirectory: false)
        guard !fileManager.fileExists(atPath: config.path) else { return }
        try fileManager.createDirectory(at: repository.deletingLastPathComponent(), withIntermediateDirectories: true)
        let result = try await commandRunner.run(try resticCommand(target: target, arguments: ["init"]), timeout: 5 * 60)
        guard result.succeeded else { throw BackupError.backupFailed(result.conciseFailureMessage) }
    }

    private func runResticBackup(_ target: BackupTargetConfiguration) async throws {
        let arguments = resticConnectionOptions(for: target)
            + ["--json", "backup"]
            + backupSources()
            + ["--tag", target.tag]
        let output = try await commandRunner.run(try resticCommand(target: target, arguments: arguments), timeout: Self.backupTimeout)
        guard output.succeeded else { throw BackupError.backupFailed(output.conciseFailureMessage) }
    }

    private func runRetentionAndCheck(_ target: BackupTargetConfiguration) async throws {
        let retention = target.retention
        let forget = resticConnectionOptions(for: target) + [
            "forget", "--tag", target.tag,
            "--keep-daily", String(retention.keepDaily),
            "--keep-weekly", String(retention.keepWeekly),
            "--keep-monthly", String(retention.keepMonthly),
            "--keep-yearly", String(retention.keepYearly),
            "--prune",
        ]
        let forgetResult = try await commandRunner.run(try resticCommand(target: target, arguments: forget), timeout: Self.backupTimeout)
        guard forgetResult.succeeded else { throw BackupError.backupFailed("Retention failed: \(forgetResult.conciseFailureMessage)") }

        let check = resticConnectionOptions(for: target) + ["check"]
        let checkResult = try await commandRunner.run(try resticCommand(target: target, arguments: check), timeout: Self.backupTimeout)
        guard checkResult.succeeded else { throw BackupError.backupFailed("Repository check failed: \(checkResult.conciseFailureMessage)") }
    }

    private func resticCommand(target: BackupTargetConfiguration, arguments: [String]) throws -> Command {
        Command(
            executable: configuration.server.toolPaths.resticURL,
            arguments: arguments,
            currentDirectoryURL: configuration.server.projectRootURL,
            environment: try resticEnvironment(for: target)
        )
    }

    private func resticConnectionOptions(for target: BackupTargetConfiguration) -> [String] {
        target.kind == .r2 ? ["-o", "s3.connections=15"] : []
    }

    private func resticEnvironment(for target: BackupTargetConfiguration) throws -> [String: String] {
        var environment: [String: String] = [
            "RESTIC_REPOSITORY": target.repository,
            "RESTIC_PASSWORD": try keychain.read(service: BackupSecret.resticPassword.rawValue, account: target.keychainService),
        ]
        if target.kind == .r2 {
            environment["AWS_ACCESS_KEY_ID"] = try keychain.read(service: BackupSecret.r2AccessKeyID.rawValue, account: target.keychainService)
            environment["AWS_SECRET_ACCESS_KEY"] = try keychain.read(service: BackupSecret.r2SecretAccessKey.rawValue, account: target.keychainService)
            environment["AWS_DEFAULT_REGION"] = "auto"
        }
        return environment
    }

    private func backupSources() -> [String] {
        let root = configuration.server.projectRootURL
        let relativePaths = [
            "library/upload", "library/library", "library/profile", "library/backups",
            "docker-compose.yml", ".env", "README.md", "start-immich.sh", "stop-immich.sh",
            "backup-immich-r2.sh", "backup-immich-usb.sh",
            "macOS/Package.swift", "macOS/Sources", "macOS/Tests", "macOS/Resources",
            "macOS/build-app.sh", "macOS/run-helper.sh", "macOS/README.md",
            "immich.local.json", "tailscale/config", "example.env", ".gitignore",
            "com.tan.immich-r2-backup.plist", "com.tan.immich-usb-backup.plist",
        ]
        var sources = relativePaths.map { root.appendingPathComponent($0).path }
        let appConfiguration = ImmichConfigurationStore.defaultURL()
        if fileManager.fileExists(atPath: appConfiguration.path) { sources.append(appConfiguration.path) }
        return sources.filter { fileManager.fileExists(atPath: $0) }
    }

    private func isServerContainerRunning() async throws -> Bool {
        if let injectedServerController { return (await injectedServerController.status()).isRunning }
        let result = try await commandRunner.run(
            dockerCommand(arguments: ["inspect", "--format", "{{.State.Running}}", "immich_server"]),
            timeout: 20
        )
        guard result.succeeded else {
            throw BackupError.backupFailed("Could not inspect immich_server: \(result.conciseFailureMessage)")
        }
        switch result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "true": return true
        case "false": return false
        default:
            throw BackupError.backupFailed("Docker returned an invalid immich_server state.")
        }
    }

    private func stopServerWhileLocked() async throws {
        if let injectedServerController {
            _ = try await injectedServerController.stop()
            return
        }
        let result = try await commandRunner.run(dockerCommand(arguments: ["stop", "immich_server"]), timeout: 120)
        guard result.succeeded else {
            throw BackupError.backupFailed("Stopping immich_server failed: \(result.conciseFailureMessage)")
        }
    }

    private func startServerWhileLocked() async throws {
        if let injectedServerController {
            _ = try await injectedServerController.start()
            return
        }
        let result = try await commandRunner.run(dockerCommand(arguments: ["start", "immich_server"]), timeout: 120)
        guard result.succeeded else { throw BackupError.restartFailed(result.conciseFailureMessage) }
    }

    private func restoreServerAfterBackup() async throws {
        if Task.isCancelled {
            // SIGINT/SIGTERM cancel the helper task. Cleanup must run from an
            // uncancelled context or ProcessCommandRunner immediately cancels it.
            try await Task.detached { [self] in try await startServerWhileLocked() }.value
        } else {
            try await startServerWhileLocked()
        }
    }

    private func dockerCommand(arguments: [String]) -> Command {
        Command(
            executable: configuration.server.toolPaths.dockerURL,
            arguments: ["--context", "colima"] + arguments,
            currentDirectoryURL: configuration.server.projectRootURL,
            clearedEnvironmentKeys: ["DOCKER_HOST", "DOCKER_CONTEXT"]
        )
    }

    private func throwIfCancelled() throws {
        if Task.isCancelled { throw CancellationError() }
    }

    private func result(targetID: UUID, outcome: BackupOutcome, message: String, startedAt: Date) -> BackupExecutionResult {
        let finishedAt = clock.now()
        do {
            _ = try statusStore.record(
                targetID: targetID,
                outcome: outcome,
                message: message,
                startedAt: startedAt,
                finishedAt: finishedAt
            )
        } catch {
            return BackupExecutionResult(
                targetID: targetID,
                outcome: .error,
                message: "\(message) Backup status could not be saved: \(error.localizedDescription)",
                startedAt: startedAt,
                finishedAt: finishedAt
            )
        }
        return BackupExecutionResult(
            targetID: targetID,
            outcome: outcome,
            message: message,
            startedAt: startedAt,
            finishedAt: finishedAt
        )
    }
}

private enum USBPreflight {
    case notApplicable
    case ready
    case skipped(String)
    case failed(String)
}
