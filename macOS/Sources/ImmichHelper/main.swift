import Foundation
import ImmichCore
import Darwin
import Dispatch

/// The executable entry point used by launchd and the compatibility wrappers.
/// It intentionally accepts a compact, fixed command grammar so neither the
/// shell wrappers nor launchd need to interpolate user-provided text.
enum HelperCommand: Equatable {
    case server(ServerAction)
    case backup(BackupTargetKind, online: Bool)
    case scheduler(SchedulerAction)

    enum ServerAction: String, Equatable {
        case start
        case stop
        case status
    }

    enum SchedulerAction: String, Equatable {
        case runDue = "run-due"
        case adopt
    }

    static func parse(arguments: [String]) throws -> (root: URL?, command: HelperCommand) {
        var arguments = Array(arguments.dropFirst())
        var root: URL?
        if arguments.first == "--root" {
            guard arguments.count >= 2 else { throw HelperCLIError.usage }
            let supplied = arguments[1]
            arguments.removeFirst(2)
            guard supplied.hasPrefix("/") else { throw HelperCLIError.invalidRoot }
            root = URL(fileURLWithPath: supplied, isDirectory: true).standardizedFileURL
        }
        guard let family = arguments.first else { throw HelperCLIError.usage }
        arguments.removeFirst()
        switch family {
        case "server":
            guard arguments.count == 1, let action = ServerAction(rawValue: arguments[0]) else { throw HelperCLIError.usage }
            return (root, .server(action))
        case "backup":
            guard let targetRaw = arguments.first, let target = BackupTargetKind(rawValue: targetRaw) else { throw HelperCLIError.usage }
            let rest = Array(arguments.dropFirst())
            guard rest.isEmpty || rest == ["--online"] else { throw HelperCLIError.usage }
            return (root, .backup(target, online: rest == ["--online"]))
        case "scheduler":
            guard arguments.count == 1, let action = SchedulerAction(rawValue: arguments[0]) else { throw HelperCLIError.usage }
            return (root, .scheduler(action))
        default:
            throw HelperCLIError.usage
        }
    }
}

enum HelperCLIError: LocalizedError {
    case usage
    case invalidRoot
    case rootMismatch(saved: String, requested: String)

    var errorDescription: String? {
        switch self {
        case .usage:
            return "Usage: immich-helper [--root /absolute/project/path] server start|stop|status | backup r2|usb [--online] | scheduler run-due|adopt"
        case .invalidRoot:
            return "--root must be an absolute project path."
        case let .rootMismatch(saved, requested):
            return "The saved Immich Control configuration is for \(saved), not the requested project \(requested). Update the project setting before running this helper."
        }
    }
}

@main
struct ImmichHelper {
    static func main() async {
        do {
            let parsed = try HelperCommand.parse(arguments: CommandLine.arguments)
            let work = Task<Int32, Never> { await execute(parsed) }
            let signals = SignalCancellation.install { work.cancel() }
            let code = await work.value
            signals.forEach { $0.cancel() }
            exit(code)
        } catch {
            writeError(error.localizedDescription)
            exit(EXIT_FAILURE)
        }
    }

    private static func execute(_ parsed: (root: URL?, command: HelperCommand)) async -> Int32 {
        do {
            let configuration = try loadConfiguration(root: parsed.root)
            let statusStore = StatusStore(
                legacyLogsDirectoryURL: configuration.server.projectRootURL.appendingPathComponent("logs", isDirectory: true)
            )
            let coordinator = BackupCoordinator(configuration: configuration, statusStore: statusStore)

            // `server status` stays read-only. Mutating operations recover a
            // previous interrupted backup before taking any further action.
            if requiresServerRecovery(parsed.command), let recoveryError = await coordinator.recoverInterruptedServer() {
                writeError(recoveryError)
                return EXIT_FAILURE
            }

            switch parsed.command {
            case let .server(action):
                return await performServer(action, configuration: configuration)
            case let .backup(kind, online):
                guard let target = configuration.backups.first(where: { $0.kind == kind }) else {
                    writeError("The \(kind.rawValue) backup target is not configured.")
                    return EXIT_FAILURE
                }
                let result = await coordinator.run(target: target, online: online)
                writeJSON(result)
                return result.outcome == .error ? EXIT_FAILURE : EXIT_SUCCESS
            case let .scheduler(action):
                switch action {
                case .runDue:
                    return await runDueBackups(configuration: configuration, coordinator: coordinator)
                case .adopt:
                    return await adoptSchedules(configuration: configuration)
                }
            }
        } catch is CancellationError {
            writeError("Immich helper cancelled.")
            return EXIT_FAILURE
        } catch {
            writeError(error.localizedDescription)
            return EXIT_FAILURE
        }
    }

