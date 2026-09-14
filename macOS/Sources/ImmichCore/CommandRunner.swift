@preconcurrency import Foundation
import Darwin

/// An argv-based subprocess invocation. Arguments are always passed directly to
/// `Process`; no shell is involved, so configuration values cannot be evaluated
/// as shell code.
public struct Command: Sendable, Equatable {
    public static let defaultCapturedOutputLimit = 1_048_576

    public let executable: URL
    public let arguments: [String]
    public let currentDirectoryURL: URL?
    /// Environment values can include credentials. They are never logged by the core.
    public let environment: [String: String]
    /// Ambient variables to remove before launching. This keeps GUI operations
    /// independent of a developer shell's Docker endpoint selection.
    public let clearedEnvironmentKeys: [String]
    /// When set, stdout is streamed directly to this path and is not retained in memory.
    public let standardOutputFileURL: URL?
    public let maximumCapturedOutputBytes: Int

    public init(
        executable: URL,
        arguments: [String] = [],
        currentDirectoryURL: URL? = nil,
        environment: [String: String] = [:],
        clearedEnvironmentKeys: [String] = [],
        standardOutputFileURL: URL? = nil,
        maximumCapturedOutputBytes: Int = Command.defaultCapturedOutputLimit
    ) {
        self.executable = executable
        self.arguments = arguments
        self.currentDirectoryURL = currentDirectoryURL
        self.environment = environment
        self.clearedEnvironmentKeys = clearedEnvironmentKeys
        self.standardOutputFileURL = standardOutputFileURL
        self.maximumCapturedOutputBytes = max(0, maximumCapturedOutputBytes)
    }

    /// Safe for diagnostics: only the executable and argument vector are shown.
    /// The environment is intentionally omitted because it may contain credentials.
    public var redactedDescription: String {
        ([executable.path] + arguments).joined(separator: " ")
    }
}

public struct CommandResult: Sendable, Equatable {
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String
    public let timedOut: Bool
    public let duration: TimeInterval

    public init(
        exitCode: Int32,
        standardOutput: String,
        standardError: String,
        timedOut: Bool,
        duration: TimeInterval
    ) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.timedOut = timedOut
        self.duration = duration
    }

    /// Compatibility spelling used by process-oriented callers.
    public var terminationStatus: Int32 { exitCode }
    public var succeeded: Bool { !timedOut && exitCode == 0 }
    public var stdout: String { standardOutput }
    public var stderr: String { standardError }
}

public enum CommandRunnerError: LocalizedError, Equatable, Sendable {
    case executableNotFound(String)
    case invalidCurrentDirectory(String)
    case pipelineNeedsCommands
    case unableToCreateOutputFile(String)
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .executableNotFound(let path): return "The required command is unavailable: \(path)"
        case .invalidCurrentDirectory(let path): return "The command working folder is unavailable: \(path)"
        case .pipelineNeedsCommands: return "A command pipeline needs at least one command."
        case .unableToCreateOutputFile(let path): return "The command output file could not be created: \(path)"
        case .launchFailed(let message): return "The command could not start: \(message)"
        }
    }
}

public protocol CommandRunning: Sendable {
    func run(_ command: Command, timeout: TimeInterval?) async throws -> CommandResult
}

/// A pipeline keeps data such as a PostgreSQL dump out of process memory by
/// connecting child stdout to child stdin and streaming the final output to disk.
public struct CommandPipeline: Sendable, Equatable {
    public let commands: [Command]
    public let standardOutputFileURL: URL

    public init(commands: [Command], standardOutputFileURL: URL) {
        self.commands = commands
        self.standardOutputFileURL = standardOutputFileURL
    }
}

public struct PipelineCommandResult: Sendable, Equatable {
    public let commandResults: [CommandResult]
    public let timedOut: Bool
    public let duration: TimeInterval

    public init(commandResults: [CommandResult], timedOut: Bool, duration: TimeInterval) {
        self.commandResults = commandResults
        self.timedOut = timedOut
        self.duration = duration
    }

