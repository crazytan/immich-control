import Foundation
import XCTest
@testable import ImmichCore

final class CommandRunnerTests: XCTestCase {
    private var fixtureRoot: URL!

    override func setUpWithError() throws {
        fixtureRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("immich-command-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let fixtureRoot {
            try? FileManager.default.removeItem(at: fixtureRoot)
        }
        fixtureRoot = nil
    }

    func testRunnerPassesShellSyntaxAsLiteralArgumentAndDoesNotExecuteIt() async throws {
        let sideEffectURL = fixtureRoot.appendingPathComponent("must-not-exist")
        let shellLookingArgument = "$(touch \(sideEffectURL.path)); echo unsafe"
        let command = Command(
            executable: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["%s", shellLookingArgument],
            currentDirectoryURL: fixtureRoot
        )

        let result = try await ProcessCommandRunner().run(command, timeout: 5)

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.standardOutput, shellLookingArgument)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sideEffectURL.path))
    }

    func testRunnerUsesExplicitWorkingDirectory() async throws {
        let sentinel = fixtureRoot.appendingPathComponent("cwd-sentinel")
        try Data("present".utf8).write(to: sentinel)
        let command = Command(
            executable: URL(fileURLWithPath: "/bin/pwd"),
            currentDirectoryURL: fixtureRoot
        )

        let result = try await ProcessCommandRunner().run(command, timeout: 5)

        XCTAssertTrue(result.succeeded)
        // `/bin/pwd` canonicalizes macOS's `/var` alias to `/private/var`, so
        // compare through a fixture sentinel instead of textual spellings.
        let reportedDirectory = URL(fileURLWithPath: result.standardOutput.trimmingCharacters(in: .newlines), isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: reportedDirectory.appendingPathComponent("cwd-sentinel").path))
    }

    func testDiagnosticDescriptionNeverIncludesEnvironmentSecrets() {
        let command = Command(
            executable: URL(fileURLWithPath: "/usr/bin/true"),
            arguments: ["--verify"],
            environment: ["RESTIC_PASSWORD": "super-secret-value"]
        )

        XCTAssertEqual(command.redactedDescription, "/usr/bin/true --verify")
        XCTAssertFalse(command.redactedDescription.contains("super-secret-value"))
        XCTAssertFalse(command.redactedDescription.contains("RESTIC_PASSWORD"))
    }

    func testRunnerStreamsOutputToRequestedFileAndTruncatesStaleContent() async throws {
        let outputURL = fixtureRoot.appendingPathComponent("dump.sql.gz.tmp")
        try Data("stale bytes which must not survive".utf8).write(to: outputURL)
        let command = Command(
            executable: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["%s", "fresh dump"],
            standardOutputFileURL: outputURL
        )

        let result = try await ProcessCommandRunner().run(command, timeout: 5)

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.standardOutput, "")
        XCTAssertEqual(try String(contentsOf: outputURL, encoding: .utf8), "fresh dump")
    }

    func testPipelineFailsWhenProducerFailsEvenIfGzipExitsSuccessfully() async throws {
        let outputURL = fixtureRoot.appendingPathComponent("failed-dump.sql.gz")
        let pipeline = CommandPipeline(
            commands: [
                Command(executable: URL(fileURLWithPath: "/usr/bin/false")),
                Command(executable: URL(fileURLWithPath: "/usr/bin/gzip")),
            ],
            standardOutputFileURL: outputURL
        )

        let result = try await ProcessCommandRunner().runPipeline(pipeline, timeout: 5)

        XCTAssertFalse(result.succeeded)
        XCTAssertFalse(result.commandResults[0].succeeded)
        XCTAssertTrue(result.commandResults[1].succeeded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
    }

    func testRunnerDrainsBusyStandardOutputAndStandardErrorWithoutDeadlocking() async throws {
        let script = "for i in $(seq 1 70000); do printf o; printf e >&2; done"
        let command = Command(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script],
            maximumCapturedOutputBytes: 200_000
        )

        let result = try await ProcessCommandRunner().run(command, timeout: 10)

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.standardOutput.count, 70_000)
        XCTAssertEqual(result.standardError.count, 70_000)
    }

    func testBoundedDiagnosticOutputRetainsFailureSummaryAtEnd() async throws {
        let noisyPrefix = String(repeating: "x", count: 4_096)
        let command = Command(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf '%s' '\(noisyPrefix)' >&2; printf ' FINAL-RESTIC-FAILURE' >&2; exit 1"],
            maximumCapturedOutputBytes: 256
        )

        let result = try await ProcessCommandRunner().run(command, timeout: 5)

        XCTAssertFalse(result.succeeded)
        XCTAssertLessThanOrEqual(result.standardError.utf8.count, 256)
        XCTAssertTrue(result.standardError.contains("FINAL-RESTIC-FAILURE"))
    }

    func testCancellingRunTerminatesAnUncooperativeChildPromptly() async throws {
        let command = Command(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap '' INT TERM; while :; do :; done"]
        )
        let startedAt = Date()
        let task = Task {
            try await ProcessCommandRunner().run(command, timeout: 30)
        }

        try await Task.sleep(nanoseconds: 150_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("A cancelled process run must not report a normal result")
        } catch is CancellationError {
            XCTAssertLessThan(Date().timeIntervalSince(startedAt), 3)
        }
    }
}
