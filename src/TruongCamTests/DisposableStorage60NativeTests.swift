#if canImport(UIKit) && canImport(XCTest) && !TC_TESTKIT_STANDALONE
import Foundation
import XCTest
@testable import TruongCam

final class DisposableStorage60NativeTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("storage60-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func name(_ id: Int) -> String { String(format: "%064x.tcthumb", id) }
    private func size(_ root: URL) throws -> (Int, Int) {
        let entries = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey])
            .filter { ThumbnailDiskBudget.owns($0.lastPathComponent) && (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true }
        return (entries.count, try entries.reduce(0) { $0 + (try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) })
    }
    func testByteAndEntryBudgetsEvictOldestCacheWithoutChangingUnrelatedFiles() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("cache"), unknown = cache.appendingPathComponent("notes.txt")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data([91]).write(to: unknown)
        for i in 0..<4 {
            let file = cache.appendingPathComponent(name(i))
            try Data(repeating: UInt8(i), count: 12).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(i + 1))], ofItemAtPath: file.path)
        }
        let budget = ThumbnailDiskBudget(directory: cache, bytes: 24, entries: 3)
        budget.prepareRead()
        XCTAssertEqual(try size(cache).0, 2); XCTAssertEqual(try size(cache).1, 24)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.appendingPathComponent(name(0)).path))
        XCTAssertEqual(try Data(contentsOf: cache.appendingPathComponent(name(3))), Data(repeating: 3, count: 12))
        budget.write(Data(repeating: 9, count: 12), name: name(9))
        XCTAssertEqual(try size(cache).0, 2); XCTAssertLessThanOrEqual(try size(cache).1, 24)
        XCTAssertEqual(try Data(contentsOf: unknown), Data([91]))
        budget.write(Data(repeating: 1, count: 25), name: name(99))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.appendingPathComponent(name(99)).path))
        ThumbnailDiskBudget(directory: cache, bytes: 1000, entries: 1).prepareRead()
        XCTAssertEqual(try size(cache).0, 1)
    }
    func testCacheLinksAndForeignNamesCannotReadOrOverwriteOriginals() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("cache"), original = root.appendingPathComponent("original.dng")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data([4, 8, 15, 16]).write(to: original)
        let link = cache.appendingPathComponent(name(1))
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        let budget = ThumbnailDiskBudget(directory: cache, bytes: 12, entries: 1)
        budget.prepareRead(); XCTAssertFalse(budget.canRead(link))
        budget.write(Data([99]), name: name(1)); budget.write(Data([98]), name: "original.dng")
        XCTAssertEqual(try Data(contentsOf: original), Data([4, 8, 15, 16]))
        XCTAssertTrue((try link.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == true)
        XCTAssertFalse(ThumbnailDiskBudget.owns(String(repeating: "ａ", count: 64) + ".tcthumb"))
        let linkedRoot = root.appendingPathComponent("linked-cache")
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: cache)
        let untrusted = ThumbnailDiskBudget(directory: linkedRoot, bytes: 100)
        untrusted.write(Data([3]), name: name(3)); untrusted.prepareRead()
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.appendingPathComponent(name(3)).path))
    }
    func testLegacyCacheMovesKnownEntriesWithoutRewritingTheirPixels() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("support-cache"), destination = root.appendingPathComponent("caches")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let bytes = Data([0, 1, 2, 3, 4, 5])
        try bytes.write(to: legacy.appendingPathComponent(name(1)))
        try Data([7]).write(to: legacy.appendingPathComponent("unknown.json"))
        let budget = ThumbnailDiskBudget(directory: destination, bytes: 24)
        budget.adoptLegacy(from: legacy)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(name(1))), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.appendingPathComponent(name(1)).path))
        XCTAssertEqual(try Data(contentsOf: legacy.appendingPathComponent("unknown.json")), Data([7]))
        XCTAssertTrue(budget.canRead(destination.appendingPathComponent(name(1))))
        // A directory URL with the other trailing-slash spelling is still the
        // same cache; migration must never retire its own entries as duplicates.
        budget.adoptLegacy(from: URL(fileURLWithPath: destination.path, isDirectory: true))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(name(1))), bytes)
    }
    func testConcurrentCacheWritersStayWithinOneDirectoryBudget() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let budgets = (0..<3).map { _ in ThumbnailDiskBudget(directory: root, bytes: 128, entries: 6) }
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<40 {
                let file = name(i), budget = budgets[i % budgets.count]
                group.addTask { budget.write(Data(repeating: 1, count: 16), name: file) }
            }
        }
        XCTAssertLessThanOrEqual(try size(root).0, 6); XCTAssertLessThanOrEqual(try size(root).1, 128)
    }
    func testAbandonedScratchSweepRetiresOnlyOldOwnedDirectories() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let cutoff = Date(timeIntervalSince1970: 100_000), old = Date(timeIntervalSince1970: 1)
        let original = root.appendingPathComponent("retained-original.dng")
        try Data([1, 2, 3]).write(to: original)
        for prefix in ["", "TruongCamPhotos-"] {
            let parent = root.appendingPathComponent(prefix.isEmpty ? "exports" : "temp")
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let stale = parent.appendingPathComponent(prefix + UUID().uuidString)
            let fresh = parent.appendingPathComponent(prefix + UUID().uuidString)
            let unknown = parent.appendingPathComponent("user-files")
            let linked = parent.appendingPathComponent(prefix + UUID().uuidString)
            for item in [stale, fresh, unknown] { try FileManager.default.createDirectory(at: item, withIntermediateDirectories: true) }
            try FileManager.default.createSymbolicLink(at: stale.appendingPathComponent("do-not-follow"), withDestinationURL: original)
            try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: unknown)
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: stale.path)
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: unknown.path)
            DisposableScratchMaintenance.prune(parent: parent, prefix: prefix, before: cutoff)
            XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: unknown.path))
            XCTAssertTrue((try linked.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == true)
            XCTAssertEqual(try Data(contentsOf: original), Data([1, 2, 3]))
        }
        XCTAssertEqual(DisposableScratchMaintenance.minimumAge, 86_400)
    }
}
#endif
