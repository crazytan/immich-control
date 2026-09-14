import Foundation
import XCTest
@testable import ImmichCore

final class ConfigurationStoreTests: XCTestCase {
    private var fixtureRoot: URL!

    override func setUpWithError() throws {
        fixtureRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("immich-control-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let fixtureRoot {
            try? FileManager.default.removeItem(at: fixtureRoot)
        }
        fixtureRoot = nil
    }

    func testStoreRoundTripsValidConfigurationWithoutPersistingSecrets() throws {
        let projectRoot = try makeProjectRoot()
        var configuration = ImmichConfiguration.default(projectRoot: projectRoot)
        configuration.backups[0].enabled = true
        configuration.backups[0].repository = "s3:https://example.invalid/immich/restic"
        configuration.backups[1].enabled = true
        configuration.backups[1].usbVolumeUUID = "test-volume-uuid"

        let fileURL = fixtureRoot.appendingPathComponent("settings/Configuration.json")
        let store = ImmichConfigurationStore(fileURL: fileURL, installationRoot: projectRoot)
        try store.save(configuration)

        let serialized = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertFalse(serialized.contains("RESTIC_PASSWORD"))
        XCTAssertFalse(serialized.contains("AWS_SECRET_ACCESS_KEY"))
        XCTAssertFalse(serialized.contains("DB_PASSWORD"))
        XCTAssertFalse(serialized.contains(".env"))
        XCTAssertEqual(try store.load(), configuration)
    }

    func testInvalidUpdateDoesNotOverwriteLastKnownGoodConfiguration() throws {
        let projectRoot = try makeProjectRoot()
        let fileURL = fixtureRoot.appendingPathComponent("settings/Configuration.json")
        let store = ImmichConfigurationStore(fileURL: fileURL, installationRoot: projectRoot)
        let original = ImmichConfiguration.default(projectRoot: projectRoot)
        try store.save(original)

        XCTAssertThrowsError(try store.update { configuration in
            configuration.server.projectName = "contains a space"
        }) { error in
            XCTAssertEqual(error as? ConfigurationError, .invalidProjectName("contains a space"))
        }

        XCTAssertEqual(try store.load(), original)
    }

    func testConfigurationRejectsComposeFileOutsideProjectRoot() throws {
        let projectRoot = try makeProjectRoot()
        let unrelatedRoot = fixtureRoot.appendingPathComponent("unrelated", isDirectory: true)
        try FileManager.default.createDirectory(at: unrelatedRoot, withIntermediateDirectories: true)
        let unrelatedCompose = unrelatedRoot.appendingPathComponent("docker-compose.yml")
        try Data("services: {}\n".utf8).write(to: unrelatedCompose)

        let server = ServerSettings(projectRootURL: projectRoot, composeFileURL: unrelatedCompose)
        let configuration = ImmichConfiguration(server: server, backups: [])

        XCTAssertThrowsError(try configuration.validate()) { error in
            XCTAssertEqual(error as? ConfigurationError, .invalidComposeFile(unrelatedCompose.path))
        }
    }

    func testLegacyImportDoesNotReadOrCopyDotEnvSecrets() throws {
        let projectRoot = try makeProjectRoot()
        let envURL = projectRoot.appendingPathComponent(".env")
        try Data("DB_PASSWORD=definitely-not-in-settings\n".utf8).write(to: envURL)

        let imported = try LegacyConfigurationImporter.importConfiguration(from: projectRoot)
        let encoded = try JSONEncoder().encode(imported)
        let serialized = String(decoding: encoded, as: UTF8.self)

        XCTAssertFalse(serialized.contains("definitely-not-in-settings"))
        XCTAssertFalse(serialized.contains("DB_PASSWORD"))
    }

    func testLegacyImportPreservesLaunchAgentScheduleWithoutLoadingIt() throws {
        let projectRoot = try makeProjectRoot()
        let legacyAgent = projectRoot.appendingPathComponent("com.tan.immich-r2-backup.plist")
        let plist: [String: Any] = [
            "Label": "com.tan.immich-r2-backup",
            "StartCalendarInterval": [
                ["Hour": 4, "Minute": 20, "Weekday": 0],
                ["Hour": 4, "Minute": 20, "Weekday": 3],
            ],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: legacyAgent)

        let imported = try LegacyConfigurationImporter.importConfiguration(from: projectRoot)
        let r2 = try XCTUnwrap(imported.backups.first(where: { $0.kind == .r2 }))

        XCTAssertEqual(r2.schedule, BackupSchedule(hour: 4, minute: 20, weekdays: [1, 4]))
        XCTAssertEqual(try Data(contentsOf: legacyAgent), data)
    }

    func testConfigurationRejectsTwoTargetsForSameDestinationKind() throws {
        let projectRoot = try makeProjectRoot()
        let first = r2Target()
        let second = r2Target()
        let configuration = ImmichConfiguration(
            server: ServerSettings(projectRootURL: projectRoot),
            backups: [first, second]
        )

        XCTAssertThrowsError(try configuration.validate()) { error in
            XCTAssertEqual(error as? ConfigurationError, .duplicateBackupTargetKind)
        }
    }

    func testEnabledR2TargetRejectsCredentialBearingRepositoryURL() {
        let target = r2Target(repository: "s3:https://access-key:secret@example.invalid/immich/restic")

        XCTAssertThrowsError(try target.validate()) { error in
            XCTAssertEqual(error as? ConfigurationError, .invalidBackupRepository(target.id))
        }
    }

    func testEnabledUSBTargetRejectsRepositoryEscapingConfiguredMount() {
        let target = BackupTargetConfiguration(
            kind: .usb,
            displayName: "USB",
            enabled: true,
            schedule: BackupSchedule(hour: 5, minute: 15),
            retention: .standard,
            repository: "/Volumes/MediaUSB/../../tmp/not-a-backup-repository",
            tag: "immich-usb",
            keychainService: "immich-backup",
            usbMountPath: "/Volumes/MediaUSB",
            usbVolumeUUID: "expected-volume"
        )

        XCTAssertThrowsError(try target.validate()) { error in
            XCTAssertEqual(error as? ConfigurationError, .invalidUSBTarget(target.id))
        }
    }

    func testRetentionCannotDiscardEveryBackupImmediately() {
        let target = r2Target()
        var unsafeTarget = target
        unsafeTarget.retention = RetentionPolicy(keepDaily: 0, keepWeekly: 0, keepMonthly: 0, keepYearly: 0)

        XCTAssertThrowsError(try unsafeTarget.validate()) { error in
            XCTAssertEqual(error as? ConfigurationError, .invalidRetentionPolicy)
        }
    }

    private func makeProjectRoot() throws -> URL {
        let root = fixtureRoot.appendingPathComponent("project-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("services: {}\n".utf8).write(to: root.appendingPathComponent("docker-compose.yml"))
        return root
    }

    private func r2Target(repository: String = "s3:https://example.invalid/immich/restic") -> BackupTargetConfiguration {
        BackupTargetConfiguration(
            kind: .r2,
            displayName: "Cloud",
            enabled: true,
            schedule: BackupSchedule(hour: 3, minute: 15),
            retention: .standard,
            repository: repository,
            tag: "immich-r2",
            keychainService: "immich-backup"
        )
    }
}
