import AppKit
import Darwin
import Foundation
import ImmichCore
import ServiceManagement
import SwiftUI

/// The app-facing coordinator. Operational work is deliberately delegated to
/// the bundled helper so a backup survives closing the menu-bar process. This
/// object only holds presentation state and non-secret configuration drafts.
@MainActor
final class ImmichAppController: ObservableObject {
    @Published private(set) var serverState: ServerPresentationState
    @Published private(set) var backupSummaries: [BackupPresentation]
    @Published var launchAppAtLogin: Bool
    @Published var startServerAtLogin: Bool
    @Published var projectRootPath: String
    @Published var localServerAddress: String
    @Published var resourcePreset: ServerResourcePresetChoice
    @Published var backupSettings: [BackupSettingsDraft]
    @Published private(set) var errorMessage: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isServerOperation = false
    @Published private(set) var isSavingSettings = false
    @Published private(set) var isMigratingSchedules = false
    @Published private(set) var schedulesAreManaged: Bool

    let isDemoMode: Bool
    let configurationLocation: String

    private let configurationStore: ImmichConfigurationStore
    private let statusStore: StatusStore
    private let activityStore = BackupActivityStore()
    private let scheduler = BackupScheduler()
    private var configuration: ImmichConfiguration
    private var activeBackupKinds = Set<BackupKind>()
    private var activeHelperProcesses: [UUID: (process: Process, log: FileHandle)] = [:]
    private var statusRefreshTimer: Timer?

    private static let backupScheduleOwnershipKey = "ImmichControl.hasAdoptedBackupSchedules"

    init(demoMode: Bool) {
        self.isDemoMode = demoMode

        if demoMode {
            let demoRoot = URL(fileURLWithPath: "/Users/demo/server/immich-app", isDirectory: true)
            let demoConfiguration = Self.demoConfiguration(root: demoRoot)
            configurationStore = ImmichConfigurationStore(
                fileURL: URL(fileURLWithPath: "/dev/null"),
                installationRoot: demoRoot
            )
            statusStore = StatusStore(fileURL: URL(fileURLWithPath: "/dev/null"))
            configuration = demoConfiguration
            configurationLocation = "Demo mode — settings are not saved"
            serverState = .running
            backupSummaries = Self.demoBackups()
            launchAppAtLogin = false
            startServerAtLogin = false
            projectRootPath = demoRoot.path
            localServerAddress = demoConfiguration.server.localServerURL
            resourcePreset = .balanced
            backupSettings = Self.makeBackupDrafts(configuration: demoConfiguration)
            schedulesAreManaged = false
            return
        }

        let store = ImmichConfigurationStore()
        configurationStore = store
        configurationLocation = store.fileURL.path

        let loaded: ImmichConfiguration
        var loadingError: String?
        do {
            loaded = try store.load()
        } catch {
            let root = LegacyConfigurationImporter.findInstallationRoot()
            loaded = ImmichConfiguration.default(projectRoot: root)
            loadingError = "Could not load Immich Control settings: \(error.localizedDescription)"
        }
        configuration = loaded
        statusStore = StatusStore(
            legacyLogsDirectoryURL: loaded.server.projectRootURL.appendingPathComponent("logs", isDirectory: true)
        )
        serverState = .unavailable("Checking server status…")
        backupSummaries = []
        launchAppAtLogin = Self.isAppRegisteredForLogin()
        startServerAtLogin = loaded.server.launchServerAtLogin
        projectRootPath = loaded.server.projectRootPath
        localServerAddress = loaded.server.localServerURL
        resourcePreset = Self.presentationPreset(for: loaded.server.resourcePreset)
        backupSettings = Self.makeBackupDrafts(configuration: loaded)
        let detectedManagedSchedules = Self.detectManagedSchedules()
        schedulesAreManaged = detectedManagedSchedules || UserDefaults.standard.bool(forKey: Self.backupScheduleOwnershipKey)
        if detectedManagedSchedules {
            UserDefaults.standard.set(true, forKey: Self.backupScheduleOwnershipKey)
        }
        errorMessage = loadingError
        refreshBackupSummaries()
        installStatusRefreshTimer()
    }

