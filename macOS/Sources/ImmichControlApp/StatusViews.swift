import SwiftUI

struct StatusPill: View {
    enum Tone {
        case positive
        case neutral
        case warning
        case negative
        case active

        var tint: Color {
            switch self {
            case .positive: return .green
            case .neutral: return .secondary
            case .warning: return .orange
            case .negative: return .red
            case .active: return .blue
            }
        }
    }

    let text: String
    let symbolName: String
    let tone: Tone

    var body: some View {
        Label(text, systemImage: symbolName)
            .font(.caption.weight(.medium))
            .foregroundStyle(tone.tint)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityElement(children: .combine)
    }
}

extension ServerPresentationState {
    var pillTone: StatusPill.Tone {
        switch self {
        case .running: return .positive
        case .starting: return .active
        case .stopped: return .neutral
        case .unavailable, .unhealthy: return .negative
        }
    }
}

extension BackupPresentationState {
    var pillTone: StatusPill.Tone {
        switch self {
        case .succeeded, .ready: return .positive
        case .running: return .active
        case .skipped: return .warning
        case .failed, .unavailable: return .negative
        case .unknown: return .neutral
        }
    }
}

struct ServerSummary: View {
    let state: ServerPresentationState

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "photo.stack.fill")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text("Immich server")
                    .font(.headline)
                StatusPill(text: state.title, symbolName: state.symbolName, tone: state.pillTone)
                if let detail = state.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Immich server, \(state.title)\(state.detail.map { ", \($0)" } ?? "")")
    }
}

struct BackupSummaryCard: View {
    let backup: BackupPresentation
    var isActionAvailable = true
    let action: () -> Void

    private var lastBackupText: String {
        guard let date = backup.lastSuccessfulBackup else { return "No completed backup recorded" }
        return "Last success \(date.formatted(.relative(presentation: .named)))"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: backup.kind.symbolName)
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(backup.kind.title)
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 8)
                    StatusPill(
                        text: backup.state.title,
                        symbolName: backup.state.symbolName,
                        tone: backup.state.pillTone
                    )
                }
                Text(lastBackupText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let detail = backup.state.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(backup.state.pillTone.tint)
                        .fixedSize(horizontal: false, vertical: true)
                } else if backup.isEnabled {
                    Text(backup.scheduleDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Scheduled backups are turned off")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Button(action: action) {
                if backup.isRunning {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 20, height: 20)
                } else {
                    Image(systemName: "play.fill")
                }
            }
            .buttonStyle(.borderless)
            .disabled(backup.isRunning || !backup.isEnabled || !isActionAvailable)
            .help(backup.isEnabled ? "Back up \(backup.kind.title) now" : "Enable this backup in Settings first")
            .accessibilityLabel("Back up \(backup.kind.title) now")
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
    }
}

struct InlineProblem: View {
    let message: String
    var retry: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(message)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            if let retry {
                Button("Try Again", action: retry)
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
