import Foundation
import XCTest
@testable import ImmichCore

final class SchedulerTests: XCTestCase {
    private var fixtureRoot: URL!
    private var helperURL: URL!
    private var projectRoot: URL!

    override func setUpWithError() throws {
        fixtureRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("immich-scheduler-tests-\(UUID().uuidString)", isDirectory: true)
        projectRoot = fixtureRoot.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        try Data("services: {}\n".utf8).write(to: projectRoot.appendingPathComponent("docker-compose.yml"))
        helperURL = fixtureRoot.appendingPathComponent("immich-helper")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: helperURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helperURL.path)
    }

    override func tearDownWithError() throws {
        if let fixtureRoot {
            try? FileManager.default.removeItem(at: fixtureRoot)
        }
        fixtureRoot = nil
        helperURL = nil
        projectRoot = nil
    }

    func testSchedulerMapsCalendarSundayToLaunchdZeroAndOmitsSecrets() async throws {
        let runner = SchedulerRunner()
        let scheduler = makeScheduler(runner: runner)
        let target = r2Target(schedule: BackupSchedule(hour: 3, minute: 15, weekdays: [1, 2, 7]))

        try await scheduler.syncBackupSchedules(configuration: configuration(backups: [target]))

        let plist = try plistDictionary(at: scheduler.agentURL(for: .r2))
        let intervals = try XCTUnwrap(plist["StartCalendarInterval"] as? [[String: Int]])
        XCTAssertEqual(intervals.map { $0["Weekday"] }, [0, 1, 6])
        XCTAssertEqual(intervals.map { $0["Hour"] }, [3, 3, 3])
        XCTAssertEqual(intervals.map { $0["Minute"] }, [15, 15, 15])
        XCTAssertEqual(
            plist["ProgramArguments"] as? [String],
            [helperURL.path, "--root", projectRoot.path, "backup", "r2"]
        )
        let encoded = try Data(contentsOf: scheduler.agentURL(for: .r2))
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(text.contains("RESTIC_PASSWORD"))
        XCTAssertFalse(text.contains("s3:"))
        XCTAssertFalse(text.contains(".env"))
    }

    func testSchedulerAbortsWhenBootoutFailsInsteadOfInstallingDuplicateJob() async throws {
        let runner = SchedulerRunner(
            initiallyLoaded: [BackupScheduler.r2Label],
            failBootoutOnceFor: BackupScheduler.r2Label
        )
        let scheduler = makeScheduler(runner: runner)
        let target = r2Target()
        let agentURL = scheduler.agentURL(for: .r2)
        try FileManager.default.createDirectory(at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("previous r2 schedule".utf8)
        try original.write(to: agentURL)

        do {
            try await scheduler.syncBackupSchedules(configuration: configuration(backups: [target]))
            XCTFail("A failed bootout must abort schedule replacement")
        } catch let error as SchedulerError {
            guard case .launchdRejected = error else {
                return XCTFail("Unexpected scheduler error: \(error)")
            }
        }

        XCTAssertEqual(try Data(contentsOf: agentURL), original)
        let commands = await runner.commands()
        XCTAssertTrue(commands.contains(where: { $0.arguments.first == "bootout" }))
    }

    func testSchedulerRestoresBothExistingAgentsWhenSecondTargetBootstrapFails() async throws {
        let runner = SchedulerRunner(
            initiallyLoaded: [BackupScheduler.r2Label, BackupScheduler.usbLabel],
            failBootstrapOnceFor: BackupScheduler.usbLabel
        )
        let scheduler = makeScheduler(runner: runner)
        let r2URL = scheduler.agentURL(for: .r2)
        let usbURL = scheduler.agentURL(for: .usb)
        try FileManager.default.createDirectory(at: r2URL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let originalR2 = Data("legacy app r2 schedule".utf8)
        let originalUSB = Data("legacy app usb schedule".utf8)
        try originalR2.write(to: r2URL)
        try originalUSB.write(to: usbURL)

        do {
            try await scheduler.syncBackupSchedules(configuration: configuration(backups: [r2Target(), usbTarget()]))
            XCTFail("Expected second schedule bootstrap failure")
        } catch let error as SchedulerError {
            guard case .launchdRejected = error else {
                return XCTFail("Unexpected scheduler error: \(error)")
            }
        }

        XCTAssertEqual(try Data(contentsOf: r2URL), originalR2)
        XCTAssertEqual(try Data(contentsOf: usbURL), originalUSB)
    }

    func testLegacyMigrationRestoresOriginalAgentWhenNewScheduleFails() async throws {
        let runner = SchedulerRunner(
            initiallyLoaded: [BackupScheduler.legacyR2Label],
            failBootstrapOnceFor: BackupScheduler.r2Label
        )
        let scheduler = makeScheduler(runner: runner)
        let legacyURL = fixtureRoot
            .appendingPathComponent("agents", isDirectory: true)
            .appendingPathComponent("\(BackupScheduler.legacyR2Label).plist")
        try FileManager.default.createDirectory(at: legacyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("legacy shell schedule".utf8)
        try original.write(to: legacyURL)

        do {
            try await scheduler.migrateLegacySchedules(configuration: configuration(backups: [r2Target()]))
            XCTFail("Expected replacement launchd failure")
        } catch let error as SchedulerError {
            guard case .launchdRejected = error else {
                return XCTFail("Unexpected scheduler error: \(error)")
            }
        }

        XCTAssertEqual(try Data(contentsOf: legacyURL), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.appendingPathExtension("immich-control-disabled").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: scheduler.agentURL(for: .r2).path))
    }

    private func makeScheduler(runner: SchedulerRunner) -> BackupScheduler {
        BackupScheduler(
            helperURL: helperURL,
            launchAgentsDirectoryURL: fixtureRoot.appendingPathComponent("agents", isDirectory: true),
            logsDirectoryURL: fixtureRoot.appendingPathComponent("logs", isDirectory: true),
            commandRunner: runner
        )
    }

    private func configuration(backups: [BackupTargetConfiguration]) -> ImmichConfiguration {
        ImmichConfiguration(
            server: ServerSettings(
                projectRootURL: projectRoot,
                toolPaths: ToolPaths(colimaPath: "/usr/bin/true", dockerPath: "/usr/bin/true", resticPath: "/usr/bin/true")
            ),
            backups: backups
        )
    }

    private func r2Target(schedule: BackupSchedule = BackupSchedule(hour: 3, minute: 15)) -> BackupTargetConfiguration {
        BackupTargetConfiguration(
            kind: .r2,
            displayName: "R2",
            enabled: true,
            schedule: schedule,
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

    private func plistDictionary(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }
}

private actor SchedulerRunner: CommandRunning {
    private var loadedLabels: Set<String>
    private var failBootoutOnceFor: String?
    private var failBootstrapOnceFor: String?
    private var recordedCommands: [Command] = []

    init(
        initiallyLoaded: Set<String> = [],
        failBootoutOnceFor: String? = nil,
        failBootstrapOnceFor: String? = nil
    ) {
        loadedLabels = initiallyLoaded
        self.failBootoutOnceFor = failBootoutOnceFor
        self.failBootstrapOnceFor = failBootstrapOnceFor
    }

    func run(_ command: Command, timeout: TimeInterval?) async throws -> CommandResult {
        recordedCommands.append(command)
        guard let action = command.arguments.first else {
            throw NSError(domain: "SchedulerTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "launchctl call was missing an action"])
        }
        switch action {
        case "print":
            guard let label = command.arguments.last?.split(separator: "/").last.map(String.init) else {
                throw NSError(domain: "SchedulerTests", code: 1)
            }
            return loadedLabels.contains(label) ? .success() : .failure(error: "Could not find service")
        case "bootout":
            let label = labelFromPlistPath(command)
            if failBootoutOnceFor == label {
                failBootoutOnceFor = nil
                return .failure(error: "permission denied")
            }
            loadedLabels.remove(label)
            return .success()
        case "bootstrap":
            let label = labelFromPlistPath(command)
            if failBootstrapOnceFor == label {
                failBootstrapOnceFor = nil
                return .failure(error: "launchd rejected \(label)")
            }
            loadedLabels.insert(label)
            return .success()
        default:
            throw NSError(domain: "SchedulerTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unexpected launchctl action \(action)"])
        }
    }

    func commands() -> [Command] { recordedCommands }

    private func labelFromPlistPath(_ command: Command) -> String {
        URL(fileURLWithPath: command.arguments.last!).deletingPathExtension().lastPathComponent
    }
}

private extension CommandResult {
    static func success() -> CommandResult {
        CommandResult(exitCode: 0, standardOutput: "", standardError: "", timedOut: false, duration: 0)
    }

    static func failure(error: String) -> CommandResult {
        CommandResult(exitCode: 1, standardOutput: "", standardError: error, timedOut: false, duration: 0)
    }
}
