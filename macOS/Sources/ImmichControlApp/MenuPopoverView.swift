import AppKit
import SwiftUI

struct MenuPopoverView: View {
    @ObservedObject var controller: ImmichAppController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if controller.isDemoMode {
                Label("Sample data — demo mode", systemImage: "testtube.2")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Sample data. Demo mode makes no changes.")
            }

            ServerSummary(state: controller.serverState)

            if let message = controller.errorMessage {
                InlineProblem(message: message, retry: controller.refresh)
            }

            HStack(spacing: 8) {
                Button(controller.serverActionTitle, action: controller.performServerAction)
                    .keyboardShortcut(.defaultAction)
                    .disabled(controller.isServerOperation || !controller.canControlServer)
                Button("Open Immich", action: controller.openImmich)
                    .disabled(!controller.canOpenImmich)
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("Backups")
                    .font(.headline)

                ForEach(controller.backupSummaries) { backup in
                    BackupSummaryCard(backup: backup, isActionAvailable: !controller.isDemoMode) {
                        controller.runBackup(backup.kind)
                    }
                }
            }

            Divider()

            HStack {
                Button("Refresh", action: controller.refresh)
                    .disabled(controller.isRefreshing || controller.isDemoMode)
                Spacer()
                settingsButton
                Button("Quit", action: MenuPopoverView.quit)
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 360)
        .task {
            controller.refresh()
        }
    }

    @ViewBuilder
    private var settingsButton: some View {
        if #available(macOS 14.0, *) {
            SettingsLink {
                Text("Settings…")
            }
        } else {
            Button("Settings…", action: MenuPopoverView.openSettings)
        }
    }

    private static func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func quit() {
        NSApp.terminate(nil)
    }
}