    public var succeeded: Bool { !timedOut && commandResults.allSatisfy(\.succeeded) }
}

public protocol CommandPipelining: CommandRunning {
    func runPipeline(_ pipeline: CommandPipeline, timeout: TimeInterval?) async throws -> PipelineCommandResult
}

/// Native process runner for both the menu app and the background helper.
/// It supplies an explicit Homebrew-aware PATH because GUI processes do not
/// inherit an interactive shell's PATH.
public struct ProcessCommandRunner: CommandPipelining, Sendable {
    public static let guiPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    public init() {}

    public func run(_ command: Command, timeout: TimeInterval? = nil) async throws -> CommandResult {
        try validate(command)
        let startedAt = Date()
        let process = configuredProcess(for: command)
        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        let stdoutPipe: Pipe?
        let outputFile: FileHandle?
        if let outputURL = command.standardOutputFileURL {
            outputFile = try makeOutputFile(at: outputURL)
            process.standardOutput = outputFile
            stdoutPipe = nil
        } else {
            outputFile = nil
            let pipe = Pipe()
            process.standardOutput = pipe
            stdoutPipe = pipe
        }

        do {
            try process.run()
        } catch {
            outputFile?.closeFile()
            throw CommandRunnerError.launchFailed(error.localizedDescription)
        }

        let stdoutTask = stdoutPipe.map { pipe in
            Task.detached { BoundedOutputReader.read(from: pipe.fileHandleForReading, limit: command.maximumCapturedOutputBytes) }
        }
        let stderrTask = Task.detached {
            BoundedOutputReader.read(from: stderrPipe.fileHandleForReading, limit: command.maximumCapturedOutputBytes)
        }

        let timedOut: Bool
        do {
            timedOut = try await waitForExit(process, timeout: timeout)
        } catch {
            outputFile?.closeFile()
            _ = await stdoutTask?.value
            _ = await stderrTask.value
            throw error
        }
        outputFile?.closeFile()
        let stdout = await stdoutTask?.value ?? ""
        let stderr = await stderrTask.value

        return CommandResult(
            exitCode: process.terminationStatus,
            standardOutput: stdout,
            standardError: stderr,
            timedOut: timedOut,
            duration: Date().timeIntervalSince(startedAt)
        )
    }

    public func runPipeline(_ pipeline: CommandPipeline, timeout: TimeInterval? = nil) async throws -> PipelineCommandResult {
        guard !pipeline.commands.isEmpty else { throw CommandRunnerError.pipelineNeedsCommands }
        for command in pipeline.commands { try validate(command) }

        let startedAt = Date()
        let processes = pipeline.commands.map(configuredProcess)
        let stderrPipes = processes.map { _ in Pipe() }
        let bridges = (0..<(max(0, processes.count - 1))).map { _ in Pipe() }
        let outputFile = try makeOutputFile(at: pipeline.standardOutputFileURL)
        defer { outputFile.closeFile() }

        for index in processes.indices {
            processes[index].standardError = stderrPipes[index]
            if index == processes.startIndex {
                continue
            }
            processes[index].standardInput = bridges[index - 1]
        }
        for index in bridges.indices {
            processes[index].standardOutput = bridges[index]
        }
        processes[processes.count - 1].standardOutput = outputFile

        do {
            // Start consumers before producers so a large dump has a reader from
            // its first bytes onward.
            for process in processes.reversed() { try process.run() }
        } catch {
            await terminate(processes)
            throw CommandRunnerError.launchFailed(error.localizedDescription)
        }
        for bridge in bridges { bridge.fileHandleForWriting.closeFile() }

        let stderrTasks = zip(stderrPipes, pipeline.commands).map { pipe, command in
            Task.detached { BoundedOutputReader.read(from: pipe.fileHandleForReading, limit: command.maximumCapturedOutputBytes) }
        }
        let timedOut: Bool
        do {
            timedOut = try await waitForExit(processes, timeout: timeout)
        } catch {
            _ = await stderrTasks.asyncValues()
            throw error
        }
        let standardErrors = await stderrTasks.asyncValues()
        let results = zip(processes, standardErrors).map { process, error in
            CommandResult(
                exitCode: process.terminationStatus,
                standardOutput: "",
                standardError: error,
                timedOut: timedOut,
                duration: Date().timeIntervalSince(startedAt)
            )
        }
        return PipelineCommandResult(
            commandResults: results,
            timedOut: timedOut,
            duration: Date().timeIntervalSince(startedAt)
        )
    }

