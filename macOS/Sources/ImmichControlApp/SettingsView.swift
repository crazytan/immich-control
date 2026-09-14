import AppKit
import SwiftUI

struct ImmichSettingsView: View {
    @ObservedObject var controller: ImmichAppController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if controller.isDemoMode {
                Label("Sample data — demo mode makes no changes", systemImage: "testtube.2")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
            }
            TabView {
                GeneralSettingsView(controller: controller)
                    .tabItem { Label("General", systemImage: "gearshape") }
                ServerSettingsView(controller: controller)
                    .tabItem { Label("Server", systemImage: "server.rack") }
                BackupSettingsView(controller: controller)
                    .tabItem { Label("Backups", systemImage: "externaldrive.badge.checkmark") }
            }
            .disabled(controller.isDemoMode)
        }
        .frame(width: 560, height: 430)
        .padding(20)
    }
}

private struct GeneralSettingsView: View {
    @ObservedObject var controller: ImmichAppController

    var body: some View {
        Form {
            Section {
                Toggle("Open Immich Control at login", isOn: $controller.launchAppAtLogin)
                    .onChange(of: controller.launchAppAtLogin) { value in
                        controller.setLaunchAppAtLogin(value)
                    }

                Toggle("Start the server after login", isOn: $controller.startServerAtLogin)
                    .onChange(of: controller.startServerAtLogin) { value in
                        controller.setStartServerAtLogin(value)
                    }
                    .help("Runs once at your next macOS login. Opening Immich Control manually never starts the server.")

                Text("This starts the server next time you sign in, even if Immich Control is closed. Opening Immich Control manually leaves the server unchanged.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Login")
            }

            Section {
                LabeledContent("Configuration") {
                    Text(controller.configurationLocation)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(controller.configurationLocation)
                }
                if controller.isDemoMode {
                    Label("Sample data — demo mode does not start services or write settings.", systemImage: "testtube.2")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Storage")
            }

            if let message = controller.errorMessage {
                Section {
                    InlineProblem(message: message, retry: controller.refresh)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ServerSettingsView: View {
    @ObservedObject var controller: ImmichAppController

    var body: some View {
        Form {
            Section {
                TextField("Project folder", text: $controller.projectRootPath)
                    .textFieldStyle(.roundedBorder)
                TextField("Local address", text: $controller.localServerAddress)
                    .textFieldStyle(.roundedBorder)
                    .help("The address opened by the menu-bar app, normally http://localhost:2283.")
            } header: {
                Text("Immich installation")
            }

            Section {
                Picker("Resources", selection: $controller.resourcePreset) {
                    ForEach(ServerResourcePresetChoice.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                Text(controller.resourcePreset.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("CPU and memory limits take effect the next time Colima starts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Colima")
            }

            Section {
                Button("Save Server Settings") {
                    controller.saveServerSettings()
                }
                .disabled(controller.isSavingSettings)

                if controller.isSavingSettings {
                    ProgressView("Saving…")
                        .controlSize(.small)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct BackupSettingsView: View {
    @ObservedObject var controller: ImmichAppController
    @State private var showScheduleMigrationAlert = false
    @State private var r2AccessKeyID = ""
    @State private var r2SecretAccessKey = ""
    @State private var resticPassword = ""

    var body: some View {
        Form {
            ForEach($controller.backupSettings) { $settings in
                BackupTargetSettingsEditor(settings: $settings)
            }

            Section {
                Text("Credentials are stored in your login Keychain and never written to the configuration file. Leave a field blank to retain the current saved value.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SecureField("R2 access key ID", text: $r2AccessKeyID)
                SecureField("R2 secret access key", text: $r2SecretAccessKey)
                SecureField("Restic repository password", text: $resticPassword)
                Text("Changing the Restic password here changes the credential used for future access; it does not re-encrypt existing repository data.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Save Credentials") {
                    controller.saveBackupCredentials(
                        r2AccessKeyID: r2AccessKeyID,
                        r2SecretAccessKey: r2SecretAccessKey,
                        resticPassword: resticPassword
                    )
                    r2AccessKeyID = ""
                    r2SecretAccessKey = ""
                    resticPassword = ""
                }
                .disabled(controller.isSavingSettings)
            } header: {
                Text("Credentials")
            }

            Section {
                Button("Save Backup Settings") {
                    controller.saveBackupSettings()
                }
                .disabled(controller.isSavingSettings)

                if controller.schedulesAreManaged {
                    Label("Backup schedules are managed by Immich Control.", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                    Text("Save settings to apply schedule changes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button("Adopt Existing Backup Schedules…") {
                        showScheduleMigrationAlert = true
                    }
                    .disabled(controller.isMigratingSchedules || controller.isDemoMode)
                    .help("This is the explicit step that transfers the existing LaunchAgent schedule to Immich Control. It never runs automatically.")

                    Text("Adoption is optional. Until you choose it, existing scheduled backup jobs stay outside Immich Control and will not be duplicated; schedule changes above take effect after adoption.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Scheduling")
            }

            if let message = controller.errorMessage {
                Section {
                    InlineProblem(message: message, retry: controller.refresh)
                }
            }
        }
        .formStyle(.grouped)
        .alert("Adopt Existing Backup Schedules?", isPresented: $showScheduleMigrationAlert) {
            Button("Adopt Schedules") { controller.adoptExistingSchedules() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Immich Control will take over the existing backup schedule and avoid duplicate backup runs. This does not run a backup now.")
        }
    }
}

private struct BackupTargetSettingsEditor: View {
    @Binding var settings: BackupSettingsDraft
    @State private var usbSelectionError: String?

    private var title: String { settings.kind.title }

    var body: some View {
        Section {
            Toggle("Enable \(title) backups", isOn: $settings.isEnabled)
            DatePicker("Daily at", selection: $settings.time, displayedComponents: .hourAndMinute)
                .disabled(!settings.isEnabled)

            if settings.kind == .r2 {
                TextField("R2 endpoint", text: $settings.cloudEndpoint)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!settings.isEnabled)
                Text("Existing Keychain credentials are retained. Enter values below only to update them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                TextField("USB mount path", text: $settings.usbVolumeName)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!settings.isEnabled)
                Button("Choose Drive…", action: chooseUSBDrive)
                    .disabled(!settings.isEnabled)
                    .help("Choose the mounted USB volume used for this backup.")
                TextField("Expected volume UUID", text: $settings.expectedUSBVolumeUUID)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!settings.isEnabled)
                Text("The volume UUID prevents a different drive mounted at this path from receiving the backup.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let usbSelectionError {
                    Text(usbSelectionError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            DisclosureGroup("Retention") {
                Stepper("Keep \(settings.retainDaily) daily", value: $settings.retainDaily, in: 0...365)
                Stepper("Keep \(settings.retainWeekly) weekly", value: $settings.retainWeekly, in: 0...520)
                Stepper("Keep \(settings.retainMonthly) monthly", value: $settings.retainMonthly, in: 0...1200)
                Stepper("Keep \(settings.retainYearly) yearly", value: $settings.retainYearly, in: 0...1000)
            }
            .disabled(!settings.isEnabled)
        } header: {
            Label(title, systemImage: settings.kind.symbolName)
        }
    }

    private func chooseUSBDrive() {
        let panel = NSOpenPanel()
        panel.title = "Choose USB Backup Drive"
        panel.message = "Select the mounted drive Immich Control should use for backups."
        panel.prompt = "Use This Drive"
        panel.directoryURL = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        guard panel.runModal() == .OK, let selected = panel.url else { return }
        let components = selected.standardizedFileURL.pathComponents
        guard components.count >= 3, components[1] == "Volumes" else {
            usbSelectionError = "Choose a mounted drive under /Volumes."
            return
        }
        let volumeRoot = URL(fileURLWithPath: "/Volumes/\(components[2])", isDirectory: true)
        guard let values = try? volumeRoot.resourceValues(forKeys: [.volumeUUIDStringKey]),
              let uuid = values.volumeUUIDString,
              !uuid.isEmpty else {
            usbSelectionError = "Could not read a volume UUID from \(volumeRoot.path)."
            return
        }
        settings.usbVolumeName = volumeRoot.path
        settings.expectedUSBVolumeUUID = uuid
        usbSelectionError = nil
    }
}
