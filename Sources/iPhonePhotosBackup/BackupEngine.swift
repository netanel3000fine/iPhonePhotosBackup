import Foundation
@preconcurrency import ImageCaptureCore
@preconcurrency import UserNotifications

// MARK: - Backup State

enum BackupState: Equatable {
    case idle
    case scanning
    case copying(current: Int, total: Int, progress: Double)
    case paused(current: Int, total: Int, progress: Double)
    case interrupted(current: Int, total: Int, progress: Double)
    case completed(copiedCount: Int)
    case failed(String)
}

// MARK: - Rich Stats (published separately for UI consumption)

struct BackupStats {
    var totalFiles: Int = 0
    var skippedFiles: Int = 0       // Already in manifest — not re-downloaded
    var successCount: Int = 0
    var failedCount: Int = 0
    var retriedCount: Int = 0
    var currentBatch: Int = 0
    var totalBatches: Int = 0
    var filesInCurrentBatch: Int = 0
    var currentFileName: String = ""
    var failedFileNames: [String] = []
    var startTime: Date? = nil
    var lastError: String = ""
    var isFullBackup: Bool = false
    var manifestSize: Int = 0       // How many files were already known
    var reorganizedCount: Int = 0   // Existing destination files moved to target folder format

    var elapsedSeconds: Int {
        guard let start = startTime else { return 0 }
        return Int(Date().timeIntervalSince(start))
    }

    var elapsedFormatted: String {
        let s = elapsedSeconds
        if s < 60 { return "\(s)s" }
        return "\(s / 60)m \(s % 60)s"
    }

    var averageSecondsPerFile: Double {
        guard successCount > 0, let start = startTime else { return 0 }
        return Date().timeIntervalSince(start) / Double(successCount)
    }

    var remainingFilesCount: Int {
        max(0, totalFiles - successCount - failedCount)
    }

    var remainingFiles: Int {
        remainingFilesCount
    }

    var etaFormatted: String {
        let remaining = remainingFilesCount
        guard remaining > 0, averageSecondsPerFile > 0 else { return "—" }
        let eta = Int(Double(remaining) * averageSecondsPerFile)
        if eta < 60 { return "~\(eta)s" }
        return "~\(eta / 60)m \(eta % 60)s"
    }

    var overallProgress: Double {
        guard totalFiles > 0 else { return 0 }
        return Double(successCount + failedCount) / Double(totalFiles)
    }

    var batchProgress: Double {
        guard filesInCurrentBatch > 0 else { return 0 }
        let doneInBatch = (successCount + failedCount) % filesInCurrentBatch
        return Double(doneInBatch) / Double(filesInCurrentBatch)
    }

    static var empty: BackupStats { BackupStats() }
}

public enum BackupScanMode: Int, Sendable {
    case incremental = 0
    case deepValidation = 1
    case fullRecountAndReconcile = 2
}

public enum ScanPhase: String, Sendable, CaseIterable {
    case idle
    case readingCatalog
    case buildingIndex
    case validatingAndReorganizing
    case complete
}

public struct ValidationRecountStats: Equatable, Sendable {
    public var sourceFileCount: Int = 0
    public var destinationFileCount: Int = 0
    public var isRecountComplete: Bool = false
    public var isReconciliationComplete: Bool = false
    public var isReconciliationSkipped: Bool = false
    public var missingOrCorruptCount: Int = 0
    public var verifiedSafeCount: Int = 0
    public var reorganizedCount: Int = 0
    public var currentScannedFile: String = ""
    public var scannedCount: Int = 0
    public var totalToScan: Int = 0
    public var currentPhase: ScanPhase = .idle
    public var scanMode: BackupScanMode = .incremental

    public var differenceCount: Int {
        max(0, sourceFileCount - destinationFileCount)
    }

    public var scanProgress: Double {
        guard totalToScan > 0 else { return 0.0 }
        return min(1.0, Double(scannedCount) / Double(totalToScan))
    }
}

struct ScanFileInfo: Sendable {
    let index: Int
    let name: String
    let fileSize: Int64
    let creationDate: Date?
    let isPhoto: Bool
    let isVideo: Bool
    let manifestKey: String
}

/// Serializes manifest writes away from the main actor. The highest sequence
/// always wins, so a delayed older write can never overwrite newer progress.
private actor BackupManifestWriter {
    private var newestSequence = 0

    func save(_ manifest: [String: Bool], to path: URL, sequence: Int) {
        guard sequence >= newestSequence else { return }
        newestSequence = sequence

        do {
            let data = try JSONEncoder().encode(manifest)
            try data.write(to: path, options: .atomic)
        } catch {
            print("BackupEngine: Failed to save manifest: \(error.localizedDescription)")
        }
    }
}

// MARK: - Engine

@MainActor
class BackupEngine: NSObject, ObservableObject {
    @Published var state: BackupState = .idle
    @Published var stats: BackupStats = .empty
    @Published var lastBackedUpFileName: String = ""
    @Published var recentlyProcessedFileNames: [String] = []
    @Published var recentlyProcessedFiles: [ICCameraFile] = []
    @Published var currentDeviceName: String = ""
    @Published var currentDeviceID: String = ""
    /// True when backup was paused because the source device locked.
    @Published var pausedByDeviceLock: Bool = false
    /// True when the device locked while the engine was still in the scanning phase.
    /// The scan task is cancelled immediately; resumeFromDeviceLock will signal the
    /// caller (AppDelegate) to re-enqueue the job so the scan can restart cleanly.
    @Published var pausedDuringScan: Bool = false
    /// Published two-step deep validation recount & reconciliation metrics.
    @Published var validationStats: ValidationRecountStats? = nil
    /// Called only after Image Capture reports a successful transfer and the
    /// resulting local file has been verified on disk.
    var onVerifiedFileBackup: ((ICCameraFile) -> Void)?

    // MARK: - Configuration
    private let batchSize = 50
    private let maxRetries = 1
    private let interFileDelayMs: UInt64 = 80
    private let manifestSaveInterval = 25
    private let downloadTimeoutSeconds: Double = 45

    // MARK: - Internal state
    private var pendingFiles: [ICCameraFile] = []
    private var downloadQueue: [ICCameraFile] = []
    private var retryCounters: [String: Int] = [:]

    private var totalToDownload = 0
    private var successfullyDownloaded = 0
    private var failedDownloads = 0
    private var sinceLastManifestSave = 0

    private var currentCamera: ICCameraDevice?
    private var targetDirectory: URL?
    private var manifestPath: URL?
    private var manifest: [String: Bool] = [:]
    private var manifestCache: [URL: [String: Bool]] = [:]
    private let manifestWriter = BackupManifestWriter()
    private var manifestSaveSequence = 0
    /// Monotonic token; incremented on start/cancel so in-flight async work can bail out safely.
    private var backupSessionID = 0
    private var scanTask: Task<Void, Never>?
    private var pendingWorkTask: Task<Void, Never>?
    private var downloadTimeoutTask: Task<Void, Never>?
    private var inFlightFile: ICCameraFile?

