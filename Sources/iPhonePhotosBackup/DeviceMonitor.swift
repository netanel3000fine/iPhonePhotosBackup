// this file handles the detection of the iPhone and the management of the camera devices
import Foundation
import ImageCaptureCore
import Combine
import AVFoundation
import ImageIO

// MARK: - Device History

/// A lightweight record of a device that has previously connected.
struct DeviceHistoryEntry: Identifiable, Codable, Equatable {
    let id: String      // Same UUID key used in ConnectedDevice
    var name: String
    var lastConnected: Date
}

// MARK: - Per-device state

struct ConnectedDevice: Identifiable {
    let id: String          // UUID string from ICDevice.uuidString, or name as fallback
    let camera: ICCameraDevice
    var name: String
    var isReady: Bool       // true once session opened successfully
    var sessionError: String
    /// Prevents multiple concurrent requestOpenSession() calls for the same device.
    var isOpeningSession: Bool = false
    var isCatalogLoaded: Bool = false
    var discoveredCount: Int = 0
    /// Number of one-off "session already open" recovery attempts since last success.
    var autoRetryCount: Int = 0
    /// Set when ImageCapture gets stuck and needs a real USB detach/attach cycle.
    var needsCableReconnect: Bool = false
    /// Monotonic token used to ignore stale timeout callbacks from previous attempts.
    var sessionAttemptID: Int = 0
    /// Last error surfaced to the UI; used to avoid re-publishing the same failure rapidly.
    var lastSessionErrorMessage: String = ""
    var lastSessionErrorUpdate: Date = .distantPast
    /// True while the device is locked / access-restricted. Set by
    /// cameraDeviceDidEnableAccessRestriction, cleared by cameraDeviceDidRemoveAccessRestriction.
    var isAccessRestricted: Bool = false
    /// Whether the device had an open session before the most recent lock event.
    var wasReadyBeforeLock: Bool = false
}

// MARK: - DeviceMonitor

@MainActor
class DeviceMonitor: NSObject, ObservableObject {

    // All currently discovered camera devices (keyed by UUID / name)
    @Published var connectedDevices: [ConnectedDevice] = []

    // Convenience: the first ready device — used by the backup engine
    @Published var activeCamera: ICCameraDevice? = nil

    // Convenience flags for legacy UI code
    @Published var isDeviceConnected: Bool = false
    @Published var connectedDeviceName: String = ""
    @Published var connectedDeviceID: String = ""
    @Published var isDeviceOpening: Bool = false
    @Published var isCatalogLoading: Bool = false
    @Published var discoveredCount: Int = 0

    // Session error for the primary (active) device
    @Published var sessionError: String = ""

    /// True while a full relaunch-style device discovery reset is in progress.
    @Published var isReconnecting: Bool = false

    /// True if a connected device is currently locked, access-restricted, or reporting an unlock error.
    var isWaitingForDeviceUnlock: Bool {
        connectedDevices.contains { dev in
            dev.isAccessRestricted ||
            dev.sessionError.localizedCaseInsensitiveContains("unlock") ||
            (dev.isOpeningSession && !dev.isReady)
        }
    }

    /// Persisted list of recently connected devices, newest first (max 10).
    @Published var deviceHistory: [DeviceHistoryEntry] = []

    @Published var thumbnails: [String: CGImage] = [:]
    /// Files for which a thumbnail was requested but the device returned nil.
    /// On Android MTP, requestThumbnail() silently fails; we mark these so
    /// the UI can show a static icon instead of an endless spinner.
    @Published var failedThumbnails: Set<String> = []

    /// Medium-resolution renditions fetched on demand for the Quick Swiping deck,
    /// keyed by file name. The device's own thumbnail is tiny (~600px) and looks
    /// blurry filling a swipe card, so items that aren't backed up locally yet get
    /// a one-off higher-res download instead of relying on that thumbnail forever.
    @Published var reviewPreviews: [String: CGImage] = [:]

    private var localThumbnailRequests = Set<String>()
    private var reviewPreviewRequests = Set<String>()
    private lazy var reviewPreviewDirectory: URL = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ReviewPreviews", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Set to the name of the most recently failed delete — observed by ThumbnailView.
    @Published var lastDeleteFailedItem: String? = nil

    @Published var pendingDeletions: Set<String> = []
    @Published var failedDeletions: Set<String> = []

