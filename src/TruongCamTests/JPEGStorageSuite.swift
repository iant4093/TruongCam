import CoreGraphics
import Foundation
import ImageIO
#if canImport(XCTest)
@testable import TruongCam
#endif

/// Generated JPEG/HEIF/TIFF fixtures and isolated temporary folders only. These
/// checks exercise the real storage/index/display pipeline without phone access
/// or any user library mutation, and do not establish camera capability.

/// Synthetic native output backed by the shipping request/ticket owners. Its
/// output bytes are generated fixtures; nothing opens a camera or invents device
/// support. ChainCameraSpy supplies the existing correlated control readback.
private actor JPEG51CaptureSurface: CaptureCameraSurface {
    let capabilitySnapshot: CameraCapabilitySnapshot
    private let controls = ChainCameraSpy()
    private let bytes: Data
    private let deliveredType: String
    private(set) var submissionCount = 0
    private(set) var lastRequest: PerCaptureRequest?
    var lifecycle: CameraLifecycle { .running }

    init(capability: CameraCapabilitySnapshot, bytes: Data, deliveredType: String = "public.jpeg") {
        self.capabilitySnapshot = capability
        self.bytes = bytes
        self.deliveredType = deliveredType
        controls.setConfigurationGeneration(capability.generation)
    }
    func applyControls(revision: UInt64, exposure: ExposureChoice, biasEV: Double,
                       focus: FocusIntent, whiteBalance: WhiteBalanceIntent, aperture: ApertureChoice = .auto) async -> Result<AppliedControlSnapshot, CaptureFailure> {
        await controls.applyControls(revision: revision, exposure: exposure, biasEV: biasEV,
            focus: focus, whiteBalance: whiteBalance, aperture: aperture)
    }
    func currentControlReadback() async -> AppliedControlSnapshot? { await controls.currentControlReadback() }
    func beginCapture(intent: CaptureIntent) -> any CaptureRequestTicket {
        submissionCount += 1
        let settingsID = Int64(51_000 + submissionCount)
        let request = PerCaptureRequest(captureID: intent.captureID, intent: intent,
            rawPixelFormatType: 0, rawFileType: "public.jpeg", maximumRepresentations: 1)
        _ = request.bindNativeSettingsID(settingsID)
        lastRequest = request
        _ = request.recordRepresentation(DeliveredRAWRepresentation(bytes: bytes, captureID: intent.captureID,
            resolvedSettingsUniqueID: settingsID, nativeBracketIdentity: nil, rawPixelFormatType: 0,
            rawFileType: deliveredType, rawPhotoDimensions: PixelDimensions(width: 32, height: 24),
            rawPixelBufferDimensions: nil, timestampSeconds: nil, metadata: [:]))
        _ = request.recordNativeTerminal(settingsID: settingsID, mappedFailure: nil)
        return CameraCaptureTicket(captureID: intent.captureID, uniqueSettingsID: settingsID, request: request)
    }
}

