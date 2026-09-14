import Foundation

public enum USBVolumeState: Equatable, Sendable {
    /// The expected mount point does not exist. This is an expected condition for
    /// a removable backup drive and maps to a skipped backup, never a success.
    case unavailable
    case wrongVolume(actualUUID: String?)
    case notWritable
    case ready
}

public protocol USBInspecting: Sendable {
    func inspect(mountPath: URL, expectedVolumeUUID: String) -> USBVolumeState
}

public struct SystemUSBInspector: USBInspecting, @unchecked Sendable {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func inspect(mountPath: URL, expectedVolumeUUID: String) -> USBVolumeState {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: mountPath.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .unavailable
        }
        let resolvedMount = mountPath.resolvingSymlinksInPath().standardizedFileURL
        guard let values = try? resolvedMount.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeURLKey]),
              let actualUUID = values.volumeUUIDString
        else { return .wrongVolume(actualUUID: nil) }
        // A matching UUID is not enough: a user could configure a subdirectory
        // within that volume. Backups must only ever target the actual mount root
        // that was approved as the removable destination.
        guard let volumeRoot = values.volume?.resolvingSymlinksInPath().standardizedFileURL,
              volumeRoot.path == resolvedMount.path else {
            return .wrongVolume(actualUUID: actualUUID)
        }
        guard actualUUID.caseInsensitiveCompare(expectedVolumeUUID) == .orderedSame else {
            return .wrongVolume(actualUUID: actualUUID)
        }
        return fileManager.isWritableFile(atPath: mountPath.path) ? .ready : .notWritable
    }
}

public protocol BackupClock: Sendable {
    func now() -> Date
    func weekday(at date: Date) -> Int
}

public struct SystemBackupClock: BackupClock, Sendable {
    public init() {}
    public func now() -> Date { Date() }
    /// Calendar weekday: Sunday is 1, which matches the legacy retention run.
    public func weekday(at date: Date) -> Int { Calendar.current.component(.weekday, from: date) }
}

public enum BackupError: LocalizedError, Equatable {
    case targetNotFound
    case targetDisabled
    case missingUSBConfiguration
    case usbWrongVolume(actualUUID: String?)
    case usbNotWritable
    case missingDatabaseSetting(String)
    case databaseDumpFailed(String)
    case backupFailed(String)
    case restartFailed(String)
    case missingRepository

    public var errorDescription: String? {
        switch self {
        case .targetNotFound: return "The requested backup target no longer exists."
        case .targetDisabled: return "This backup target is disabled."
        case .missingUSBConfiguration: return "The USB backup needs a mount path and volume UUID."
        case let .usbWrongVolume(actualUUID):
            return "Refusing USB backup: the mounted volume UUID \(actualUUID ?? "is unavailable") does not match the configured backup drive."
        case .usbNotWritable: return "The expected USB backup volume is not writable."
        case let .missingDatabaseSetting(name): return "The project .env file is missing \(name)."
        case let .databaseDumpFailed(message): return "Creating the PostgreSQL dump failed: \(message)"
        case let .backupFailed(message): return "Restic backup failed: \(message)"
        case let .restartFailed(message): return "The backup completed, but Immich could not be restarted: \(message)"
        case .missingRepository: return "This backup target does not have a Restic repository."
        }
    }
}

public struct BackupExecutionResult: Codable, Equatable, Sendable {
    public let targetID: UUID
    public let outcome: BackupOutcome
    public let message: String
    public let startedAt: Date
    public let finishedAt: Date

    public init(targetID: UUID, outcome: BackupOutcome, message: String, startedAt: Date, finishedAt: Date) {
        self.targetID = targetID
        self.outcome = outcome
        self.message = message
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }
}

extension CommandResult {
    var conciseFailureMessage: String {
        let source = stderr.isEmpty ? stdout : stderr
        let collapsed = source
            .split(whereSeparator: \.isNewline)
            .suffix(3)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? "exit status \(terminationStatus)" : collapsed
    }
}