    private var browser: ICDeviceBrowser
    private var discoveredFilesByDeviceID: [String: [ICCameraFile]] = [:]
    private let sessionTimeoutSeconds: Double = 12.0
    private let repeatedErrorPublishInterval: TimeInterval = 8.0
    private let cableReconnectMessage = "Unplug and re-plug the USB cable, then unlock your iPhone and tap Trust if asked."

    var onDeviceReady: ((ICCameraDevice) -> Void)?
    var onDeviceRemoved: ((ICCameraDevice) -> Void)?
    /// Fired when the device locks and USB photo access is restricted.
    var onAccessRestricted: ((ICCameraDevice) -> Void)?
    /// Fired when the device unlocks and USB photo access is restored.
    var onAccessRestrictionRemoved: ((ICCameraDevice) -> Void)?
    /// Fired when a brand-new device (UUID not seen before) opens a session successfully.
    var onNewDevice: ((ICCameraDevice) -> Void)?
    var onCatalogChanged: (() -> Void)?

    override init() {
        self.browser = ICDeviceBrowser()
        super.init()
        self.browser.delegate = self
        self.browser.browsedDeviceTypeMask = .camera
        deviceHistory = Self.loadHistory()
    }

    func start() {
        browser.start()
        // Safety net: if icdd hasn't reported any devices within 2.5 s of launch
        // (can happen when the app starts while the phone is already plugged in),
        // restart the browser to force a fresh re-enumeration.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, self.connectedDevices.isEmpty else { return }
            print("DeviceMonitor: no devices found after 2.5 s — re-enumerating…")
            self.browser.stop()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                self.browser.start()
            }
        }
    }

    func stop() {
        browser.stop()
        connectedDevices.forEach {
            $0.camera.delegate = nil
            $0.camera.requestCloseSession()
        }
        connectedDevices.removeAll()
    }

    /// Re-open the session for all devices with a full ImageCaptureCore browser and USB reset.
    func requestReconnect() {
        guard !isReconnecting else { return }
        isReconnecting = true
        print("DeviceMonitor: reconnect — performing full ImageCaptureCore browser & device reset")

        // 1. Close all active sessions & release delegates
        connectedDevices.forEach { dev in
            dev.camera.delegate = nil
            dev.camera.requestCloseSession()
        }
        connectedDevices.removeAll()
        discoveredFilesByDeviceID.removeAll()
        sessionError = ""
        syncConvenienceState()

        // 2. Stop the browser
        browser.stop()

        // 3. Re-instantiate a fresh browser and start discovery after short delay to let icdd reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            self.browser = ICDeviceBrowser()
            self.browser.delegate = self
            self.browser.browsedDeviceTypeMask = .camera
            self.browser.start()

            // Keep reconnecting status active for 1.5s while USB devices are re-enumerated
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.isReconnecting = false
                self?.syncConvenienceState()
            }
        }
    }

    func getCameraFiles() -> [ICCameraFile] {
        guard let camera = activeCamera else { return [] }
        let key = deviceKey(for: camera)
        if let cached = discoveredFilesByDeviceID[key], !cached.isEmpty {
            return cached
        }
        if let mediaFiles = camera.mediaFiles {
            return mediaFiles.compactMap { $0 as? ICCameraFile }
        } else if let contents = camera.contents {
            return contents.compactMap { $0 as? ICCameraFile }
        }
        return []
    }

    func allDiscoveredFiles() -> [ICCameraFile] {
        guard let camera = activeCamera else { return [] }
        let key = deviceKey(for: camera)
        if let cached = discoveredFilesByDeviceID[key], !cached.isEmpty {
            return cached
        }
        let rootItems = camera.mediaFiles ?? camera.contents ?? []
        return rootItems.flatMap { Self.cameraFiles(in: $0) }
    }

    func allReadyDiscoveredFiles() -> [ICCameraFile] {
        connectedDevices
            .filter { $0.isReady }
            .flatMap { files(for: $0.camera) }
    }

    func allReadyDiscoveredFiles(for deviceID: String) -> [ICCameraFile] {
        guard let device = connectedDevices.first(where: { $0.id == deviceID && $0.isReady }) else {
            return []
        }
        return files(for: device.camera)
    }

    func files(for camera: ICCameraDevice) -> [ICCameraFile] {
        let key = deviceKey(for: camera)
        if let cached = discoveredFilesByDeviceID[key], !cached.isEmpty {
            return cached
        }
        let rootItems = camera.mediaFiles ?? camera.contents ?? []
        let files = rootItems.flatMap { Self.cameraFiles(in: $0) }
        if !files.isEmpty {
            cacheDiscoveredFiles(files, for: key)
        }
        return files
    }

    func fileCount(for camera: ICCameraDevice) -> Int {
        let key = deviceKey(for: camera)
        if let count = discoveredFilesByDeviceID[key]?.count, count > 0 {
            return count
        }
        return camera.mediaFiles?.count ?? camera.contents?.count ?? 0
    }

    func owningCamera(for file: ICCameraFile) -> ICCameraDevice? {
        let targetIdentity = fileIdentity(file)
        return connectedDevices.first { device in
            files(for: device.camera).contains { candidate in
                candidate === file || fileIdentity(candidate) == targetIdentity
            }
        }?.camera ?? activeCamera
    }

    func deviceState(for camera: ICCameraDevice) -> ConnectedDevice? {
        let key = deviceKey(for: camera)
        return connectedDevices.first(where: { $0.camera === camera || $0.id == key })
    }

    func requestThumbnail(for file: ICCameraFile, localURL: URL? = nil) {
        guard let name = file.name else { return }
        if thumbnails[name] != nil { return }

        if let localURL,
           FileManager.default.fileExists(atPath: localURL.path) {
            if failedThumbnails.contains(name) {
                failedThumbnails.remove(name)
            }
            generateLocalThumbnailAsync(from: localURL, name: name, isVideo: file.isVideoFile)
            return
        }

        if failedThumbnails.contains(name) { return }  // already tried, device returned nothing
        if let cached = file.thumbnail { thumbnails[name] = cached; return }
        file.requestThumbnail()
    }

    /// Downloads a medium-resolution rendition of a not-yet-backed-up photo into a
    /// scratch directory purely so the Quick Swiping deck can display it sharply,
    /// then deletes the downloaded file once the rendition is decoded.
    func requestReviewPreview(for file: ICCameraFile, camera: ICCameraDevice?) {
        guard let name = file.name, let camera, file.isPhotoFile else { return }
        guard reviewPreviews[name] == nil else { return }
        guard reviewPreviewRequests.insert(name).inserted else { return }

        let destURL = reviewPreviewDirectory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: destURL)

        let options: [ICDownloadOption: Any] = [
            .downloadsDirectoryURL: reviewPreviewDirectory,
            .overwrite: true,
            .sidecarFiles: false
        ]

        camera.requestDownloadFile(
            file,
            options: options,
            downloadDelegate: self,
            didDownloadSelector: #selector(didDownloadReviewPreviewFile(_:error:options:contextInfo:)),
            contextInfo: nil
        )
    }

    @objc private func didDownloadReviewPreviewFile(
        _ file: ICCameraFile,
        error: Error?,
        options: [String: Any],
        contextInfo: UnsafeMutableRawPointer?
    ) {
        guard let name = file.name else { return }
        let url = reviewPreviewDirectory.appendingPathComponent(name)
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.reviewPreviewRequests.remove(name)
            guard error == nil else { return }

            let image = await Task.detached(priority: .userInitiated) {
                Self.loadDownsampledImage(at: url)
            }.value
            try? FileManager.default.removeItem(at: url)
            guard let image, self.reviewPreviews[name] == nil else { return }
            self.reviewPreviews[name] = image
            if self.reviewPreviews.count > 8 {
                let excess = self.reviewPreviews.count - 8
                let keysToRemove = Array(self.reviewPreviews.keys.prefix(excess))
                for k in keysToRemove {
                    self.reviewPreviews.removeValue(forKey: k)
                }
            }
        }
    }

    func purgeReviewPreview(for name: String) {
        reviewPreviews.removeValue(forKey: name)
        reviewPreviewRequests.remove(name)
    }

    func pruneReviewPreviews(keeping validNames: Set<String>) {
        let toRemove = reviewPreviews.keys.filter { !validNames.contains($0) }
        for k in toRemove {
            reviewPreviews.removeValue(forKey: k)
        }
    }

    nonisolated private static func loadDownsampledImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 2_560,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private func generateLocalThumbnailAsync(from url: URL, name: String, isVideo: Bool) {
        guard localThumbnailRequests.insert(name).inserted else { return }

        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let thumbnail: CGImage?
            if isVideo {
                let asset = AVAsset(url: url)
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                thumbnail = try? generator.copyCGImage(
                    at: CMTime(seconds: 0, preferredTimescale: 600),
                    actualTime: nil
                )
            } else if let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
                let options: CFDictionary = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 600,
                    kCGImageSourceCreateThumbnailWithTransform: true
                ] as CFDictionary
                thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options)
            } else {
                thumbnail = nil
            }

            await MainActor.run {
                self.localThumbnailRequests.remove(name)
                if let thumbnail {
                    self.thumbnails[name] = thumbnail
                    self.failedThumbnails.remove(name)
                } else {
                    self.failedThumbnails.insert(name)
                }
            }
        }
    }

    private func generateVideoThumbnailAsync(from url: URL, name: String) {
        Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            let asset = AVAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            do {
                let time = CMTime(seconds: 0.0, preferredTimescale: 600)
                let cgImage = try generator.copyCGImage(at: time, actualTime: nil)
                _ = await MainActor.run {
                    self.thumbnails[name] = cgImage
                    self.failedThumbnails.remove(name)
                }
            } catch {
                _ = await MainActor.run {
                    self.localThumbnailRequests.remove(name)
                    self.failedThumbnails.insert(name)
                }
            }
        }
    }

    func deleteFileFromDevice(_ file: ICCameraFile) {
        guard let name = file.name else { return }
        guard let camera = owningCamera(for: file) ?? activeCamera else { return }
        
        pendingDeletions.insert(name)
        failedDeletions.remove(name)
        
        camera.requestDeleteFiles([file])
    }

    // MARK: - Device History Persistence

    private static let historyKey = "deviceHistory"
    private static let historyMaxCount = 10

    private static func loadHistory() -> [DeviceHistoryEntry] {
        guard let data = UserDefaults.standard.data(forKey: historyKey),
              let entries = try? JSONDecoder().decode([DeviceHistoryEntry].self, from: data)
        else { return [] }
        return entries
    }

    private func saveHistory() {
        guard let data = try? JSONEncoder().encode(deviceHistory) else { return }
        UserDefaults.standard.set(data, forKey: Self.historyKey)
    }

    /// Upsert a history entry for the given device, keeping the list newest-first and capped at `historyMaxCount`.
    private func recordHistory(id: String, name: String) {
        guard !id.isEmpty else { return }
        var entries = deviceHistory
        entries.removeAll { $0.id == id }
        entries.insert(DeviceHistoryEntry(id: id, name: name, lastConnected: Date()), at: 0)
        if entries.count > Self.historyMaxCount {
            entries = Array(entries.prefix(Self.historyMaxCount))
        }
        deviceHistory = entries
        saveHistory()
    }

    /// Remove a remembered device from history.
    func removeHistory(id: String) {
        guard !id.isEmpty else { return }
        deviceHistory.removeAll { $0.id == id }
        saveHistory()
    }

    private func deviceKey(for device: ICDevice) -> String {
        if let uuid = device.uuidString, !uuid.isEmpty {
            return uuid
        }
        let name = device.name ?? "Device"
        return "\(name)_\(ObjectIdentifier(device).hashValue)"
    }

    nonisolated static func cameraFiles(in item: ICCameraItem) -> [ICCameraFile] {
        if let file = item as? ICCameraFile {
            return [file]
        } else if let folder = item as? ICCameraFolder, let contents = folder.contents {
            return contents.flatMap { cameraFiles(in: $0) }
        }
        return []
    }

    private func cacheDiscoveredFiles(_ files: [ICCameraFile], for key: String) {
        var cached = discoveredFilesByDeviceID[key] ?? []
        var known = Set(cached.map { fileIdentity($0) })

        for file in files {
            let identity = fileIdentity(file)
            guard !known.contains(identity) else { continue }
            cached.append(file)
            known.insert(identity)
        }
        discoveredFilesByDeviceID[key] = cached
    }

    private func fileIdentity(_ file: ICCameraFile) -> String {
        let name = file.name ?? "unknown"
        let date = file.creationDate?.timeIntervalSince1970 ?? 0
        return "\(name)|\(file.fileSize)|\(date)"
    }

    /// Recompute the convenience published properties from `connectedDevices`.
    private func syncConvenienceState() {
        let readyDevices = connectedDevices.filter { $0.isReady }
        activeCamera      = readyDevices.first?.camera
        isDeviceConnected = !readyDevices.isEmpty
        connectedDeviceName = readyDevices.first?.name ?? ""
        connectedDeviceID   = readyDevices.first?.id ?? ""
        if readyDevices.isEmpty {
            sessionError = connectedDevices.first(where: { !$0.isReady && !$0.sessionError.isEmpty })?.sessionError ?? ""
        } else {
            sessionError = ""
        }

        isDeviceOpening = connectedDevices.contains { $0.isOpeningSession }
        isCatalogLoading = connectedDevices.contains { $0.isReady && !$0.isCatalogLoaded }
        discoveredCount = connectedDevices.first?.discoveredCount ?? 0
    }

    private func markOpeningSession(at idx: Int, clearError: Bool = true) {
        var dev = connectedDevices[idx]
        dev.isOpeningSession = true
        dev.needsCableReconnect = false
        dev.sessionAttemptID += 1
        if clearError { dev.sessionError = "" }
        connectedDevices[idx] = dev
    }

    private func requireCableReconnect(at idx: Int) {
        guard !connectedDevices[idx].needsCableReconnect else { return }
        let now = Date()
        var dev = connectedDevices[idx]
        dev.isOpeningSession = false
        dev.needsCableReconnect = true
        dev.sessionAttemptID += 1
        dev.sessionError = cableReconnectMessage
        dev.lastSessionErrorMessage = cableReconnectMessage
        dev.lastSessionErrorUpdate = now
        connectedDevices[idx] = dev
    }

    /// Close and re-open the ICC session for one device.
    func retrySession(at idx: Int) {
        guard connectedDevices.indices.contains(idx),
              !connectedDevices[idx].isOpeningSession else { return }
        print("DeviceMonitor: retrying session for \(connectedDevices[idx].name)")
        markOpeningSession(at: idx)
        connectedDevices[idx].camera.requestCloseSession()
        let cam = connectedDevices[idx].camera
        let targetKey = connectedDevices[idx].id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self,
                  let i = self.connectedDevices.firstIndex(where: { $0.camera === cam || $0.id == targetKey }),
                  self.connectedDevices[i].isOpeningSession else { return }
            cam.requestOpenSession()
            self.startSessionTimeout(for: targetKey)
        }
        syncConvenienceState()
    }

    @discardableResult
    private func setSessionError(at idx: Int, _ message: String, force: Bool = false) -> Bool {
        let now = Date()
        let previousMessage = connectedDevices[idx].lastSessionErrorMessage
        let previousUpdate = connectedDevices[idx].lastSessionErrorUpdate
        let isRapidRepeat = previousMessage == message &&
            now.timeIntervalSince(previousUpdate) < repeatedErrorPublishInterval

        guard force || !isRapidRepeat else { return false }

        connectedDevices[idx].sessionError = message
        connectedDevices[idx].lastSessionErrorMessage = message
        connectedDevices[idx].lastSessionErrorUpdate = now
        return true
    }

    private func startSessionTimeout(for key: String, seconds: Double? = nil) {
        guard let initialIdx = connectedDevices.firstIndex(where: { $0.id == key }),
              !connectedDevices[initialIdx].needsCableReconnect else { return }
        let attemptID = connectedDevices[initialIdx].sessionAttemptID
        let timeout = seconds ?? sessionTimeoutSeconds

        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self else { return }
            if let idx = self.connectedDevices.firstIndex(where: { $0.id == key }) {
                let dev = self.connectedDevices[idx]
                if dev.isOpeningSession && !dev.isReady && !dev.needsCableReconnect && dev.sessionAttemptID == attemptID {
                    print("DeviceMonitor: session opening timed out for \(dev.name)")
                    self.requireCableReconnect(at: idx)
                    self.syncConvenienceState()
                }
            }
        }
    }

    private func scheduleCatalogFallback(for camera: ICCameraDevice, key: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self, weak camera] in
            guard let self, let camera,
                  let idx = self.connectedDevices.firstIndex(where: { $0.camera === camera || $0.id == key }),
                  self.connectedDevices[idx].isReady else { return }

            let rootItems = camera.mediaFiles ?? camera.contents ?? []
            let files = rootItems.flatMap { Self.cameraFiles(in: $0) }
            if !files.isEmpty {
                self.cacheDiscoveredFiles(files, for: key)
                self.connectedDevices[idx].isCatalogLoaded = true
                self.connectedDevices[idx].discoveredCount = max(
                    self.connectedDevices[idx].discoveredCount,
                    files.count
                )
                self.syncConvenienceState()
                self.onCatalogChanged?()
                self.onDeviceReady?(camera)
            } else {
                self.scheduleCatalogLoadedTimeout(for: key)
            }
        }
    }

    private func scheduleCatalogLoadedTimeout(for key: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) { [weak self] in
            guard let self,
                  let idx = self.connectedDevices.firstIndex(where: { $0.id == key }),
                  self.connectedDevices[idx].isReady,
                  !self.connectedDevices[idx].isCatalogLoaded else { return }

            self.connectedDevices[idx].isCatalogLoaded = true
            self.syncConvenienceState()
            self.onCatalogChanged?()
        }
    }
}

