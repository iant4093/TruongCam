import Foundation

/// Only disposable, hashed thumbnail files are eligible. All callers already
/// run on the scoped display I/O worker; no maintenance runs per preview frame.
final class ThumbnailDiskBudget: @unchecked Sendable {
    static let defaultBytes = 32 * 1024 * 1024
    private static let lock = NSLock()
    let directory: URL
    let budget: Int
    let entryLimit: Int
    private var hasTrimmed = false

    init(directory: URL, bytes: Int = defaultBytes, entries: Int = 256) {
        self.directory = directory.standardizedFileURL
        budget = max(0, bytes); entryLimit = max(0, entries)
    }
    static func owns(_ name: String) -> Bool {
        name.hasSuffix(".tcthumb") && name.count == 72
            && name.dropLast(8).utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private func regularRoot() -> Bool {
        guard let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }
    func prepareRead() {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard !hasTrimmed else { return }
        hasTrimmed = true
        trimLocked()
    }
    func write(_ data: Data, name: String) {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard Self.owns(name), data.count <= budget, entryLimit > 0 else { return }
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) {
            guard (try? fm.createDirectory(at: directory, withIntermediateDirectories: true)) != nil else { return }
        }
        guard regularRoot() else { return }
        let destination = directory.appendingPathComponent(name)
        if let values = try? destination.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true { return }
        guard (try? data.write(to: destination, options: .atomic)) != nil else { return }
        hasTrimmed = true
        trimLocked()
    }
    func canRead(_ url: URL) -> Bool {
        guard regularRoot(), url.deletingLastPathComponent().standardizedFileURL.path == directory.path,
              Self.owns(url.lastPathComponent),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }
    /// Move old disposable entries rather than forcing every gallery to decode
    /// again. Unknown files and symbolic links never acquire cache authority.
    func adoptLegacy(from legacy: URL) {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let fm = FileManager.default
        guard legacy.standardizedFileURL.path != directory.path,
              let root = try? legacy.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              root.isDirectory == true, root.isSymbolicLink != true else { return }
        if !fm.fileExists(atPath: directory.path) { try? fm.createDirectory(at: directory, withIntermediateDirectories: true) }
        guard regularRoot(), let files = try? fm.contentsOfDirectory(at: legacy,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return }
        for file in files where Self.owns(file.lastPathComponent) {
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let destination = directory.appendingPathComponent(file.lastPathComponent)
            if fm.fileExists(atPath: destination.path) { try? fm.removeItem(at: file) }
            else { try? fm.moveItem(at: file, to: destination) }
        }
        if (try? fm.contentsOfDirectory(atPath: legacy.path).isEmpty) == true { try? fm.removeItem(at: legacy) }
        hasTrimmed = true
        trimLocked()
    }
    private func trimLocked() {
        guard regularRoot(), let files = try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]) else { return }
        let entries = files.compactMap { url -> (URL, Int, Date)? in
            guard Self.owns(url.lastPathComponent),
                  let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]),
                  v.isRegularFile == true, v.isSymbolicLink != true, let size = v.fileSize else { return nil }
            return (url, size, v.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 == $1.2 ? $0.0.lastPathComponent < $1.0.lastPathComponent : $0.2 < $1.2 }
        var bytes = entries.reduce(Int64(0)) { $0 + Int64($1.1) }, count = entries.count
        for entry in entries {
            guard bytes > Int64(budget) || count > entryLimit else { break }
            if (try? FileManager.default.removeItem(at: entry.0)) != nil { bytes -= Int64(entry.1); count -= 1 }
        }
    }
}
