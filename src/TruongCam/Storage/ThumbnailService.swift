import CoreGraphics
import CoreImage
import CryptoKit
import Foundation
import ImageIO
import Synchronization

// LIBRARY.md "Gallery rebuilding and local availability" + CONTRACTS.md
// "Browsing, export, lifecycle and UI".
//
// Thumbnails are disposable derivatives. This service only ever READS an
// original; it has no write path back to the library. The thumbnail's own pixel
// size is reported as the thumbnail size and is never presented as the RAW
// sensor size — embedded previews are frequently smaller than the sensor output
// and CIRAWFilter output here is display-only.

/// Decodes bounded display previews from originals.
///
/// REVIEW.md F01: this was an `actor`, which meant the coordinated read had to leave
/// the `NSFileCoordinator` accessor before any decode could run — so file
/// coordination never actually covered the read. `CGImageSourceCreateWithURL` and
/// `CGImageSourceCreateThumbnailAtIndex` are SYNCHRONOUS, so the decode can and now
/// does run inside the accessor on the store's I/O owner. The service is a
/// lock-guarded class rather than an actor so it can be entered synchronously.
///
/// Ownership invariant for the narrow `@unchecked Sendable`: `cache` (memory +
/// memory-pressure monitor) is only touched while its own lock is held. `CIContext`
/// is documented as safe to use from multiple threads, and the disk cache uses
/// atomic file operations.
final class ThumbnailService: ThumbnailProviding, @unchecked Sendable {
    private struct CacheKey: Hashable {
        let identity: String
        let fingerprint: String
        let longEdge: Int
    }

    private struct CachedImage {
        let bytes: [UInt8]
        let width: Int
        let height: Int
        let pixelFingerprint: String

        var cost: Int { bytes.count + 64 }
    }

    private struct MemoryCache {
        var entries: [CacheKey: CachedImage] = [:]
        var insertionOrder: [CacheKey] = []
        var totalCost = 0

        mutating func insert(_ image: CachedImage, for key: CacheKey) {
            if let existing = entries[key] {
                totalCost -= existing.cost
                insertionOrder.removeAll { $0 == key }
            }
            entries[key] = image
            insertionOrder.append(key)
            totalCost += image.cost
        }

        mutating func evict(untilCostAtMost budget: Int) {
            while totalCost > budget, !insertionOrder.isEmpty {
                let key = insertionOrder.removeFirst()
                if let removed = entries.removeValue(forKey: key) {
                    totalCost -= removed.cost
                }
            }
        }
    }

    private let rootURLProvider: @Sendable () -> URL?
    private let diskCacheDirectory: URL
    private let diskBudget: ThumbnailDiskBudget
    private let memoryBudgetBytes: Int
    /// A single reused CIContext: creating one per decode is the documented
    /// Core Image performance mistake.
    private let contextBox = Mutex<CIContext?>(nil)
    private var context: CIContext {
        contextBox.withLock {
            if let existing = $0 { return existing }
            let created = CIContext(options:[.useSoftwareRenderer:false])
            $0 = created
            return created
        }
    }
    /// The memory cache and its pressure monitor, behind one lock so the service can
    /// be entered synchronously from the accessor.
    private final class CacheBox: @unchecked Sendable {
        private let lock = NSLock()
        private var memory = MemoryCache()
        private var installedMemoryPressureMonitor = false
        private var memoryPressureSource: (any DispatchSourceMemoryPressure)?

        func withMemory<T>(_ body: (inout MemoryCache) -> T) -> T {
            lock.lock(); defer { lock.unlock() }
            return body(&memory)
        }

        func markPressureMonitorInstalled() -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !installedMemoryPressureMonitor else { return false }
            installedMemoryPressureMonitor = true
            return true
        }

