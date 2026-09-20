import Cocoa
import Combine
import ImageCaptureCore
@preconcurrency import UserNotifications
import SwiftUI

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSToolbarDelegate, UNUserNotificationCenterDelegate {

    private var statusItem: NSStatusItem!
    private var statusMenu: NSMenu!

    private let ssdMonitor    = SSDMonitor()
    private let deviceMonitor = DeviceMonitor()
    private let backupEngine  = BackupEngine()
    private let dashboardNavigation = DashboardNavigation()

    private var cancellables = Set<AnyCancellable>()
    private var dashboardWindow: NSWindow?
    private var detailWindow: NSWindow?

    private let dashboardToolbarIdentifier = NSToolbar.Identifier("DashboardToolbar")
    private let sidebarToolbarItemIdentifier = NSToolbarItem.Identifier.toggleSidebar

    /// True while the Live Sync Console window is visible.
    @Published var isDetailWindowOpen: Bool = false

    // New-device prompt: non-nil when a previously-unseen device just connected
    @Published var newDeviceCamera: ICCameraDevice? = nil

    // Quick Swiping prompt: non-nil when a connected device has unswiped photos and prompt setting is enabled
    @Published var quickSwipePromptCamera: ICCameraDevice? = nil
    @Published var quickSwipePromptCount: Int = 0

    /// Incremented every time a backup destination is saved.
    /// SwiftUI views observe this to re-read the destination after the panel closes.
    @Published var destinationVersion: Int = 0

    /// Non-nil when the user just changed a backup path while a backup was running or queued.
    /// The value is the device ID whose path changed ("" = global/default destination).
    /// DashboardView observes this to show the "start full backup?" prompt.
    @Published var pathChangedDeviceID: String? = nil

    // Flicker animation while backup is running
    private var flickerTimer: Timer?
    private var flickerOn = false
    private var menuRefreshTask: Task<Void, Never>?
    private var pendingBackupStartTask: Task<Void, Never>?

    // MARK: - Sequential backup queue
    // Jobs waiting to run — each entry is one device + its resolved destination URL.
    private struct BackupJob {
        let camera: ICCameraDevice
        let destination: URL
        let deviceName: String
        let scanMode: BackupScanMode

        var isFullBackup: Bool {
            scanMode != .incremental
        }
    }
    private var backupQueue: [BackupJob] = []
    // The job currently being processed (nil when engine is idle).
    private var activeJob: BackupJob? = nil

    // MARK: - Per-device backup destinations

    /// Key for storing a device-specific backup destination bookmark in UserDefaults.
    private func destBookmarkKey(for deviceID: String) -> String { "backupDest_\(deviceID)" }
    private func destPathKey(for deviceID: String) -> String     { "backupDestPath_\(deviceID)" }
    private func destSMBKey(for deviceID: String) -> String      { "backupDestSMB_\(deviceID)" }

    private func canonicalDestinationPath(_ url: URL) -> String {
        url.standardizedFileURL.path
    }

    private func canonicalDestinationPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private func mountedVolumeRoot(for path: String) -> String? {
        guard path.hasPrefix("/Volumes/") else { return nil }
        let components = (path as NSString).pathComponents
        guard components.count > 2 else { return nil }
        return "/Volumes/\(components[2])"
    }

    private func isMountedVolumesPath(_ path: String) -> Bool {
        guard let volumeRoot = mountedVolumeRoot(for: path) else { return true }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: volumeRoot, isDirectory: &isDir) && isDir.boolValue
    }

    private func urlForStoredDestinationPath(_ path: String) -> URL? {
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    private func storedDeviceDestinationIDs() -> [String] {
        UserDefaults.standard.dictionaryRepresentation().keys.compactMap { key in
            guard key.hasPrefix("backupDestPath_") else { return nil }
            let id = String(key.dropFirst("backupDestPath_".count))
            return id.isEmpty ? nil : id
        }
    }

    private func clearStoredDestination(for deviceID: String) {
        UserDefaults.standard.removeObject(forKey: destBookmarkKey(for: deviceID))
        UserDefaults.standard.removeObject(forKey: destPathKey(for: deviceID))
        UserDefaults.standard.removeObject(forKey: destSMBKey(for: deviceID))
    }

    /// Reads the SMB remote URL from the kernel mount table using statfs.
    /// Returns a string like "smb://server/share" if the path lives on a
    /// mounted SMB share, or nil otherwise.
    static func smbRemoteURL(forPath path: String) -> String? {
        var buf = statfs()
        guard statfs(path, &buf) == 0 else { return nil }
        let fstypeName = withUnsafeBytes(of: &buf.f_fstypename) { ptr -> String in
            let bytes = ptr.bindMemory(to: CChar.self)
            return String(cString: bytes.baseAddress!)
        }
        guard fstypeName == "smbfs" else { return nil }
        let mntfrom = withUnsafeBytes(of: &buf.f_mntfromname) { ptr -> String in
            let bytes = ptr.bindMemory(to: CChar.self)
            return String(cString: bytes.baseAddress!)
        }
        // f_mntfromname for SMB looks like: //user@server/share or //server/share
        guard mntfrom.hasPrefix("//") else { return nil }
        return "smb:" + mntfrom
    }

    /// Returns the raw stored destination path (even if unmounted).
    func rawDestinationPath(for deviceID: String = "") -> String? {
        if !deviceID.isEmpty {
            if let path = UserDefaults.standard.string(forKey: destPathKey(for: deviceID)), !path.isEmpty {
                return path
            }
        }
        if let global = UserDefaults.standard.string(forKey: "backupDestinationPath"), !global.isEmpty {
            return global
        }
        // Fallback: scan for any per-device backup paths
        let dict = UserDefaults.standard.dictionaryRepresentation()
        for (key, value) in dict {
            if key.hasPrefix("backupDestinationPath_"), let valStr = value as? String, !valStr.isEmpty {
                return valStr
            }
        }
        return nil
    }

    /// Returns the saved or derived SMB remote URL string for the given device.
    func resolvedSMBURL(for deviceID: String = "") -> String? {
        // 1. Try device-specific key first, then global key
        let keys = deviceID.isEmpty
            ? ["backupDestSMB_"]
            : [destSMBKey(for: deviceID), "backupDestSMB_"]
        for key in keys {
            if let url = UserDefaults.standard.string(forKey: key), !url.isEmpty {
                return url
            }
        }

        // 2. Fallback: match the destination path of the target device to any device's saved path
        if let targetPath = rawDestinationPath(for: deviceID) {
            let dict = UserDefaults.standard.dictionaryRepresentation()
            for (key, value) in dict {
                if key.hasPrefix("backupDestinationPath_"), let valStr = value as? String, valStr == targetPath {
                    let devID = key.replacingOccurrences(of: "backupDestinationPath_", with: "")
                    if let url = UserDefaults.standard.string(forKey: destSMBKey(for: devID)), !url.isEmpty {
                        return url
                    }
                }
            }
        }

        return nil
    }

    private func deviceLabel(for deviceID: String) -> String {
        if deviceID.isEmpty { return "default backup" }
        return deviceMonitor.connectedDevices.first { $0.id == deviceID }?.name ?? "another device"
    }

    func deviceName(for deviceID: String) -> String? {
        if let dev = deviceMonitor.connectedDevices.first(where: { $0.id == deviceID }) {
            return dev.name
        }
        if let entry = deviceMonitor.deviceHistory.first(where: { $0.id == deviceID }) {
            return entry.name
        }
        return nil
    }

    private func conflictingDeviceName(for deviceID: String, destination url: URL) -> String? {
        let targetPath = canonicalDestinationPath(url)
        let knownIDs = Set(storedDeviceDestinationIDs() + deviceMonitor.connectedDevices.map(\.id))

        for otherID in knownIDs where otherID != deviceID {
            guard let otherURL = resolvedBackupDestination(for: otherID) else { continue }
            if canonicalDestinationPath(otherURL) == targetPath {
                return deviceLabel(for: otherID)
            }
        }

        return nil
    }

    private func conflictingQueuedDeviceName(for deviceID: String, destination url: URL) -> String? {
        let targetPath = canonicalDestinationPath(url)

        if let active = activeJob {
            let activeID = active.camera.uuidString ?? active.camera.name ?? ""
            if activeID != deviceID,
               canonicalDestinationPath(active.destination) == targetPath {
                return active.deviceName
            }
        }

        if let queued = backupQueue.first(where: { job in
            let queuedID = job.camera.uuidString ?? job.camera.name ?? ""
            return queuedID != deviceID && canonicalDestinationPath(job.destination) == targetPath
        }) {
            return queued.deviceName
        }

        return nil
    }

    private func showDestinationConflictAlert(destination url: URL, otherDeviceName: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Choose a Different Folder"
        alert.informativeText = "\(otherDeviceName) is already assigned to:\n\(url.path)\n\nEach device needs its own backup folder so their indexes and files do not mix."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func discardUnavailableVolumeDestinations() {
        // Kept empty to preserve unmounted/unavailable volume destination paths in settings.
    }

    private func resolveSpecificDestination(for deviceID: String) -> URL? {
        if let data = UserDefaults.standard.data(forKey: destBookmarkKey(for: deviceID)) {
            let knownPath = UserDefaults.standard.string(forKey: destPathKey(for: deviceID))
            if let url = AppDelegate.safeResolveBookmark(data, knownPath: knownPath) {
                return url
            }
        }
        if let path = UserDefaults.standard.string(forKey: destPathKey(for: deviceID)),
           !path.isEmpty {
            return urlForStoredDestinationPath(path)
        }
        return nil
    }

    /// Resolve the backup destination for a specific device UUID.
    /// Falls back to other devices with the same name, then to global destination.
    func resolvedBackupDestination(for deviceID: String = "") -> URL? {
        guard !deviceID.isEmpty else {
            if let global = resolvedBackupDestination() {
                return global
            }
            // Scan for any per-device destinations if no global is set
            let dict = UserDefaults.standard.dictionaryRepresentation()
            for (key, value) in dict {
                if key.hasPrefix("backupDestinationBookmark_"), let data = value as? Data {
                    let devID = key.replacingOccurrences(of: "backupDestinationBookmark_", with: "")
                    let knownPath = UserDefaults.standard.string(forKey: destPathKey(for: devID))
                    if let url = AppDelegate.safeResolveBookmark(data, knownPath: knownPath) {
                        return url
                    }
                }
            }
            for (key, value) in dict {
                if key.hasPrefix("backupDestinationPath_"), let path = value as? String, !path.isEmpty {
                    return urlForStoredDestinationPath(path)
                }
            }
            return nil
        }

        // 1. Try directly with deviceID
        if let url = resolveSpecificDestination(for: deviceID) {
            return url
        }

        // 2. Try by matching the name of the device
        if let name = deviceName(for: deviceID) {
            let storedIDs = storedDeviceDestinationIDs()
            for otherID in storedIDs where otherID != deviceID {
                if deviceName(for: otherID) == name {
                    if let url = resolveSpecificDestination(for: otherID) {
                        return url
                    }
                }
            }
        }

        // 3. Fallback to global destination (legacy / single-device mode)
        return resolvedBackupDestination()
    }

    func isDestinationAvailable(_ url: URL?) -> Bool {
        guard let url else { return false }
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    /// Resolves a security-scoped bookmark WITHOUT letting macOS attempt to
    /// auto-remount an unreachable network share. Resolving a security-scoped
    /// bookmark whose target lives on an SMB/AFP volume that isn't currently
    /// mounted can trigger the OS's own "There was a problem connecting to
    /// the server" alert and a long network timeout — this happens inside
    /// CoreServices, outside try/catch, and can stall app launch for minutes.
    ///
    /// To avoid touching the bookmark resolver at all when the destination is
    /// unreachable, we use the plain path string already saved alongside
    /// every bookmark (see setBackupDestination) as a cheap, local, instant
    /// pre-check via FileManager. Only if that confirms the volume is mounted
    /// do we resolve the bookmark itself.
    static func safeResolveBookmark(_ data: Data, knownPath: String?) -> URL? {
        if let path = knownPath, !path.isEmpty, path.hasPrefix("/Volumes/") {
            let components = (path as NSString).pathComponents
            if components.count > 2 {
                let volumeRoot = "/Volumes/\(components[2])"
                var isDir: ObjCBool = false
                let mounted = FileManager.default.fileExists(atPath: volumeRoot, isDirectory: &isDir) && isDir.boolValue
                guard mounted else {
                    print("AppDelegate: Skipping bookmark resolution — volume \(volumeRoot) not mounted.")
                    return nil
                }
            }
        }

        var stale = false
        return try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                        relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    /// Persist a backup destination for a specific device UUID.
    @discardableResult
    func setBackupDestination(_ url: URL, for deviceID: String = "") -> Bool {
        if let conflict = conflictingDeviceName(for: deviceID, destination: url) {
            showDestinationConflictAlert(destination: url, otherDeviceName: conflict)
            return false
        }

        // Detect if work was already in progress so we can prompt after saving
        let hadActiveWork = (activeJob != nil) || !backupQueue.isEmpty

        if deviceID.isEmpty {
            // Global destination (used when no device context is known)
            if let data = try? url.bookmarkData(options: .withSecurityScope,
                                                includingResourceValuesForKeys: nil,
                                                relativeTo: nil) {
                UserDefaults.standard.set(data, forKey: "backupDestinationBookmark")
            }
            UserDefaults.standard.set(url.path, forKey: "backupDestinationPath")
            // Capture SMB remote URL while the volume is mounted
            if let smbURL = AppDelegate.smbRemoteURL(forPath: url.path) {
                UserDefaults.standard.set(smbURL, forKey: "backupDestSMB_")
            }

            // A global change should not leave currently connected devices pinned
            // to an older per-device folder that the Settings UI no longer shows.
            for dev in deviceMonitor.connectedDevices {
                clearStoredDestination(for: dev.id)
            }
        } else {
            if let data = try? url.bookmarkData(options: .withSecurityScope,
                                                includingResourceValuesForKeys: nil,
                                                relativeTo: nil) {
                UserDefaults.standard.set(data, forKey: destBookmarkKey(for: deviceID))
            }
            UserDefaults.standard.set(url.path, forKey: destPathKey(for: deviceID))
            // Capture SMB remote URL while the volume is mounted
            if let smbURL = AppDelegate.smbRemoteURL(forPath: url.path) {
                UserDefaults.standard.set(smbURL, forKey: destSMBKey(for: deviceID))
            }
        }
        destinationVersion += 1
        ssdMonitor.checkConnectedVolumes()

        // Cancel any running or queued jobs — they reference the old destination
        if hadActiveWork {
            if activeJob != nil {
                backupEngine.interruptBackup()
                activeJob = nil
            }
            backupQueue.removeAll()
            // Signal the dashboard to show the "start fresh?" prompt
            pathChangedDeviceID = deviceID
        }

        drainQueue()
        rebuildMenu()
        return true
    }

    /// Expose public trigger for checking SSD volumes
    func triggerSSDCheck() {
        ssdMonitor.checkConnectedVolumes()
    }

    // MARK: - Backup destination URL (global / legacy single-device)

    var backupDestinationURL: URL? {
        guard let data = UserDefaults.standard.data(forKey: "backupDestinationBookmark") else { return nil }
        let knownPath = UserDefaults.standard.string(forKey: "backupDestinationPath")
        return AppDelegate.safeResolveBookmark(data, knownPath: knownPath)
    }

    @discardableResult
    func setBackupDestination(_ url: URL) -> Bool {
        setBackupDestination(url, for: "")
    }

    func resolvedBackupDestination() -> URL? {
        if let url = backupDestinationURL { return url }
        if let path = UserDefaults.standard.string(forKey: "backupDestinationPath"), !path.isEmpty {
            return urlForStoredDestinationPath(path)
        }
        return nil
    }

    func isDestinationOnSSD(for deviceID: String = "") -> Bool {
        guard let dest = resolvedBackupDestination(for: deviceID) else {
            return false
        }
        let target = ssdMonitor.targetSSDName.trimmingCharacters(in: .whitespacesAndNewlines)
        if target.isEmpty {
            return false
        }
        return dest.path.hasPrefix("/Volumes/\(target)")
    }

    // MARK: - Per-Device Settings Management

    func mediaType(for deviceID: String) -> Int {
        if !deviceID.isEmpty, let val = UserDefaults.standard.object(forKey: "deviceMediaType_\(deviceID)") as? Int {
            return val
        }
        return UserDefaults.standard.integer(forKey: "backupMediaType")
    }

    func setMediaType(_ value: Int, for deviceID: String) {
        if deviceID.isEmpty {
            UserDefaults.standard.set(value, forKey: "backupMediaType")
        } else {
            UserDefaults.standard.set(value, forKey: "deviceMediaType_\(deviceID)")
        }
        destinationVersion += 1
    }

    func organizeByYear(for deviceID: String) -> Bool {
        if !deviceID.isEmpty, let val = UserDefaults.standard.object(forKey: "deviceOrganizeByYear_\(deviceID)") as? Bool {
            return val
        }
        return UserDefaults.standard.object(forKey: "organizeByYear") == nil ? true : UserDefaults.standard.bool(forKey: "organizeByYear")
    }

    func setOrganizeByYear(_ value: Bool, for deviceID: String) {
        if deviceID.isEmpty {
            UserDefaults.standard.set(value, forKey: "organizeByYear")
        } else {
            UserDefaults.standard.set(value, forKey: "deviceOrganizeByYear_\(deviceID)")
        }
        destinationVersion += 1
    }

    func organizeByMonth(for deviceID: String) -> Bool {
        if !deviceID.isEmpty, let val = UserDefaults.standard.object(forKey: "deviceOrganizeByMonth_\(deviceID)") as? Bool {
            return val
        }
        return UserDefaults.standard.object(forKey: "organizeByMonth") == nil ? true : UserDefaults.standard.bool(forKey: "organizeByMonth")
    }

    func setOrganizeByMonth(_ value: Bool, for deviceID: String) {
        if deviceID.isEmpty {
            UserDefaults.standard.set(value, forKey: "organizeByMonth")
        } else {
            UserDefaults.standard.set(value, forKey: "deviceOrganizeByMonth_\(deviceID)")
        }
        destinationVersion += 1
    }

    func skipEditedDuplicates(for deviceID: String) -> Bool {
        if !deviceID.isEmpty, let val = UserDefaults.standard.object(forKey: "deviceSkipEditedDuplicates_\(deviceID)") as? Bool {
            return val
        }
        return UserDefaults.standard.bool(forKey: "skipEditedDuplicates")
    }

    func setSkipEditedDuplicates(_ value: Bool, for deviceID: String) {
        if deviceID.isEmpty {
            UserDefaults.standard.set(value, forKey: "skipEditedDuplicates")
        } else {
            UserDefaults.standard.set(value, forKey: "deviceSkipEditedDuplicates_\(deviceID)")
        }
        destinationVersion += 1
    }

    func forgetDevice(id: String) {
        guard !id.isEmpty else { return }
        UserDefaults.standard.removeObject(forKey: destBookmarkKey(for: id))
        UserDefaults.standard.removeObject(forKey: destPathKey(for: id))
        UserDefaults.standard.removeObject(forKey: destSMBKey(for: id))
        UserDefaults.standard.removeObject(forKey: "deviceMediaType_\(id)")
        UserDefaults.standard.removeObject(forKey: "deviceOrganizeByYear_\(id)")
        UserDefaults.standard.removeObject(forKey: "deviceOrganizeByMonth_\(id)")
        UserDefaults.standard.removeObject(forKey: "deviceSkipEditedDuplicates_\(id)")
        deviceMonitor.removeHistory(id: id)
        destinationVersion += 1
        rebuildMenu()
    }


    // MARK: - App Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Start hidden from the Dock — show the Dock icon only when the window is open,
        // exactly like RememberMyWindows. This allows the app to stay alive as a
        // background process and observe system dark-mode changes at all times.
        NSApp.setActivationPolicy(.accessory)

        setupMainMenu()
        configureNotifications()
        LaunchAtLoginManager.shared.cleanupLegacyLoginItem()
        setupAppearanceObserver()

        // Apply in-app language preference (set by the Language picker in Settings)
        if let lang = UserDefaults.standard.string(forKey: "appLanguage"), !lang.isEmpty {
            UserDefaults.standard.set([lang], forKey: "AppleLanguages")
        }

        discardUnavailableVolumeDestinations()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "arrow.triangle.2.circlepath.camera",
            accessibilityDescription: "Photo Backup"
        )

        statusMenu = NSMenu()
        statusItem.menu = statusMenu

        ssdMonitor.onStatusChanged = { [weak self] in
            self?.drainQueue()
            self?.rebuildMenu()
        }

        // Called when a device's content catalog is fully available → handle auto backup or quick swipe prompt
        deviceMonitor.onDeviceReady = { [weak self] camera in
            self?.handleDeviceReady(camera)
            self?.rebuildMenu()
        }

        deviceMonitor.onDeviceRemoved = { [weak self] camera in
            self?.handleDeviceRemoved(camera)
            self?.rebuildMenu()
        }

        deviceMonitor.onAccessRestricted = { [weak self] camera in
            guard let self, self.activeJob?.camera === camera else { return }
            self.backupEngine.pauseForDeviceLock()
            self.rebuildMenu()
        }

        deviceMonitor.onAccessRestrictionRemoved = { [weak self] camera in
            guard let self, self.activeJob?.camera === camera else { return }
            let needsRestart = self.backupEngine.resumeFromDeviceLock()
            if needsRestart, let job = self.activeJob {
                // Scan was cancelled by the lock — re-enqueue the job so it can
                // restart from scratch now that the device is unlocked again.
                self.activeJob = nil
                self.backupQueue.insert(job, at: 0)
                self.drainQueue()
            }
            self.rebuildMenu()
        }

        deviceMonitor.onNewDevice = { [weak self] camera in
            guard let self else { return }
            self.newDeviceCamera = camera
            self.openDashboard()
            self.rebuildMenu()
        }

        backupEngine.onVerifiedFileBackup = { [weak self] file in
            guard UserDefaults.standard.bool(forKey: "deleteAfterBackup") else { return }
            self?.deviceMonitor.deleteFileFromDevice(file)
        }

        // Watch engine state — when a job finishes, start the next one
        backupEngine.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                if case .copying = state {
                    self?.scheduleMenuRefresh()
                } else {
                    self?.menuRefreshTask?.cancel()
                    self?.menuRefreshTask = nil
                    self?.rebuildMenu()
                }
                self?.updateFlicker(for: state)
                switch state {
                case .completed, .failed:
                    self?.activeJob = nil
                    self?.drainQueue()
                case .idle:
                    if self?.activeJob != nil {
                        self?.activeJob = nil
                        self?.drainQueue()
                    }
                default:
                    break
                }
            }
            .store(in: &cancellables)

        deviceMonitor.start()

        if UserDefaults.standard.object(forKey: "autoBackupActive") == nil {
            UserDefaults.standard.set(true, forKey: "autoBackupActive")
        }
        if UserDefaults.standard.object(forKey: "promptQuickSwipeBeforeSync") == nil {
            UserDefaults.standard.set(true, forKey: "promptQuickSwipeBeforeSync")
        }
        if UserDefaults.standard.object(forKey: "openFolderAfterBackup") == nil {
            UserDefaults.standard.set(true, forKey: "openFolderAfterBackup")
        }
        if UserDefaults.standard.object(forKey: "deleteAfterBackup") == nil {
            UserDefaults.standard.set(false, forKey: "deleteAfterBackup")
        }
        if UserDefaults.standard.object(forKey: "folderOrganization") == nil {
            UserDefaults.standard.set(1, forKey: "folderOrganization")  // default: Year/Month
        }
        if UserDefaults.standard.object(forKey: "autoLaunchOnDeviceConnect") == nil {
            LaunchAtLoginManager.shared.setEnabled(true)
        }

        rebuildMenu()
        openDashboard()
    }

    private func configureNotifications() {
        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.delegate = self
        notificationCenter.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else {
                if settings.alertSetting == .disabled {
                    print("AppDelegate: Notifications are allowed, but macOS is set to deliver them quietly.")
                }
                return
            }

            notificationCenter.requestAuthorization(options: [.alert, .sound, .badge]) { _, error in
                if let error {
                    print("AppDelegate: Notification authorization error: \(error.localizedDescription)")
                }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep the process alive so we can keep observing dark-mode changes and
        // responding to USB-trigger launches — same pattern as RememberMyWindows.
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        backupEngine.interruptBackup()
        deviceMonitor.stop()
        stopFlicker()
    }

    /// Applies the selected language while the app is running so AppKit menus
    /// and future localized lookups update without requiring a relaunch.
    func applyAppLanguagePreference(_ languageCode: String) {
        UserDefaults.standard.set([languageCode], forKey: "AppleLanguages")
        rebuildMenu()
    }

    // MARK: - Queue management

    /// Count unswiped/unprocessed photos & videos on the device visible within the Quick Swiping
    /// "This Week" date window — matches exactly what Quick Swiping shows by default.
    func unswipedReviewCount(for camera: ICCameraDevice) -> Int {
        let files = deviceMonitor.files(for: camera)
        let nonMediaExtensions: Set<String> = ["aae", "plist", "thm", "lrv"]
        let cachedIDs = ReviewProcessedCache.shared.processedIDs
        let now = Date()
        let weekAgo = Calendar.autoupdatingCurrent.date(byAdding: .day, value: -7, to: now) ?? now

        // 1. Filter to media only
        let mediaFiles = files.filter { file in
            guard file.isPhotoFile || file.isVideoFile else { return false }
            let ext = (file.name as NSString?)?.pathExtension.lowercased() ?? ""
            return !nonMediaExtensions.contains(ext)
        }

        // 2. Collect edited-duplicate base names (IMG_E → skips original), same logic as Quick Swiping
        let editedBaseNames = Set(mediaFiles.compactMap { file -> String? in
            guard let name = file.name, BackupEngine.isIOSEditedDuplicate(name: name) else { return nil }
            let base = name.replacingOccurrences(of: "IMG_E", with: "IMG_")
            return (base as NSString).deletingPathExtension.uppercased()
        })

        // 3. Apply date (this week), dedup edited, and exclude already-processed
        var seenKeys = Set<String>()
        return mediaFiles.filter { file in
            guard let name = file.name else { return false }

            // Skip originals that have an edited version
            let nameWithoutExt = (name as NSString).deletingPathExtension.uppercased()
            if !BackupEngine.isIOSEditedDuplicate(name: name),
               editedBaseNames.contains(nameWithoutExt) { return false }

            // Date filter: this week
            guard let captureDate = file.effectiveCaptureDate,
                  captureDate >= weekAgo, captureDate <= now else { return false }

            // Not already swiped
            let key = backupEngine.manifestKey(for: file)
            guard !cachedIDs.contains(key) else { return false }

            return seenKeys.insert(key).inserted
        }.count
    }

    /// Handles a ready device: if auto-backup is active, either prompts the user for Quick Swiping
    /// (if unswiped photos exist and prompt setting is on) or directly enqueues the backup.
    private func handleDeviceReady(_ camera: ICCameraDevice) {
        guard UserDefaults.standard.bool(forKey: "autoBackupActive") else { return }

        let shouldPrompt = UserDefaults.standard.bool(forKey: "promptQuickSwipeBeforeSync")
        if shouldPrompt {
            let unswiped = unswipedReviewCount(for: camera)
            if unswiped > 0 {
                // Avoid re-prompting if backup is already pending or active
                let alreadyPending = backupQueue.contains { $0.camera === camera }
                let isActive       = activeJob?.camera === camera
                guard !alreadyPending && !isActive else { return }

                quickSwipePromptCamera = camera
                quickSwipePromptCount = unswiped
                openDashboard()
                return
            }
        }

        enqueueDevice(camera)
    }

    /// Enqueue a camera directly, bypassing the Quick Swiping prompt check.
    func enqueueDeviceDirectly(_ camera: ICCameraDevice) {
        quickSwipePromptCamera = nil
        enqueueDevice(camera)
    }

    /// Enqueue a camera for backup (if auto-backup is on and a destination exists).
    /// If the engine is idle right now, start immediately; otherwise append to queue.
    private func enqueueDevice(_ camera: ICCameraDevice) {
        guard UserDefaults.standard.bool(forKey: "autoBackupActive") else { return }

        let deviceID = camera.uuidString ?? camera.name ?? ""
        guard let destURL = resolvedBackupDestination(for: deviceID) else {
            print("AppDelegate: No backup destination for \(camera.name ?? "device") — skipping auto-enqueue")
            return
        }

        if let conflict = conflictingQueuedDeviceName(for: deviceID, destination: destURL) {
            showDestinationConflictAlert(destination: destURL, otherDeviceName: conflict)
            print("AppDelegate: Skipping \(camera.name ?? "device") because \(conflict) already targets \(destURL.path)")
            return
        }

        // If a previous backup was interrupted by disconnect, clear it so the new job can start.
        if case .interrupted = backupEngine.state {
            backupEngine.cancelInterrupted()
        }

        // Avoid duplicates: don't re-enqueue if this device is already waiting or active
        let alreadyPending = backupQueue.contains { $0.camera === camera }
        let isActive       = activeJob?.camera === camera
        guard !alreadyPending && !isActive else { return }

        let job = BackupJob(camera: camera, destination: destURL, deviceName: camera.name ?? "Device", scanMode: .incremental)
        print("AppDelegate: Enqueuing backup for \(job.deviceName) → \(destURL.lastPathComponent)")
        backupQueue.append(job)
        drainQueue()
    }

    /// Remove any queued jobs for cameras that are no longer connected.
    private func handleDeviceRemoved(_ camera: ICCameraDevice) {
        if quickSwipePromptCamera === camera {
            quickSwipePromptCamera = nil
            quickSwipePromptCount = 0
        }
        backupQueue.removeAll { $0.camera === camera }
        // If the active job's device disconnected, interrupt the backup gracefully.
        if let active = activeJob, active.camera === camera {
            backupEngine.interruptBackup()
            activeJob = nil          // allow drainQueue once device reconnects
            drainQueue()
        }
    }

    /// Start the next queued job only when no device is actively transferring.
    private func drainQueue() {
        guard activeJob == nil else { return }                  // busy
        guard canStartNextBackup else { return }                // engine busy
        guard !backupQueue.isEmpty else { return }              // nothing waiting

        let job = backupQueue.removeFirst()
        activeJob = job
        print("AppDelegate: Starting backup for \(job.deviceName) → \(job.destination.lastPathComponent)")
        _ = job.destination.startAccessingSecurityScopedResource()
        pendingBackupStartTask?.cancel()
        pendingBackupStartTask = Task { @MainActor [weak self] in
            // Finish the pressed-button animation before beginning any setup
            // work that ImageCaptureCore needs on the main actor.
            await Task.yield()
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard let self,
                  !Task.isCancelled,
                  self.activeJob?.camera === job.camera else { return }
            self.pendingBackupStartTask = nil
            self.backupEngine.startBackup(
                camera: job.camera,
                destinationURL: job.destination,
                scanMode: job.scanMode
            )
            self.rebuildMenu()
        }
        rebuildMenu()
    }

    /// The status-menu contents do not need a redraw for every transferred file.
    /// Coalescing them keeps the desktop UI responsive during fast backups.
    private func scheduleMenuRefresh() {
        guard menuRefreshTask == nil else { return }
        menuRefreshTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 400_000_000)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.menuRefreshTask = nil
            self.rebuildMenu()
        }
    }

    private var canStartNextBackup: Bool {
        switch backupEngine.state {
        case .idle, .completed, .failed:
            return true
        case .scanning, .copying, .paused, .interrupted:
            return false
        }
    }

    var activeBackupDeviceName: String? {
        activeJob?.deviceName
    }

    var waitingBackupDeviceNames: [String] {
        backupQueue.map(\.deviceName)
    }

    var isBackupRunning: Bool {
        switch backupEngine.state {
        case .scanning, .copying, .paused:
            return true
        default:
            return false
        }
    }

    // MARK: - Icon Flicker

    private func updateFlicker(for state: BackupState) {
        switch state {
        case .copying, .scanning: startFlicker()
        default:                  stopFlicker()
        }
    }

    private func startFlicker() {
        guard flickerTimer == nil else { return }
        flickerOn = false
        flickerTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.flickerOn.toggle()
                let name = self.flickerOn
                    ? "arrow.triangle.2.circlepath.camera.fill"
                    : "arrow.triangle.2.circlepath.camera"
                self.statusItem.button?.image = NSImage(
                    systemSymbolName: name, accessibilityDescription: "Photo Backup"
                )
            }
        }
    }

    private func stopFlicker() {
        flickerTimer?.invalidate()
        flickerTimer = nil
        flickerOn = false
        statusItem.button?.image = NSImage(
            systemSymbolName: "arrow.triangle.2.circlepath.camera",
            accessibilityDescription: "Photo Backup"
        )
    }

    // MARK: - Menu

    private func rebuildMenu() {
        statusMenu.removeAllItems()

        let statusTitle = menuStatusTitle
        let titleItem = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        statusMenu.addItem(titleItem)
        statusMenu.addItem(.separator())

        // Queue status lines (when multiple devices are waiting)
        if !backupQueue.isEmpty {
            for (i, job) in backupQueue.enumerated() {
                let qItem = NSMenuItem(
                    title: "  \(i + 1). \(job.deviceName) — waiting",
                    action: nil, keyEquivalent: ""
                )
                qItem.isEnabled = false
                statusMenu.addItem(qItem)
            }
            statusMenu.addItem(.separator())
        }

        let dashboardItem = NSMenuItem(title: "Open Dashboard", action: #selector(openDashboard), keyEquivalent: "d")
        dashboardItem.target = self
        statusMenu.addItem(dashboardItem)

        if case .idle = backupEngine.state, backupQueue.isEmpty {
            let activeDeviceID = deviceMonitor.activeCamera?.uuidString ?? deviceMonitor.activeCamera?.name ?? ""
            let canBackup = deviceMonitor.activeCamera != nil && isDestinationAvailable(resolvedBackupDestination(for: activeDeviceID))
            let backupItem = NSMenuItem(title: "Backup Now", action: #selector(forceBackup), keyEquivalent: "b")
            backupItem.target = self
            backupItem.isEnabled = canBackup
            statusMenu.addItem(backupItem)
        }

        // Show cancel option when a backup was interrupted
        if case .interrupted = backupEngine.state {
            let cancelItem = NSMenuItem(title: "Cancel Interrupted Backup", action: #selector(cancelInterruptedBackup), keyEquivalent: "")
            cancelItem.target = self
            statusMenu.addItem(cancelItem)
        }

        statusMenu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        statusMenu.addItem(quitItem)
    }

    private var menuStatusTitle: String {
        if let job = activeJob {
            switch backupEngine.state {
            case .idle:
                return "Preparing \(job.deviceName)…"
            case .scanning:
                return "Scanning \(job.deviceName)…"
            case .copying(let cur, let tot, let pct):
                return "\(job.deviceName): \(cur)/\(tot) (\(Int(pct * 100))%)"
            case .paused(let cur, let tot, let pct):
                return "⏸️ \(job.deviceName) (Paused): \(cur)/\(tot) (\(Int(pct * 100))%)"
            case .interrupted(let cur, let tot, _):
                return "📵 \(job.deviceName) disconnected — \(cur)/\(tot) saved"
            case .completed(let n):
                let waiting = backupQueue.count
                let suffix = waiting > 0 ? " · \(waiting) queued" : ""
                return n == 0 ? "Up to date\(suffix)" : "Done — \(n) files\(suffix)"
            case .failed:
                return "⚠️ \(job.deviceName) failed"
            }
        }
        switch backupEngine.state {
        case .idle:
            let devices = deviceMonitor.connectedDevices.filter { $0.isReady }.count
            let devLabel = devices == 0 ? "No Device" : "\(devices) Device\(devices == 1 ? "" : "s") ✓"
            let activeDeviceID = deviceMonitor.activeCamera?.uuidString ?? deviceMonitor.activeCamera?.name ?? ""
            let onSSD = isDestinationOnSSD(for: activeDeviceID)
            let ssd = onSSD ? (ssdMonitor.isSSDConnected ? "SSD ✓" : "No SSD") : "Local ✓"
            let queued = backupQueue.isEmpty ? "" : " · \(backupQueue.count) queued"
            return "\(devLabel)  ·  \(ssd)\(queued)"
        case .completed(let n):
            return n == 0 ? "Up to date" : "Done — \(n) new files"
        case .interrupted(let cur, let tot, _):
            return "📵 Backup interrupted — \(cur)/\(tot) saved"
        case .failed:
            return "⚠️ Backup failed — open dashboard"
        default:
            return "Working…"
        }
    }

    // MARK: - Actions

    @objc func chooseBackupFolder() {
        chooseBackupFolder(for: deviceMonitor.connectedDeviceID)
    }

    func chooseBackupFolder(for deviceID: String) {
        let panel = NSOpenPanel()
        panel.title = "Choose Backup Destination"
        panel.message = deviceID.isEmpty
            ? "Select the folder where photos will be backed up:"
            : "Select the backup folder for this device:"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.level = .floating

        if panel.runModal() == .OK, let url = panel.url {
            setBackupDestination(url, for: deviceID)
        }
    }

    @objc func reconnectDevice() {
        deviceMonitor.requestReconnect()
    }

    @objc func forceBackup() {
        requestForceBackupChoice(scanMode: .incremental)
    }

    func triggerForceBackup(isFullBackup: Bool) {
        requestForceBackupChoice(scanMode: isFullBackup ? .deepValidation : .incremental)
    }

    func triggerForceBackup(scanMode: BackupScanMode) {
        requestForceBackupChoice(scanMode: scanMode)
    }

    func requestForceBackupChoice(isFullBackup: Bool = false) {
        requestForceBackupChoice(scanMode: isFullBackup ? .deepValidation : .incremental)
    }

    func requestForceBackupChoice(scanMode: BackupScanMode) {
        let eligibleDevices = deviceMonitor.connectedDevices.filter {
            $0.isReady &&
            $0.isCatalogLoaded &&
            isDestinationAvailable(resolvedBackupDestination(for: $0.id))
        }

        guard eligibleDevices.count > 1 else {
            if let device = eligibleDevices.first {
                enqueueForceBackup(for: device.id, scanMode: scanMode)
            } else {
                enqueueForceBackup(scanMode: scanMode)
            }
            return
        }

        let alert = NSAlert()
        alert.messageText = "Choose Device to Sync"
        alert.informativeText = "More than one device is connected. Select which device to sync now."
        alert.alertStyle = .informational

        for device in eligibleDevices {
            alert.addButton(withTitle: device.name)
        }
        alert.addButton(withTitle: "All Devices")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        let selectedIndex = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue

        guard selectedIndex >= 0 else { return }
        if selectedIndex < eligibleDevices.count {
            enqueueForceBackup(for: eligibleDevices[selectedIndex].id, scanMode: scanMode)
        } else if selectedIndex == eligibleDevices.count {
            enqueueForceBackup(scanMode: scanMode)
        }
    }

    func enqueueForceBackup(isFullBackup: Bool) {
        enqueueForceBackup(scanMode: isFullBackup ? .deepValidation : .incremental)
    }

    func enqueueForceBackup(scanMode: BackupScanMode) {
        if case .interrupted = backupEngine.state {
            backupEngine.cancelInterrupted()
        }
        // Force-enqueue all ready cameras that aren't already queued/active
        for dev in deviceMonitor.connectedDevices where dev.isReady && dev.isCatalogLoaded {
            let alreadyPending = backupQueue.contains { $0.camera === dev.camera }
            let isActive       = activeJob?.camera === dev.camera
            guard !alreadyPending && !isActive else { continue }

            let deviceID = dev.id
            guard let destURL = resolvedBackupDestination(for: deviceID), isDestinationAvailable(destURL) else { continue }
            if let conflict = conflictingQueuedDeviceName(for: deviceID, destination: destURL) {
                showDestinationConflictAlert(destination: destURL, otherDeviceName: conflict)
                continue
            }
            let job = BackupJob(camera: dev.camera, destination: destURL, deviceName: dev.name, scanMode: scanMode)
            backupQueue.append(job)
        }
        drainQueue()
        openDetailWindow()
    }

    func enqueueForceBackup(for deviceID: String, isFullBackup: Bool) {
        enqueueForceBackup(for: deviceID, scanMode: isFullBackup ? .deepValidation : .incremental)
    }

    func enqueueForceBackup(for deviceID: String, scanMode: BackupScanMode) {
        if case .interrupted = backupEngine.state {
            backupEngine.cancelInterrupted()
        }

        guard let dev = deviceMonitor.connectedDevices.first(where: {
            $0.id == deviceID && $0.isReady && $0.isCatalogLoaded
        }) else { return }

        let alreadyPending = backupQueue.contains { $0.camera === dev.camera }
        let isActive       = activeJob?.camera === dev.camera
        guard !alreadyPending && !isActive else {
            drainQueue()
            return
        }

        guard let destURL = resolvedBackupDestination(for: dev.id), isDestinationAvailable(destURL) else { return }
        if let conflict = conflictingQueuedDeviceName(for: dev.id, destination: destURL) {
            showDestinationConflictAlert(destination: destURL, otherDeviceName: conflict)
            return
        }

        let job = BackupJob(camera: dev.camera, destination: destURL, deviceName: dev.name, scanMode: scanMode)
        backupQueue.append(job)
        drainQueue()
        openDetailWindow()
    }

    @objc func cancelInterruptedBackup() {
        backupEngine.cancelInterrupted()
        rebuildMenu()
    }

    @objc private func quitApp() {
        requestQuit()
    }

    func requestQuit() {
        if isBackupRunning {
            let alert = NSAlert()
            alert.messageText = "Quit iPhone Backup Center?"
            alert.informativeText = "A backup is currently running. Quitting now will stop the current backup."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Quit App")
            alert.addButton(withTitle: "Keep Running")

            guard alert.runModal() == .alertFirstButtonReturn else { return }
            backupEngine.interruptBackup()
        }

        NSApplication.shared.terminate(self)
    }

    @objc func openDashboard() {
        NSApp.setActivationPolicy(.regular)

        if dashboardWindow == nil {
            let rootView = DashboardView(
                ssdMonitor: ssdMonitor,
                deviceMonitor: deviceMonitor,
                backupEngine: backupEngine,
                navigation: dashboardNavigation,
                appDelegate: self,
                onClose: { [weak self] in self?.requestQuit() },
                onForceBackup: { [weak self] isFull in self?.triggerForceBackup(isFullBackup: isFull) },
                onChooseFolder: { [weak self] in self?.chooseBackupFolder() },
                onReconnect: { [weak self] in self?.reconnectDevice() }
            )

            let controller = NSHostingController(rootView: rootView)
            // Explicitly make the hosting view's layer transparent so AppKit doesn't
            // paint a default background that would block the .behindWindow frosted-glass effect.
            controller.view.wantsLayer = true
            controller.view.layer?.backgroundColor = CGColor(red: 0, green: 0, blue: 0, alpha: 0)
            let window = NSWindow(contentViewController: controller)

            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.delegate = self
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.isReleasedWhenClosed = false
            window.minSize = dashboardMinimumSize()
            window.setContentSize(dashboardInitialSize())
            // Let SwiftUI manage the toolbar natively via DashboardView's .toolbar modifier
            // configureDashboardToolbar(for: window)

            self.dashboardWindow = window
        }

        dashboardWindow?.center()
        dashboardWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Main Application Menu

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // ── App menu ────────────────────────────────────────────────────────
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu

        appMenu.addItem(withTitle: "About iPhonePhotosBackup",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())

        let openItem = NSMenuItem(title: "Open Dashboard",
                                  action: #selector(openDashboard),
                                  keyEquivalent: "o")
        openItem.keyEquivalentModifierMask = .command
        appMenu.addItem(openItem)

        appMenu.addItem(.separator())

        appMenu.addItem(withTitle: "Hide iPhonePhotosBackup",
                        action: #selector(NSApplication.hide(_:)),
                        keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others",
                                          action: #selector(NSApplication.hideOtherApplications(_:)),
                                          keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All",
                        action: #selector(NSApplication.unhideAllApplications(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())

        appMenu.addItem(withTitle: "Quit iPhonePhotosBackup",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")

        // ── Window menu ─────────────────────────────────────────────────────
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize",
                           action: #selector(NSWindow.miniaturize(_:)),
                           keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom",
                           action: #selector(NSWindow.zoom(_:)),
                           keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front",
                           action: #selector(NSApplication.arrangeInFront(_:)),
                           keyEquivalent: "")

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    // MARK: - Native Dashboard Toolbar

    private func configureDashboardToolbar(for window: NSWindow) {
        let toolbar = NSToolbar(identifier: dashboardToolbarIdentifier)
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [sidebarToolbarItemIdentifier]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [sidebarToolbarItemIdentifier]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard itemIdentifier == sidebarToolbarItemIdentifier else { return nil }

        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = "Sidebar"
        item.paletteLabel = "Show or Hide Sidebar"
        item.toolTip = "Show or Hide Sidebar"
        // AppKit supplies the standard toolbar chrome; only the icon and
        // dashboard action need to be supplied by the app.
        item.image = NSImage(systemSymbolName: "sidebar.leading", accessibilityDescription: "Show or Hide Sidebar")
        item.target = self
        item.action = #selector(toggleDashboardSidebar)
        return item
    }

    @objc private func toggleDashboardSidebar() {
        openDashboard()
        dashboardNavigation.toggleSidebar()
    }

    @objc func openDetailWindow() {
        NSApp.setActivationPolicy(.regular)

        if detailWindow == nil {
            let detailView = LiveBackupDetailView(
                backupEngine: backupEngine,
                deviceMonitor: deviceMonitor,
                onClose: { [weak self] in self?.closeDetailWindow() }
            )
            let controller = NSHostingController(rootView: detailView)
            controller.view.wantsLayer = true
            controller.view.layer?.backgroundColor = CGColor(red: 0, green: 0, blue: 0, alpha: 0.0)
            let window = NSWindow(contentViewController: controller)

            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.delegate = self
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 480, height: 520)
            window.level = .floating

            // Match the dashboard window's exact frame so console opens on top of it
            if let dashFrame = dashboardWindow?.frame {
                window.setFrame(dashFrame, display: false)
            } else {
                // Fallback: center on screen at a generous default size
                let windowSize = NSSize(width: 760, height: 640)
                window.setContentSize(windowSize)
                if let screen = NSScreen.main {
                    let sf = screen.visibleFrame
                    window.setFrameOrigin(NSPoint(
                        x: sf.midX - windowSize.width / 2,
                        y: sf.midY - windowSize.height / 2
                    ))
                }
            }

            // Track open/close state
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.isDetailWindowOpen = false
                    self?.detailWindow = nil
                }
            }

            self.detailWindow = window
        }

        isDetailWindowOpen = true
        detailWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func closeDetailWindow() {
        detailWindow?.performClose(nil)
        dashboardWindow?.makeKeyAndOrderFront(nil)
    }

    private func dashboardMinimumSize() -> NSSize {
        guard let visibleFrame = NSScreen.main?.visibleFrame else {
            return NSSize(width: 480, height: 640)
        }

        return NSSize(
            width: min(480, max(360, visibleFrame.width - 80)),
            height: min(630, max(520, visibleFrame.height - 80))
        )
    }

    private func dashboardInitialSize() -> NSSize {
        guard let visibleFrame = NSScreen.main?.visibleFrame else {
            return NSSize(width: 820, height: 760)
        }

        let storedAppearance = UserDefaults.standard.string(forKey: "appAppearanceV2") ?? ""
        let isLiquidGlass = storedAppearance == "liquidGlass"

        let minimumSize = dashboardMinimumSize()
        if isLiquidGlass {
            return NSSize(
                width: max(680, min(760, visibleFrame.width - 80)),
                height: max(600, min(680, visibleFrame.height - 80))
            )
        }
        return NSSize(
            width: max(minimumSize.width, min(600, visibleFrame.width - 80)),
            height: max(minimumSize.height, min(940, visibleFrame.height - 80))
        )
    }

    @objc func windowWillClose(_ notification: Notification) {
        let closingWindow = notification.object as? NSWindow
        if closingWindow === dashboardWindow {
            dashboardWindow = nil
        } else if closingWindow === detailWindow {
            detailWindow = nil
        }
        // Retreat to .accessory (background) if no user-facing windows remain open.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            let hasVisible = NSApp.windows.contains { $0.isVisible && !($0 is NSPanel) }
            if !hasVisible {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        if #available(macOS 11.0, *) {
            completionHandler([.banner, .sound, .badge, .list])
        } else {
            completionHandler([.alert, .sound, .badge])
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            self.openDashboard()
        }
        completionHandler()
    }

    // MARK: - Dark Mode App Icon

    private func setupAppearanceObserver() {
        updateApplicationIconForCurrentAppearance()

        DistributedNotificationCenter.default()
            .publisher(for: NSNotification.Name("AppleInterfaceThemeChangedNotification"))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateApplicationIconForCurrentAppearance()
            }
            .store(in: &cancellables)

        NSApp.publisher(for: \.effectiveAppearance)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateApplicationIconForCurrentAppearance()
            }
            .store(in: &cancellables)
    }

    private func updateApplicationIconForCurrentAppearance() {
        let isDark: Bool
        if let best = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) {
            isDark = (best == .darkAqua)
        } else {
            isDark = NSApp.effectiveAppearance.name.rawValue.lowercased().contains("dark")
        }

        let iconName = isDark ? "AppIcon-Dark" : "AppIcon"
        if let iconURL = Bundle.main.url(forResource: iconName, withExtension: "icns") ??
                         Bundle.main.url(forResource: iconName, withExtension: "png"),
           let image = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = image
        } else if !isDark {
            NSApp.applicationIconImage = nil
        }
    }
}

// MARK: - Custom NSApplication: suppress the macOS loading/busy cursor

/// Subclassing NSApplication and overriding `sendEvent` to intercept cursor-update
/// events is the correct way to prevent macOS from showing the spinning-wheel cursor.
final class NoWaitCursorApplication: NSApplication {
    override func sendEvent(_ event: NSEvent) {
        super.sendEvent(event)
        // After every cursor-update event, force the arrow cursor so the system
        // never shows the spinning-wait indicator.
        if event.type == .cursorUpdate {
            NSCursor.arrow.set()
        }
    }
}