    // MARK: - Public API

    func isFileInManifest(key: String) -> Bool {
        return manifest[key] == true
    }

    /// Check if a file is backed up at a specific destination, using a separate cache.
    func isAssetBackedUp(_ file: ICCameraFile, at destinationURL: URL) -> Bool {
        let manifestKey = getManifestKey(for: file)
        
        // If this is the active backup destination, use the active manifest which might have
        // new unsaved changes from the current run.
        if let activeDest = targetDirectory, activeDest.standardizedFileURL == destinationURL.standardizedFileURL {
            return manifest[manifestKey] == true
        }
        
        let standardized = destinationURL.standardizedFileURL
        if let cached = manifestCache[standardized] {
            return cached[manifestKey] == true
        }
        
        let path = standardized.appendingPathComponent(".backup_manifest.json")
        guard FileManager.default.fileExists(atPath: path.path) else {
            manifestCache[standardized] = [:]
            return false
        }
        
        do {
            let data = try Data(contentsOf: path)
            let loaded = try JSONDecoder().decode([String: Bool].self, from: data)
            manifestCache[standardized] = loaded
            return loaded[manifestKey] == true
        } catch {
            print("BackupEngine: Failed to load manifest for gallery at \(path.path): \(error.localizedDescription)")
            manifestCache[standardized] = [:]
            return false
        }
    }

    func invalidateManifestCache(for destinationURL: URL) {
        manifestCache.removeValue(forKey: destinationURL.standardizedFileURL)
    }

    func manifestKey(for file: ICCameraFile) -> String {
        return getManifestKey(for: file)
    }

    func isAssetAlreadyBackedUp(_ file: ICCameraFile) -> Bool {
        return isFileInManifest(key: getManifestKey(for: file))
    }

    func localURL(for file: ICCameraFile) -> URL? {
        guard let target = targetDirectory else { return nil }
        return destinationDirectory(for: file, baseURL: target).appendingPathComponent(file.name ?? "")
    }

    func useManifest(at destinationURL: URL) {
        let path = destinationURL.appendingPathComponent(".backup_manifest.json")
        guard manifestPath != path else { return }
        manifestPath = path
        loadManifest()
    }

    /// Returns a snapshot of all backed-up manifest keys as a plain `Set<String>`.
    /// Safe to capture in `Task.detached` because `Set<String>` is `Sendable`.
    func manifestSnapshot() -> Set<String> {
        return Set(manifest.compactMap { $0.value ? $0.key : nil })
    }

    /// Returns an in-memory manifest snapshot when `destinationURL` is the
    /// destination currently being backed up. This avoids disk I/O while a
    /// dashboard filter is being prepared during a live sync.
    func activeManifestSnapshot(for destinationURL: URL) -> Set<String>? {
        guard let targetDirectory,
              targetDirectory.standardizedFileURL == destinationURL.standardizedFileURL else {
            return nil
        }
        return manifestSnapshot()
    }

    /// Reads a persisted manifest without touching UI-owned state. Call this
    /// from a detached task when the dashboard is browsing another destination.
    nonisolated static func persistedManifestSnapshot(at destinationURL: URL) -> Set<String> {
        let path = destinationURL.appendingPathComponent(".backup_manifest.json")
        guard let data = try? Data(contentsOf: path),
              let storedManifest = try? JSONDecoder().decode([String: Bool].self, from: data) else {
            return []
        }
        return Set(storedManifest.compactMap { $0.value ? $0.key : nil })
    }

    // MARK: - Device Settings Helpers

    nonisolated static func deviceMediaType(for deviceID: String) -> Int {
        if !deviceID.isEmpty, let val = UserDefaults.standard.object(forKey: "deviceMediaType_\(deviceID)") as? Int {
            return val
        }
        return UserDefaults.standard.integer(forKey: "backupMediaType")
    }

    nonisolated static func deviceSkipEditedDuplicates(for deviceID: String) -> Bool {
        if !deviceID.isEmpty, let val = UserDefaults.standard.object(forKey: "deviceSkipEditedDuplicates_\(deviceID)") as? Bool {
            return val
        }
        return UserDefaults.standard.bool(forKey: "skipEditedDuplicates")
    }

    nonisolated static func deviceOrganizeByYear(for deviceID: String) -> Bool {
        if !deviceID.isEmpty, let val = UserDefaults.standard.object(forKey: "deviceOrganizeByYear_\(deviceID)") as? Bool {
            return val
        }
        return UserDefaults.standard.object(forKey: "organizeByYear") == nil ? true : UserDefaults.standard.bool(forKey: "organizeByYear")
    }

    nonisolated static func deviceOrganizeByMonth(for deviceID: String) -> Bool {
        if !deviceID.isEmpty, let val = UserDefaults.standard.object(forKey: "deviceOrganizeByMonth_\(deviceID)") as? Bool {
            return val
        }
        return UserDefaults.standard.object(forKey: "organizeByMonth") == nil ? true : UserDefaults.standard.bool(forKey: "organizeByMonth")
    }

    // MARK: - Folder Organization Helpers

    /// Returns the directory where `file` should be saved.
    /// When `folderOrganization == 1`, files go to `base/YYYY/MM - MonthName/`.
    /// Falls back to `baseURL` if the file has no creation date.
    private func destinationDirectory(for file: ICCameraFile, baseURL: URL, deviceID: String = "") -> URL {
        guard let date = file.creationDate else {
            return baseURL
        }
        let devID = deviceID.isEmpty ? (currentCamera?.uuidString ?? currentCamera?.name ?? "") : deviceID
        let organizeByYear = Self.deviceOrganizeByYear(for: devID)
        let organizeByMonth = Self.deviceOrganizeByMonth(for: devID)
        
        var url = baseURL
        let cal = Calendar.current
        
        if organizeByYear {
            let year = cal.component(.year, from: date)
            url = url.appendingPathComponent("\(year)", isDirectory: true)
        }
        
        if organizeByMonth {
            let month = cal.component(.month, from: date)
            let monthName = cal.monthSymbols[month - 1]
            let monthFolder = String(format: "%02d - %@", month, monthName)
            url = url.appendingPathComponent(monthFolder, isDirectory: true)
        }
        
        return url
    }

    /// One leaf directory's contribution to the file cache, plus the directory's
    /// modification date at scan time — used to decide whether a future run can
    /// skip rescanning this folder.
    private struct LeafCacheEntry: Codable {
        var dirModDate: Date
        var files: [String: FileCacheRecord]
    }

