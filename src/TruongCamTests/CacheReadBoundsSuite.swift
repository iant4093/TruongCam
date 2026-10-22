import Foundation
import Synchronization
#if canImport(XCTest)
@testable import TruongCam
#endif

/// Advertises large/racing files without allocating them. The real decoder
/// must reject their size/header before asking this handle for a payload.
private final class CacheBounds56Reader: FileReadHandle {
    private struct State {
        var offset = 0
        var requested: [Int] = []
        var closed = false
    }
    let byteCount: Int64
    private let bytes: Data
    private let maximumReturn: Int
    private let failOnRead: Int?
    private let state = Mutex(State())
    init(_ bytes: Data, declaredSize: Int64? = nil, maximumReturn: Int = .max, failOnRead: Int? = nil) {
        self.bytes = bytes; byteCount = declaredSize ?? Int64(bytes.count)
        self.maximumReturn = maximumReturn; self.failOnRead = failOnRead
    }
    var requests: [Int] { state.withLock { $0.requested } }
    var isClosed: Bool { state.withLock { $0.closed } }
    func read(maxBytes: Int) throws -> Data {
        try state.withLock { current in
            current.requested.append(maxBytes)
            if current.requested.count == failOnRead { throw FileAdapterError.ioFailure("Synthetic cache read failure") }
            guard !current.closed, maxBytes > 0 else { return Data() }
            let end = min(bytes.count, current.offset + min(maxBytes, maximumReturn))
            let result = Data(bytes[current.offset..<end]); current.offset = end
            return result
        }
    }
    func close() { state.withLock { $0.closed = true } }
}

enum CacheReadBoundsSuite {
    private static func header(_ width: UInt32, _ height: UInt32) -> Data {
        Data([width, height].flatMap { value in (0..<4).map { UInt8((value >> ($0 * 8)) & 255) } })
    }

