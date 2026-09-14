import Foundation

public enum ServerUnavailableReason: LocalizedError, Equatable, Sendable {
    case invalidConfiguration(String)
    case missingTool(String)
    case colimaUnavailable
    case dockerUnavailable
    case composeUnavailable
    case commandTimedOut

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message): return message
        case .missingTool(let path): return "Required tool is unavailable: \(path)"
        case .colimaUnavailable: return "Colima is unavailable."
        case .dockerUnavailable: return "Docker is unavailable."
        case .composeUnavailable: return "Docker Compose is unavailable for this project."
        case .commandTimedOut: return "The server status check timed out."
        }
    }
}

public enum ServerStatus: Equatable, Sendable {
    case unavailable(ServerUnavailableReason)
    case starting
    case running
    case unhealthy(String)
    case stopped

    public var detail: String? {
        switch self {
        case .unavailable(let reason): return reason.errorDescription
        case .unhealthy(let message): return message
        case .starting, .running, .stopped: return nil
        }
    }

    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    public var snapshot: ServerStatusSnapshot { ServerStatusSnapshot(self) }
}

/// Stable, compact status payload for the helper's JSON output. It avoids
/// serializing command output and makes UI polling independent of enum coding.
public struct ServerStatusSnapshot: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case unavailable
        case starting
        case running
        case unhealthy
        case stopped
    }

    public let kind: Kind
    public let detail: String?

    public init(_ status: ServerStatus) {
        switch status {
        case .unavailable: kind = .unavailable
        case .starting: kind = .starting
        case .running: kind = .running
        case .unhealthy: kind = .unhealthy
        case .stopped: kind = .stopped
        }
        detail = status.detail
    }
}

public enum ServerControllerError: LocalizedError, Equatable, Sendable {
    case invalidConfiguration(String)
    case requiredToolUnavailable(String)
    case colimaStartFailed
    case composeStartFailed
    case composeStopFailed

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message): return message
        case .requiredToolUnavailable(let path): return "Required tool is unavailable: \(path)"
        case .colimaStartFailed: return "Colima could not be started."
        case .composeStartFailed: return "Immich could not be started with Docker Compose."
        case .composeStopFailed: return "Immich could not be stopped with Docker Compose."
        }
    }
}

public protocol ServerControlling: Sendable {
    func status() async -> ServerStatus
    func start() async throws -> ServerStatus
    func stop() async throws -> ServerStatus
}

public extension ServerControlling {
    func serverStatus() async -> ServerStatus { await status() }
}

/// Controls the existing Colima + Docker Compose deployment without changing
/// Compose files, launch agents, .env, or data. Stop leaves the Colima VM
/// running, matching the legacy stop script's behaviour.
public final class ServerController: ServerControlling, @unchecked Sendable {
    public let configuration: ImmichConfiguration
    public let commandRunner: any CommandRunning
    public let operationLock: OperationLock
    public let operationTimeout: TimeInterval

    public init(
        configuration: ImmichConfiguration,
        commandRunner: any CommandRunning = ProcessCommandRunner(),
        operationLock: OperationLock = OperationLock(),
        operationTimeout: TimeInterval = 30
    ) {
        self.configuration = configuration
        self.commandRunner = commandRunner
        self.operationLock = operationLock
        self.operationTimeout = operationTimeout
    }

    public func status() async -> ServerStatus {
        do {
            try configuration.server.validate()
        } catch {
            return .unavailable(.invalidConfiguration(error.localizedDescription))
        }
        guard FileManager.default.isExecutableFile(atPath: configuration.server.toolPaths.colimaPath) else {
            return .unavailable(.missingTool(configuration.server.toolPaths.colimaPath))
        }
        guard FileManager.default.isExecutableFile(atPath: configuration.server.toolPaths.dockerPath) else {
            return .unavailable(.missingTool(configuration.server.toolPaths.dockerPath))
        }

        do {
            let colima = try await commandRunner.run(colimaCommand(arguments: ["status"]), timeout: 15)
            if colima.timedOut { return .unavailable(.commandTimedOut) }
            if !colima.succeeded {
                return isStoppedColimaMessage(colima) ? .stopped : .unavailable(.colimaUnavailable)
            }

            let compose = try await commandRunner.run(composeCommand(arguments: ["ps", "--all", "--format", "json"]), timeout: 20)
            if compose.timedOut { return .unavailable(.commandTimedOut) }
            guard compose.succeeded else { return .unavailable(.dockerUnavailable) }
            return Self.interpretComposeStatus(compose.standardOutput)
        } catch let error as CommandRunnerError {
            switch error {
            case .executableNotFound(let path): return .unavailable(.missingTool(path))
            default: return .unavailable(.composeUnavailable)
            }
        } catch {
            return .unavailable(.composeUnavailable)
        }
    }

    public func start() async throws -> ServerStatus {
        try await operationLock.withLock(timeout: operationTimeout) { [self] in
            try await startWhileOperationLocked()
        }
    }