    private struct FileCacheRecord: Codable {
        var size: Int64
        var modDate: Date
    }

    /// On-disk sidecar persisting the per-leaf-folder file cache so unchanged
    /// folders (e.g. past months that will never be written to again) don't need
    /// to be re-walked over SMB on every backup run.
    private nonisolated static func fileCacheSidecarPath(baseURL: URL) -> URL {
        baseURL.appendingPathComponent(".backup_filecache.json")
    }

    private nonisolated static func loadPersistedFileCache(baseURL: URL) -> [String: LeafCacheEntry] {
        let path = fileCacheSidecarPath(baseURL: baseURL)
        guard let data = try? Data(contentsOf: path),
              let decoded = try? JSONDecoder().decode([String: LeafCacheEntry].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private nonisolated static func savePersistedFileCache(_ cache: [String: LeafCacheEntry], baseURL: URL) {
        let path = fileCacheSidecarPath(baseURL: baseURL)
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: path, options: .atomic)
    }

    /// Walks `baseURL` collecting (filename -> size/modDate) for matching against
    /// camera files. Directories that haven't changed since the last run (per the
    /// persisted sidecar) are skipped entirely — their previously-recorded files
    /// are reused as-is. This is the expensive step on a network (SMB) destination,
    /// since every unscanned folder costs a network round-trip per file.
    ///
    /// `onProgress` is called periodically (off the main actor) with a running
    /// count of files scanned so far, so the caller can surface live progress.
    /// Matching semantics (size + modificationDate, single entry per filename)
    /// are unchanged from the previous implementation.
    private nonisolated static func buildFileCache(
        baseURL: URL,
        onProgress: (@Sendable (Int) -> Void)? = nil
    ) -> [String: (size: Int64, modDate: Date)] {
        let fm = FileManager.default
        let persisted = loadPersistedFileCache(baseURL: baseURL)
        var updatedPersisted: [String: LeafCacheEntry] = [:]
        var cache: [String: (size: Int64, modDate: Date)] = [:]
        var scannedCount = 0
        var lastReported = 0

        func reportProgressIfNeeded() {
            // Report roughly every 200 files to avoid hammering the main actor.
            if scannedCount - lastReported >= 200 {
                lastReported = scannedCount
                onProgress?(scannedCount)
            }
        }

        /// Scans a directory's direct file children, recurses into subdirectories,
        /// and records it as a reusable "leaf" in updatedPersisted if it contains
        /// files directly (no further subfolders).
        func scan(dir: URL) {
            guard let contents = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.fileSizeKey, .attributeModificationDateKey],
                options: []
            ) else {
                return
            }

            var subdirs: [URL] = []
            var dirFiles: [String: FileCacheRecord] = [:]

            for url in contents {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
                if isDir.boolValue {
                    subdirs.append(url)
                } else {
                    let name = url.lastPathComponent
                    if let attrs = try? fm.attributesOfItem(atPath: url.path),
                       let size = attrs[.size] as? Int64 {
                        let modDate = attrs[.modificationDate] as? Date ?? Date.distantPast
                        dirFiles[name] = FileCacheRecord(size: size, modDate: modDate)
                        scannedCount += 1
                        reportProgressIfNeeded()
                    }
                }
            }

            for (name, rec) in dirFiles {
                cache[name] = (rec.size, rec.modDate)
            }

            // A "leaf" directory has files directly inside and no subfolders —
            // e.g. a "06 - June" month folder. Those are safe to cache wholesale,
            // since once a month has passed it's effectively read-only.
            if !dirFiles.isEmpty && subdirs.isEmpty {
                let dirModDate = (try? fm.attributesOfItem(atPath: dir.path)[.modificationDate] as? Date) ?? Date()
                updatedPersisted[dir.path] = LeafCacheEntry(dirModDate: dirModDate, files: dirFiles)
            }

            for sub in subdirs {
                scanWithCacheReuse(dir: sub)
            }
        }

        /// Checks whether `dir` is an unchanged, previously recorded leaf — if so,
        /// reuses the persisted entry without touching the filesystem. Otherwise
        /// falls back to a full `scan`.
        func scanWithCacheReuse(dir: URL) {
            let key = dir.path
            if let previous = persisted[key] {
                let currentModDate = try? fm.attributesOfItem(atPath: dir.path)[.modificationDate] as? Date
                if let currentModDate = currentModDate ?? nil, currentModDate == previous.dirModDate {
                    // Unchanged since last scan — reuse without rescanning file-by-file.
                    updatedPersisted[key] = previous
                    for (name, rec) in previous.files {
                        cache[name] = (rec.size, rec.modDate)
                    }
                    scannedCount += previous.files.count
                    reportProgressIfNeeded()
                    return
                }
            }
            scan(dir: dir)
        }

        // The root itself is always scanned fully (cheap — it's usually just
        // year folders, not thousands of files). Cache-reuse only kicks in one
        // level down, at the leaf (month) folders, where the real file counts live.
        scanWithCacheReuse(dir: baseURL)

