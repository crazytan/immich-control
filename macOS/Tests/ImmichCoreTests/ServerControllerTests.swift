import Foundation
import XCTest
@testable import ImmichCore

final class ServerControllerTests: XCTestCase {
    private var fixtureRoot: URL!

    override func setUpWithError() throws {
        fixtureRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("immich-server-controller-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        try Data("services: {}\n".utf8).write(to: fixtureRoot.appendingPathComponent("docker-compose.yml"))
    }

    override func tearDownWithError() throws {
        if let fixtureRoot {
            try? FileManager.default.removeItem(at: fixtureRoot)
        }
        fixtureRoot = nil
    }

    func testStatusReportsHealthyImmichServiceAsRunningAndUsesExplicitComposeRoot() async throws {
        let compose = """
        [{"Name":"immich_server","Service":"immich-server","State":"running","Health":"healthy","Status":"Up 2 minutes"}]
        """
        let runner = RecordingRunner(results: [.success(), .success(output: compose)])
        let controller = ServerController(
            configuration: configuration(),
            commandRunner: runner,
            operationLock: OperationLock(lockDirectoryURL: fixtureRoot.appendingPathComponent("locks"))
        )

        let status = await controller.status()

        XCTAssertEqual(status, .running)
        let commands = await runner.commands()
        XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(commands[0].arguments, ["status"])
        XCTAssertEqual(commands[1].currentDirectoryURL, fixtureRoot.standardizedFileURL)
        XCTAssertEqual(
            commands[1].arguments,
            [
                "--context", "colima", "compose", "--project-name", "immich-test",
                "--project-directory", fixtureRoot.path,
                "--file", fixtureRoot.appendingPathComponent("docker-compose.yml").path,
                "ps", "--all", "--format", "json",
            ]
        )
        XCTAssertEqual(Set(commands[1].clearedEnvironmentKeys), Set(["DOCKER_HOST", "DOCKER_CONTEXT"]))
    }

    func testStatusDistinguishesUnhealthyAndValidEmptyComposeOutput() async throws {
        let unhealthy = RecordingRunner(results: [
            .success(),
            .success(output: "{\"Name\":\"immich_server\",\"Service\":\"immich-server\",\"State\":\"running\",\"Health\":\"unhealthy\",\"Status\":\"Up\"}\n"),
        ])
        let unhealthyController = ServerController(
            configuration: configuration(),
            commandRunner: unhealthy,
            operationLock: OperationLock(lockDirectoryURL: fixtureRoot.appendingPathComponent("unhealthy-locks"))
        )
        let unhealthyStatus = await unhealthyController.status()
        XCTAssertEqual(unhealthyStatus, .unhealthy("The Immich server container is unhealthy."))

        let empty = RecordingRunner(results: [.success(), .success(output: "[]\n")])
        let stoppedController = ServerController(
            configuration: configuration(),
            commandRunner: empty,
            operationLock: OperationLock(lockDirectoryURL: fixtureRoot.appendingPathComponent("empty-locks"))
        )
        let stoppedStatus = await stoppedController.status()
        XCTAssertEqual(stoppedStatus, .stopped)
    }

    func testStatusTreatsMalformedComposeResponseAsUnavailableInsteadOfStopped() async throws {
        let runner = RecordingRunner(results: [.success(), .success(output: "definitely not compose JSON")])
        let controller = ServerController(
            configuration: configuration(),
            commandRunner: runner,
            operationLock: OperationLock(lockDirectoryURL: fixtureRoot.appendingPathComponent("malformed-locks"))
        )

        let status = await controller.status()

        XCTAssertEqual(status, .unavailable(.composeUnavailable))
    }

    func testStatusDoesNotInvokeRunnerWhenToolIsMissing() async throws {
        let runner = RecordingRunner(results: [])
        var configuration = configuration()
        configuration.server.toolPaths.colimaPath = fixtureRoot.appendingPathComponent("missing-colima").path
        let controller = ServerController(configuration: configuration, commandRunner: runner)

        let status = await controller.status()

        XCTAssertEqual(status, .unavailable(.missingTool(configuration.server.toolPaths.colimaPath)))
        let commands = await runner.commands()
        XCTAssertTrue(commands.isEmpty)
    }

    private func configuration() -> ImmichConfiguration {
        let tools = ToolPaths(
            colimaPath: "/usr/bin/true",
            dockerPath: "/usr/bin/true",
            resticPath: "/usr/bin/true"
        )
        return ImmichConfiguration(
            server: ServerSettings(
                projectRootURL: fixtureRoot,
                projectName: "immich-test",
                toolPaths: tools
            ),
            backups: []
        )
    }
}

private actor RecordingRunner: CommandRunning {
    private var queuedResults: [CommandResult]
    private var recordedCommands: [Command] = []

    init(results: [CommandResult]) {
        queuedResults = results
    }

    func run(_ command: Command, timeout: TimeInterval?) async throws -> CommandResult {
        recordedCommands.append(command)
        guard !queuedResults.isEmpty else {
            throw NSError(domain: "ServerControllerTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unexpected command: \(command.redactedDescription)"])
        }
        return queuedResults.removeFirst()
    }

    func commands() -> [Command] { recordedCommands }
}

private extension CommandResult {
    static func success(output: String = "") -> CommandResult {
        CommandResult(exitCode: 0, standardOutput: output, standardError: "", timedOut: false, duration: 0)
    }
}