        func store(pressureSource: any DispatchSourceMemoryPressure) {
            lock.lock(); memoryPressureSource = pressureSource; lock.unlock()
        }
    }

    private let cache = CacheBox()

    /// Thumbnail decoding is clamped to this long edge. A 60 MP RAW must never
    /// become a full-size RGBA buffer here.
    static let maximumThumbnailLongEdge = 512
    static let maximumViewerLongEdge = 2_048

    init(
        rootURLProvider: @escaping @Sendable () -> URL?,
        diskCacheDirectory: URL? = nil,
        memoryBudgetBytes: Int = 32 * 1024 * 1024,
        diskBudgetBytes: Int = ThumbnailDiskBudget.defaultBytes
    ) {
        self.rootURLProvider = rootURLProvider
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.diskCacheDirectory = (diskCacheDirectory ?? caches.appendingPathComponent("TruongCamThumbnails", isDirectory: true))
            .standardizedFileURL
        self.diskBudget = ThumbnailDiskBudget(directory: self.diskCacheDirectory, bytes: diskBudgetBytes)
        self.memoryBudgetBytes = max(1 * 1024 * 1024, memoryBudgetBytes)
    }

    deinit {
        // Nothing to release explicitly: the disk cache and the memory cache are
        // both disposable, and the CIContext lifetime ends with the actor.
    }

    /// Diagnostics expose allocation state without initializing the renderer.
    var isRenderContextAllocated: Bool { contextBox.withLock { $0 != nil } }

    // MARK: - ThumbnailProviding

    func thumbnail(identity: String,
                   relativePath: String,
                   fingerprint: String?,
                   targetLongEdge: Int) async -> ThumbnailOutcome {
        let edge = min(max(targetLongEdge, 32), ThumbnailService.maximumThumbnailLongEdge)
        // Prefer the lease-owning absolute variant. The relative variant remains
        // for callers that already hold a scope.
        guard let url = resolve(relativePath: relativePath) else {
            return .unavailable(reason: "The library folder is not available.")
        }
        return produceSynchronously(identity: identity, url: url, fingerprint: fingerprint,
                       longEdge: edge, useDiskCache: true)
    }

    func thumbnail(atAbsoluteURL url: URL,
                   identity: String,
                   fingerprint: String?,
                   targetLongEdge: Int) async -> ThumbnailOutcome {
        let edge = min(max(targetLongEdge, 32), ThumbnailService.maximumThumbnailLongEdge)
        return produceSynchronously(identity: identity, url: url, fingerprint: fingerprint,
                       longEdge: edge, useDiskCache: true)
    }

    /// Synchronous bounded decode, for the coordinated-read boundary.
    func thumbnailSynchronously(atAbsoluteURL url: URL,
                                identity: String,
                                fingerprint: String?,
                                targetLongEdge: Int) -> ThumbnailOutcome {
        let edge = min(max(targetLongEdge, 32), ThumbnailService.maximumThumbnailLongEdge)
        return produceSynchronously(identity: identity, url: url, fingerprint: fingerprint,
                                    longEdge: edge, useDiskCache: true)
    }

    /// Synchronous bounded viewer decode, for the coordinated-read boundary.
    func viewerPreviewSynchronously(atAbsoluteURL url: URL,
                                    identity: String,
                                    boundLongEdge: Int) -> ThumbnailOutcome {
        let edge = min(max(boundLongEdge, 64), ThumbnailService.maximumViewerLongEdge)
        return produceSynchronously(identity: identity, url: url,
                                    fingerprint: fingerprint(for: identity,
                                                             relativePath: url.lastPathComponent),
                                    longEdge: edge, useDiskCache: false)
    }

    func viewerPreview(atAbsoluteURL url: URL,
                       identity: String,
                       boundLongEdge: Int) async -> ThumbnailOutcome {
        let edge = min(max(boundLongEdge, 64), ThumbnailService.maximumViewerLongEdge)
        return produceSynchronously(identity: identity, url: url,
                       fingerprint: fingerprint(for: identity, relativePath: url.lastPathComponent),
                       longEdge: edge, useDiskCache: false)
    }

    /// Resolves a relative original under the granted root, if one is available.
    private func resolve(relativePath: String) -> URL? {
        guard let root = rootURLProvider() else { return nil }
        return try? PathSafety.resolve(relativePath, under: root)
    }

    func viewerPreview(identity: String,
                       relativePath: String,
                       boundLongEdge: Int) async -> ThumbnailOutcome {
        let edge = min(max(boundLongEdge, 64), ThumbnailService.maximumViewerLongEdge)
        guard let url = resolve(relativePath: relativePath) else {
            return .unavailable(reason: "The library folder is not available.")
        }
        return produceSynchronously(identity: identity,
                       url: url,
                       fingerprint: fingerprint(for: identity, relativePath: relativePath),
                       longEdge: edge,
                       useDiskCache: false)
    }

    func clearMemoryCache() {
        cache.withMemory { $0 = MemoryCache() }
    }

    /// Current memory-cache footprint, used by tests to prove the bound holds.
    var memoryCacheCost: Int { cache.withMemory { $0.totalCost } }

    // MARK: - Pipeline

    private func fingerprint(for identity: String, relativePath: String) -> String {
        var hasher = SHA256()
        hasher.update(data: Data("\(identity)|\(relativePath)".utf8))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The synchronous decode core.
    ///
    /// Called from inside the coordination accessor, on the I/O owner. It never
    /// awaits and never dispatches: the caller's accessor waits for it to finish.
    func produceSynchronously(identity: String,
                              url: URL,
                              fingerprint: String?,
                              longEdge: Int,
                              useDiskCache: Bool) -> ThumbnailOutcome {
        #if DEBUG
        let began = ProcessInfo.processInfo.systemUptime
        var path = "missing-original"
        defer {
            print("TruongCam timing display-preview=\(Int((ProcessInfo.processInfo.systemUptime-began)*1000))ms edge=\(longEdge) path=\(path) main=\(Thread.isMainThread)")
        }
        #endif
        guard FileManager.default.fileExists(atPath: url.path) else {
            // No file means no preview. A rendering or a stale cache entry is
            // never substituted for a missing original.
            return .unavailable(reason: "The original file is not present locally.")
        }

        let key = CacheKey(identity: identity, fingerprint: fingerprint ?? "-", longEdge: longEdge)
        if let hit = cache.withMemory({ $0.entries[key] }) {
            #if DEBUG
            path = "memory-hit"
            #endif
            return .image(rgbaBytes: hit.bytes,
                          width: hit.width,
                          height: hit.height,
                          pixelFingerprint: hit.pixelFingerprint)
        }
        if useDiskCache, let cached = readDiskCache(key: key) {
            #if DEBUG
            path = "disk-hit"
            #endif
            cache.withMemory { memory in
                memory.insert(cached, for: key)
                memory.evict(untilCostAtMost: memoryBudgetBytes)
            }
            return .image(rgbaBytes: cached.bytes,
                          width: cached.width,
                          height: cached.height,
                          pixelFingerprint: cached.pixelFingerprint)
        }

        #if DEBUG
        path = "decode-failed"
        #endif
        guard let produced = decodeImage(at: url, longEdge: longEdge) else {
            return .unavailable(reason: "No displayable preview could be decoded from this original.")
        }

        #if DEBUG
        path = "decoded"
        #endif
        let cached = CachedImage(bytes: produced.bytes,
                                 width: produced.width,
                                 height: produced.height,
                                 pixelFingerprint: pixelFingerprint(of: produced.bytes))
        cache.withMemory { memory in
            memory.insert(cached, for: key)
            memory.evict(untilCostAtMost: memoryBudgetBytes)
        }
        if useDiskCache { writeDiskCache(cached, key: key) }
        return .image(rgbaBytes: cached.bytes,
                      width: cached.width,
                      height: cached.height,
                      pixelFingerprint: cached.pixelFingerprint)
    }

    /// ImageIO RAW-derived display image first (always-create, never embedded-first),
    /// then a bounded Core Image RAW decode. Both paths are read-only.
    private func decodeImage(at url: URL, longEdge: Int) -> (bytes: [UInt8], width: Int, height: Int)? {
        // Cold codecs can retain substantial temporary native objects. Drain them
        // at each bounded read, rather than waiting for a long-lived queue pool.
        autoreleasepool { decodeImageInPool(at: url, longEdge: longEdge) }
    }

    private func decodeImageInPool(at url: URL, longEdge: Int) -> (bytes: [UInt8], width: Int, height: Int)? {
        #if DEBUG
        let began = ProcessInfo.processInfo.systemUptime
        var decoder = "unavailable"
        defer {
            print("TruongCam timing display-decode=\(Int((ProcessInfo.processInfo.systemUptime-began)*1000))ms decoder=\(decoder) edge=\(longEdge) main=\(Thread.isMainThread)")
        }
        #endif
        if let image = imageIOThumbnail(at: url, longEdge: longEdge),
           let rgba = rgbaBytes(from: image, longEdge: longEdge) {
            #if DEBUG
            decoder = "ImageIO-always-create"
            #endif
            return rgba
        }
        if let image = coreImagePreview(at: url, longEdge: longEdge),
           let rgba = rgbaBytes(from: image, longEdge: longEdge) {
            #if DEBUG
            decoder = "CoreImage-RAW"
            #endif
            return rgba
        }
        return nil
    }

    private func imageIOThumbnail(at url: URL, longEdge: Int) -> CGImage? {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary) else {
            return nil
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: longEdge,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary)
    }

    /// Bounded native RAW decode. `scaleFactor` keeps the decoded buffer small;
    /// the result is display-only and never treated as the sensor size.
    private func coreImagePreview(at url: URL, longEdge: Int) -> CGImage? {
        guard let filter = CIRAWFilter(imageURL: url) else { return nil }
        let native = filter.nativeSize
        guard native.width > 0, native.height > 0 else { return nil }
        let longest = max(native.width, native.height)
        let requested = CGFloat(longEdge) / longest
        // Never decode above 1/4 scale for a preview, and never below 1/16, so
        // the intermediate buffer stays bounded even for a very large RAW.
        let scale = min(max(requested, 1.0 / 16.0), 0.25)
        filter.scaleFactor = Float(scale)
        guard let output = filter.outputImage else { return nil }
        let extent = output.extent.integral
        guard extent.width.isFinite, extent.height.isFinite, extent.width >= 1, extent.height >= 1 else {
            return nil
        }
        return context.createCGImage(output, from: extent)
    }

    /// Rasterizes into RGBA8 so no image object crosses the isolation boundary.
    private func rgbaBytes(from image: CGImage, longEdge: Int) -> (bytes: [UInt8], width: Int, height: Int)? {
        let sourceWidth = image.width
        let sourceHeight = image.height
        guard sourceWidth > 0, sourceHeight > 0 else { return nil }
        let scale = min(1.0, Double(longEdge) / Double(max(sourceWidth, sourceHeight)))
        let width = max(1, Int((Double(sourceWidth) * scale).rounded()))
        let height = max(1, Int((Double(sourceHeight) * scale).rounded()))
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let created: Bool = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return false }
            guard let context = CGContext(data: base,
                                          width: width,
                                          height: height,
                                          bitsPerComponent: 8,
                                          bytesPerRow: bytesPerRow,
                                          space: colorSpace,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return false
            }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard created else { return nil }
        return (bytes, width, height)
    }

    private func pixelFingerprint(of bytes: [UInt8]) -> String {
        var hasher = SHA256()
        // Hash the already materialized bounded raster in place. Converting a
        // 2,048-pixel viewer raster to Data just for its digest duplicated the
        // entire RGBA allocation before the separate display-image copy.
        bytes.withUnsafeBytes { hasher.update(bufferPointer: $0) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Disposable disk cache

    private func diskCacheURL(for key: CacheKey) -> URL {
        var hasher = SHA256()
        hasher.update(data: Data("raw-derived-v2|\(key.identity)|\(key.fingerprint)|\(key.longEdge)".utf8))
        let name = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return diskCacheDirectory.appendingPathComponent("\(name).tcthumb", isDirectory: false)
    }

    private func readDiskCache(key: CacheKey) -> CachedImage? {
        diskBudget.prepareRead()
        let url = diskCacheURL(for: key)
        guard diskBudget.canRead(url) else { return nil }
        do {
            let reader = try SystemFileSystemAdapter().openRead(at: url)
            guard let payload = try Self.readBoundedDiskCache(from: reader, longEdge: key.longEdge) else { return nil }
            return CachedImage(bytes: payload.bytes, width: payload.width, height: payload.height,
                               pixelFingerprint: pixelFingerprint(of: payload.bytes))
        } catch {
            // A missing or unreadable disposable cache entry is simply a miss.
            return nil
        }
    }

    struct DiskCachePayload {
        let bytes: [UInt8]
        let width: Int
        let height: Int
    }

    /// Disposable files are not trusted allocation sizes. Validate the opened
    /// file's size and eight-byte header before reading its bounded RGBA payload.
    /// The reader is always closed, including malformed/partial/racing entries.
    static func readBoundedDiskCache(from reader: any FileReadHandle, longEdge: Int) throws -> DiskCachePayload? {
        defer { try? reader.close() }
        let edge = min(max(1, longEdge), maximumThumbnailLongEdge)
        guard reader.byteCount >= 12, reader.byteCount <= Int64(8 + edge * edge * 4) else { return nil }
        func readExactly(_ count: Int) throws -> Data? {
            var result = Data(capacity: count)
            while result.count < count {
                let remaining = count - result.count
                let part = try reader.read(maxBytes: remaining)
                guard !part.isEmpty, part.count <= remaining else { return nil }
                result.append(part)
            }
            return result
        }
        guard let header = try readExactly(8) else { return nil }
        func dimension(at offset: Int) -> Int {
            (0..<4).reduce(0) { $0 | (Int(header[header.startIndex + offset + $1]) << ($1 * 8)) }
        }
        let width = dimension(at: 0), height = dimension(at: 4)
        guard width > 0, height > 0, width <= edge, height <= edge else { return nil }
        let expected = width * height * 4
        guard reader.byteCount == Int64(expected + 8), let payload = try readExactly(expected),
              try reader.read(maxBytes: 1).isEmpty else { return nil }
        return DiskCachePayload(bytes: [UInt8](payload), width: width, height: height)
    }

    private func writeDiskCache(_ image: CachedImage, key: CacheKey) {
        var data = Data(capacity: 8 + image.bytes.count)
        data.append(contentsOf: [
            UInt8(image.width & 0xFF), UInt8((image.width >> 8) & 0xFF),
            UInt8((image.width >> 16) & 0xFF), UInt8((image.width >> 24) & 0xFF),
            UInt8(image.height & 0xFF), UInt8((image.height >> 8) & 0xFF),
            UInt8((image.height >> 16) & 0xFF), UInt8((image.height >> 24) & 0xFF),
        ])
        data.append(contentsOf: image.bytes)
        // Disposable cache: a failed write only costs a future re-decode.
        diskBudget.write(data, name: diskCacheURL(for: key).lastPathComponent)
    }

    /// Deletes the whole disposable thumbnail cache. Never touches originals.
    func clearDiskCache() {
        guard FileManager.default.fileExists(atPath: diskCacheDirectory.path) else { return }
        do { try FileManager.default.removeItem(at: diskCacheDirectory) } catch { /* disposable */ }
    }

    /// Installs the system memory-pressure monitor so a warning clears the
    /// disposable memory cache (TEST_PLAN.md T37). The app can also call
    /// `clearMemoryCache()` directly.
    func installMemoryPressureMonitor() {
        #if os(iOS)
        // The installed flag and the source are cache-box state, so the guard and the
        // assignment happen under its lock rather than as two unsynchronized steps.
        guard cache.markPressureMonitorInstalled() else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical],
                                                            queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.cache.withMemory { $0 = MemoryCache() }
        }
        source.activate()
        cache.store(pressureSource: source)
        #endif
    }
}