        onProgress?(scannedCount)
        savePersistedFileCache(updatedPersisted, baseURL: baseURL)
        return cache
    }
    /// Computes the expected destination sub-directory for a file given the
    /// folder-organisation prefs. Pure function — no I/O, safe to call off the main actor.
    private nonisolated static func destinationDir(
        creationDate: Date?,
        baseURL: URL,
        organizeByYear: Bool,
        organizeByMonth: Bool
    ) -> URL {
        guard let date = creationDate else { return baseURL }
        var url = baseURL
        let cal = Calendar.current
        if organizeByYear {
            let year = cal.component(.year, from: date)
            url = url.appendingPathComponent("\(year)", isDirectory: true)
        }
        if organizeByMonth {
            let month = cal.component(.month, from: date)
            let monthName = cal.monthSymbols[month - 1]
            url = url.appendingPathComponent(String(format: "%02d - %@", month, monthName), isDirectory: true)
        }
        return url
    }

    /// Pre-builds a destination file index: lowercased filename → URL.
    /// Called once before the per-file scan loop to avoid O(N×M) disk I/O.
    nonisolated static func buildDestinationIndex(
        baseURL: URL,
        fm: FileManager
    ) -> [String: URL] {
        guard let enumerator = fm.enumerator(
            at: baseURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [:] }

        var index: [String: URL] = [:]
        for case let fileURL as URL in enumerator {
            guard let rv = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                  rv.isRegularFile == true else { continue }
            let key = fileURL.lastPathComponent.lowercased()
            // Keep the first occurrence (don't overwrite) – duplicates will be
            // caught naturally when the file-move step fires.
            if index[key] == nil {
                index[key] = fileURL
            }
        }
        return index
    }

    /// Searches for an existing file using a pre-built destination index (O(1) lookup).
    /// If found at an alternate path with matching size, relocates it to `targetDir`
    /// (overwriting any colliding file at targetDir) and returns true for relocated.
    nonisolated static func smartFindAndRelocateExistingFile(
        file: ScanFileInfo,
        targetDir: URL,
        baseURL: URL,
        destinationIndex: [String: URL],
        fm: FileManager
    ) -> (found: Bool, relocated: Bool) {
        let targetPath = targetDir.appendingPathComponent(file.name)

        // 1. Check if already at target path with matching size
        if let attrs = try? fm.attributesOfItem(atPath: targetPath.path),
           let size = attrs[.size] as? Int64,
           file.fileSize <= 0 || size == file.fileSize {
            return (found: true, relocated: false)
        }

        // 2. O(1) lookup in the pre-built index by lowercase filename
        let lookupKey = file.name.lowercased()
        if let candidate = destinationIndex[lookupKey],
           candidate.path != targetPath.path {
            // Verify size match
            if let attrs = try? fm.attributesOfItem(atPath: candidate.path),
               let size = attrs[.size] as? Int64,
               file.fileSize <= 0 || size == file.fileSize {
                // File found in a different folder layout — relocate to targetDir.
                do {
                    try fm.createDirectory(at: targetDir, withIntermediateDirectories: true, attributes: nil)
                    if fm.fileExists(atPath: targetPath.path) {
                        try fm.removeItem(at: targetPath)
                    }
                    try fm.moveItem(at: candidate, to: targetPath)
                    print("BackupEngine: Relocated \(file.name) → \(targetDir.lastPathComponent)/")
                    return (found: true, relocated: true)
                } catch {
                    print("BackupEngine: Failed to move \(file.name): \(error.localizedDescription)")
                    // Still counts as found — file exists on disk, just couldn't move it
                    return (found: true, relocated: false)
                }
            }
        }

        return (found: false, relocated: false)
    }

    /// Recursively prunes empty subdirectories in `baseURL` after relocation.
    nonisolated static func pruneEmptyDirectories(in baseURL: URL, fm: FileManager) {
        guard let contents = try? fm.contentsOfDirectory(at: baseURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return }

        for item in contents {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue else { continue }

            // Recurse first (bottom-up cleanup)
            pruneEmptyDirectories(in: item, fm: fm)

            // Check if directory is now empty (or contains only .DS_Store)
            if let children = try? fm.contentsOfDirectory(atPath: item.path) {
                let meaningful = children.filter { $0 != ".DS_Store" }
                if meaningful.isEmpty {
                    let dsStore = item.appendingPathComponent(".DS_Store")
                    try? fm.removeItem(at: dsStore)
                    try? fm.removeItem(at: item)
                    print("BackupEngine: Cleaned up empty folder at \(item.lastPathComponent)")
                }
            }
        }
    }

    /// Recursively counts all valid media files present in the destination hierarchy (Year/Month/Flat).
    nonisolated static func countMediaFilesInDestination(_ destURL: URL) -> Int {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: destURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return 0 }

        var count = 0
        let validExtensions: Set<String> = [
            "jpg", "jpeg", "heic", "heif", "png", "gif", "tif", "tiff", "bmp", "raw", "dng", "cr2", "cr3", "nef", "arw", "webp",
            "mov", "mp4", "m4v", "avi", "mkv", "3gp"
        ]

        for case let fileURL as URL in enumerator {
            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                  resourceValues.isRegularFile == true else { continue }
            let ext = fileURL.pathExtension.lowercased()
            if validExtensions.contains(ext) {
                count += 1
            }
        }
        return count
    }

    /// Allows skipping Step 2 (reconciliation) while keeping recount metrics visible.
    func skipValidationReconciliation() {
        guard let stats = validationStats, stats.isRecountComplete else { return }
        var updated = stats
        updated.isReconciliationSkipped = true
        self.validationStats = updated
        self.scanTask?.cancel()
        self.scanTask = nil
        self.state = .idle
    }

    func startBackup(camera: ICCameraDevice, destinationURL: URL, isFullBackup: Bool? = nil) {
        let mode: BackupScanMode = (isFullBackup ?? UserDefaults.standard.bool(forKey: "isFullBackup")) ? .deepValidation : .incremental
        startBackup(camera: camera, destinationURL: destinationURL, scanMode: mode)
    }

    func startBackup(camera: ICCameraDevice, destinationURL: URL, scanMode: BackupScanMode) {
        switch state {
        case .idle, .completed, .failed:
            break
        case .scanning, .copying, .paused, .interrupted:
            print("BackupEngine: Ignoring start request because another backup is already active.")
            return
        }

        let session = beginBackupSession()
        self.state = .scanning
        self.stats = .empty
        self.lastBackedUpFileName = ""
        self.recentlyProcessedFileNames = []
        self.recentlyProcessedFiles = []
        self.currentCamera = camera
        self.currentDeviceName = camera.name ?? "Device"
        self.currentDeviceID = camera.uuidString ?? camera.name ?? ""

        let destURL = destinationURL
        self.targetDirectory = destURL
        self.manifestPath = destURL.appendingPathComponent(".backup_manifest.json")

        do {
            try FileManager.default.createDirectory(at: destURL, withIntermediateDirectories: true, attributes: nil)
        } catch {
            let msg = "Failed to create destination folder: \(error.localizedDescription)"
            self.state = .failed(msg)
            self.stats.lastError = msg
            sendNotification(title: "Backup Destination Unavailable", body: "Could not create target directory on destination storage.")
            return
        }

        loadManifest()

        // Robustly gather all media files using recursive camera file traversal
        var allFiles: [ICCameraFile] = []
        let rootItems = camera.mediaFiles ?? camera.contents ?? []
        allFiles = rootItems.flatMap { DeviceMonitor.cameraFiles(in: $0) }
        if allFiles.isEmpty, let direct = camera.mediaFiles {
            allFiles = direct.compactMap { $0 as? ICCameraFile }
        }

        print("BackupEngine: Found \(allFiles.count) total files on device.")

        let deviceID = camera.uuidString ?? camera.name ?? ""

        // Apply media-type filter
        let mediaType = Self.deviceMediaType(for: deviceID)
        let filteredFiles: [ICCameraFile]
        switch mediaType {
        case 1: filteredFiles = allFiles.filter { $0.isPhotoFile }
        case 2: filteredFiles = allFiles.filter { $0.isVideoFile }
        default: filteredFiles = allFiles
        }

        // Optionally skip IMG_E#### files (iOS auto-processed edited copies)
        let skipEdited = Self.deviceSkipEditedDuplicates(for: deviceID)
        let finalFiles = skipEdited
            ? filteredFiles.filter { !BackupEngine.isIOSEditedDuplicate(name: $0.name ?? "") }
            : filteredFiles

        let isFullBackup = (scanMode != .incremental)
        let isRecountMode = (scanMode == .fullRecountAndReconcile)
        let manifestSnapshot = self.manifest
        
        let infos: [ScanFileInfo] = finalFiles.enumerated().map { idx, file in
            let name = file.name ?? ""
            return ScanFileInfo(
                index: idx,
                name: name,
                fileSize: file.fileSize,
                creationDate: file.creationDate,
                isPhoto: file.isPhotoFile,
                isVideo: file.isVideoFile,
                manifestKey: getManifestKey(for: file)
            )
        }

        self.validationStats = ValidationRecountStats(
            sourceFileCount: finalFiles.count,
            destinationFileCount: 0,
            isRecountComplete: false,
            isReconciliationComplete: false,
            isReconciliationSkipped: false,
            missingOrCorruptCount: 0,
            verifiedSafeCount: 0,
            reorganizedCount: 0,
            currentScannedFile: "",
            scannedCount: 0,
            totalToScan: finalFiles.count,
            currentPhase: .readingCatalog,
            scanMode: scanMode
        )

        scanTask = Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) { [weak self] () -> (newIndices: [Int], updatedManifest: [String: Bool], skippedCount: Int, recountStats: ValidationRecountStats?, reorganizedCount: Int) in
                let accessed = destURL.startAccessingSecurityScopedResource()
                defer {
                    if accessed { destURL.stopAccessingSecurityScopedResource() }
                }
                var updatedManifest = manifestSnapshot
                var newIndices: [Int] = []
                var skippedCount = 0
                var verifiedSafe = 0
                var missingOrCorrupt = 0
                var reorganizedCount = 0
                let fm = FileManager.default

                // Step 1 & 2: Build destination file index & recount ONLY for Full Recount & Reconcile mode
                var destCount = 0
                var destinationIndex: [String: URL] = [:]
                if isRecountMode {
                    await MainActor.run {
                        self?.validationStats?.currentPhase = .buildingIndex
                    }
                    destCount = Self.countMediaFilesInDestination(destURL)
                    destinationIndex = Self.buildDestinationIndex(baseURL: destURL, fm: fm)
                    await MainActor.run {
                        self?.validationStats?.destinationFileCount = destCount
                    }
                }

                // Step 3: Per-file parity verification
                await MainActor.run {
                    self?.validationStats?.currentPhase = .validatingAndReorganizing
                }

                // Read folder-organisation prefs once (UserDefaults is thread-safe).
                let organizeByYear  = Self.deviceOrganizeByYear(for: deviceID)
                let organizeByMonth = Self.deviceOrganizeByMonth(for: deviceID)

                for (idx, info) in infos.enumerated() {
                    let key = info.manifestKey
                    let targetDir = Self.destinationDir(
                        creationDate: info.creationDate,
                        baseURL: destURL,
                        organizeByYear: organizeByYear,
                        organizeByMonth: organizeByMonth
                    )

                    if isRecountMode {
                        // Full Recount mode: Smart reorganization & cross-layout matching
                        let checkResult = Self.smartFindAndRelocateExistingFile(
                            file: info,
                            targetDir: targetDir,
                            baseURL: destURL,
                            destinationIndex: destinationIndex,
                            fm: fm
                        )

                        if checkResult.found {
                            if checkResult.relocated {
                                reorganizedCount += 1
                            }
                            updatedManifest[key] = true
                            skippedCount += 1
                            verifiedSafe += 1
                        } else {
                            missingOrCorrupt += 1
                            newIndices.append(info.index)
                        }
                    } else {
                        // Deep Validation & Incremental mode: SMB-safe fast path
                        // 1. Trust manifest first
                        if manifestSnapshot[key] == true {
                            updatedManifest[key] = true
                            skippedCount += 1
                            verifiedSafe += 1
                        } else {
                            // 2. Not in manifest: check expected target file directly on disk
                            let targetPath = targetDir.appendingPathComponent(info.name)
                            if let attrs = try? fm.attributesOfItem(atPath: targetPath.path),
                               let size = attrs[.size] as? Int64,
                               info.fileSize <= 0 || size == info.fileSize {
                                updatedManifest[key] = true
                                skippedCount += 1
                                verifiedSafe += 1
                            } else {
                                missingOrCorrupt += 1
                                newIndices.append(info.index)
                            }
                        }
                    }

                    // Periodically push live scan progress to UI (every 50 files or on last)
                    if idx % 50 == 0 || idx == infos.count - 1 {
                        let currentIdx = idx + 1
                        let currentName = info.name
                        let safeSnapshot = verifiedSafe
                        let reorgSnapshot = reorganizedCount
                        let missingSnapshot = missingOrCorrupt
                        let destSnapshot = isRecountMode ? destCount : (safeSnapshot + reorgSnapshot)
                        await MainActor.run {
                            guard let s = self else { return }
                            var stats = s.validationStats ?? ValidationRecountStats()
                            stats.scannedCount = currentIdx
                            stats.totalToScan = infos.count
                            stats.currentScannedFile = currentName
                            stats.verifiedSafeCount = safeSnapshot
                            stats.reorganizedCount = reorgSnapshot
                            stats.missingOrCorruptCount = missingSnapshot
                            stats.currentPhase = .validatingAndReorganizing
                            stats.scanMode = scanMode
                            stats.destinationFileCount = destSnapshot
                            s.validationStats = stats
                        }
                    }
                }

                // Prune empty directories left behind after relocation ONLY in recount mode
                if isRecountMode {
                    Self.pruneEmptyDirectories(in: destURL, fm: fm)
                }

                let recountStats = ValidationRecountStats(
                    sourceFileCount: infos.count,
                    destinationFileCount: isRecountMode ? destCount : (verifiedSafe + reorganizedCount),
                    isRecountComplete: true,
                    isReconciliationComplete: true,
                    isReconciliationSkipped: false,
                    missingOrCorruptCount: missingOrCorrupt,
                    verifiedSafeCount: verifiedSafe,
                    reorganizedCount: reorganizedCount,
                    currentScannedFile: "",
                    scannedCount: infos.count,
                    totalToScan: infos.count,
                    currentPhase: .complete,
                    scanMode: scanMode
                )

                return (newIndices, updatedManifest, skippedCount, recountStats, reorganizedCount)
            }.value

            guard session == self.backupSessionID, !Task.isCancelled else { return }

            if let stats = result.recountStats {
                self.validationStats = stats
            }

            self.manifest = result.updatedManifest
            if self.manifest != manifestSnapshot {
                self.saveManifest()
            }
            
            let newFiles = result.newIndices.compactMap { idx -> ICCameraFile? in
                guard idx < finalFiles.count else { return nil }
                return finalFiles[idx]
            }
            
            let skipped = result.skippedCount
            let reorganized = result.reorganizedCount
            
            print("BackupEngine: \(newFiles.count) files to backup, \(skipped) already backed up, \(reorganized) reorganized.")

            if newFiles.isEmpty {
                self.stats.totalFiles = filteredFiles.count
                self.stats.skippedFiles = skipped
                self.stats.manifestSize = self.manifest.count
                self.stats.isFullBackup = isFullBackup
                self.stats.reorganizedCount = reorganized
                self.state = .completed(copiedCount: 0)
                self.sendNotification(title: "Backup Complete", body: "No new photos to back up.")
                self.openFolderIfRequested()
                return
            }

            // Initialise counters & stats
            let totalBatches = Int(ceil(Double(newFiles.count) / Double(self.batchSize)))

            self.pendingFiles = newFiles
            self.downloadQueue = []
            self.retryCounters = [:]
            self.totalToDownload = newFiles.count
            self.successfullyDownloaded = 0
            self.failedDownloads = 0
            self.sinceLastManifestSave = 0

            self.stats = BackupStats(
                totalFiles: newFiles.count,
                skippedFiles: skipped,
                successCount: 0,
                failedCount: 0,
                retriedCount: 0,
                currentBatch: 0,
                totalBatches: totalBatches,
                filesInCurrentBatch: 0,
                currentFileName: "",
                failedFileNames: [],
                startTime: Date(),
                lastError: "",
                isFullBackup: isFullBackup,
                manifestSize: self.manifest.count,
                reorganizedCount: reorganized
            )

            if self.pausedByDeviceLock {
                self.state = .paused(current: 0, total: self.totalToDownload, progress: 0.0)
                print("BackupEngine: Scan finished while phone locked — waiting for unlock.")
            } else {
                self.state = .copying(current: 0, total: self.totalToDownload, progress: 0.0)
                self.sendNotification(title: "Backup Started", body: "Backing up \(self.totalToDownload) photos/videos…")
                self.loadNextBatch()
            }
        }
    }

    @discardableResult
    private func beginBackupSession() -> Int {
        scanTask?.cancel()
        scanTask = nil
        pendingWorkTask?.cancel()
        pendingWorkTask = nil
        backupSessionID += 1
        return backupSessionID
    }

    private func invalidateBackupSession() {
        backupSessionID += 1
        scanTask?.cancel()
        scanTask = nil
        pendingWorkTask?.cancel()
        pendingWorkTask = nil
        downloadTimeoutTask?.cancel()
        downloadTimeoutTask = nil
        inFlightFile = nil
    }

    private func resetBackupRuntimeState() {
        pendingFiles = []
        downloadQueue = []
        retryCounters = [:]
        lastBackedUpFileName = ""
        recentlyProcessedFileNames = []
        recentlyProcessedFiles = []
        totalToDownload = 0
        successfullyDownloaded = 0
        failedDownloads = 0
        sinceLastManifestSave = 0
        currentCamera = nil
        currentDeviceName = ""
        currentDeviceID = ""
        pausedByDeviceLock = false
        pausedDuringScan = false
        inFlightFile = nil
    }

    func pauseBackup() {
        guard case .copying(let current, let total, let progress) = state else { return }
        cancelInFlightDownload()
        self.state = .paused(current: current, total: total, progress: progress)
        print("BackupEngine: Paused at \(current)/\(total)")
    }

    func resumeBackup() {
        guard case .paused(let current, let total, let progress) = state else { return }
        pausedByDeviceLock = false
        self.state = .copying(current: current, total: total, progress: progress)
        print("BackupEngine: Resumed at \(current)/\(total)")
        downloadNext()
    }

    /// Pause an active backup because the source device locked.
    func pauseForDeviceLock() {
        guard !pausedByDeviceLock else { return }
        pausedByDeviceLock = true

        // Re-queue any in-flight download so it can be retried after unlock.
        if let file = inFlightFile {
            downloadQueue.insert(file, at: 0)
            inFlightFile = nil
        }
        cancelInFlightDownload()

        switch state {
        case .copying(let current, let total, let progress):
            state = .paused(current: current, total: total, progress: progress)
            print("BackupEngine: Paused for device lock at \(current)/\(total)")
        case .scanning:
            // Device locked while we were scanning (e.g. deep validation).
            // Cancel the scan task immediately — continuing would waste time and
            // then try to download from a locked device.
            scanTask?.cancel()
            scanTask = nil
            pausedDuringScan = true
            state = .paused(current: 0, total: 0, progress: 0)
            print("BackupEngine: Device locked during scan — scan cancelled, will re-scan after unlock.")
        default:
            break
        }
    }

    /// Resume a backup that was paused because the source device locked.
    /// Returns true if the caller should re-enqueue the job (scan was interrupted).
    @discardableResult
    func resumeFromDeviceLock() -> Bool {
        guard pausedByDeviceLock else { return false }
        pausedByDeviceLock = false
        cancelInFlightDownload()

        if pausedDuringScan {
            // Scan was cancelled on lock — caller must re-enqueue the job.
            pausedDuringScan = false
            resetBackupRuntimeState()
            state = .idle
            print("BackupEngine: Device unlocked after scan was interrupted — signalling re-enqueue.")
            return true
        }

        switch state {
        case .paused(let current, let total, let progress):
            state = .copying(current: current, total: total, progress: progress)
            print("BackupEngine: Resumed after device unlock at \(current)/\(total)")
            downloadNext()
        case .scanning:
            print("BackupEngine: Device unlocked during scan — scan continues.")
        default:
            break
        }
        return false
    }

    private func cancelInFlightDownload() {
        pendingWorkTask?.cancel()
        pendingWorkTask = nil
        downloadTimeoutTask?.cancel()
        downloadTimeoutTask = nil
    }

    /// Called when the source device disconnects mid-backup.
    /// Saves the manifest so progress is not lost, then freezes into .interrupted.
    func interruptBackup() {
        switch state {
        case .scanning:
            // Device disconnected while we were still scanning — cancel the task
            // immediately so we don't keep walking the destination folder pointlessly.
            print("BackupEngine: Interrupted during scan — cancelling scan task.")
            invalidateBackupSession()
            resetBackupRuntimeState()
            state = .idle
        case .copying(let current, let total, let progress),
             .paused(let current, let total, let progress):
            saveManifest()
            downloadQueue = []   // discard in-flight requests
            state = .interrupted(current: current, total: total, progress: progress)
            print("BackupEngine: Interrupted at \(current)/\(total)")
        default:
            break
        }
    }

    /// Cancels an interrupted backup and resets the engine to idle.
    func cancelInterrupted() {
        guard case .interrupted = state else { return }
        invalidateBackupSession()
        resetBackupRuntimeState()
        state = .idle
        print("BackupEngine: Interrupted backup cancelled.")
    }

    func cancelBackup() {
        switch state {
        case .scanning, .copying, .paused:
            invalidateBackupSession()
            saveManifest()
            resetBackupRuntimeState()
            state = .idle
            print("BackupEngine: Active backup cancelled.")
        case .interrupted:
            cancelInterrupted()
        default:
            break
        }
    }

    private func noteProcessedFileName(_ name: String) {
        guard !name.isEmpty, name != "unknown", name != "file" else { return }
        recentlyProcessedFileNames.removeAll { $0 == name }
        recentlyProcessedFileNames.insert(name, at: 0)
        if recentlyProcessedFileNames.count > 9 {
            recentlyProcessedFileNames.removeLast(recentlyProcessedFileNames.count - 9)
        }
    }

    private func noteProcessedFile(_ file: ICCameraFile) {
        guard let name = file.name, !name.isEmpty else { return }
        noteProcessedFileName(name)
        recentlyProcessedFiles.removeAll { $0.name == name }
        recentlyProcessedFiles.insert(file, at: 0)
        if recentlyProcessedFiles.count > 9 {
            recentlyProcessedFiles.removeLast(recentlyProcessedFiles.count - 9)
        }
    }

    // MARK: - Batching

    private func loadNextBatch() {
        guard case .copying = state else { return }
        guard !pendingFiles.isEmpty else {
            if downloadQueue.isEmpty {
                finalizeBackup()
            }
            return
        }

        let count = min(batchSize, pendingFiles.count)
        downloadQueue = Array(pendingFiles.prefix(count))
        pendingFiles.removeFirst(count)

        stats.currentBatch += 1
        stats.filesInCurrentBatch = count
        print("BackupEngine: Starting batch \(stats.currentBatch)/\(stats.totalBatches) — \(count) files.")
        downloadNext()
    }

    private func downloadNext() {
        guard case .copying = state else { return }
        guard !downloadQueue.isEmpty else {
            let session = backupSessionID
            pendingWorkTask?.cancel()
            pendingWorkTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard session == self.backupSessionID, !Task.isCancelled else { return }
                guard case .copying = self.state else { return }
                self.loadNextBatch()
            }
            return
        }

        let file = downloadQueue.removeFirst()
        let currentName = file.name ?? "unknown"
        stats.currentFileName = currentName
        noteProcessedFile(file)
        inFlightFile = file

        guard let camera = currentCamera, let destURL = targetDirectory else {
            let msg = "Device disconnected or destination path lost."
            self.state = .failed(msg)
            self.stats.lastError = msg
            return
        }

        // Resolve per-file destination (flat root or YYYY/MM - Month subfolder)
        let fileDestDir = destinationDirectory(for: file, baseURL: destURL)
        if fileDestDir != destURL {
            try? FileManager.default.createDirectory(
                at: fileDestDir,
                withIntermediateDirectories: true,
                attributes: nil
            )
        }

        let options: [ICDownloadOption: Any] = [
            .downloadsDirectoryURL: fileDestDir,
            .overwrite: false,
            .sidecarFiles: true
        ]

        print("BackupEngine: Requesting \(file.name ?? "file") → \(fileDestDir.lastPathComponent)/")

        let session = backupSessionID
        pendingWorkTask?.cancel()
        pendingWorkTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: interFileDelayMs * 1_000_000)
            guard session == self.backupSessionID, !Task.isCancelled else { return }
            guard case .copying = self.state else { return }
            guard self.currentCamera === camera else { return }
            camera.requestDownloadFile(
                file,
                options: options,
                downloadDelegate: self,
                didDownloadSelector: #selector(self.didDownloadFile(_:error:options:contextInfo:)),
                contextInfo: nil
            )
            self.startDownloadTimeout(for: file, session: session)
        }
    }

    /// If a download callback never arrives (common when the phone locks mid-transfer),
    /// re-queue the file and pause until the device is unlocked again.
    private func startDownloadTimeout(for file: ICCameraFile, session: Int) {
        downloadTimeoutTask?.cancel()
        let fileName = file.name ?? "unknown"
        downloadTimeoutTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(downloadTimeoutSeconds * 1_000_000_000))
            guard session == self.backupSessionID, !Task.isCancelled else { return }
            guard case .copying = self.state else { return }
            guard self.inFlightFile?.name == file.name else { return }
            print("BackupEngine: Download timeout for \(fileName) — pausing for device unlock.")
            self.inFlightFile = nil
            self.downloadQueue.insert(file, at: 0)
            self.pauseForDeviceLock()
        }
    }

    // MARK: - Finalize

    private func finalizeBackup() {
        saveManifest()
        stats.currentFileName = ""
        print("BackupEngine: Done. Success: \(successfullyDownloaded), Failed: \(failedDownloads)")

        if failedDownloads > 0 {
            // Partial failures are not fatal — failed files will be retried next run.
            // Use .completed so the UI shows a success summary, not a scary error state.
            let retryNote = "\(failedDownloads) file(s) couldn't be copied and will be retried automatically next time you sync."
            self.state = .completed(copiedCount: successfullyDownloaded)
            self.stats.lastError = retryNote
            sendNotification(
                title: "Backup Complete",
                body: "Backed up \(successfullyDownloaded) of \(totalToDownload) files. \(failedDownloads) will retry next sync."
            )
        } else {
            self.state = .completed(copiedCount: successfullyDownloaded)
            sendNotification(
                title: "Backup Complete",
                body: "Successfully backed up \(successfullyDownloaded) photos/videos."
            )
        }

        openFolderIfRequested()
    }

    // MARK: - Helpers

    /// Image Capture's completion callback means the transfer ended, but we
    /// still verify the destination before allowing a caller to clean up the
    /// source device. A zero file-size is treated as unknown rather than a
    /// mismatch because some cameras do not report sizes reliably.
    private func hasVerifiedLocalCopy(of file: ICCameraFile) -> Bool {
        guard let targetDirectory,
              let name = file.name,
              !name.isEmpty
        else { return false }

        let localURL = destinationDirectory(for: file, baseURL: targetDirectory)
            .appendingPathComponent(name)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: localURL.path),
              let localSize = attributes[.size] as? Int64
        else { return false }

        return file.fileSize <= 0 || localSize == file.fileSize
    }

    private func openFolderIfRequested() {
        guard UserDefaults.standard.bool(forKey: "openFolderAfterBackup"),
              let dest = targetDirectory else { return }
        DispatchQueue.main.async {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: dest.path)
        }
    }

    fileprivate func getManifestKey(for file: ICCameraFile) -> String {
        let name = file.name ?? "unknown"
        let size = file.fileSize
        let dateInterval = file.creationDate?.timeIntervalSince1970 ?? 0.0
        return "\(name)_\(size)_\(dateInterval)"
    }

    /// Returns true if `name` matches the iOS convention for auto-edited duplicates
    /// (e.g. IMG_E6626.HEIC, IMG_E0042.JPG).
    /// The pattern is: starts with IMG_E followed immediately by a digit.
    nonisolated static func isIOSEditedDuplicate(name: String) -> Bool {
        let upper = name.uppercased()
        guard upper.hasPrefix("IMG_E") else { return false }
        // The character right after "IMG_E" must be a digit
        let afterPrefix = upper.dropFirst(5)
        return afterPrefix.first?.isNumber == true
    }

    fileprivate func loadManifest() {
        guard let path = manifestPath, FileManager.default.fileExists(atPath: path.path) else {
            self.manifest = [:]
            return
        }
        do {
            let data = try Data(contentsOf: path)
            self.manifest = try JSONDecoder().decode([String: Bool].self, from: data)
            print("BackupEngine: Loaded manifest with \(manifest.count) entries.")
        } catch {
            print("BackupEngine: Failed to load manifest, resetting. Error: \(error.localizedDescription)")
            self.manifest = [:]
        }
    }

    fileprivate func saveManifest() {
        guard let path = manifestPath else { return }
        manifestSaveSequence += 1
        let sequence = manifestSaveSequence
        let snapshot = manifest
        let writer = manifestWriter

        Task.detached(priority: .utility) {
            await writer.save(snapshot, to: path, sequence: sequence)
        }

        if let dest = targetDirectory {
            manifestCache.removeValue(forKey: dest.standardizedFileURL)
        }
    }

    fileprivate func sendNotification(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
            center.add(request) { error in
                if let error { print("BackupEngine: Notification error: \(error.localizedDescription)") }
            }
        }
    }
}

