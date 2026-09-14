import Foundation
import XCTest
@testable import ImmichCore

final class BackupCoordinatorTests: XCTestCase {
    private var fixtureRoot: URL!
    private var projectRoot: URL!
    private var statusStore: StatusStore!

    override func setUpWithError() throws {
        fixtureRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("immich-backup-coordinator-tests-\(UUID().uuidString)", isDirectory: true)
        projectRoot = fixtureRoot.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(
            at: projectRoot.appendingPathComponent("library/backups", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("services: {}\n".utf8).write(to: projectRoot.appendingPathComponent("docker-compose.yml"))
        try Data("DB_DATABASE_NAME=immich\nDB_USERNAME=postgres\n".utf8).write(to: projectRoot.appendingPathComponent(".env"))
        statusStore = StatusStore(fileURL: fixtureRoot.appendingPathComponent("status.json"))
    }

    override func tearDownWithError() throws {
        if let fixtureRoot {
            try? FileManager.default.removeItem(at: fixtureRoot)
        }
        fixtureRoot = nil
        projectRoot = nil
        statusStore = nil
    }

    func testMissingUSBIsSkippedBeforeAnyDockerOrResticCommandAndKeepsLastSuccess() async throws {
        let target = usbTarget()
        let successfulAt = Date(timeIntervalSinceReferenceDate: 500)
        _ = try statusStore.record(
            targetID: target.id,
            outcome: .success,
            message: "Prior USB snapshot",
            startedAt: successfulAt.addingTimeInterval(-2),
            finishedAt: successfulAt
        )
        let runner = BackupRunner(runResults: [], pipelineResult: .success())
        let server = BackupServer(status: .running)
        let coordinator = makeCoordinator(
            target: target,
            runner: runner,
            server: server,
            usb: FixtureUSBInspector(state: .unavailable)
        )

        let result = await coordinator.run(target: target)

        XCTAssertEqual(result.outcome, .skipped)
        XCTAssertTrue(result.message.localizedCaseInsensitiveContains("not connected"))
        let commands = await runner.commands()
        let pipelines = await runner.pipelines()
        let serverEvents = await server.events()
        XCTAssertTrue(commands.isEmpty)
        XCTAssertTrue(pipelines.isEmpty)
        XCTAssertTrue(serverEvents.isEmpty)
        let persisted = try XCTUnwrap(statusStore.status(for: target.id))
        XCTAssertEqual(persisted.outcome, .skipped)
        XCTAssertEqual(persisted.lastSuccessAt, successfulAt)
        XCTAssertEqual(persisted.lastSuccessMessage, "Prior USB snapshot")
    }

    func testResticFailureRestartsServerAndDoesNotReplaceLastSuccessStatus() async throws {
        let target = r2Target()
        let priorSuccess = Date(timeIntervalSinceReferenceDate: 1_000)
        _ = try statusStore.record(
            targetID: target.id,
            outcome: .success,
            message: "Prior cloud snapshot",
            startedAt: priorSuccess.addingTimeInterval(-5),
            finishedAt: priorSuccess
        )
        let runner = BackupRunner(
            runResults: [.failure(error: "repository is unavailable")],
            pipelineResult: .success(),
            pipelineOutput: Data("fresh compressed dump".utf8)
        )
        let server = BackupServer(status: .running)
        let coordinator = makeCoordinator(target: target, runner: runner, server: server)

        let result = await coordinator.run(target: target)

        XCTAssertEqual(result.outcome, .error)
        XCTAssertTrue(result.message.contains("repository is unavailable"))
        let serverEvents = await server.events()
        XCTAssertEqual(serverEvents, ["status", "stop", "start"])
        let persisted = try XCTUnwrap(statusStore.status(for: target.id))
        XCTAssertEqual(persisted.outcome, .error)
        XCTAssertEqual(persisted.lastSuccessAt, priorSuccess)
        XCTAssertEqual(persisted.lastSuccessMessage, "Prior cloud snapshot")
        let latestDump = projectRoot.appendingPathComponent("library/backups/restic-latest.sql.gz")
        XCTAssertEqual(try Data(contentsOf: latestDump), Data("fresh compressed dump".utf8))

        let commands = await runner.commands()
        let resticCommand = try XCTUnwrap(commands.first(where: { $0.arguments.contains("backup") }))
        XCTAssertTrue(resticCommand.arguments.contains("--json"))
        XCTAssertEqual(resticCommand.environment["RESTIC_REPOSITORY"], target.repository)
        XCTAssertFalse(resticCommand.redactedDescription.contains("fixture-restic-password"))
    }

    func testFailedDumpPreservesPreviousDumpAndStillRestartsServer() async throws {
        let target = r2Target()
        let latestDump = projectRoot.appendingPathComponent("library/backups/restic-latest.sql.gz")
        let previousDump = Data("last known good dump".utf8)
        try previousDump.write(to: latestDump)
        let runner = BackupRunner(
            runResults: [],
            pipelineResult: .failure(error: "pg_dump exited 1")
        )
        let server = BackupServer(status: .running)
        let coordinator = makeCoordinator(target: target, runner: runner, server: server)

        let result = await coordinator.run(target: target)

        XCTAssertEqual(result.outcome, .error)
        XCTAssertTrue(result.message.contains("pg_dump exited 1"))
        XCTAssertEqual(try Data(contentsOf: latestDump), previousDump)
        let serverEvents = await server.events()
        XCTAssertEqual(serverEvents, ["status", "stop", "start"])
        let pipelines = await runner.pipelines()
        let pipeline = try XCTUnwrap(pipelines.first)
        XCTAssertNotEqual(pipeline.standardOutputFileURL, latestDump)
        XCTAssertTrue(pipeline.standardOutputFileURL.lastPathComponent.hasPrefix("restic-"))
        XCTAssertTrue(pipeline.standardOutputFileURL.lastPathComponent.hasSuffix(".partial"))
        let commands = await runner.commands()
        XCTAssertTrue(commands.isEmpty)
    }

    func testProductionBackupStopsOnlyImmichContainerAndKeepsPostgresAvailableForDump() async throws {
        let target = r2Target()
        let runner = BackupRunner(
            runResults: [
                .success(output: "true\n"), // inspect immich_server
                .success(), // stop immich_server
                .success(), // Restic backup
                .success(), // start immich_server
            ],
            pipelineResult: .success(),
            pipelineOutput: Data("fresh dump".utf8)
        )
        let coordinator = BackupCoordinator(
            configuration: configuration(backups: [target]),
            commandRunner: runner,
            statusStore: statusStore,
            operationLock: OperationLock(lockDirectoryURL: fixtureRoot.appendingPathComponent("locks")),
            activityStore: BackupActivityStore(fileURL: fixtureRoot.appendingPathComponent("activity.json")),
            recoveryStore: BackupRecoveryStore(fileURL: fixtureRoot.appendingPathComponent("recovery.json")),
            keychain: FixtureKeychain(),
            clock: FixtureClock(now: Date(timeIntervalSinceReferenceDate: 2_000), weekday: 2)
        )

        let result = await coordinator.run(target: target)

        XCTAssertEqual(result.outcome, .success)
        let commands = await runner.commands()
        XCTAssertEqual(commands[0].arguments, ["--context", "colima", "inspect", "--format", "{{.State.Running}}", "immich_server"])
        XCTAssertEqual(commands[1].arguments, ["--context", "colima", "stop", "immich_server"])
        XCTAssertTrue(commands[2].arguments.contains("backup"))
        XCTAssertEqual(commands[3].arguments, ["--context", "colima", "start", "immich_server"])
        XCTAssertFalse(commands.flatMap(\.arguments).contains("compose"))
        XCTAssertFalse(commands.flatMap(\.arguments).contains("down"))
        XCTAssertTrue(commands[1].clearedEnvironmentKeys.contains("DOCKER_HOST"))
        XCTAssertTrue(commands[1].clearedEnvironmentKeys.contains("DOCKER_CONTEXT"))
        let pipelines = await runner.pipelines()
        let dumpCommand = try XCTUnwrap(pipelines.first?.commands.first)
        XCTAssertEqual(dumpCommand.arguments.prefix(5), ["--context", "colima", "exec", "immich_postgres", "pg_dump"])
    }

    func testCancellationAfterContainerStopStillRestartsContainer() async throws {
        let target = r2Target()
        let runner = BackupRunner(
            runResults: [.success(output: "true\n"), .success(), .success()],
            pipelineResult: .success(),
            pipelineOutput: Data("fresh dump".utf8),
            cancelBackupCommand: true
        )
        let coordinator = BackupCoordinator(
            configuration: configuration(backups: [target]),
            commandRunner: runner,
            statusStore: statusStore,
            operationLock: OperationLock(lockDirectoryURL: fixtureRoot.appendingPathComponent("locks")),
            activityStore: BackupActivityStore(fileURL: fixtureRoot.appendingPathComponent("activity.json")),
            recoveryStore: BackupRecoveryStore(fileURL: fixtureRoot.appendingPathComponent("recovery.json")),
            keychain: FixtureKeychain(),
            clock: FixtureClock(now: Date(timeIntervalSinceReferenceDate: 2_000), weekday: 2)
        )

        let result = await coordinator.run(target: target)

        XCTAssertEqual(result.outcome, .error)
        XCTAssertTrue(result.message.localizedCaseInsensitiveContains("cancelled"))
        let commands = await runner.commands()
        XCTAssertEqual(commands.last?.arguments, ["--context", "colima", "start", "immich_server"])
        XCTAssertNil(try BackupRecoveryStore(fileURL: fixtureRoot.appendingPathComponent("recovery.json")).pendingRecovery())
    }

    func testInspectFailureFailsClosedBeforeCreatingSnapshot() async throws {
        let target = r2Target()
        let runner = BackupRunner(
            runResults: [.failure(error: "Docker daemon unavailable")],
            pipelineResult: .success()
        )
        let coordinator = makeProductionCoordinator(target: target, runner: runner)

        let result = await coordinator.run(target: target)

        XCTAssertEqual(result.outcome, .error)
        XCTAssertTrue(result.message.contains("Could not inspect immich_server"))
        let commands = await runner.commands()
        XCTAssertEqual(commands.map(\.arguments), [["--context", "colima", "inspect", "--format", "{{.State.Running}}", "immich_server"]])
        let pipelines = await runner.pipelines()
        XCTAssertTrue(pipelines.isEmpty)
    }

    func testFailedContainerStopStillAttemptsRestartBeforeReportingFailure() async throws {
        let target = r2Target()
        let runner = BackupRunner(
            runResults: [
                .success(output: "true\n"),
                .failure(error: "stop rejected"),
                .success(),
            ],
            pipelineResult: .success()
        )
        let coordinator = makeProductionCoordinator(target: target, runner: runner)

        let result = await coordinator.run(target: target)

        XCTAssertEqual(result.outcome, .error)
        XCTAssertTrue(result.message.contains("Stopping immich_server failed"))
        let commands = await runner.commands()
        XCTAssertEqual(commands.map(\.arguments), [
            ["--context", "colima", "inspect", "--format", "{{.State.Running}}", "immich_server"],
            ["--context", "colima", "stop", "immich_server"],
            ["--context", "colima", "start", "immich_server"],
        ])
        let pipelines = await runner.pipelines()
        XCTAssertTrue(pipelines.isEmpty)
    }

    func testActivityWriteFailureAfterStopStillRestartsContainer() async throws {
        let target = r2Target()
        let activityURL = fixtureRoot.appendingPathComponent("activity-that-will-fail.json")
        let runner = BackupRunner(
            runResults: [.success(output: "true\n"), .success(), .success()],
            pipelineResult: .success(),
            corruptActivityFileOnStop: activityURL
        )
        let coordinator = BackupCoordinator(
            configuration: configuration(backups: [target]),
            commandRunner: runner,
            statusStore: statusStore,
            operationLock: OperationLock(lockDirectoryURL: fixtureRoot.appendingPathComponent("activity-failure-locks")),
            activityStore: BackupActivityStore(fileURL: activityURL),
            recoveryStore: BackupRecoveryStore(fileURL: fixtureRoot.appendingPathComponent("activity-failure-recovery.json")),
            keychain: FixtureKeychain(),
            clock: FixtureClock(now: Date(timeIntervalSinceReferenceDate: 2_000), weekday: 2)
        )

        let result = await coordinator.run(target: target)

        XCTAssertEqual(result.outcome, .error)
        let commands = await runner.commands()
        XCTAssertEqual(commands.map(\.arguments), [
            ["--context", "colima", "inspect", "--format", "{{.State.Running}}", "immich_server"],
            ["--context", "colima", "stop", "immich_server"],
            ["--context", "colima", "start", "immich_server"],
        ])
        XCTAssertFalse(FileManager.default.fileExists(atPath: activityURL.path))
    }

    func testStatusWriteFailureReturnsErrorInsteadOfClaimingBackupWasSkipped() async throws {
        let blockedParent = fixtureRoot.appendingPathComponent("not-a-directory")
        try Data("blocks status directory".utf8).write(to: blockedParent)
        let failingStore = StatusStore(fileURL: blockedParent.appendingPathComponent("BackupStatus.json"))
        var disabled = r2Target()
        disabled.enabled = false
        let runner = BackupRunner(runResults: [], pipelineResult: .success())
        let coordinator = BackupCoordinator(
            configuration: configuration(backups: [disabled]),
            commandRunner: runner,
            statusStore: failingStore,
            operationLock: OperationLock(lockDirectoryURL: fixtureRoot.appendingPathComponent("status-failure-locks")),
            activityStore: BackupActivityStore(fileURL: fixtureRoot.appendingPathComponent("status-failure-activity.json")),
            recoveryStore: BackupRecoveryStore(fileURL: fixtureRoot.appendingPathComponent("status-failure-recovery.json")),
            keychain: FixtureKeychain(),
            clock: FixtureClock(now: Date(timeIntervalSinceReferenceDate: 2_000), weekday: 2)
        )

        let result = await coordinator.run(target: disabled)

        XCTAssertEqual(result.outcome, .error)
        XCTAssertTrue(result.message.contains("Backup status could not be saved"))
        let commands = await runner.commands()
        XCTAssertTrue(commands.isEmpty)
    }

    private func makeCoordinator(
        target: BackupTargetConfiguration,
        runner: BackupRunner,
        server: BackupServer,
        usb: FixtureUSBInspector = FixtureUSBInspector(state: .ready)
    ) -> BackupCoordinator {
        let clock = FixtureClock(now: Date(timeIntervalSinceReferenceDate: 2_000), weekday: 2)
        return BackupCoordinator(
            configuration: configuration(backups: [target]),
            commandRunner: runner,
            serverController: server,
            statusStore: statusStore,
            operationLock: OperationLock(lockDirectoryURL: fixtureRoot.appendingPathComponent("locks")),
            activityStore: BackupActivityStore(fileURL: fixtureRoot.appendingPathComponent("activity.json")),
            recoveryStore: BackupRecoveryStore(fileURL: fixtureRoot.appendingPathComponent("recovery.json")),
            keychain: FixtureKeychain(),
            usbInspector: usb,
            clock: clock
        )
    }

    private func makeProductionCoordinator(target: BackupTargetConfiguration, runner: BackupRunner) -> BackupCoordinator {
        BackupCoordinator(
            configuration: configuration(backups: [target]),
            commandRunner: runner,
            statusStore: statusStore,
            operationLock: OperationLock(lockDirectoryURL: fixtureRoot.appendingPathComponent("production-locks")),
            activityStore: BackupActivityStore(fileURL: fixtureRoot.appendingPathComponent("production-activity.json")),
            recoveryStore: BackupRecoveryStore(fileURL: fixtureRoot.appendingPathComponent("production-recovery.json")),
            keychain: FixtureKeychain(),
            clock: FixtureClock(now: Date(timeIntervalSinceReferenceDate: 2_000), weekday: 2)
        )
    }

    private func configuration(backups: [BackupTargetConfiguration]) -> ImmichConfiguration {
        ImmichConfiguration(
            server: ServerSettings(
                projectRootURL: projectRoot,
                projectName: "immich-test",
                toolPaths: ToolPaths(colimaPath: "/usr/bin/true", dockerPath: "/usr/bin/true", resticPath: "/usr/bin/true")
            ),
            backups: backups
        )
    }

    private func r2Target() -> BackupTargetConfiguration {
        BackupTargetConfiguration(
            kind: .r2,
            displayName: "Cloud R2",
            enabled: true,
            schedule: BackupSchedule(hour: 3, minute: 15),
            retention: .standard,
            repository: "s3:https://example.invalid/immich/restic",
            tag: "immich-r2",
            keychainService: "immich-backup"
        )
    }

    private func usbTarget() -> BackupTargetConfiguration {
        BackupTargetConfiguration(
            kind: .usb,
            displayName: "USB",
            enabled: true,
            schedule: BackupSchedule(hour: 5, minute: 15),
            retention: .standard,
            repository: "/Volumes/MediaUSB/ImmichBackup/restic",
            tag: "immich-usb",
            keychainService: "immich-backup",
            usbMountPath: "/Volumes/MediaUSB",
            usbVolumeUUID: "expected-volume"
        )
    }
}

private actor BackupRunner: CommandPipelining {
    private var runResults: [CommandResult]
    private let pipelineResult: PipelineCommandResult
    private let pipelineOutput: Data?
    private let cancelBackupCommand: Bool
    private let corruptActivityFileOnStop: URL?
    private var recordedCommands: [Command] = []
    private var recordedPipelines: [CommandPipeline] = []

    init(
        runResults: [CommandResult],
        pipelineResult: PipelineCommandResult,
        pipelineOutput: Data? = nil,
        cancelBackupCommand: Bool = false,
        corruptActivityFileOnStop: URL? = nil
    ) {
        self.runResults = runResults
        self.pipelineResult = pipelineResult
        self.pipelineOutput = pipelineOutput
        self.cancelBackupCommand = cancelBackupCommand
        self.corruptActivityFileOnStop = corruptActivityFileOnStop
    }

    func run(_ command: Command, timeout: TimeInterval?) async throws -> CommandResult {
        recordedCommands.append(command)
        if cancelBackupCommand, command.arguments.contains("backup") {
            throw CancellationError()
        }
        if command.arguments.contains("stop"), let corruptActivityFileOnStop {
            try? FileManager.default.removeItem(at: corruptActivityFileOnStop)
            try? FileManager.default.createDirectory(at: corruptActivityFileOnStop, withIntermediateDirectories: true)
        }
        guard !runResults.isEmpty else {
            throw NSError(domain: "BackupCoordinatorTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unexpected command: \(command.redactedDescription)"])
        }
        return runResults.removeFirst()
    }

    func runPipeline(_ pipeline: CommandPipeline, timeout: TimeInterval?) async throws -> PipelineCommandResult {
        recordedPipelines.append(pipeline)
        if let pipelineOutput {
            try FileManager.default.createDirectory(at: pipeline.standardOutputFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try pipelineOutput.write(to: pipeline.standardOutputFileURL)
        }
        return pipelineResult
    }

    func commands() -> [Command] { recordedCommands }
    func pipelines() -> [CommandPipeline] { recordedPipelines }
}

private actor BackupServer: ServerControlling {
    private let currentStatus: ServerStatus
    private var recordedEvents: [String] = []

    init(status: ServerStatus) {
        currentStatus = status
    }

    func status() async -> ServerStatus {
        recordedEvents.append("status")
        return currentStatus
    }

    func start() async throws -> ServerStatus {
        recordedEvents.append("start")
        return .running
    }

    func stop() async throws -> ServerStatus {
        recordedEvents.append("stop")
        return .stopped
    }

    func events() -> [String] { recordedEvents }
}

private struct FixtureUSBInspector: USBInspecting {
    let state: USBVolumeState
    func inspect(mountPath: URL, expectedVolumeUUID: String) -> USBVolumeState { state }
}

private struct FixtureClock: BackupClock {
    let instant: Date
    let weekdayValue: Int

    init(now: Date, weekday: Int) {
        instant = now
        weekdayValue = weekday
    }

    func now() -> Date { instant }
    func weekday(at date: Date) -> Int { weekdayValue }
}

private struct FixtureKeychain: SecretStoring {
    func read(service: String, account: String) throws -> String {
        switch service {
        case BackupSecret.resticPassword.rawValue: return "fixture-restic-password"
        case BackupSecret.r2AccessKeyID.rawValue: return "fixture-access-key"
        case BackupSecret.r2SecretAccessKey.rawValue: return "fixture-secret-key"
        default: throw KeychainStoreError.itemNotFound(service: service, account: account)
        }
    }

    func write(_ value: String, service: String, account: String) throws {}
    func delete(service: String, account: String) throws {}
}

private extension CommandResult {
    static func success(output: String = "") -> CommandResult {
        CommandResult(exitCode: 0, standardOutput: output, standardError: "", timedOut: false, duration: 0)
    }

    static func failure(error: String) -> CommandResult {
        CommandResult(exitCode: 1, standardOutput: "", standardError: error, timedOut: false, duration: 0)
    }
}

private extension PipelineCommandResult {
    static func success() -> PipelineCommandResult {
        PipelineCommandResult(
            commandResults: [
                CommandResult(exitCode: 0, standardOutput: "", standardError: "", timedOut: false, duration: 0),
                CommandResult(exitCode: 0, standardOutput: "", standardError: "", timedOut: false, duration: 0),
            ],
            timedOut: false,
            duration: 0
        )
    }

    static func failure(error: String) -> PipelineCommandResult {
        PipelineCommandResult(
            commandResults: [
                CommandResult(exitCode: 1, standardOutput: "", standardError: error, timedOut: false, duration: 0),
                CommandResult(exitCode: 0, standardOutput: "", standardError: "", timedOut: false, duration: 0),
            ],
            timedOut: false,
            duration: 0
        )
    }
}
