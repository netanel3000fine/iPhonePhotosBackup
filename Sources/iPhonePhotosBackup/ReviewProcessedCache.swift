import Foundation

public struct RecentDeletionRecord: Codable, Hashable {
    public let id: String
    public let name: String
    public let timestamp: Date

    public init(id: String, name: String, timestamp: Date = Date()) {
        self.id = id
        self.name = name
        self.timestamp = timestamp
    }
}

private struct ReviewCachePayload: Codable {
    var processedIDs: [String]
    var recentDeletions: [RecentDeletionRecord]
}

/// Lightweight persistent cache that records which photos the user has
/// already swiped in Quick Swiping and tracks recent deletions for retry/verification.
/// Survives app restarts.
/// Items are stored in Application Support.
final class ReviewProcessedCache {

    static let shared = ReviewProcessedCache()

    private let cacheURL: URL
    private(set) var processedIDs: Set<String> = []
    private(set) var recentDeletions: [String: RecentDeletionRecord] = [:] // Keyed by ID

    private init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = appSupport.appendingPathComponent("iPhonePhotosBackup", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        cacheURL = dir.appendingPathComponent("review_processed_cache.json")
        load()
    }

    // MARK: - Public API (Processed IDs)

    func markProcessed(id: String) {
        guard !processedIDs.contains(id) else { return }
        processedIDs.insert(id)
        save()
    }

    func unmarkProcessed(id: String) {
        guard processedIDs.contains(id) else { return }
        processedIDs.remove(id)
        save()
    }

    // MARK: - Public API (Recent Deletions)

    func recordRecentDeletions(_ items: [(id: String, name: String)]) {
        var changed = false
        for item in items {
            let record = RecentDeletionRecord(id: item.id, name: item.name, timestamp: Date())
            recentDeletions[item.id] = record
            if !processedIDs.contains(item.id) {
                processedIDs.insert(item.id)
            }
            changed = true
        }
        if changed {
            save()
        }
    }

    func removeRecentDeletions(matchingNames names: Set<String>) {
        guard !names.isEmpty else { return }
        let initialCount = recentDeletions.count
        recentDeletions = recentDeletions.filter { !names.contains($0.value.name) }
        if recentDeletions.count != initialCount {
            save()
        }
    }

    func removeRecentDeletions(matchingIDs ids: Set<String>) {
        guard !ids.isEmpty else { return }
        var changed = false
        for id in ids {
            if recentDeletions.removeValue(forKey: id) != nil {
                changed = true
            }
        }
        if changed {
            save()
        }
    }

    func allRecentDeletions() -> [RecentDeletionRecord] {
        Array(recentDeletions.values)
    }

    func clearAll() {
        processedIDs.removeAll()
        recentDeletions.removeAll()
        try? FileManager.default.removeItem(at: cacheURL)
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: cacheURL) else { return }
        if let decoded = try? JSONDecoder().decode(ReviewCachePayload.self, from: data) {
            processedIDs = Set(decoded.processedIDs)
            recentDeletions = Dictionary(uniqueKeysWithValues: decoded.recentDeletions.map { ($0.id, $0) })
        } else if let legacy = try? JSONDecoder().decode([String].self, from: data) {
            // Backward-compatible fallback for legacy JSON array of IDs
            processedIDs = Set(legacy)
            recentDeletions = [:]
        }
    }

    private func save() {
        let payload = ReviewCachePayload(
            processedIDs: Array(processedIDs),
            recentDeletions: Array(recentDeletions.values)
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }
}