/// Read-only native file metadata. No RAW development, location request, network
/// lookup or DNG write is involved. All displayed values must exist in the file.
struct PhotoMetadataDetails: Hashable, Sendable {
    struct Field: Hashable, Sendable, Identifiable {
        var id: String { name }
        let name: String
        let value: String
        var label: String {
            let names = ["Make": "Manufacturer", "Model": "Camera model", "LensModel": "Lens",
                "ExposureTime": "Shutter speed", "ISOSpeedRatings": "ISO", "FNumber": "Aperture",
                "FocalLength": "Focal length", "FocalLenIn35mmFilm": "35 mm equivalent", "ExposureBiasValue": "EV bias",
                "ExposureMode": "Exposure mode", "ExposureProgram": "Exposure program", "WhiteBalance": "White balance",
                "ColorSpace": "EXIF color space", "ProfileName": "Container color profile", "DateTimeOriginal": "Original date/time",
                "DateTimeDigitized": "Digitized date/time", "DNGVersion": "DNG version", "DNGBackwardVersion": "DNG compatibility",
                "PixelWidth": "Container image width", "PixelHeight": "Container image height", "BitsPerSample": "Bits per sample"]
            return names[name] ?? name.replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1 $2", options: .regularExpression)
        }
    }
    struct Section: Hashable, Sendable, Identifiable {
        var id: String { name }
        let name: String
        let fields: [Field]
    }
    let shutter: String?
    let iso: String?
    let aperture: String?
    let focalLength: String?
    /// This original's validated EXIF 35 mm equivalent, never its physical lens
    /// focal length or a legacy sidecar's nominal camera-kind hint.
    let equivalentFocalLength: String?
    private let focalLengthInfo: String?
    let sections: [Section]