enum JPEGStorageSuite {
    private struct Harness: Sendable {
        let base: URL
        let root: URL
        let support: URL
        let store: LibraryStore
        let libraryID: LibraryID
        let generation: RootGeneration
    }
    private static func makeStore(base: URL) -> LibraryStore {
        LibraryStore(adapter: SystemFileSystemAdapter(), coordinator: DirectFileCoordinatorMutator(),
            wallClock: StorageFixture.fixedClock(), supportDirectory: base.appendingPathComponent("support"),
            temporaryDirectory: base.appendingPathComponent("exports"), ownedContainerURLs: [],
            bookmarkStore: InMemoryRootBookmarkStore(), scopeDriver: ScriptedSecurityScopeDriver(grants: [true]),
            capacityReserveBytes: 0,
            injectedLocalityVerdict: .userConfirmedLocalDestination(evidence: "Isolated generated JPEG fixture"))
    }
    private static func make(_ name: String) async throws -> Harness {
        let base = StorageFixture.temporaryDirectory("jpeg51-" + name)
        let root = base.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = makeStore(base: base)
        guard case .initialized(let libraryID, let generation) = await store.selectRoot(from: root) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return Harness(base: base, root: root, support: base.appendingPathComponent("support"), store: store,
            libraryID: libraryID, generation: generation)
    }
    private static func bytes() throws -> Data {
        guard let context = CGContext(data: nil, width: 32, height: 24, bitsPerComponent: 8,
            bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw CocoaError(.fileWriteUnknown) }
        context.setFillColor(CGColor(red: 0.7, green: 0.3, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil),
              let image = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return data as Data
    }
    private static func metadata(_ id: CaptureID, _ library: LibraryID, front: Bool = false) -> SourceCaptureMetadata {
        let base = StorageFixture.metadata(captureID: id, libraryID: library)
        return SourceCaptureMetadata(captureID: id, libraryID: library, capturedAtUTC: base.capturedAtUTC,
            capturedAtProvenance: base.capturedAtProvenance, timezoneOffsetSeconds: base.timezoneOffsetSeconds,
            format: .jpeg, deviceModel: base.deviceModel, osVersion: base.osVersion,
            cameraDeviceType: front ? "front" : "wide", requested: base.requested,
            observed: SourceObservedRecord(rawDimensions: PixelDimensions(width: 32, height: 24),
                durationSeconds: 1.0 / 125, iso: 100, aperture: 1.8, focalLengthMM: 5.9,
                orientation: 1, focus: nil, whiteBalance: nil), acquisitionStatus: .complete,
            sequence: nil, equivalentFocalLengthMM: front ? nil : 26)
    }
    private static func sidecar(id: CaptureID, library: LibraryID, path: String, bytes: Data) -> SourceSidecar {
        var value = StorageFixture.sidecar(captureID: id, libraryID: library, relativePath: path,
            byteCount: Int64(bytes.count), sha256: StorageFixture.sha256Hex(bytes))
        value.format = .jpeg
        value.cameraDeviceType = "wide"
        value.observed.rawDimensions = PixelDimensions(width: 32, height: 24)
        return value
    }
    private static func write(_ bytes: Data, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
    }

    private static func capability(kind: PhysicalCameraKind = .wide, generation: ConfigurationGeneration = ConfigurationGeneration(51),
                                   supported: Bool = true) -> CameraCapabilitySnapshot {
        var value = StartupRepairSuite.controlFixture(modes: [.auto], kind: kind, generation: generation)
        value.bayerCaptureSupported = .unavailable(reason: "Synthetic JPEG-only output")
        value.jpegSupported = supported
        value.jpegMaximumDimensions = supported ? PixelDimensions(width: 32, height: 24) : nil
        return value
    }
    private static func intent(_ h: Harness, kind: PhysicalCameraKind = .wide,
                               generation: ConfigurationGeneration = ConfigurationGeneration(51),
                               dimensions: PixelDimensions = PixelDimensions(width: 32, height: 24)) -> CaptureIntent {
        CaptureIntent(captureID: CaptureID(), libraryID: h.libraryID, requestedDimensions: dimensions,
            exposure: .auto, biasEV: 0, focus: FocusIntent(mode: .continuousAuto, position: nil, pointOfInterest: nil),
            whiteBalance: WhiteBalanceIntent(mode: .auto, temperatureAndTint: nil), configurationGeneration: generation,
            rootGeneration: h.generation, physicalCameraKind: kind, createdAtUTC: StorageFixture.fixedDate,
            timezoneOffsetSeconds: 0, mode: .single, fileFormat: .jpeg)
    }

    static let suite = TCSuite(id: "JPEGStorage", title: "Explicit JPEG exact-byte storage and recovery", cases: [
        TCCase(id: "JST51F", title: "The shipping coordinator freezes JPEG identity and commits one exact JPEG through real storage") { r in
            for kind in [PhysicalCameraKind.wide, .front] {
                do {
                    let h = try await make("coordinator-\(kind.rawValue)")
                    defer { StorageFixture.removeDirectory(h.base) }
                    let jpeg = try bytes(), frozen = intent(h, kind: kind)
                    let surface = JPEG51CaptureSurface(capability: capability(kind: kind), bytes: jpeg)
                    let capture = CaptureCoordinator(camera: surface, store: h.store, clock: SystemMonotonicClock())
                    let result = await capture.capture(intent: frozen)
                    r.equal("one JPEG native request", await surface.submissionCount, 1)
                    let nativeRequest = await surface.lastRequest
                    r.equal("native retains the exact immutable intent", nativeRequest?.intent, frozen)
                    r.equal("processed pixel declaration", nativeRequest?.rawPixelFormatType, 0)
                    r.equal("JPEG-only container declaration", nativeRequest?.rawFileType, "public.jpeg")
                    r.equal("one original saved", result.savedToFolderCount, 1)
                    r.check("no capture or save failure", result.failures.isEmpty && result.pendingTransactionIDs.isEmpty,
                        String(describing: result.failures))
                    guard let receipt = result.committedReceipts.first else { r.check("coordinator verified JPEG receipt", false); continue }
                    r.equal("exact capture receipt identity", receipt.captureID, frozen.captureID)
                    r.equal("exact library receipt identity", receipt.libraryID, frozen.libraryID)
                    r.equal("exact root receipt identity", receipt.rootGeneration, frozen.rootGeneration)
                    r.equal("saved actual JPEG bytes", try Data(contentsOf: h.root.appendingPathComponent(receipt.relativeOriginalPath)), jpeg)
                    r.equal("JPEG SHA from actual original", receipt.verifiedSHA256.hex, StorageFixture.sha256Hex(jpeg))
                    r.check("receipt explicitly processed JPEG", receipt.metadata.format.isJPEGDeclaration && !receipt.metadata.format.isBayerRAWDeclaration)
                    r.equal("source retains selected facing", receipt.metadata.cameraDeviceType, kind.rawValue)
                    r.equal("source preserves frozen output ceiling", receipt.metadata.requested.maxDimensions, frozen.requestedDimensions)
                    r.equal("source reports actual native JPEG dimensions", receipt.metadata.observed.rawDimensions, PixelDimensions(width: 32, height: 24))
                    let sidecarData = try Data(contentsOf: h.root.appendingPathComponent(receipt.relativeSidecarPath))
                    let source = try PortableJSONReader().decode(SourceSidecar.self, from: sidecarData,
                        limitBytes: MetadataBounds.maxSourceSidecarUTF8Bytes)
                    r.check("durable sidecar honestly JPEG", source.format.isJPEGDeclaration && source.format.rawPixelFormat == 0 && !source.format.bayerClassification)
                    r.equal("sidecar matches original checksum", source.sha256, receipt.verifiedSHA256.hex)
                    let cards = try await h.store.allReconciledSourceCards()
                    r.equal("exactly one JPEG source card", cards.count, 1)
                    r.equal("no DNG twin", cards.filter { ($0.relativeOriginalPath as NSString).pathExtension == "dng" }.count, 0)
                    r.equal("no pending source left", await h.store.pendingOriginals().count, 0)
                    await h.store.releaseRoot()
                } catch { r.check("connected coordinator JPEG \(kind.rawValue)", false, String(describing: error)) }
            }
        },
        TCCase(id: "JST51G", title: "The shipping coordinator rejects unsupported, stale, wrong-camera, oversized and mismatched JPEG delivery") { r in
            do {
                let h = try await make("coordinator-negative")
                defer { StorageFixture.removeDirectory(h.base) }
                let jpeg = try bytes()
                let scenarios: [(String, CameraCapabilitySnapshot, CaptureIntent, String, Int)] = [
                    ("unsupported", capability(supported: false), intent(h), "public.jpeg", 0),
                    ("stale generation", capability(generation: ConfigurationGeneration(52)), intent(h), "public.jpeg", 0),
                    ("wrong camera", capability(kind: .front), intent(h), "public.jpeg", 0),
                    ("oversized", capability(), intent(h, dimensions: PixelDimensions(width: 33, height: 24)), "public.jpeg", 0),
                    ("wrong delivered type", capability(), intent(h), "public.heic", 1)
                ]
                for (name, cap, frozen, type, submissions) in scenarios {
                    let surface = JPEG51CaptureSurface(capability: cap, bytes: jpeg, deliveredType: type)
                    let capture = CaptureCoordinator(camera: surface, store: h.store, clock: SystemMonotonicClock())
                    let result = await capture.capture(intent: frozen)
                    r.equal("\(name) native submission count", await surface.submissionCount, submissions)
                    r.equal("\(name) never saved", result.savedToFolderCount, 0)
                    r.check("\(name) reports failure", !result.failures.isEmpty)
                    r.check("\(name) owns no invented pending original", result.pendingTransactionIDs.isEmpty && result.pendingHandles.isEmpty)
                    r.equal("\(name) writes no pending bytes", await h.store.pendingOriginals().count, 0)
                    r.equal("\(name) adds no gallery original", try await h.store.allReconciledSourceCards().count, 0)
                }
                await h.store.releaseRoot()
            } catch { r.check("coordinator rejects invalid JPEG capture", false, String(describing: error)) }
        },
        TCCase(id: "JST51A", title: "JPEG type validation rejects misleading names, headers and other photo containers") { r in
            do {
                let h = try await make("discrimination")
                defer { StorageFixture.removeDirectory(h.base) }
                let jpeg = try bytes()
                r.check("generated JPEG decoded", LibraryStore.isJPEGData(jpeg))
                r.check("SOI alone insufficient", !LibraryStore.isJPEGData(Data([0xFF, 0xD8, 0xFF, 0xE0])))
                r.check("truncated header rejected", !LibraryStore.isJPEGData(Data(jpeg.prefix(24))))
                r.check("TIFF cannot be JPEG", !LibraryStore.isJPEGData(StorageFixture.rawBytes()))
                r.check("HEIF cannot be JPEG", !LibraryStore.isJPEGData(try StorageFixture.heifBytes()))
                r.check("JPEG cannot be HEIF", !LibraryStore.isHEIFData(jpeg))
                r.check("JPEG cannot be TIFF", !LibraryStore.looksLikeTIFFContainer(jpeg))
                for bad in [StorageFixture.rawBytes(), try StorageFixture.heifBytes(), Data(jpeg.prefix(24))] {
                    do {
                        _ = try await h.store.stageSource(bytes: bad, metadata: metadata(CaptureID(), h.libraryID))
                        r.check("non-JPEG never staged as JPEG", false)
                    } catch { r.check("non-JPEG never staged as JPEG", true) }
                }
                do {
                    _ = try await h.store.stageSource(bytes: jpeg,
                        metadata: StorageFixture.metadata(captureID: CaptureID(), libraryID: h.libraryID))
                    r.check("JPEG never staged as RAW", false)
                } catch { r.check("JPEG never staged as RAW", true) }
                r.equal("no invalid durable pending records", await h.store.pendingOriginals().count, 0)
                await h.store.releaseRoot()
            } catch { r.check("JPEG type discrimination", false, String(describing: error)) }
        },
        TCCase(id: "JST51B", title: "JPEG keeps exact bytes through save, SQLite, display, export, Trash, restore and purge") { r in
            do {
                let h = try await make("connected")
                defer { StorageFixture.removeDirectory(h.base) }
                let jpeg = try bytes(), id = CaptureID()
                let staged = try await h.store.stageSource(bytes: jpeg, metadata: metadata(id, h.libraryID))
                r.check("pending uses jpg", staged.pendingRelativePath.hasSuffix("/source.jpg"))
                let receipt = try await h.store.commit(handle: staged)
                r.check("verified JPG original", receipt.isOriginalAvailable && receipt.relativeOriginalPath.hasSuffix(".jpg"))
                let originalURL = h.root.appendingPathComponent(receipt.relativeOriginalPath)
                r.equal("byte exact original", try Data(contentsOf: originalURL), jpeg)
                r.equal("verified byte count", receipt.verifiedByteCount, Int64(jpeg.count))
                r.equal("verified checksum", receipt.verifiedSHA256.hex, StorageFixture.sha256Hex(jpeg))
                r.check("metadata is separate", receipt.relativeSidecarPath.hasPrefix("metadata/"))
                let report = try await h.store.reconcile(onProgress: nil)
                r.equal("one verified original", report.verifiedOriginalCount, 1)
                let cards = try await h.store.allReconciledSourceCards()
                guard let card = cards.first else { r.check("JPEG source card", false); return }
                r.check("exact matching app metadata", card.isTruongCamCapture && card.captureID == id)
                let index = SQLiteIndex(databaseURL: h.base.appendingPathComponent("index.sqlite"))
                try await index.reset(libraryID: h.libraryID, generation: h.generation)
                try await index.upsert(scanned: cards)
                let model = await LibraryViewModel(index: index, store: h.store)
                await model.loadFirstPage()
                r.equal("shipping library model loads JPEG", await model.loadedSourceCount, 1)
                let thumbnails = ThumbnailService(rootURLProvider: { h.root }, diskCacheDirectory: h.base.appendingPathComponent("cache"))
                let display = thumbnails.viewerPreviewSynchronously(atAbsoluteURL: originalURL,
                    identity: id.description, boundLongEdge: 256)
                if case .image = display { r.check("JPEG display decoded", true) }
                else { r.check("JPEG display decoded", false, String(describing: display)) }
                let exported = try await h.store.prepareOriginalExport(sourceIDs: [id], includeSidecars: false)
                r.equal("one original export", exported.fileURLs.count, 1)
                r.equal("JPEG export extension", exported.fileURLs.first?.pathExtension, "jpg")
                if let url = exported.fileURLs.first { r.equal("exact exported JPEG", try Data(contentsOf: url), jpeg) }
                await h.store.discardExport(sessionID: exported.sessionID)
                let trash = try await h.store.trashOriginal(card: card, generation: h.generation)
                r.equal("exact JPEG in Trash", try Data(contentsOf: h.root.appendingPathComponent(trash.storedOriginalPath)), jpeg)
                r.equal("JPEG Trash visible", try await h.store.trashedOriginals().count, 1)
                try await h.store.restoreOriginal(trashID: trash.id, libraryID: h.libraryID, generation: h.generation)
                r.equal("restored original exact", try Data(contentsOf: originalURL), jpeg)
                let retrash = try await h.store.trashOriginal(card: card, generation: h.generation)
                let unknown = h.root.appendingPathComponent(retrash.directory + "/keep-user-file.txt")
                try write(Data("preserve".utf8), at: unknown)
                try await h.store.permanentlyDeleteOriginal(record: retrash, generation: h.generation)
                r.check("purged original absent", !FileManager.default.fileExists(atPath: h.root.appendingPathComponent(retrash.storedOriginalPath).path))
                r.equal("purge preserves unrelated file", try Data(contentsOf: unknown), Data("preserve".utf8))
                r.equal("no deleted record left", try await h.store.trashedOriginals().count, 0)
                await h.store.releaseRoot()
            } catch { r.check("connected JPEG storage pipeline", false, String(describing: error)) }
        },
        TCCase(id: "JST51C", title: "JPEG pending survives reconstruction, exact export and retry with or without its journal") { r in
            for removeJournal in [false, true] {
                do {
                    let h = try await make("pending-\(removeJournal)")
                    defer { StorageFixture.removeDirectory(h.base) }
                    let jpeg = try bytes(), id = CaptureID()
                    let staged = try await h.store.stageSource(bytes: jpeg, metadata: metadata(id, h.libraryID, front: true))
                    if removeJournal {
                        let directory = h.support.appendingPathComponent(staged.pendingRelativePath).deletingLastPathComponent()
                        try FileManager.default.removeItem(at: directory.appendingPathComponent("transaction.json"))
                    }
                    await h.store.releaseRoot()
                    let recovered = makeStore(base: h.base)
                    guard case .opened = await recovered.selectRoot(from: h.root) else { r.check("JPEG recovery reconnect", false); continue }
                    let pending = await recovered.pendingOriginals()
                    guard let entry = pending.first else { r.check("JPEG pending recovered", false); continue }
                    r.equal("one durable JPEG pending", pending.count, 1)
                    r.check("pending JPG kept", entry.pendingRelativePath.hasSuffix(".jpg") && entry.intendedRelativeOriginalPath.hasSuffix(".jpg"))
                    let exported = try await recovered.preparePendingOriginalExport(transactionIDs: [entry.transactionID], includeSidecars: false)
                    r.equal("pending export extension", exported.fileURLs.first?.pathExtension, "jpg")
                    if let url = exported.fileURLs.first { r.equal("pending export exact", try Data(contentsOf: url), jpeg) }
                    await recovered.discardExport(sessionID: exported.sessionID)
                    let receipt = try await recovered.retry(transactionID: entry.transactionID)
                    r.equal("retry exact original", try Data(contentsOf: h.root.appendingPathComponent(receipt.relativeOriginalPath)), jpeg)
                    r.check("retry remains JPEG declaration", receipt.metadata.format.isJPEGDeclaration)
                    r.equal("pending removed after verified commit", await recovered.pendingOriginals().count, 0)
                    await recovered.releaseRoot()
                } catch { r.check("reconstructed JPEG pending \(removeJournal)", false, String(describing: error)) }
            }
        },
        TCCase(id: "JST51D", title: "Reconnect accepts real jpg/jpeg originals and refuses renamed bytes without rewriting") { r in
            do {
                let h = try await make("reconnect")
                defer { StorageFixture.removeDirectory(h.base) }
                let jpeg = try bytes(), validID = CaptureID()
                let validPath = "originals/TC_\(validID.description).jpg"
                let alternatePath = "originals/from-another-camera.JPEG"
                let badRAW = "originals/renamed-jpeg.dng", badJPEG = "originals/renamed-tiff.jpg"
                for (path, data) in [(validPath, jpeg), (alternatePath, jpeg), (badRAW, jpeg), (badJPEG, StorageFixture.rawBytes())] {
                    try write(data, at: h.root.appendingPathComponent(path))
                }
                let value = sidecar(id: validID, library: h.libraryID, path: validPath, bytes: jpeg)
                try write(StorageFixture.sidecarData(value), at: h.root.appendingPathComponent(LibraryLayout.metadataSidecarPath(for: validPath)))
                let report = try await h.store.reconcile(onProgress: nil)
                r.equal("matching JPEG metadata verified", report.verifiedOriginalCount, 1)
                r.equal("unrecorded JPEG recovered", report.recoveredRAWCount, 1)
                let cards = try await h.store.allReconciledSourceCards()
                r.equal("only real photo containers browsable", Set(cards.map(\.relativeOriginalPath)), Set([validPath, alternatePath]))
                r.equal("jpg UUID parsed", LibraryStore.captureID(fromFileName: "TC_\(validID.description).jpg"), validID)
                r.equal("jpeg UUID parsed", LibraryStore.captureID(fromFileName: "TC_\(validID.description).JPEG"), validID)
                guard let recoveredCard = cards.first(where: { $0.relativeOriginalPath == alternatePath }) else { r.check("alternate JPEG card", false); return }
                let export = try await h.store.prepareOriginalExport(sourceIDs: [recoveredCard.captureID], includeSidecars: false)
                r.equal("alternate JPEG exact export", try Data(contentsOf: export.fileURLs[0]), jpeg)
                await h.store.discardExport(sessionID: export.sessionID)
                for (path, data) in [(validPath, jpeg), (alternatePath, jpeg), (badRAW, jpeg), (badJPEG, StorageFixture.rawBytes())] {
                    r.equal("scan preserves all original bytes \(path)", try Data(contentsOf: h.root.appendingPathComponent(path)), data)
                }
                // A stale selected card cannot export newly substituted TIFF
                // bytes as JPEG, even without authoritative app metadata.
                try StorageFixture.rawBytes().write(to: h.root.appendingPathComponent(alternatePath))
                do {
                    _ = try await h.store.prepareOriginalExport(sourceIDs: [recoveredCard.captureID], includeSidecars: false)
                    r.check("renamed replacement export refused", false)
                } catch { r.check("renamed replacement export refused", true) }
                try jpeg.write(to: h.root.appendingPathComponent(alternatePath))
                await h.store.releaseRoot()
                guard case .opened = await h.store.selectRoot(from: h.root) else { r.check("JPEG reconnect opened", false); return }
                r.equal("reinstall-style rebuild keeps JPEGs", try await h.store.allReconciledSourceCards().count, 2)
                await h.store.releaseRoot()
            } catch { r.check("JPEG reconnect discrimination", false, String(describing: error)) }
        },
        TCCase(id: "JST51E", title: "External JPEG staging recovers exact bytes and rejects a hash-matching renamed TIFF") { r in
            for validJPEG in [true, false] {
                do {
                    let h = try await make("external-\(validJPEG)")
                    defer { StorageFixture.removeDirectory(h.base) }
                    let data = validJPEG ? try bytes() : StorageFixture.rawBytes()
                    let id = CaptureID(), transaction = TransactionID()
                    let path = LibraryLayout.relativeOriginalPath(for: id, capturedAt: StorageFixture.fixedDate,
                        calendar: StorageFixture.utcCalendar, format: .jpeg)
                    let packet = h.root.appendingPathComponent(LibraryLayout.stagingDirectoryName + "/" + transaction.description)
                    let record = TransactionRecord(schemaVersion: truongCamSupportedSchemaVersion,
                        transactionID: transaction.rawValue, captureID: id.rawValue, libraryID: h.libraryID.rawValue,
                        rootGeneration: h.generation.value, phase: .stagingProvider, expectedByteCount: Int64(data.count),
                        expectedSHA256: StorageFixture.sha256Hex(data), relativeOriginalPath: path,
                        createdAtUTC: StorageFixture.fixedDate, updatedAtUTC: StorageFixture.fixedDate, lastError: nil)
                    try write(PortableJSONWriter().encode(record, explicitNullKeys: []), at: packet.appendingPathComponent("transaction.json"))
                    try write(data, at: packet.appendingPathComponent("source.jpg.partial"))
                    try write(StorageFixture.sidecarData(sidecar(id: id, library: h.libraryID, path: path, bytes: data)),
                        at: packet.appendingPathComponent("source.json.partial"))
                    let report = try await h.store.reconcile(onProgress: nil)
                    let finalURL = h.root.appendingPathComponent(path)
                    r.equal("only genuine JPEG recovered", report.verifiedOriginalCount, validJPEG ? 1 : 0)
                    r.equal("only genuine JPEG published", FileManager.default.fileExists(atPath: finalURL.path), validJPEG)
                    if validJPEG { r.equal("external recovered exact", try Data(contentsOf: finalURL), data) }
                    else { r.equal("rejected bytes preserved", try Data(contentsOf: packet.appendingPathComponent("source.jpg.partial")), data) }
                    await h.store.releaseRoot()
                } catch { r.check("external JPEG recovery \(validJPEG)", false, String(describing: error)) }
            }
        }
    ])
}