    var menuSymbolName: String {
        switch serverState {
        case .running: return "photo.stack.fill"
        case .starting: return "arrow.triangle.2.circlepath.circle.fill"
        case .stopped: return "photo.stack"
        case .unavailable, .unhealthy: return "exclamationmark.triangle.fill"
        }
    }

    var serverActionTitle: String {
        switch serverState {
        case .running, .unhealthy: return "Stop Server"
        case .starting: return "Starting…"
        case .stopped: return "Start Server"
        case .unavailable: return "Server Unavailable"
        }
    }

    var canControlServer: Bool {
        guard !isDemoMode else { return false }
        if case .unavailable = serverState { return false }
        return true
    }

    var canOpenImmich: Bool {
        !isDemoMode && configuration.server.localURL != nil
    }

    /// Refresh is read-only. It never reloads the configuration, so it cannot
    /// overwrite edits a person has made in the Settings window before saving.
    func refresh() {
        guard !isDemoMode, !isRefreshing else { return }
        isRefreshing = true
        let snapshot = configuration
        Task { [weak self] in
            let status = await ServerController(configuration: snapshot).status()
            await MainActor.run {
                guard let self else { return }
                self.serverState = Self.presentationState(for: status)
                self.refreshBackupSummaries()
                self.isRefreshing = false
            }
        }
    }

    func performServerAction() {
        guard !isDemoMode, !isServerOperation else { return }
        let action: String
        switch serverState {
        case .running, .unhealthy:
            action = "stop"
        case .stopped:
            action = "start"
            serverState = .starting
        case .starting, .unavailable:
            return
        }

        isServerOperation = true
        do {
            try launchHelper(arguments: ["server", action]) { [weak self] terminationStatus in
                guard let self else { return }
                self.isServerOperation = false
                if terminationStatus != 0 {
                    self.errorMessage = "The background server \(action) failed. See \(self.helperLogURL.path) for details."
                }
                self.refresh()
            }
        } catch {
            isServerOperation = false
            errorMessage = "Could not start the background server \(action): \(error.localizedDescription)"
            refresh()
        }
    }

    func runBackup(_ kind: BackupKind) {
        guard !isDemoMode,
              !activeBackupKinds.contains(kind),
              let target = configuration.backups.first(where: { Self.presentationKind(for: $0.kind) == kind })
        else { return }
        guard target.enabled else {
            errorMessage = "Enable \(kind.title) backups in Settings before starting one."
            return
        }

        activeBackupKinds.insert(kind)
        refreshBackupSummaries()
        do {
            try launchHelper(arguments: ["backup", kind.rawValue]) { [weak self] terminationStatus in
                guard let self else { return }
                self.activeBackupKinds.remove(kind)
                if terminationStatus != 0 {
                    self.errorMessage = "The \(kind.title) backup failed. See \(self.helperLogURL.path) for details."
                }
                self.refreshBackupSummaries()
            }
        } catch {
            activeBackupKinds.remove(kind)
            errorMessage = "Could not start the background \(kind.title) backup: \(error.localizedDescription)"
            refreshBackupSummaries()
        }
    }

    func openImmich() {
        guard !isDemoMode, let url = configuration.server.localURL else {
            errorMessage = "The configured local Immich address is invalid."
            return
        }
        NSWorkspace.shared.open(url)
    }