    private static func loadConfiguration(root: URL?) throws -> ImmichConfiguration {
        guard let root else { return try ImmichConfigurationStore().load() }
        let store = ImmichConfigurationStore(installationRoot: root)
        if FileManager.default.fileExists(atPath: store.fileURL.path) {
            // Do not hide corruption by reverting to legacy defaults: a helper
            // must fail closed rather than run with an unexpected repository.
            let saved = try store.load()
            guard saved.server.projectRootURL == root else {
                throw HelperCLIError.rootMismatch(saved: saved.server.projectRootPath, requested: root.path)
            }
            return saved
        }
        // First-run import persists only non-secret deployment metadata. It does
        // not source `.env` or copy any credential into application settings.
        let imported = try store.importLegacyConfiguration(from: root)
        try store.save(imported)
        return imported
    }

    private static func performServer(_ action: HelperCommand.ServerAction, configuration: ImmichConfiguration) async -> Int32 {
        let server = ServerController(configuration: configuration)
        let status: ServerStatus
        do {
            switch action {
            case .status: status = await server.status()
            case .start: status = try await server.start()
            case .stop: status = try await server.stop()
            }
            writeJSON(status.snapshot)
            return EXIT_SUCCESS
        } catch {
            writeError(error.localizedDescription)
            return EXIT_FAILURE
        }
    }

    private static func runDueBackups(configuration: ImmichConfiguration, coordinator: BackupCoordinator) async -> Int32 {
        let now = Date()
        let values = Calendar.current.dateComponents([.hour, .minute, .weekday], from: now)
        let due = configuration.backups.filter {
            $0.enabled
                && $0.schedule.hour == values.hour
                && $0.schedule.minute == values.minute
                && $0.schedule.weekdays.contains(values.weekday ?? 0)
        }
        var results: [BackupExecutionResult] = []
        for target in due {
            let result = await coordinator.run(target: target)
            results.append(result)
        }
        writeJSON(results)
        return results.contains(where: { $0.outcome == .error }) ? EXIT_FAILURE : EXIT_SUCCESS
    }

    private static func adoptSchedules(configuration: ImmichConfiguration) async -> Int32 {
        let helper = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        do {
            let scheduler = BackupScheduler(helperURL: helper)
            try await scheduler.migrateLegacySchedules(configuration: configuration, helperURL: helper)
            writeJSON(HelperActionResult(message: "Legacy backup schedules adopted."))
            return EXIT_SUCCESS
        } catch {
            writeError(error.localizedDescription)
            return EXIT_FAILURE
        }
    }

    private static func requiresServerRecovery(_ command: HelperCommand) -> Bool {
        switch command {
        case .server(.start), .server(.stop), .backup:
            return true
        case .server(.status), .scheduler:
            return false
        }
    }

    private static func writeJSON<T: Encodable>(_ value: T) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

private struct HelperActionResult: Codable {
    let message: String
}

private enum SignalCancellation {
    static func install(cancel: @escaping @Sendable () -> Void) -> [DispatchSourceSignal] {
        [SIGINT, SIGTERM].map { signalNumber in
            Darwin.signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global(qos: .userInitiated))
            source.setEventHandler(handler: cancel)
            source.resume()
            return source
        }
    }
}