// MARK: - ICDeviceBrowserDelegate

extension DeviceMonitor: @preconcurrency ICDeviceBrowserDelegate {

    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        print("DeviceMonitor: found device: \(device.name ?? "unknown")")
        guard let camera = device as? ICCameraDevice else { return }

        let key = deviceKey(for: camera)
        if let existing = connectedDevices.first(where: { $0.camera === camera || $0.id == key }) {
            guard !existing.isOpeningSession,
                  !existing.isReady else { return }
        }

        if let idx = connectedDevices.firstIndex(where: { $0.camera === camera || $0.id == key }) {
            markOpeningSession(at: idx)
            connectedDevices[idx].isAccessRestricted = false
            connectedDevices[idx].autoRetryCount = 0
            connectedDevices[idx].needsCableReconnect = false
        } else {
            let entry = ConnectedDevice(
                id: key,
                camera: camera,
                name: camera.name ?? "Unknown Device",
                isReady: false,
                sessionError: "",
                isOpeningSession: true,
                sessionAttemptID: 1
            )
            connectedDevices.append(entry)
            camera.delegate = self
        }

        print("DeviceMonitor: opening session for \(camera.name ?? "device")")
        camera.requestOpenSession()
        startSessionTimeout(for: key)
        syncConvenienceState()
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        print("DeviceMonitor: removed device: \(device.name ?? "unknown")")
        guard let camera = device as? ICCameraDevice else { return }

