#if canImport(UIKit) && canImport(XCTest) && !TC_TESTKIT_STANDALONE
import Foundation
import Synchronization
import XCTest
@testable import TruongCam

/// Hashes synthetic import copies without invoking PhotoKit or loading a whole
/// fixture into Data. URLs remain available only through addOriginals return.
private actor BoundedPhotos56Library: DNGPhotoLibraryWriting {
    private(set) var calls = 0
    private(set) var files: [URL] = []
    private(set) var hashes: [HashAndByteCount] = []
    func requestAddAuthorization() -> Bool { true }
    func addOriginals(_ files: [URL]) throws {
        calls += 1; self.files = files
        hashes = try files.map { try SystemFileSystemAdapter().hashFile(at: $0, chunkBytes: FileAdapterDefaults.hashChunkBytes) }
    }
}

final class BoundedPhotosExportNativeTests: XCTestCase {
    private func fixture() throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PhotosStream56-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("synthetic.dng")
        let writer = try SystemFileSystemAdapter().beginExclusiveCreate(at: source)
        for index in 0..<41 { try writer.write(Data(repeating: UInt8(index), count: 65_536)) }
        try writer.write(Data([1, 3, 5, 7, 9])); try writer.close()
        return (root, source)
    }

    func testDefaultPhotosPathStreamsExactLargeCopiesAndReleasesOnlyItsScratchFiles() async throws {
        let (root, source) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let expected = try SystemFileSystemAdapter().hashFile(at: source, chunkBytes: FileAdapterDefaults.hashChunkBytes)
        let library = BoundedPhotos56Library()
        let count = try await DNGPhotosExporter(library: library).save([source])
        let hashes = await library.hashes, files = await library.files
        XCTAssertEqual(count, 1); XCTAssertEqual(hashes, [expected])
        XCTAssertGreaterThan(expected.byteCount, Int64(FileAdapterDefaults.hashChunkBytes * 2))
        XCTAssertTrue(files.allSatisfy { $0 != source && !FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertEqual(try SystemFileSystemAdapter().hashFile(at: source, chunkBytes: FileAdapterDefaults.hashChunkBytes), expected)
    }

    func testSourceMutationAfterStreamingPreflightCannotReachPhotoKit() async throws {
        let (root, source) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let library = BoundedPhotos56Library(), paths = Mutex<[URL]>([])
        let exporter = DNGPhotosExporter(library: library, hashFile: { url in
            paths.withLock { $0.append(url) }
            let digest = try SystemFileSystemAdapter().hashFile(at: url, chunkBytes: FileAdapterDefaults.hashChunkBytes)
            if url == source {
                let writer = try FileHandle(forWritingTo: source)
                try writer.write(contentsOf: Data([255])); try writer.close()
            }
            return digest
        })
        do { _ = try await exporter.save([source]); XCTFail("A changed source cannot be imported") }
        catch DNGPhotosExporter.Failure.changedCopy { }
        let calls = await library.calls
        XCTAssertEqual(calls, 0)
        let observed = paths.withLock { $0 }
        XCTAssertEqual(observed.count, 2); XCTAssertEqual(observed.first, source)
        let scratch = try XCTUnwrap(observed.last)
        XCTAssertNotEqual(scratch, source); XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "Import cleanup cannot remove its source export")
    }

    func testPostCopyStreamingReadFailureNeverImportsAndCleansTheOwnedCopy() async throws {
        let (root, source) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let expected = try SystemFileSystemAdapter().hashFile(at: source, chunkBytes: FileAdapterDefaults.hashChunkBytes)
        let library = BoundedPhotos56Library(), paths = Mutex<[URL]>([])
        let exporter = DNGPhotosExporter(library: library, hashFile: { url in
            paths.withLock { $0.append(url) }
            if url != source { throw CocoaError(.fileReadUnknown) }
            return try SystemFileSystemAdapter().hashFile(at: url, chunkBytes: FileAdapterDefaults.hashChunkBytes)
        })
        do { _ = try await exporter.save([source]); XCTFail("An unverified copy cannot be imported") }
        catch { }
        let calls = await library.calls
        XCTAssertEqual(calls, 0)
        let observed = paths.withLock { $0 }
        XCTAssertEqual(observed.count, 2)
        let copy = try XCTUnwrap(observed.last)
        XCTAssertNotEqual(copy, source); XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertEqual(try SystemFileSystemAdapter().hashFile(at: source, chunkBytes: FileAdapterDefaults.hashChunkBytes), expected)
    }
}
#endif