// MARK: - Download Delegate

extension BackupEngine: @preconcurrency ICCameraDeviceDownloadDelegate {
    @objc func didDownloadFile(
        _ file: ICCameraFile,
        error: Error?,
        options: [String: Any],
        contextInfo: UnsafeMutableRawPointer?
    ) {
        switch state {
        case .copying, .paused:
            break
        default:
            return
        }

        downloadTimeoutTask?.cancel()
        downloadTimeoutTask = nil
        inFlightFile = nil

        if let error = error {
            let name = file.name ?? "file"
            let retries = retryCounters[name, default: 0]

            if retries < maxRetries {
                print("BackupEngine: Error for \(name), retrying (\(retries + 1)/\(maxRetries))…")
                retryCounters[name] = retries + 1
                stats.retriedCount += 1
                downloadQueue.insert(file, at: 0)
            } else {
                print("BackupEngine: Permanent failure for \(name): \(error.localizedDescription)")
                retryCounters.removeValue(forKey: name)
                self.failedDownloads += 1
                stats.failedCount += 1
                stats.lastError = "\(name): \(error.localizedDescription)"
                if !stats.failedFileNames.contains(name) {
                    stats.failedFileNames.append(name)
                }
            }
        } else {
            let name = file.name ?? "file"
            print("BackupEngine: Downloaded \(name) successfully.")
            self.lastBackedUpFileName = name
            noteProcessedFile(file)
            self.successfullyDownloaded += 1
            stats.successCount += 1

            let key = getManifestKey(for: file)
            self.manifest[key] = true

            sinceLastManifestSave += 1
            if sinceLastManifestSave >= manifestSaveInterval {
                saveManifest()
                sinceLastManifestSave = 0
            }

            if hasVerifiedLocalCopy(of: file) {
                onVerifiedFileBackup?(file)
            } else {
                print("BackupEngine: Skipping source cleanup for \(name) because its local copy could not be verified.")
            }
        }

        let currentCount = successfullyDownloaded + failedDownloads
        let progress = Double(currentCount) / Double(totalToDownload)

        // If the device disconnected while this download was in-flight, stay interrupted.
        if case .interrupted = state { return }

        switch state {
        case .paused:
            self.state = .paused(current: currentCount, total: totalToDownload, progress: progress)
        case .copying:
            self.state = .copying(current: currentCount, total: totalToDownload, progress: progress)
            downloadNext()
        default:
            break
        }
    }
}

