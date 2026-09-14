import Foundation
import Darwin

public enum BackupOutcome: String, Codable, CaseIterable, Sendable {
    case success
    case skipped
    case error

    /// Compatibility spelling for callers that present an error as a failure.
    public static var failed: BackupOutcome { .error }
}

/// The durable state of one backup destination. A skipped or failed attempt
/// deliberately preserves the prior successful backup timestamp, which keeps a
/// missing USB drive from appearing current.
public struct BackupTargetStatus: Codable, Equatable, Sendable, Identifiable {
    public var targetID: UUID
    public var outcome: BackupOutcome
    public var message: String
    public var startedAt: Date
    public var finishedAt: Date
    public var lastSuccessAt: Date?
    public var lastSuccessMessage: String?

    public var id: UUID { targetID }

    public init(
        targetID: UUID,
        outcome: BackupOutcome,
        message: String,
        startedAt: Date,
        finishedAt: Date,
        lastSuccessAt: Date? = nil,
        lastSuccessMessage: String? = nil
    ) {
        self.targetID = targetID
        self.outcome = outcome
        self.message = message
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.lastSuccessAt = lastSuccessAt
        self.lastSuccessMessage = lastSuccessMessage
    }
}

/// JSON-backed status history shared by the menu bar app and its helper.
/// Writes are atomic, and callers should hold `OperationLock.sharedOperationName`
/// while performing an operation and recording its result.
public final class StatusStore: @unchecked Sendable {
    public static let r2TargetID = UUID(uuidString: "B11D3810-BEF3-4C46-8C93-04D6D4A3CFB9")!
    public static let usbTargetID = UUID(uuidString: "35998B0D-CF48-4EA9-8E2E-6A5727C35B1E")!

    public let fileURL: URL
    public let legacyLogsDirectoryURL: URL?
    private let fileManager: FileManager
    private let lock = NSLock()

    public init(
        fileURL: URL = StatusStore.defaultURL(),
        legacyLogsDirectoryURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL.standardizedFileURL
        self.legacyLogsDirectoryURL = legacyLogsDirectoryURL?.standardizedFileURL
        self.fileManager = fileManager
    }

    public static func defaultURL(fileManager: FileManager = .default) -> URL {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return support.appendingPathComponent("ImmichControl", isDirectory: true)
            .appendingPathComponent("BackupStatus.json", isDirectory: false)
    }

    @discardableResult
    public func record(
        targetID: UUID,
        outcome: BackupOutcome,
        message: String,
        startedAt: Date = Date(),
        finishedAt: Date = Date()
    ) throws -> BackupTargetStatus {
        lock.lock()
        defer { lock.unlock() }
        return try withFileLock {
            var stored = try loadStoredStatus()
            let previous = stored.records.first(where: { $0.targetID == targetID })
            let wasSuccessful = outcome == .success
            let status = BackupTargetStatus(
                targetID: targetID,
                outcome: outcome,
                message: message,
                startedAt: startedAt,
                finishedAt: finishedAt,
                lastSuccessAt: wasSuccessful ? finishedAt : previous?.lastSuccessAt,
                lastSuccessMessage: wasSuccessful ? message : previous?.lastSuccessMessage
            )
            stored.records.removeAll { $0.targetID == targetID }
            stored.records.append(status)
            stored.records.sort { $0.targetID.uuidString < $1.targetID.uuidString }
            try write(stored)
            return status
        }
    }

    public func status(for targetID: UUID) throws -> BackupTargetStatus? {
        lock.lock()
        defer { lock.unlock() }
        return try withFileLock { try loadStoredStatus().records.first(where: { $0.targetID == targetID }) }
    }

    public func status(kind: BackupTargetKind) throws -> BackupTargetStatus? {
        try status(for: kind == .r2 ? Self.r2TargetID : Self.usbTargetID)
    }

    public func allStatuses() throws -> [BackupTargetStatus] {
        lock.lock()
        defer { lock.unlock() }
        return try withFileLock { try loadStoredStatus().records }
    }

    /// Convenience status for the migrated R2 destination.
    public var r2: BackupTargetStatus? { try? status(for: Self.r2TargetID) }
    /// Convenience status for the migrated USB destination.
    public var usb: BackupTargetStatus? { try? status(for: Self.usbTargetID) }

    private func loadStoredStatus() throws -> StoredStatus {
        if fileManager.fileExists(atPath: fileURL.path) {
            return try decoder().decode(StoredStatus.self, from: Data(contentsOf: fileURL))
        }
        let migrated = migrateLegacyLogs()
        if !migrated.records.isEmpty { try write(migrated) }
        return migrated
    }

    private func write(_ status: StoredStatus) throws {
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder().encode(status).write(to: fileURL, options: .atomic)
    }

    /// Status outcomes can be recorded before a backup obtains the long-lived
    /// operation lock (for example, a USB skip). This short file lock prevents
    /// the app and helper from racing a read-modify-write of the JSON file.
    private func withFileLock<T>(_ operation: () throws -> T) throws -> T {
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lockURL = fileURL.appendingPathExtension("lock")
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(.EACCES) }
        defer {
            _ = flock(descriptor, LOCK_UN)
            _ = Darwin.close(descriptor)
        }
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(.EWOULDBLOCK) }
        return try operation()
    }

    private func migrateLegacyLogs() -> StoredStatus {
        guard let directory = legacyLogsDirectoryURL else { return StoredStatus(records: []) }
        let mappings: [(String, String, UUID)] = [
            ("immich-r2-backup.log", "Immich R2 backup completed", Self.r2TargetID),
            ("immich-usb-backup.log", "Immich USB backup completed", Self.usbTargetID),
        ]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        let records = mappings.compactMap { filename, completionMessage, targetID -> BackupTargetStatus? in
            let url = directory.appendingPathComponent(filename)
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  let date = lastCompletedRun(in: text, completionMessage: completionMessage, formatter: formatter) else {
                return nil
            }
            return BackupTargetStatus(
                targetID: targetID,
                outcome: .success,
                message: completionMessage,
                startedAt: date,
                finishedAt: date,
                lastSuccessAt: date,
                lastSuccessMessage: completionMessage
            )
        }
        return StoredStatus(records: records)
    }

    /// A completed line is only trusted when it is the final timestamped event
    /// in the log. This avoids calling a prior backup current after an unfinished
    /// or failed later attempt whose wording the importer does not understand.
    private func lastCompletedRun(in text: String, completionMessage: String, formatter: DateFormatter) -> Date? {
        var finalTimestampedMessage: (date: Date, message: String)?
        for rawLine in text.components(separatedBy: .newlines) {
            guard rawLine.count >= 20 else { continue }
            let prefix = String(rawLine.prefix(19))
            guard let date = formatter.date(from: prefix) else { continue }
            let message = String(rawLine.dropFirst(19)).trimmingCharacters(in: .whitespaces)
            finalTimestampedMessage = (date, message)
        }
        guard let final = finalTimestampedMessage, final.message == completionMessage else { return nil }
        return final.date
    }

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private struct StoredStatus: Codable, Sendable {
    var schemaVersion = 1
    var records: [BackupTargetStatus]
}
