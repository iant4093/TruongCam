import Foundation

// Composition root for the storage stack.
//
// ARCHITECTURE.md: "Do not build a generic dependency-injection framework." This
// is the single place that constructs the concrete storage services, so the UI
// and the camera layer only ever see protocols.
//
// There is no in-container fallback: if the support directory cannot be created,
// the factory returns nil and the app reports an unavailable library instead of
// pretending the app sandbox is the permanent library.

enum LibraryStoreFactory {
    /// The app's private, disposable support directory. Pending originals and
    /// the rebuildable index live here. This is NOT the permanent library.
    static func supportDirectory() -> URL? {
        let fileManager = FileManager.default
        guard let base = fileManager.urls(for: .applicationSupportDirectory,
                                          in: .userDomainMask).first else { return nil }
        let directory = base.appendingPathComponent("TruongCam", isDirectory: true)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        guard let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true, values.isSymbolicLink != true else { return nil }
        return directory
    }

    /// Directories that belong to this app's own removable container. A root
    /// inside any of them is rejected by `LibraryStore`, because deleting
    /// TruongCam would delete the user's originals with it.
    static func ownedContainerURLs() -> [URL] {
        let fileManager = FileManager.default
        var urls: [URL] = []
        for directory in [FileManager.SearchPathDirectory.documentDirectory,
                          .applicationSupportDirectory,
                          .cachesDirectory,
                          .libraryDirectory] {
            if let url = fileManager.urls(for: directory, in: .userDomainMask).first {
                urls.append(url)
            }
        }
        urls.append(fileManager.temporaryDirectory)
        return urls
    }

    static func makeDefaultStore() -> (any LibraryStoring)? {
        guard let support = supportDirectory() else { return nil }
        // Called on production's detached construction worker, before the
        // first export/import can acquire a native reader in this process.
        DisposableScratchMaintenance.runOnce(support: support, temporary: FileManager.default.temporaryDirectory)
        var staging = support.appendingPathComponent("ExportStaging", isDirectory: true)
        try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        guard let values = try? staging.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true, values.isSymbolicLink != true else { return nil }
        var backup = URLResourceValues(); backup.isExcludedFromBackup = true
        try? staging.setResourceValues(backup)
        return LibraryStore(
            supportDirectory: support,
            temporaryDirectory: staging,
            ownedContainerURLs: ownedContainerURLs())
    }

    static func makeDefaultIndex() -> (any LibraryIndexing)? {
        guard let support = supportDirectory() else { return nil }
        return SQLiteIndex(databaseURL: support.appendingPathComponent("library-index.sqlite"))
    }

    /// Thumbnails are disposable, so they live in Caches and are rebuilt from the
    /// originals whenever they are missing.
    ///
    /// REVIEW.md C10: the provider is no longer given a bare root URL. The gallery
    /// resolves each original through the store's balanced scope lease, so a root
    /// release cannot invalidate a decode in flight.
    static func makeDefaultThumbnails() -> (any ThumbnailProviding)? {
        let fm = FileManager.default
        guard let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let directory = caches.appendingPathComponent("TruongCamThumbnails", isDirectory: true)
        if let support = supportDirectory() {
            ThumbnailDiskBudget(directory: directory).adoptLegacy(from: support.appendingPathComponent("ThumbnailCache", isDirectory: true))
        }
        return ThumbnailService(rootURLProvider: { nil }, diskCacheDirectory: directory)
    }
}
