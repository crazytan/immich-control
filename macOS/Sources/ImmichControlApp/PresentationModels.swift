import Foundation

/// Presentation-only state. Keeping these types separate from the configuration
/// file means the UI can describe unavailable and in-progress work honestly,
/// without inventing an operational state from a partially loaded config.
enum ServerPresentationState: Equatable {
    case unavailable(String)
    case stopped
    case starting
    case running
    case unhealthy(String)

    var title: String {
        switch self {
        case .unavailable: return "Unavailable"
        case .stopped: return "Stopped"
        case .starting: return "Starting"
        case .running: return "Running"
        case .unhealthy: return "Needs attention"
        }
    }

    var detail: String? {
        switch self {
        case let .unavailable(message), let .unhealthy(message): return message
        case .starting: return "Starting Colima and Immich…"
        case .stopped, .running: return nil
        }
    }

    var symbolName: String {
        switch self {
        case .unavailable, .unhealthy: return "exclamationmark.triangle.fill"
        case .stopped: return "stop.circle.fill"
        case .starting: return "arrow.triangle.2.circlepath.circle.fill"
        case .running: return "checkmark.circle.fill"
        }
    }
}

enum BackupPresentationState: Equatable {
    case unknown
    case ready
    case running
    case succeeded
    case skipped(String)
    case failed(String)
    case unavailable(String)

    var title: String {
        switch self {
        case .unknown: return "Not checked"
        case .ready: return "Ready"
        case .running: return "Backing up"
        case .succeeded: return "Last backup succeeded"
        case .skipped: return "Skipped"
        case .failed: return "Failed"
        case .unavailable: return "Unavailable"
        }
    }

    var detail: String? {
        switch self {
        case let .skipped(message), let .failed(message), let .unavailable(message): return message
        case .unknown, .ready, .running, .succeeded: return nil
        }
    }

    var symbolName: String {
        switch self {
        case .unknown: return "questionmark.circle"
        case .ready, .succeeded: return "checkmark.circle.fill"
        case .running: return "arrow.triangle.2.circlepath.circle.fill"
        case .skipped: return "arrow.right.circle"
        case .failed, .unavailable: return "exclamationmark.triangle.fill"
        }
    }
}

enum BackupKind: String, CaseIterable, Identifiable {
    case r2
    case usb

    var id: String { rawValue }

    var title: String {
        switch self {
        case .r2: return "Cloudflare R2"
        case .usb: return "USB drive"
        }
    }

    var symbolName: String {
        switch self {
        case .r2: return "cloud.fill"
        case .usb: return "externaldrive.fill"
        }
    }
}

struct BackupPresentation: Identifiable, Equatable {
    let kind: BackupKind
    var isEnabled: Bool
    var state: BackupPresentationState
    var lastSuccessfulBackup: Date?
    var scheduleDescription: String
    var isRunning: Bool

    var id: BackupKind { kind }
}

enum ServerResourcePresetChoice: String, CaseIterable, Identifiable {
    case balanced
    case compact
    case performance

    var id: String { rawValue }

    var title: String {
        switch self {
        case .balanced: return "Balanced"
        case .compact: return "Compact"
        case .performance: return "Performance"
        }
    }

    var detail: String {
        switch self {
        case .balanced: return "4 CPU · 8 GiB memory. Recommended limits for a personal photo server."
        case .compact: return "2 CPU · 4 GiB memory. Lower use when the Mac is busy."
        case .performance: return "6 CPU · 12 GiB memory. Faster processing with more room for Immich."
        }
    }
}

struct BackupSettingsDraft: Identifiable, Equatable {
    let kind: BackupKind
    var isEnabled: Bool
    var time: Date
    var retainDaily: Int
    var retainWeekly: Int
    var retainMonthly: Int
    var retainYearly: Int
    var usbVolumeName: String
    var expectedUSBVolumeUUID: String
    var cloudEndpoint: String
    var isCredentialConfigured: Bool

    var id: BackupKind { kind }
}
