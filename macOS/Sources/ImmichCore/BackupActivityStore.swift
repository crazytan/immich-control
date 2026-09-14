import Foundation
import Darwin

public enum BackupStage: String, Codable, CaseIterable, Sendable {
    case preparing = "Preparing"
    case database = "Database"
    case snapshot = "Snapshot"
    case restarting = "Restarting"
    case maintenance = "Maintenance"
}

/// A single cross-process activity record. The menu app reads this while the
/// helper is running, so scheduled and manual backups have the same visible
/// progress state. Restic's output is intentionally not persisted here because
/// it may grow without bound.
public struct BackupActivity: Codable, Equatable, Sendable {
    public let targetID: UUID
    public let projectRootPath: String
    public let processID: Int32
    public let startedAt: Date
    public var stage: BackupStage

    public init(targetID: UUID, projectRootPath: String, processID: Int32 = getpid(), startedAt: Date = Date(), stage: BackupStage) {
        self.targetID = targetID
        self.projectRootPath = projectRootPath
        self.processID = processID
        self.startedAt = startedAt
        self.stage = stage
    }
}

public final class BackupActivityStore: @unchecked Sendable {
    public let fileURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    public init(fileURL: URL = BackupActivityStore.defaultURL(), fileManager: FileManager = .default) {
        self.fileURL = fileURL.standardizedFileURL
        self.fileManager = fileManager
    }

    public static func defaultURL(fileManager: FileManager = .default) -> URL {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return support.appendingPathComponent("ImmichControl/BackupActivity.json", isDirectory: false)
    }

    public func begin(_ activity: BackupActivity) throws {
        lock.lock()
        defer { lock.unlock() }
        try write(activity)
    }

    public func update(stage: BackupStage) throws {
        lock.lock()
        defer { lock.unlock() }
        guard var activity = try read() else { return }
        activity.stage = stage
        try write(activity)
    }

    public func currentActivity() throws -> BackupActivity? {
        lock.lock()
        defer { lock.unlock() }
        guard let activity = try read(), isProcessAlive(activity.processID) else { return nil }
        return activity
    }

    /// Consumes a record left by a terminated helper so its next operation can
    /// make that interruption visible instead of silently showing a stale spinner.
    public func takeStaleActivity() throws -> BackupActivity? {
        lock.lock()
        defer { lock.unlock() }
        guard let activity = try read(), !isProcessAlive(activity.processID) else { return nil }
        try removeFileIfPresent()
        return activity
    }

    public func clear() throws {
        lock.lock()
        defer { lock.unlock() }
        try removeFileIfPresent()
    }

    private func read() throws -> BackupActivity? {
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BackupActivity.self, from: Data(contentsOf: fileURL))
    }

    private func write(_ activity: BackupActivity) throws {
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(activity).write(to: fileURL, options: .atomic)
    }

    private func removeFileIfPresent() throws {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try fileManager.removeItem(at: fileURL)
    }

    private func isProcessAlive(_ processID: Int32) -> Bool {
        guard processID > 0 else { return false }
        if Darwin.kill(processID, 0) == 0 { return true }
        return errno == EPERM
    }
}