    var settings: [String] { [shutter, iso, aperture, equivalentFocalLength].compactMap { $0 } }

    /// The photo Info sheet is a curated camera summary, never a metadata dump.
    /// The full parsed record remains internal for exact-file diagnostics/tests.
    var infoFields: [Field] {
        func value(_ section: String, _ name: String) -> String? {
            sections.first { $0.name == section }?.fields.first { $0.name == name }?.value
        }
        var result: [Field] = []
        func add(_ name: String, _ text: String?) { if let text { result.append(Field(name: name, value: text)) } }
        add("Make", value("TIFF", "Make"))
        add("Model", value("TIFF", "Model"))
        add("ColorSpace", value("Image container", "ProfileName") ?? value("Exif", "ColorSpace"))
        add("FocalLength", focalLengthInfo)
        add("ExposureMode", value("Exif", "ExposureMode"))
        add("ExposureBiasValue", value("Exif", "ExposureBiasValue"))
        add("Flash", value("Exif", "Flash"))
        add("WhiteBalance", value("Exif", "WhiteBalance"))
        return result
    }


    static func read(at url: URL) throws -> Self {
        guard let source = CGImageSourceCreateWithURL(url as CFURL,
                [kCGImageSourceShouldCache: false] as CFDictionary),
              let raw = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return parse(raw)
    }