    private func configuredProcess(for command: Command) -> Process {
        let process = Process()
        process.executableURL = command.executable
        process.arguments = command.arguments
        process.currentDirectoryURL = command.currentDirectoryURL
        var environment = ProcessInfo.processInfo.environment
        for key in command.clearedEnvironmentKeys { environment.removeValue(forKey: key) }
        for (key, value) in command.environment { environment[key] = value }
        environment["PATH"] = command.environment["PATH"] ?? Self.guiPath
        process.environment = environment
        return process
    }

    private func validate(_ command: Command) throws {
        guard FileManager.default.isExecutableFile(atPath: command.executable.path) else {
            throw CommandRunnerError.executableNotFound(command.executable.path)
        }
        if let directory = command.currentDirectoryURL {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw CommandRunnerError.invalidCurrentDirectory(directory.path)
            }
        }
    }

    private func makeOutputFile(at url: URL) throws -> FileHandle {
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard FileManager.default.createFile(
                atPath: url.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw CommandRunnerError.unableToCreateOutputFile(url.path)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return try FileHandle(forWritingTo: url)
        } catch let error as CommandRunnerError {
            throw error
        } catch {
            throw CommandRunnerError.unableToCreateOutputFile(url.path)
        }
    }

    private func waitForExit(_ process: Process, timeout: TimeInterval?) async throws -> Bool {
        try await waitForExit([process], timeout: timeout)
    }

    private func waitForExit(_ processes: [Process], timeout: TimeInterval?) async throws -> Bool {
        let timeout = timeout.map { max(0, $0) }
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        while processes.contains(where: \.isRunning) {
            if Task.isCancelled {
                await terminate(processes)
                throw CancellationError()
            }
            if let deadline, Date() >= deadline {
                await terminate(processes)
                return true
            }
            do {
                try await Task.sleep(nanoseconds: 50_000_000)
            } catch {
                await terminate(processes)
                throw CancellationError()
            }
        }
        return false
    }

    private func terminate(_ processes: [Process]) async {
        for process in processes where process.isRunning { process.interrupt() }
        let gracefulDeadline = Date().addingTimeInterval(1)
        while processes.contains(where: \.isRunning), Date() < gracefulDeadline {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        for process in processes where process.isRunning { process.terminate() }
        let terminationDeadline = Date().addingTimeInterval(1)
        while processes.contains(where: \.isRunning), Date() < terminationDeadline {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        for process in processes where process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
        }
        let reapDeadline = Date().addingTimeInterval(1)
        while processes.contains(where: \.isRunning), Date() < reapDeadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private enum BoundedOutputReader {
    static func read(from handle: FileHandle, limit: Int) -> String {
        defer { try? handle.close() }
        var retained = Data()
        while true {
            let chunk = handle.availableData
            guard !chunk.isEmpty else { break }
            guard limit > 0 else { continue }
            if chunk.count >= limit {
                retained = Data(chunk.suffix(limit))
                continue
            }
            let overflow = max(0, retained.count + chunk.count - limit)
            if overflow > 0 { retained.removeFirst(overflow) }
            retained.append(chunk)
        }
        return String(decoding: retained, as: UTF8.self)
    }
}

private extension Array where Element == Task<String, Never> {
    func asyncValues() async -> [String] {
        var values: [String] = []
        values.reserveCapacity(count)
        for task in self { values.append(await task.value) }
        return values
    }
}