// MARK: - ICCameraFile Helpers

extension ICCameraFile {
    /// Best available capture timestamp for gallery date filters.
    /// ImageCaptureCore sometimes omits `creationDate`; fall back to modification date or filename patterns.
    var effectiveCaptureDate: Date? {
        if let creationDate { return creationDate }
        if let modificationDate { return modificationDate }
        return Self.dateFromFilename(name ?? "")
    }

    private static func dateFromFilename(_ name: String) -> Date? {
        let stem = (name as NSString).deletingPathExtension
        let patterns = [
            "yyyyMMdd_HHmmss",
            "yyyyMMdd-HHmmss",
            "yyyyMMdd",
            "yyyy-MM-dd_HH-mm-ss",
            "yyyy-MM-dd"
        ]
        let formatters = patterns.map { pattern -> DateFormatter in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone.current
            formatter.dateFormat = pattern
            return formatter
        }

        for formatter in formatters {
            for length in [15, 14, 8, 19, 10] where stem.count >= length {
                let slice = String(stem.prefix(length))
                if let date = formatter.date(from: slice) {
                    return date
                }
            }
        }
        return nil
    }

    var isPhotoFile: Bool {
        let ext = (self.name?.lowercased() ?? "") as NSString
        let photoExts: Set<String> = [
            "jpg", "jpeg", "heic", "heif", "png", "gif", "tiff", "tif",
            "dng", "webp", "bmp",
            // Common RAW formats
            "arw", "cr2", "cr3", "nef", "nrw", "orf", "rw2", "raf", "pef", "srw"
        ]
        if photoExts.contains(ext.pathExtension) { return true }
        return uti.map { $0.contains("image") || $0.contains("jpeg") || $0.contains("heic") || $0.contains("png") } ?? false
    }

    var isVideoFile: Bool {
        let ext = (self.name?.lowercased() ?? "") as NSString
        let videoExts: Set<String> = [
            "mp4", "mov", "m4v", "avi", "mkv",
            "3gp", "3g2", "ts", "mts", "m2ts", "wmv", "flv", "webm"
        ]
        if videoExts.contains(ext.pathExtension) { return true }
        return uti.map { $0.contains("movie") || $0.contains("video") || $0.contains("mp4") || $0.contains("quicktime") } ?? false
    }
}