        let key = deviceKey(for: camera)
        camera.delegate = nil
        camera.requestCloseSession()
        let retiringCamera = camera
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            _ = retiringCamera
        }
        connectedDevices.removeAll { $0.camera === camera || $0.id == key }
        discoveredFilesByDeviceID.removeValue(forKey: key)
        syncConvenienceState()
        onDeviceRemoved?(camera)
    }
}

// MARK: - ICCameraDeviceDelegate / ICDeviceDelegate

extension DeviceMonitor: @preconcurrency ICCameraDeviceDelegate, @preconcurrency ICDeviceDelegate {

    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        guard let camera = device as? ICCameraDevice else { return }
        let key = deviceKey(for: device)

        if let idx = connectedDevices.firstIndex(where: { $0.camera === camera || $0.id == key }),
           connectedDevices[idx].needsCableReconnect {
            print("DeviceMonitor: ignoring session error — already awaiting cable reconnect")
            return
        }

        if let error = error {
            let nsError = error as NSError
            print("DeviceMonitor: error opening session for \(device.name ?? "device"): \(error.localizedDescription) (\(nsError.domain) \(nsError.code))")

            let isAlreadyOpen = (nsError.domain == "ICErrorDomain" && nsError.code == -9922)
                || error.localizedDescription.localizedCaseInsensitiveContains("already open")

            if let idx = connectedDevices.firstIndex(where: { $0.camera === camera || $0.id == key }) {
                connectedDevices[idx].isReady = false

                if connectedDevices[idx].needsCableReconnect {
                    requireCableReconnect(at: idx)
                    syncConvenienceState()
                    return
                }

                if isAlreadyOpen && connectedDevices[idx].autoRetryCount == 0 {
                    print("DeviceMonitor: session already open — closing and retrying in 2 s…")
                    connectedDevices[idx].autoRetryCount += 1
                    markOpeningSession(at: idx)
                    let cam = connectedDevices[idx].camera
                    let targetKey = key
                    cam.requestCloseSession()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                        guard let self,
                               let i = self.connectedDevices.firstIndex(where: { $0.camera === cam || $0.id == targetKey }),
                               !self.connectedDevices[i].isReady,
                               !self.connectedDevices[i].needsCableReconnect else { return }
                        cam.requestOpenSession()
                        self.startSessionTimeout(for: targetKey)
                    }
                } else {
                    requireCableReconnect(at: idx)
                }
            }
            syncConvenienceState()

        } else {
            print("DeviceMonitor: session opened for \(device.name ?? "device")")
            let knownIDs = UserDefaults.standard.stringArray(forKey: "knownDeviceIDs") ?? []
            let isNew = !key.isEmpty && !knownIDs.contains(key)
            if isNew {
                var updated = knownIDs
                updated.append(key)
                UserDefaults.standard.set(updated, forKey: "knownDeviceIDs")
            }

            if let idx = connectedDevices.firstIndex(where: { $0.camera === camera || $0.id == key }) {
                var dev = connectedDevices[idx]
                dev.isOpeningSession = false
                dev.isReady = true
                dev.isCatalogLoaded = false
                dev.discoveredCount = 0
                dev.sessionError = ""
                dev.lastSessionErrorMessage = ""
                dev.lastSessionErrorUpdate = .distantPast
                dev.autoRetryCount = 0
                dev.isAccessRestricted = false
                dev.needsCableReconnect = false
                connectedDevices[idx] = dev
            }
            discoveredFilesByDeviceID[key] = []

            let deviceName = device.name ?? connectedDevices.first(where: { $0.camera === camera || $0.id == key })?.name ?? "Unknown Device"
            recordHistory(id: key, name: deviceName)

            syncConvenienceState()

            if isNew, let camera = connectedDevices.first(where: { $0.camera === camera || $0.id == key })?.camera {
                onNewDevice?(camera)
            }

            if let camera = connectedDevices.first(where: { $0.camera === camera || $0.id == key })?.camera {
                scheduleCatalogFallback(for: camera, key: key)
            }
        }
    }

    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {
        print("DeviceMonitor: session closed for \(device.name ?? "device")")
    }

    func didRemove(_ device: ICDevice) {
        print("DeviceMonitor: didRemove device \(device.name ?? "device")")
        guard let camera = device as? ICCameraDevice else { return }
        let key = deviceKey(for: camera)
        camera.delegate = nil
        camera.requestCloseSession()
        let retiringCamera = camera
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            _ = retiringCamera
        }
        connectedDevices.removeAll { $0.camera === camera || $0.id == key }
        discoveredFilesByDeviceID.removeValue(forKey: key)
        syncConvenienceState()
        onDeviceRemoved?(camera)
    }

    func deviceDidBecomeReady(_ device: ICDevice) {
        print("DeviceMonitor: deviceDidBecomeReady: \(device.name ?? "device")")
        guard let camera = device as? ICCameraDevice else { return }
        let key = deviceKey(for: device)
        if let idx = connectedDevices.firstIndex(where: { $0.camera === camera || $0.id == key }),
           !connectedDevices[idx].isReady,
           !connectedDevices[idx].isOpeningSession {
            print("DeviceMonitor: triggering session open on device readiness for \(device.name ?? "device")")
            retrySession(at: idx)
        }
    }

    func deviceDidBecomeReady(withCompleteContentCatalog camera: ICCameraDevice) {
        print("DeviceMonitor: camera ready with full catalog: \(camera.name ?? "camera")")
        let key = deviceKey(for: camera)
        let rootItems = camera.mediaFiles ?? camera.contents ?? []
        let files = rootItems.flatMap { Self.cameraFiles(in: $0) }
        cacheDiscoveredFiles(files, for: key)
        if let idx = connectedDevices.firstIndex(where: { $0.camera === camera || $0.id == key }) {
            connectedDevices[idx].isCatalogLoaded = true
            connectedDevices[idx].discoveredCount = max(connectedDevices[idx].discoveredCount, files.count)
        }
        syncConvenienceState()
        onCatalogChanged?()
        onDeviceReady?(camera)
    }

    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {
        print("DeviceMonitor: added \(items.count) items to \(camera.name ?? "camera")")
        let key = deviceKey(for: camera)
        let files = items.flatMap { Self.cameraFiles(in: $0) }
        cacheDiscoveredFiles(files, for: key)
        if let idx = connectedDevices.firstIndex(where: { $0.camera === camera || $0.id == key }) {
            if !files.isEmpty {
                connectedDevices[idx].isCatalogLoaded = true
            }
            connectedDevices[idx].discoveredCount = max(
                discoveredFilesByDeviceID[key]?.count ?? 0,
                connectedDevices[idx].discoveredCount + max(files.count, items.count)
            )
        }
        syncConvenienceState()
        onCatalogChanged?()
    }

    func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {
        print("DeviceMonitor: removed \(items.count) items from \(camera.name ?? "camera")")
        let removedNames: [String] = autoreleasepool {
            items.compactMap { item -> String? in
                guard let n = item.name, !n.isEmpty else { return nil }
                return n
            }
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for name in removedNames {
                self.thumbnails.removeValue(forKey: name)
                self.pendingDeletions.remove(name)
                self.failedDeletions.remove(name)
            }
            ReviewProcessedCache.shared.removeRecentDeletions(matchingNames: Set(removedNames))
            for key in self.discoveredFilesByDeviceID.keys {
                self.discoveredFilesByDeviceID[key]?.removeAll { file in
                    guard let name = file.name else { return false }
                    return removedNames.contains(name)
                }
            }
            self.onCatalogChanged?()
        }
    }

    func cameraDevice(_ camera: ICCameraDevice, didFailToDeleteItems items: [ICCameraItem], error: Error?) {
        let failedNames: [String] = autoreleasepool {
            items.compactMap { item -> String? in
                guard let n = item.name, !n.isEmpty else { return nil }
                return n
            }
        }
        let names = failedNames.joined(separator: ", ")
        print("DeviceMonitor: failed to delete [\(names)] from \(camera.name ?? "camera"): \(error?.localizedDescription ?? "unknown error")")
        
        DispatchQueue.main.async {
            for name in failedNames {
                self.pendingDeletions.remove(name)
                self.failedDeletions.insert(name)
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    self.failedDeletions.remove(name)
                }
            }
            if let firstName = failedNames.first {
                self.lastDeleteFailedItem = firstName
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    if self.lastDeleteFailedItem == firstName {
                        self.lastDeleteFailedItem = nil
                    }
                }
            }
        }
    }

    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}

    nonisolated func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let key = self.deviceKey(for: camera)
            if let idx = self.connectedDevices.firstIndex(where: { $0.camera === camera || $0.id == key }),
               !self.connectedDevices[idx].isReady,
               !self.connectedDevices[idx].isOpeningSession {
                print("DeviceMonitor: camera capability changed, retrying session for \(camera.name ?? "camera")")
                self.retrySession(at: idx)
            }
        }
    }

    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?,
                      for item: ICCameraItem, error: Error?) {
        guard let name = item.name else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let img = thumbnail {
                self.thumbnails[name] = img
                self.failedThumbnails.remove(name)
            } else {
                self.failedThumbnails.insert(name)
            }
        }
    }

    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?,
                      for item: ICCameraItem, error: Error?) {}

    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}

    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {
        print("DeviceMonitor: access restriction removed for \(device.name ?? "device")")
        guard let camera = device as? ICCameraDevice else { return }
        let key = deviceKey(for: device)
        guard let idx = connectedDevices.firstIndex(where: { $0.camera === camera || $0.id == key }) else {
            syncConvenienceState()
            return
        }
        guard !connectedDevices[idx].isOpeningSession else {
            connectedDevices[idx].isAccessRestricted = false
            syncConvenienceState()
            return
        }

        connectedDevices[idx].isAccessRestricted = false
        connectedDevices[idx].sessionError = ""

        if connectedDevices[idx].wasReadyBeforeLock && !connectedDevices[idx].needsCableReconnect {
            connectedDevices[idx].isReady = true
            connectedDevices[idx].lastSessionErrorMessage = ""
            connectedDevices[idx].lastSessionErrorUpdate = .distantPast
            connectedDevices[idx].wasReadyBeforeLock = false
            syncConvenienceState()
            onAccessRestrictionRemoved?(camera)
        } else {
            connectedDevices[idx].wasReadyBeforeLock = false
            retrySession(at: idx)
        }
    }

    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {
        print("DeviceMonitor: access restriction enabled for \(device.name ?? "device")")
        guard let camera = device as? ICCameraDevice else { return }
        let key = deviceKey(for: device)
        if let idx = connectedDevices.firstIndex(where: { $0.camera === camera || $0.id == key }) {
            guard !connectedDevices[idx].needsCableReconnect else { return }
            let message = "Please unlock \"\(device.name ?? "device")\""
            guard !connectedDevices[idx].isAccessRestricted ||
                  connectedDevices[idx].sessionError != message else { return }
            connectedDevices[idx].wasReadyBeforeLock = connectedDevices[idx].isReady
            connectedDevices[idx].isReady = false
            connectedDevices[idx].isAccessRestricted = true
            _ = setSessionError(at: idx, message)
            onAccessRestricted?(connectedDevices[idx].camera)
        }
        syncConvenienceState()
    }
}

// MARK: - ICCameraDeviceDownloadDelegate

extension DeviceMonitor: @preconcurrency ICCameraDeviceDownloadDelegate {}
