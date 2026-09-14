import Foundation

/// Records the narrow recovery fact that matters if the helper is interrupted:
/// this app stopped Immich and therefore must attempt to start it again before
/// the next app operation. It does not attempt to resume a partially completed
/// Restic run, which would be unsafe; Restic itself deduplicates the next run.
public final class BackupRecoveryStore: @unchecked Sendable {
    public struct PendingRecovery: Codable, Equatable, Sendable {
        public let targetID: UUID
        public let projectRootPath: String?
        public let startedAt: Date

        public init(targetID: UUID, projectRootPath: String? = nil, startedAt: Date) {
            self.targetID = targetID
            self.projectRootPath = projectRootPath
            self.startedAt = startedAt
        }
    }

    public let fileURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    public init(
        fileURL: URL = BackupRecoveryStore.defaultURL(),
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL.standardizedFileURL
        self.fileManager = fileManager
    }

    public static func defaultURL(fileManager: FileManager = .default) -> URL {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return support.appendingPathComponent("ImmichControl/BackupRecovery.json", isDirectory: false)
    }

    public func pendingRecovery() throws -> PendingRecovery? {
        lock.lock()
        defer { lock.unlock() }
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        return try JSONDecoder().decode(PendingRecovery.self, from: Data(contentsOf: fileURL))
    }

    public func markServerStopped(for targetID: UUID, projectRootPath: String, at date: Date) throws {
        lock.lock()
        defer { lock.unlock() }
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(PendingRecovery(targetID: targetID, projectRootPath: projectRootPath, startedAt: date))
        try data.write(to: fileURL, options: .atomic)
    }

    public func clear() throws {
        lock.lock()
        defer { lock.unlock() }
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try fileManager.removeItem(at: fileURL)
    }
}