    static func parse(_ raw: [String: Any]) -> Self {
        let exif = raw[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        func positive(_ key: CFString) -> Double? {
            let value = exif[key as String]
            if let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() { return nil }
            let number = (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init)
            return number.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        }
        let duration = positive(kCGImagePropertyExifExposureTime)
        let isoArray = exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber]
        let isoValue = positive(kCGImagePropertyExifISOSpeedRatings) ?? isoArray?.first?.doubleValue
        let f = positive(kCGImagePropertyExifFNumber)
        let focal = positive(kCGImagePropertyExifFocalLength)
        let focalLengths = OriginalPhotoFocalLength(actualMM: focal,
            equivalentMM: positive(kCGImagePropertyExifFocalLenIn35mmFilm))
        var sections: [Section] = []
        let priority = ["{TIFF}": 0, "{Exif}": 1, "{ExifAux}": 2, "{DNG}": 3, "{GPS}": 4]
        for key in raw.keys.sorted(by: { (priority[$0] ?? 100, $0) < (priority[$1] ?? 100, $1) }).prefix(40) {
            guard let dictionary = raw[key] as? [String: Any] else { continue }
            let fields = dictionary.keys.sorted().prefix(100).compactMap { name -> Field? in
                guard let value = dictionary[name], let text = metadataValue(name: name, value: value) else { return nil }
                return Field(name: name, value: text)
            }
            if !fields.isEmpty { sections.append(Section(name: key.trimmingCharacters(in: CharacterSet(charactersIn: "{}")), fields: fields)) }
        }
        let container = raw.keys.sorted().filter { !(raw[$0] is [String: Any]) }.prefix(40).compactMap { key -> Field? in
            guard let value = raw[key], let text = display(value) else { return nil }
            return Field(name: key, value: text)
        }
        if !container.isEmpty { sections.append(Section(name: "Image container", fields: container)) }
        return Self(shutter: duration.map(shutterText),
                    iso: isoValue.flatMap { $0.isFinite && $0 > 0 ? "ISO \(number($0))" : nil },
                    aperture: f.map { "ƒ/\(number($0))" }, focalLength: focal.map { "\(number($0)) mm" },
                    equivalentFocalLength: focalLengths.settingsText, focalLengthInfo: focalLengths.infoText,
                    sections: sections)
    }
    private static func shutterText(_ value: Double) -> String {
        let inverse = 1 / value
        if value < 1, inverse.isFinite, abs(inverse - inverse.rounded()) <= 0.005 * inverse {
            return "1/\(String(format: "%.0f", inverse))s"
        }
        return "\(number(value))s"
    }
    private static func number(_ value: Double) -> String { String(format: "%.6g", value) }
    private static func metadataValue(name: String, value: Any) -> String? {
        if let n = value as? NSNumber, n.doubleValue.isFinite {
            let v = n.doubleValue
            switch name {
            case "ExposureTime": return v > 0 ? shutterText(v) : number(v)
            case "WhiteBalance": return v == 0 ? "Auto" : v == 1 ? "Manual" : number(v)
            case "Flash": return v >= 0 && v <= 127 && v.rounded() == v ? (Int(v) & 1 == 1 ? "On" : "Off") : number(v)
            case "ExposureMode": return v == 0 ? "Auto" : v == 1 ? "Manual" : v == 2 ? "Auto bracket" : number(v)
            case "ExposureBiasValue": return String(format: "%+.2f EV", v)
            case "FNumber": return "ƒ/\(number(v))"
            case "FocalLength", "FocalLenIn35mmFilm": return "\(number(v)) mm"
            case "ColorSpace": return v == 1 ? "sRGB" : v == 65535 ? "Uncalibrated" : number(v)
            default: break
            }
        }
        if ["DNGVersion", "DNGBackwardVersion"].contains(name), let numbers = value as? [NSNumber] {
            return numbers.prefix(4).map { $0.stringValue }.joined(separator: ".")
        }
        return display(value)
    }
    private static func display(_ value: Any) -> String? {
        if let text = value as? String { return String(text.prefix(512)) }
        if let n = value as? NSNumber { return n.doubleValue.isFinite ? number(n.doubleValue) : nil }
        if let data = value as? Data { return "\(data.count) bytes" }
        if let array = value as? [Any] {
            return array.prefix(16).compactMap(display).joined(separator: ", ") + (array.count > 16 ? " … (\(array.count) values)" : "")
        }
        return nil
    }
}