    func setLaunchAppAtLogin(_ enabled: Bool) {
        guard !isDemoMode else {
            launchAppAtLogin = false
            errorMessage = "Demo mode does not change login items."
            return
        }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            let registered = Self.isAppRegisteredForLogin()
            launchAppAtLogin = registered
            if enabled, !registered {
                errorMessage = "macOS needs approval to open Immich Control at login. Enable it in System Settings › General › Login Items."
            }
        } catch {
            launchAppAtLogin = Self.isAppRegisteredForLogin()
            errorMessage = "Could not update the login item: \(error.localizedDescription)"
        }
    }

    func setStartServerAtLogin(_ enabled: Bool) {
        guard !isSavingSettings else {
            startServerAtLogin = configuration.server.launchServerAtLogin
            return
        }
        guard !isDemoMode else {
            startServerAtLogin = false
            errorMessage = "Demo mode does not change login behavior."
            return
        }
        let previous = configuration.server.launchServerAtLogin
        let previousConfiguration = configuration
        startServerAtLogin = enabled
        var candidate = configuration
        candidate.server.launchServerAtLogin = enabled
        isSavingSettings = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let helper = try self.helperExecutableURL()
                try await self.scheduler.setServerLoginEnabled(enabled, configuration: candidate, helperURL: helper)
                try self.configurationStore.save(candidate)
                self.configuration = candidate
                self.startServerAtLogin = enabled
            } catch {
                // The scheduler writes the agent before configuration. Restore the
                // previous agent when the configuration commit cannot be made.
                if let helper = try? self.helperExecutableURL() {
                    try? await self.scheduler.setServerLoginEnabled(
                        previous,
                        configuration: previousConfiguration,
                        helperURL: helper
                    )
                }
                self.startServerAtLogin = previous
                self.errorMessage = "Could not update server login behavior: \(error.localizedDescription)"
            }
            self.isSavingSettings = false
        }
    }

    func saveServerSettings() {
        guard !isSavingSettings else { return }
        var candidate = configuration
        candidate.server.setProjectRoot(URL(fileURLWithPath: projectRootPath, isDirectory: true))
        candidate.server.localServerURL = localServerAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        candidate.server.resourcePreset = Self.corePreset(for: resourcePreset)
        guard candidate.server.launchServerAtLogin, !isDemoMode else {
            save(candidate, action: "server settings")
            return
        }
        let previousConfiguration = configuration
        isSavingSettings = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let helper = try self.helperExecutableURL()
                try await self.scheduler.setServerLoginEnabled(true, configuration: candidate, helperURL: helper)
                try self.configurationStore.save(candidate)
                self.applySavedConfiguration(candidate)
            } catch {
                if let helper = try? self.helperExecutableURL() {
                    try? await self.scheduler.setServerLoginEnabled(true, configuration: previousConfiguration, helperURL: helper)
                }
                self.errorMessage = "Could not save server settings: \(error.localizedDescription)"
            }
            self.isSavingSettings = false
        }
    }

    func saveBackupSettings() {
        guard !isSavingSettings else { return }
        var candidate = configuration
        for draft in backupSettings {
            guard let index = candidate.backups.firstIndex(where: { Self.presentationKind(for: $0.kind) == draft.kind }) else {
                continue
            }
            let components = Calendar.current.dateComponents([.hour, .minute], from: draft.time)
            candidate.backups[index].enabled = draft.isEnabled
            candidate.backups[index].schedule.hour = components.hour ?? candidate.backups[index].schedule.hour
            candidate.backups[index].schedule.minute = components.minute ?? candidate.backups[index].schedule.minute
            candidate.backups[index].retention = RetentionPolicy(
                keepDaily: draft.retainDaily,
                keepWeekly: draft.retainWeekly,
                keepMonthly: draft.retainMonthly,
                keepYearly: draft.retainYearly
            )
            switch draft.kind {
            case .r2:
                candidate.backups[index].repository = draft.cloudEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            case .usb:
                let previousMount = candidate.backups[index].usbMountPath ?? ""
                let updatedMount = draft.usbVolumeName.trimmingCharacters(in: .whitespacesAndNewlines)
                candidate.backups[index].usbMountPath = updatedMount
                candidate.backups[index].usbVolumeUUID = draft.expectedUSBVolumeUUID.trimmingCharacters(in: .whitespacesAndNewlines)
                if candidate.backups[index].repository.hasPrefix(previousMount + "/") {
                    let suffix = String(candidate.backups[index].repository.dropFirst(previousMount.count))
                    candidate.backups[index].repository = updatedMount + suffix
                } else {
                    candidate.backups[index].repository = URL(fileURLWithPath: updatedMount, isDirectory: true)
                        .appendingPathComponent("ImmichBackup/restic", isDirectory: true)
                        .path
                }
            }
        }
        guard hasManagedBackupSchedules, !isDemoMode else {
            save(candidate, action: "backup settings")
            return
        }
        let previousConfiguration = configuration
        isSavingSettings = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let helper = try self.helperExecutableURL()
                try await self.scheduler.syncBackupSchedules(configuration: candidate, helperURL: helper)
                try self.configurationStore.save(candidate)
                self.applySavedConfiguration(candidate)
            } catch {
                if let helper = try? self.helperExecutableURL() {
                    try? await self.scheduler.syncBackupSchedules(configuration: previousConfiguration, helperURL: helper)
                }
                self.errorMessage = "Could not save backup settings: \(error.localizedDescription)"
            }
            self.isSavingSettings = false
        }
    }

    func saveBackupCredentials(r2AccessKeyID: String, r2SecretAccessKey: String, resticPassword: String) {
        guard !isSavingSettings else { return }
        guard !isDemoMode else {
            errorMessage = "Demo mode does not write Keychain items."
            return
        }
        let values: [(String, BackupSecret)] = [
            (r2AccessKeyID, .r2AccessKeyID),
            (r2SecretAccessKey, .r2SecretAccessKey),
            (resticPassword, .resticPassword),
        ]
        guard values.contains(where: { !$0.0.isEmpty }) else { return }
        isSavingSettings = true
        defer { isSavingSettings = false }
        do {
            let secrets = KeychainStore()
            for (value, secret) in values where !value.isEmpty {
                try secrets.write(value, secret: secret)
            }
            backupSettings = Self.makeBackupDrafts(configuration: configuration)
        } catch {
            errorMessage = "Could not save the backup credential: \(error.localizedDescription)"
        }
    }

    func adoptExistingSchedules() {
        guard !isDemoMode, !isMigratingSchedules else { return }
        isMigratingSchedules = true
        let candidate = configuration
        Task { [weak self] in
            guard let self else { return }
            do {
                let helper = try self.helperExecutableURL()
                try await self.scheduler.migrateLegacySchedules(configuration: candidate, helperURL: helper)
                self.schedulesAreManaged = true
                UserDefaults.standard.set(true, forKey: Self.backupScheduleOwnershipKey)
            } catch {
                self.errorMessage = "Could not adopt existing backup schedules: \(error.localizedDescription)"
            }
            self.isMigratingSchedules = false
        }
    }

    private func save(_ candidate: ImmichConfiguration, action: String) {
        guard !isSavingSettings else { return }
        isSavingSettings = true
        defer { isSavingSettings = false }
        if isDemoMode {
            configuration = candidate
            backupSettings = Self.makeBackupDrafts(configuration: candidate)
            return
        }
        do {
            try configurationStore.save(candidate)
            applySavedConfiguration(candidate)
        } catch {
            errorMessage = "Could not save \(action): \(error.localizedDescription)"
        }
    }

    private func refreshBackupSummaries() {
        if isDemoMode { return }
        do {
            if let stale = try activityStore.takeStaleActivity() {
                _ = try statusStore.record(
                    targetID: stale.targetID,
                    outcome: .error,
                    message: "A backup was interrupted while \(stale.stage.rawValue.lowercased())."
                )
            }
            let currentActivity = try activityStore.currentActivity()
            let statuses = try statusStore.allStatuses()
            backupSummaries = configuration.backups.compactMap { target in
                guard let kind = Self.presentationKind(for: target.kind) else { return nil }
                let status = statuses.first(where: { $0.targetID == target.id })
                let isRunning = activeBackupKinds.contains(kind) || currentActivity?.targetID == target.id
                return BackupPresentation(
                    kind: kind,
                    isEnabled: target.enabled,
                    state: Self.presentationState(for: status, isRunning: isRunning),
                    lastSuccessfulBackup: status?.lastSuccessAt,
                    scheduleDescription: Self.scheduleDescription(target.schedule),
                    isRunning: isRunning
                )
            }
        } catch {
            backupSummaries = configuration.backups.compactMap { target in
                guard let kind = Self.presentationKind(for: target.kind) else { return nil }
                return BackupPresentation(
                    kind: kind,
                    isEnabled: target.enabled,
                    state: .unavailable("Could not read saved backup status."),
                    lastSuccessfulBackup: nil,
                    scheduleDescription: Self.scheduleDescription(target.schedule),
                    isRunning: activeBackupKinds.contains(kind)
                )
            }
            errorMessage = "Could not read backup status: \(error.localizedDescription)"
        }
    }

    private var helperLogURL: URL {
        let directory = StatusStore.defaultURL().deletingLastPathComponent()
            .appendingPathComponent("Logs", isDirectory: true)
        return directory.appendingPathComponent("ImmichControlHelper.log", isDirectory: false)
    }

    private var hasManagedBackupSchedules: Bool {
        schedulesAreManaged
    }

    private func applySavedConfiguration(_ saved: ImmichConfiguration) {
        configuration = saved
        projectRootPath = saved.server.projectRootPath
        localServerAddress = saved.server.localServerURL
        resourcePreset = Self.presentationPreset(for: saved.server.resourcePreset)
        startServerAtLogin = saved.server.launchServerAtLogin
        backupSettings = Self.makeBackupDrafts(configuration: saved)
        refreshBackupSummaries()
    }

    private func installStatusRefreshTimer() {
        statusRefreshTimer?.invalidate()
        statusRefreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshBackupSummaries()
            }
        }
    }

    private func launchHelper(arguments: [String], finished: @escaping @MainActor (Int32) -> Void) throws {
        let executable = try helperExecutableURL()
        let logURL = helperLogURL
        try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = Darwin.open(logURL.path, O_WRONLY | O_CREAT | O_APPEND, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw HelperLaunchError.logUnavailable(logURL.path)
        }
        let log = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)

        let process = Process()
        process.executableURL = executable
        process.arguments = ["--root", configuration.server.projectRootPath] + arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = log
        process.standardError = log
        let token = UUID()
        process.terminationHandler = { [weak self] process in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.activeHelperProcesses[token]?.log.closeFile()
                self.activeHelperProcesses[token] = nil
                finished(process.terminationStatus)
            }
        }
        do {
            try process.run()
            activeHelperProcesses[token] = (process, log)
        } catch {
            log.closeFile()
            throw error
        }
    }

    private func helperExecutableURL() throws -> URL {
        let appHelper = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/immich-helper", isDirectory: false)
        if FileManager.default.isExecutableFile(atPath: appHelper.path) { return appHelper }
        if let sibling = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("immich-helper", isDirectory: false),
           FileManager.default.isExecutableFile(atPath: sibling.path) {
            return sibling
        }
        throw HelperLaunchError.helperUnavailable
    }

    private static func isAppRegisteredForLogin() -> Bool {
        switch SMAppService.mainApp.status {
        case .enabled: return true
        case .notFound, .notRegistered, .requiresApproval: return false
        @unknown default: return false
        }
    }

    private static func presentationState(for status: ServerStatus) -> ServerPresentationState {
        switch status {
        case let .unavailable(reason): return .unavailable(reason.errorDescription ?? "Server status is unavailable.")
        case .starting: return .starting
        case .running: return .running
        case let .unhealthy(message): return .unhealthy(message)
        case .stopped: return .stopped
        }
    }

    private static func presentationState(for status: BackupTargetStatus?, isRunning: Bool) -> BackupPresentationState {
        if isRunning { return .running }
        guard let status else { return .unknown }
        switch status.outcome {
        case .success: return .succeeded
        case .skipped: return .skipped(status.message)
        case .error: return .failed(status.message)
        }
    }

    private static func presentationKind(for kind: BackupTargetKind) -> BackupKind? {
        switch kind {
        case .r2: return .r2
        case .usb: return .usb
        }
    }

    private static func presentationPreset(for preset: ResourcePreset) -> ServerResourcePresetChoice {
        switch preset.name.lowercased() {
        case ResourcePreset.compact.name.lowercased(): return .compact
        case ResourcePreset.performance.name.lowercased(): return .performance
        default: return .balanced
        }
    }

    private static func corePreset(for preset: ServerResourcePresetChoice) -> ResourcePreset {
        switch preset {
        case .compact: return .compact
        case .balanced: return .balanced
        case .performance: return .performance
        }
    }

    private static func makeBackupDrafts(configuration: ImmichConfiguration) -> [BackupSettingsDraft] {
        configuration.backups.compactMap { target in
            guard let kind = presentationKind(for: target.kind) else { return nil }
            let date = Calendar.current.date(from: DateComponents(hour: target.schedule.hour, minute: target.schedule.minute)) ?? Date()
            return BackupSettingsDraft(
                kind: kind,
                isEnabled: target.enabled,
                time: date,
                retainDaily: target.retention.keepDaily,
                retainWeekly: target.retention.keepWeekly,
                retainMonthly: target.retention.keepMonthly,
                retainYearly: target.retention.keepYearly,
                usbVolumeName: target.usbMountPath ?? "/Volumes/MediaUSB",
                expectedUSBVolumeUUID: target.usbVolumeUUID ?? "",
                cloudEndpoint: target.repository,
                // Do not query login Keychain while opening Settings. Checking a
                // locked Keychain can block or prompt; blank fields below retain
                // credentials already stored under the legacy service name.
                isCredentialConfigured: false
            )
        }
    }

    private static func scheduleDescription(_ schedule: BackupSchedule) -> String {
        guard !schedule.weekdays.isEmpty else { return "Schedule disabled" }
        let time = String(format: "%02d:%02d", schedule.hour, schedule.minute)
        return schedule.weekdays.count == 7 ? "Daily at \(time)" : "Scheduled at \(time)"
    }

    private static func demoConfiguration(root: URL) -> ImmichConfiguration {
        var configuration = ImmichConfiguration.default(projectRoot: root)
        configuration.backups.indices.forEach { configuration.backups[$0].enabled = true }
        configuration.backups[0].repository = "s3:https://example.r2.cloudflarestorage.com/immich-backup/restic"
        configuration.backups[1].usbVolumeUUID = "17927BC2-3325-31CA-92E2-D8967475B2BE"
        return configuration
    }

    /// A migration moves legacy plists aside with this extension. That durable
    /// marker keeps ownership clear even if every app-managed backup schedule is
    /// subsequently disabled and its generated plist is removed.
    private static func detectManagedSchedules(fileManager: FileManager = .default) -> Bool {
        let directory = BackupScheduler.defaultLaunchAgentsDirectory()
        let legacyDisabled = [
            BackupScheduler.legacyR2Label,
            BackupScheduler.legacyUSBLabel,
        ].contains {
            fileManager.fileExists(
                atPath: directory
                    .appendingPathComponent("\($0).plist.immich-control-disabled", isDirectory: false)
                    .path
            )
        }
        if legacyDisabled { return true }
        return [BackupTargetKind.r2, .usb].contains {
            fileManager.fileExists(
                atPath: directory
                    .appendingPathComponent("\($0 == .r2 ? BackupScheduler.r2Label : BackupScheduler.usbLabel).plist", isDirectory: false)
                    .path
            )
        }
    }

    private static func demoBackups() -> [BackupPresentation] {
        let now = Date()
        return [
            BackupPresentation(
                kind: .r2,
                isEnabled: true,
                state: .succeeded,
                lastSuccessfulBackup: now.addingTimeInterval(-86_400),
                scheduleDescription: "Daily at 03:15",
                isRunning: false
            ),
            BackupPresentation(
                kind: .usb,
                isEnabled: true,
                state: .skipped("The expected USB backup drive is not connected."),
                lastSuccessfulBackup: now.addingTimeInterval(-172_800),
                scheduleDescription: "Daily at 05:15",
                isRunning: false
            ),
        ]
    }
}

private enum HelperLaunchError: LocalizedError {
    case helperUnavailable
    case logUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .helperUnavailable:
            return "The bundled immich-helper executable is unavailable. Rebuild or reinstall Immich Control."
        case let .logUnavailable(path):
            return "The helper log could not be opened at \(path)."
        }
    }
}
