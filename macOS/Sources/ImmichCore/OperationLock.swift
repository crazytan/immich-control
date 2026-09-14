import Foundation
import Darwin

/// Cross-process advisory locking for operations that must never overlap, such
/// as a backup, server start, or server stop. Both the app and helper use the
/// same Application Support lock directory.
public final class OperationLock: @unchecked Sendable {
    public enum Error: LocalizedError, Equatable, Sendable {
        case invalidName(String)
        case timedOut(String)
        case unableToCreate(String)
        case unableToAcquire(String, Int32)

        public var errorDescription: String? {
            switch self {
            case .invalidName: return "The operation lock name is invalid."
            case .timedOut(let name): return "Another Immich operation is still running (\(name))."
            case .unableToCreate(let path): return "The operation lock could not be created at \(path)."
            case .unableToAcquire(let name, _): return "The operation lock could not be acquired (\(name))."
            }
        }
    }

    public final class Handle: @unchecked Sendable {
        public let name: String
        public let fileURL: URL
        private let stateLock = NSLock()
        private var fileDescriptor: Int32

        fileprivate init(name: String, fileURL: URL, fileDescriptor: Int32) {
            self.name = name
            self.fileURL = fileURL
            self.fileDescriptor = fileDescriptor
        }

        public func release() {
            stateLock.lock()
            defer { stateLock.unlock() }
            guard fileDescriptor >= 0 else { return }
            _ = flock(fileDescriptor, LOCK_UN)
            _ = Darwin.close(fileDescriptor)
            fileDescriptor = -1
        }

        deinit { release() }
    }

    public static let sharedOperationName = "immich-operation"

    public let lockDirectoryURL: URL
    private let fileManager: FileManager

    public init(
        lockDirectoryURL: URL = OperationLock.defaultDirectory(),
        fileManager: FileManager = .default
    ) {
        self.lockDirectoryURL = lockDirectoryURL.standardizedFileURL
        self.fileManager = fileManager
    }

    public static func defaultDirectory(fileManager: FileManager = .default) -> URL {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return support.appendingPathComponent("ImmichControl/Locks", isDirectory: true)
    }

    /// Waits asynchronously for an exclusive advisory lock. A zero timeout makes
    /// a single non-blocking attempt; a positive timeout polls without blocking
    /// the app's main actor.
    public func acquire(name: String = OperationLock.sharedOperationName, timeout: TimeInterval = 30) async throws -> Handle {
        try Task.checkCancellation()
        guard Self.isSafeName(name) else { throw Error.invalidName(name) }
        do {
            try fileManager.createDirectory(at: lockDirectoryURL, withIntermediateDirectories: true)
        } catch {
            throw Error.unableToCreate(lockDirectoryURL.path)
        }

        let lockURL = lockDirectoryURL.appendingPathComponent("\(name).lock", isDirectory: false)
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw Error.unableToCreate(lockURL.path) }

        let deadline = Date().addingTimeInterval(max(0, timeout))
        while true {
            if Task.isCancelled {
                _ = Darwin.close(descriptor)
                throw CancellationError()
            }
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                return Handle(name: name, fileURL: lockURL, fileDescriptor: descriptor)
            }

            let lockError = errno
            guard lockError == EWOULDBLOCK || lockError == EAGAIN else {
                _ = Darwin.close(descriptor)
                throw Error.unableToAcquire(name, lockError)
            }
            guard Date() < deadline else {
                _ = Darwin.close(descriptor)
                throw Error.timedOut(name)
            }
            do {
                try await Task.sleep(nanoseconds: 50_000_000)
            } catch {
                _ = Darwin.close(descriptor)
                throw error
            }
        }
    }

    @discardableResult
    public func withLock<T: Sendable>(
        name: String = OperationLock.sharedOperationName,
        timeout: TimeInterval = 30,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        let handle = try await acquire(name: name, timeout: timeout)
        defer { handle.release() }
        return try await operation()
    }

    @discardableResult
    public static func withLock<T: Sendable>(
        name: String = OperationLock.sharedOperationName,
        timeout: TimeInterval = 30,
        lockDirectoryURL: URL = OperationLock.defaultDirectory(),
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        try await OperationLock(lockDirectoryURL: lockDirectoryURL).withLock(
            name: name,
            timeout: timeout,
            operation: operation
        )
    }

    private static func isSafeName(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }
}