    public func stop() async throws -> ServerStatus {
        try await operationLock.withLock(timeout: operationTimeout) { [self] in
            try await stopWhileOperationLocked()
        }
    }

    /// Backup coordination can call this while it holds the shared operation
    /// lock, avoiding re-entrant advisory-lock deadlocks.
    public func startWhileOperationLocked() async throws -> ServerStatus {
        try validateForMutation()
        let colimaStatus = try await commandRunner.run(colimaCommand(arguments: ["status"]), timeout: 15)
        if !colimaStatus.succeeded {
            let startResult = try await commandRunner.run(
                colimaCommand(arguments: [
                    "start",
                    "--cpu", String(configuration.server.resourcePreset.cpuCount),
                    "--memory", String(configuration.server.resourcePreset.memoryGiB),
                    "--disk", "100",
                    "--vm-type", "vz",
                    "--mount-type", "virtiofs",
                ]),
                timeout: 180
            )
            guard startResult.succeeded else { throw ServerControllerError.colimaStartFailed }
        }

        let compose = try await commandRunner.run(composeCommand(arguments: ["up", "--detach"]), timeout: 180)
        guard compose.succeeded else { throw ServerControllerError.composeStartFailed }
        return await status()
    }

    /// Backup coordination can call this while it holds the shared operation
    /// lock, avoiding re-entrant advisory-lock deadlocks.
    public func stopWhileOperationLocked() async throws -> ServerStatus {
        try validateForMutation()
        let colimaStatus = try await commandRunner.run(colimaCommand(arguments: ["status"]), timeout: 15)
        if !colimaStatus.succeeded, isStoppedColimaMessage(colimaStatus) { return .stopped }

        let compose = try await commandRunner.run(composeCommand(arguments: ["down"]), timeout: 120)
        guard compose.succeeded else { throw ServerControllerError.composeStopFailed }
        return .stopped
    }

    private func validateForMutation() throws {
        do {
            try configuration.server.validate()
        } catch {
            throw ServerControllerError.invalidConfiguration(error.localizedDescription)
        }
        for path in [configuration.server.toolPaths.colimaPath, configuration.server.toolPaths.dockerPath] {
            guard FileManager.default.isExecutableFile(atPath: path) else {
                throw ServerControllerError.requiredToolUnavailable(path)
            }
        }
    }

    private func colimaCommand(arguments: [String]) -> Command {
        Command(
            executable: configuration.server.toolPaths.colimaURL,
            arguments: arguments,
            currentDirectoryURL: configuration.server.projectRootURL
        )
    }

    private func composeCommand(arguments: [String]) -> Command {
        Command(
            executable: configuration.server.toolPaths.dockerURL,
            arguments: [
                "--context", "colima",
                "compose",
                "--project-name", configuration.server.projectName,
                "--project-directory", configuration.server.projectRootURL.path,
                "--file", configuration.server.composeFileURL.path,
            ] + arguments,
            currentDirectoryURL: configuration.server.projectRootURL,
            clearedEnvironmentKeys: ["DOCKER_HOST", "DOCKER_CONTEXT"]
        )
    }

    private func isStoppedColimaMessage(_ result: CommandResult) -> Bool {
        let text = (result.standardOutput + "\n" + result.standardError).lowercased()
        return text.contains("not running") || text.contains("not initialized") || text.contains("no instance")
    }

    private static func interpretComposeStatus(_ output: String) -> ServerStatus {
        guard let services = decodeComposeServices(output) else { return .unavailable(.composeUnavailable) }
        guard let server = services.first(where: { $0.service == "immich-server" || $0.name == "immich_server" }) else {
            return .stopped
        }

        let state = server.state.lowercased()
        let health = (server.health + " " + server.status).lowercased()
        if health.contains("unhealthy") { return .unhealthy("The Immich server container is unhealthy.") }
        if state == "running" {
            return health.contains("starting") ? .starting : .running
        }
        if state == "created" || state == "restarting" { return .starting }
        return .stopped
    }

    private static func decodeComposeServices(_ output: String) -> [ComposeService]? {
        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let data = Data(output.utf8)
        let decoder = JSONDecoder()
        if let array = try? decoder.decode([ComposeService].self, from: data) { return array }
        let lines = output.split(whereSeparator: \.isNewline)
        let services = lines.compactMap { line in
            try? decoder.decode(ComposeService.self, from: Data(line.utf8))
        }
        return services.count == lines.count ? services : nil
    }
}

private struct ComposeService: Decodable {
    let name: String
    let service: String
    let state: String
    let health: String
    let status: String

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case service = "Service"
        case state = "State"
        case health = "Health"
        case status = "Status"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? ""
        service = try values.decodeIfPresent(String.self, forKey: .service) ?? ""
        state = try values.decodeIfPresent(String.self, forKey: .state) ?? ""
        health = try values.decodeIfPresent(String.self, forKey: .health) ?? ""
        status = try values.decodeIfPresent(String.self, forKey: .status) ?? ""
    }
}
