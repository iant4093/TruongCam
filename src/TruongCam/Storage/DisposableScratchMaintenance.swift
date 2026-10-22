import Foundation

/// A cold-process sweep of old, app-owned sharing copies. Pending capture
/// recovery and the retained library are never inputs to this maintenance.
enum DisposableScratchMaintenance {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var started = false
    static let minimumAge: TimeInterval = 24 * 60 * 60

    static func runOnce(support: URL, temporary: URL) {
        lock.lock()
        guard !started else { lock.unlock(); return }
        started = true
        lock.unlock()
        let cutoff = Date().addingTimeInterval(-minimumAge)
        let staging = support.appendingPathComponent("ExportStaging", isDirectory: true)
        if let base = try? support.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
           base.isDirectory == true, base.isSymbolicLink != true,
           let folder = try? staging.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
           folder.isDirectory == true, folder.isSymbolicLink != true {
            prune(parent: staging.appendingPathComponent("TruongCamExport", isDirectory: true), prefix: "", before: cutoff)
        }
        prune(parent: temporary, prefix: "TruongCamPhotos-", before: cutoff)
    }

    /// Nonrecursive discovery; only a UUID-named ordinary directory can be
    /// retired. Links, fresh/undated entries and unrelated files are preserved.
    static func prune(parent: URL, prefix: String, before cutoff: Date) {
        let fm = FileManager.default
        guard let root = try? parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              root.isDirectory == true, root.isSymbolicLink != true,
              let entries = try? fm.contentsOfDirectory(at: parent,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]) else { return }
        for entry in entries {
            let name = entry.lastPathComponent
            guard name.hasPrefix(prefix), name.count == prefix.count + 36,
                  let id = UUID(uuidString: String(name.dropFirst(prefix.count))),
                  id.uuidString.lowercased() == name.dropFirst(prefix.count).lowercased(),
                  let value = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]),
                  value.isDirectory == true, value.isSymbolicLink != true,
                  let modified = value.contentModificationDate, modified < cutoff else { continue }
            try? fm.removeItem(at: entry)
        }
    }
}
