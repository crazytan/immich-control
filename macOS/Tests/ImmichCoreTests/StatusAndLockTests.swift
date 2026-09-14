import Foundation
import XCTest
@testable import ImmichCore

final class StatusAndLockTests: XCTestCase {
    private var fixtureRoot: URL!

    override func setUpWithError() throws {
        fixtureRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("immich-status-lock-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let fixtureRoot {
            try? FileManager.default.removeItem(at: fixtureRoot)
        }
        fixtureRoot = nil
    }

    func testSkippedAndFailedRunsPreserveLastSuccessfulBackup() throws {
        let store = StatusStore(fileURL: fixtureRoot.appendingPathComponent("status.json"))
        let targetID = UUID()
        let successfulAt = Date(timeIntervalSinceReferenceDate: 10_000)
        let skippedAt = successfulAt.addingTimeInterval(60)
        let failedAt = skippedAt.addingTimeInterval(60)

        _ = try store.record(
            targetID: targetID,
            outcome: .success,
            message: "Uploaded snapshot",
            startedAt: successfulAt.addingTimeInterval(-5),
            finishedAt: successfulAt
        )
        _ = try store.record(
            targetID: targetID,
            outcome: .skipped,
            message: "USB volume is unavailable",
            startedAt: skippedAt.addingTimeInterval(-5),
            finishedAt: skippedAt
        )
        let failed = try store.record(
            targetID: targetID,
            outcome: .error,
            message: "Restic exited 1",
            startedAt: failedAt.addingTimeInterval(-5),
            finishedAt: failedAt
        )

        XCTAssertEqual(failed.outcome, .error)
        XCTAssertEqual(failed.message, "Restic exited 1")
        XCTAssertEqual(failed.lastSuccessAt, successfulAt)
        XCTAssertEqual(failed.lastSuccessMessage, "Uploaded snapshot")
        XCTAssertEqual(try store.status(for: targetID), failed)
    }

    func testInitialSkipDoesNotPretendBackupEverSucceeded() throws {
        let store = StatusStore(fileURL: fixtureRoot.appendingPathComponent("status.json"))
        let skipped = try store.record(targetID: UUID(), outcome: .skipped, message: "USB unavailable")

        XCTAssertEqual(skipped.outcome, .skipped)
        XCTAssertNil(skipped.lastSuccessAt)
        XCTAssertNil(skipped.lastSuccessMessage)
    }

    func testLegacyLogMigrationRejectsPriorSuccessWhenFinalEventIsFailure() throws {
        let logs = fixtureRoot.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let log = """
        2026-01-01 03:15:00 Immich R2 backup completed
        2026-01-02 03:15:00 Restic failed: repository unavailable
        """
        try Data(log.utf8).write(to: logs.appendingPathComponent("immich-r2-backup.log"))
        let store = StatusStore(
            fileURL: fixtureRoot.appendingPathComponent("status.json"),
            legacyLogsDirectoryURL: logs
        )

        XCTAssertNil(try store.status(for: StatusStore.r2TargetID))
    }

    func testSeparateStoreInstancesDoNotLoseConcurrentStatusRecords() throws {
        let fileURL = fixtureRoot.appendingPathComponent("shared-status.json")
        let first = StatusStore(fileURL: fileURL)
        let second = StatusStore(fileURL: fileURL)
        let identifiers = (0..<30).map { _ in UUID() }
        let errorLock = NSLock()
        var errors: [Error] = []

        DispatchQueue.concurrentPerform(iterations: identifiers.count) { index in
            do {
                let store = index.isMultiple(of: 2) ? first : second
                _ = try store.record(targetID: identifiers[index], outcome: .success, message: "snapshot \(index)")
            } catch {
                errorLock.lock()
                errors.append(error)
                errorLock.unlock()
            }
        }

        XCTAssertTrue(errors.isEmpty, "Unexpected concurrent write errors: \(errors)")
        XCTAssertEqual(try first.allStatuses().map(\.targetID).sorted { $0.uuidString < $1.uuidString }, identifiers.sorted { $0.uuidString < $1.uuidString })
    }

    func testOperationLockExcludesAnotherProcessAndReleasesAfterScope() async throws {
        let lockDirectory = fixtureRoot.appendingPathComponent("locks", isDirectory: true)
        try FileManager.default.createDirectory(at: lockDirectory, withIntermediateDirectories: true)
        let lockFile = lockDirectory.appendingPathComponent("backup.lock")
        let holder = try launchExternalLockHolder(for: lockFile)
        defer {
            if holder.isRunning { holder.terminate() }
            holder.waitUntilExit()
        }

        let lock = OperationLock(lockDirectoryURL: lockDirectory)
        do {
            _ = try await lock.acquire(name: "backup", timeout: 0.1)
            XCTFail("Expected another process's advisory lock to win")
        } catch let error as OperationLock.Error {
            XCTAssertEqual(error, .timedOut("backup"))
        }

        holder.waitUntilExit()
        let handle = try await lock.acquire(name: "backup", timeout: 0.5)
        handle.release()

        let value = try await lock.withLock(name: "backup", timeout: 0.5) { "finished" }
        XCTAssertEqual(value, "finished")
    }

    private func launchExternalLockHolder(for lockFile: URL) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [
            "-e",
            "open my $lock, '>>', $ARGV[0] or die $!; flock($lock, 2) or die $!; print \"locked\\n\"; STDOUT->autoflush(1); sleep 1;",
            lockFile.path,
        ]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let ready = output.fileHandleForReading.availableData
        XCTAssertEqual(String(decoding: ready, as: UTF8.self), "locked\n")
        return process
    }
}