    static let suite = TCSuite(id: "CacheReadBounds", title: "Disposable thumbnail cache allocation bounds", cases: [
        TCCase(id: "DC56V", title: "Valid partial reads preserve exact thumbnail bytes and always close the owned reader") { r in
            let pixels = Data([0, 80, 160, 255, 90, 30, 10, 255])
            let reader = CacheBounds56Reader(header(2, 1) + pixels, maximumReturn: 1)
            do {
                let decoded = try ThumbnailService.readBoundedDiskCache(from: reader, longEdge: 64)
                r.equal("width unchanged", decoded?.width, 2)
                r.equal("height unchanged", decoded?.height, 1)
                r.equal("pixel bytes unchanged", decoded?.bytes, Array(pixels))
                r.check("partial header/payload reads complete", reader.requests.count > 3)
                r.check("all requests stay bounded", reader.requests.allSatisfy { $0 > 0 && $0 <= 8 })
                r.check("reader closed", reader.isClosed)
            } catch { r.check("valid cache", false, String(describing: error)) }
            let edge = ThumbnailService.maximumThumbnailLongEdge
            let full = Data(repeating: 127, count: edge * edge * 4)
            let largest = CacheBounds56Reader(header(UInt32(edge), UInt32(edge)) + full)
            do {
                let decoded = try ThumbnailService.readBoundedDiskCache(from: largest, longEdge: .max)
                r.equal("actual thumbnail ceiling remains valid", decoded?.bytes.count, full.count)
                r.equal("largest bytes unchanged", decoded?.bytes, Array(full))
                r.check("large argument is clamped before allocation", (largest.requests.max() ?? 0) <= edge * edge * 4)
                r.check("largest reader closed", largest.isClosed)
            } catch { r.check("largest valid cache", false, String(describing: error)) }
        },
        TCCase(id: "DC56S", title: "Oversized files and viewer-sized headers cannot allocate a grid thumbnail payload") { r in
            let huge = CacheBounds56Reader(header(1, 1), declaredSize: .max)
            do { r.check("oversized file is a miss", try ThumbnailService.readBoundedDiskCache(from: huge, longEdge: 512) == nil) }
            catch { r.check("oversized cache safely refused", false, String(describing: error)) }
            r.equal("oversized file rejected before any read", huge.requests, [])
            r.check("oversized handle closed", huge.isClosed)
            // This file's claimed size fits a thumbnail budget, but its long
            // edge is a viewer-sized 2048. No payload read is permitted.
            let viewer = CacheBounds56Reader(header(2_048, 1), declaredSize: 8 + 2_048 * 4)
            do { r.check("viewer header is a miss", try ThumbnailService.readBoundedDiskCache(from: viewer, longEdge: 512) == nil) }
            catch { r.check("viewer header safely refused", false, String(describing: error)) }
            r.equal("only the header was read", viewer.requests, [8])
            r.check("viewer handle closed", viewer.isClosed)
            let wrongKey = CacheBounds56Reader(header(128, 1), declaredSize: 8 + 128 * 4)
            do { r.check("requested key ceiling applies", try ThumbnailService.readBoundedDiskCache(from: wrongKey, longEdge: 64) == nil) }
            catch { r.check("key ceiling safely refused", false, String(describing: error)) }
            r.equal("wrong-key payload not read", wrongKey.requests, [8])
        },
        TCCase(id: "DC56R", title: "Truncation, trailing growth and forged dimensions become cache misses without excess reads") { r in
            let cases: [(CacheBounds56Reader, String)] = [
                (CacheBounds56Reader(header(2, 2) + Data(repeating: 1, count: 12)), "size disagrees with header"),
                (CacheBounds56Reader(header(2, 2) + Data(repeating: 1, count: 12), declaredSize: 24), "truncated after size snapshot"),
                (CacheBounds56Reader(header(2, 2) + Data(repeating: 1, count: 17), declaredSize: 24), "grew after size snapshot"),
                (CacheBounds56Reader(header(0, 1) + Data(repeating: 1, count: 4)), "zero dimension"),
                (CacheBounds56Reader(header(.max, .max) + Data(repeating: 1, count: 4)), "overflowing dimensions")]
            for (reader, label) in cases {
                do { r.check(label + " refused", try ThumbnailService.readBoundedDiskCache(from: reader, longEdge: 64) == nil) }
                catch { r.check(label + " refused safely", false, String(describing: error)) }
                r.check(label + " reader closed", reader.isClosed)
                r.check(label + " bounded reads", reader.requests.allSatisfy { $0 > 0 && $0 <= 16 })
            }
            r.equal("inconsistent header size stops after header", cases[0].0.requests, [8])
            r.equal("growth probe reads only one extra byte", cases[2].0.requests.last, 1)
        },
        TCCase(id: "DC56E", title: "A throwing cache read closes its file and remains disposable") { r in
            let reader = CacheBounds56Reader(header(2, 2) + Data(repeating: 20, count: 16), failOnRead: 2)
            do { _ = try ThumbnailService.readBoundedDiskCache(from: reader, longEdge: 64); r.check("failure propagated to miss boundary", false) }
            catch { r.check("failure propagated to miss boundary", true) }
            r.check("throwing reader closed", reader.isClosed)
            r.equal("no retry or unbounded fallback", reader.requests, [8, 16])
        },
        TCCase(id: "DC56P", title: "The shipping service repairs an oversized disposable entry while retaining exact original bytes") { r in
            let directory = StorageFixture.temporaryDirectory("cache56-bounded-repair")
            defer { StorageFixture.removeDirectory(directory) }
            let cache = directory.appendingPathComponent("cache"), source = directory.appendingPathComponent("photo.png")
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                guard StorageFixture.writePNG(to: source, width: 64, height: 48) else { r.check("source fixture", false); return }
                let before = try Data(contentsOf: source)
                let initial = ThumbnailService(rootURLProvider: { directory }, diskCacheDirectory: cache)
                let first = await initial.thumbnail(identity: "bounded56", relativePath: "photo.png", fingerprint: "fp", targetLongEdge: 64)
                let entries = try FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)
                guard let entry = entries.first else { r.check("real cache written", false); return }
                let writer = try FileHandle(forWritingTo: entry)
                try writer.truncate(atOffset: 64 * 1024 * 1024); try writer.close()
                let reopened = ThumbnailService(rootURLProvider: { directory }, diskCacheDirectory: cache)
                let result = await reopened.thumbnail(identity: "bounded56", relativePath: "photo.png", fingerprint: "fp", targetLongEdge: 64)
                if case .image(let expectedBytes, let expectedWidth, let expectedHeight, let expectedFingerprint) = first,
                   case .image(let bytes, let width, let height, let fingerprint) = result {
                    r.equal("real decoded pixels unchanged", bytes, expectedBytes)
                    r.equal("real decoded width unchanged", width, expectedWidth)
                    r.equal("real decoded height unchanged", height, expectedHeight)
                    r.equal("real decoded fingerprint unchanged", fingerprint, expectedFingerprint)
                } else { r.check("real bounded decode remains available", false) }
                let repaired = try FileManager.default.attributesOfItem(atPath: entry.path)
                r.equal("cache replaced by bounded raster", (repaired[.size] as? NSNumber)?.intValue, 8 + 64 * 48 * 4)
                r.equal("original remains unchanged", try Data(contentsOf: source), before)
            } catch { r.check("shipping bounded cache repair", false, String(describing: error)) }
        }
    ])
}
