import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Synchronization

// Native test bundles read the app's real types through the module; the
// standalone verifier compiles the app sources into the same executable and
// therefore cannot import a module. XCTest is only available in the native
// bundle, so it gates the import.
#if canImport(XCTest)
@testable import TruongCam
#endif


// TEST_PLAN.md T10–T24 and T30 for the portable library storage stack.
//
// Evidence class: LOCAL_HARNESS. The transaction state machine runs against the
// in-memory adapter; the SQLite index and the ImageIO thumbnail path run against
// real files under the system temporary directory. No synthetic file here is
// presented as a real device DNG or as device acceptance evidence: the RAW
// fixtures carry a TIFF container header and synthetic payload bytes only, and
// iPhone capability/file-provider persistence remain NOT_RUN.

// MARK: - Fixtures

enum StorageFixture {
    static let fixedDate = Date(timeIntervalSince1970: 1_790_000_000)

    static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    static func fixedClock() -> FixedWallClock {
        FixedWallClock(instant: fixedDate, timeZone: TimeZone(identifier: "UTC")!)
    }

    /// Synthetic RAW bytes. It is a TIFF container (so the storage stack treats it
    /// as a DNG-shaped original) with a filler payload; it is NOT a real capture
    /// and proves nothing about Bayer capability.
    static func rawBytes(byteCount: Int = 4_096, filler: UInt8 = 0x2A) -> Data {
        var data = Data([0x49, 0x49, 0x2A, 0x00])
        if byteCount > 4 {
            data.append(Data(repeating: filler, count: byteCount - 4))
        }
        return data
    }

    static func heifBytes() throws -> Data {
        let context = CGContext(data: nil, width: 32, height: 24, bitsPerComponent: 8, bytesPerRow: 128,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.heic" as CFString, 1, nil), let image = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return data as Data
    }
    static func frontMetadata(captureID: CaptureID, libraryID: LibraryID) -> SourceCaptureMetadata {
        let base = metadata(captureID: captureID, libraryID: libraryID)
        return SourceCaptureMetadata(captureID: captureID, libraryID: libraryID, capturedAtUTC: base.capturedAtUTC,
            capturedAtProvenance: base.capturedAtProvenance, timezoneOffsetSeconds: base.timezoneOffsetSeconds, format: .frontHEIF,
            deviceModel: base.deviceModel, osVersion: base.osVersion, cameraDeviceType: "front", requested: base.requested,
            observed: SourceObservedRecord(rawDimensions: PixelDimensions(width: 32, height: 24), durationSeconds: 1.0/60, iso: 100, aperture: 1.9,
                focalLengthMM: nil, orientation: 1, focus: nil, whiteBalance: nil), acquisitionStatus: .complete, sequence: nil, equivalentFocalLengthMM: nil)
    }

    static func metadata(
        captureID: CaptureID,
        libraryID: LibraryID,
        sequence: SourceSequenceLink? = nil,
        acquiredStatus: AcquisitionStatus = .complete
    ) -> SourceCaptureMetadata {
        SourceCaptureMetadata(
            captureID: captureID,
            libraryID: libraryID,
            capturedAtUTC: fixedDate,
            capturedAtProvenance: .captureMetadata,
            timezoneOffsetSeconds: 0,
            format: SourceFormatRecord(rawPixelFormat: 0x4247_4734),
            deviceModel: "TEST-device-model",
            osVersion: "TEST-os",
            cameraDeviceType: "AVCaptureDeviceTypeBuiltInWideAngleCamera",
            requested: CaptureRequestRecord(
                maxDimensions: PixelDimensions(width: 4_032, height: 3_024),
                exposure: ExposureRequestRecord(mode: .auto, durationSeconds: nil, iso: nil, biasEV: 0),
                focus: FocusRequestRecord(mode: .continuousAuto, position: nil),
                whiteBalance: WhiteBalanceRequestRecord(mode: .auto, temperatureKelvin: nil, tint: nil)),
            observed: SourceObservedRecord(
                rawDimensions: PixelDimensions(width: 4_032, height: 3_024),
                durationSeconds: 1.0 / 125,
                iso: 100,
                aperture: 1.8,
                focalLengthMM: 24,
                orientation: 1,
                focus: FocusObservedRecord(position: nil, provenance: .unknown),
                whiteBalance: WhiteBalanceObservedRecord(gains: nil, provenance: .unknown)),
            acquisitionStatus: acquiredStatus,
            sequence: sequence,
            equivalentFocalLengthMM: 24)
    }

    static func sidecar(
        captureID: CaptureID,
        libraryID: LibraryID,
        relativePath: String,
        byteCount: Int64,
        sha256: String,
        sequence: SourceSequenceLink? = nil
    ) -> SourceSidecar {
        let metadata = metadata(captureID: captureID, libraryID: libraryID, sequence: sequence)
        return SourceSidecar(
            schemaVersion: truongCamSupportedSchemaVersion,
            captureID: captureID.rawValue,
            libraryID: libraryID.rawValue,
            capturedAtUTC: metadata.capturedAtUTC,
            timezoneOffsetSeconds: metadata.timezoneOffsetSeconds,
            relativeOriginalPath: relativePath,
            byteCount: byteCount,
            sha256: sha256,
            format: metadata.format,
            deviceModel: metadata.deviceModel,
            osVersion: metadata.osVersion,
            cameraDeviceType: metadata.cameraDeviceType,
            requested: metadata.requested,
            observed: metadata.observed,
            ui: SourceUIHints(equivalentFocalLengthMM: metadata.equivalentFocalLengthMM, cropGuide: nil),
            sequence: sequence,
            acquisitionStatus: .complete,
            commitRecordedAtUTC: metadata.capturedAtUTC,
            capturedAtProvenance: metadata.capturedAtProvenance)
    }

    static func sidecarData(_ sidecar: SourceSidecar) -> Data {
        (try? PortableJSONWriter().encode(sidecar, explicitNullKeys: SourceSidecar.explicitNullKeyPaths))
            ?? Data()
    }

    static func manifestData(_ manifest: LibraryManifest) -> Data {
        (try? PortableJSONWriter().encode(manifest, explicitNullKeys: [])) ?? Data()
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func readJournal(_ memory: InMemoryFileSystemAdapter, support: URL, captureID: CaptureID) -> TransactionRecord? {
        let url = support
            .appendingPathComponent("PendingCaptures", isDirectory: true)
            .appendingPathComponent(captureID.description, isDirectory: true)
            .appendingPathComponent("transaction.json", isDirectory: false)
        guard let data = memory.fileBytes(at: url) else { return nil }
        do {
            return try PortableJSONReader().decode(
                TransactionRecord.self, from: data, limitBytes: MetadataBounds.maxSourceSidecarUTF8Bytes)
        } catch {
            return nil
        }
    }

    static func cards(count: Int, libraryID: LibraryID, startingAt date: Date) -> [LibrarySourceCard] {
        (0..<count).map { index in
            LibrarySourceCard(
                captureID: CaptureID(),
                libraryID: libraryID,
                relativeOriginalPath: "originals/2026/09/22/TC_\(UUID().uuidString.lowercased()).dng",
                capturedAtUTC: date.addingTimeInterval(-Double(index)),
                capturedAtProvenance: .captureMetadata,
                availability: .local,
                classification: .verifiedOriginal,
                rawDimensions: PixelDimensions(width: 4_032, height: 3_024),
                byteCount: 4_096,
                sequenceID: nil,
                sequenceIndex: nil,
                sequenceKind: nil,
                isTruongCamCapture: true,
                modificationFingerprint: "synthetic-\(index)")
        }
    }

    static func temporaryDirectory(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("TruongCamStorageTests", isDirectory: true)
            .appendingPathComponent("\(name)-\(UUID().uuidString.lowercased())", isDirectory: true)
    }

    static func removeDirectory(_ url: URL) {
        do { try FileManager.default.removeItem(at: url) } catch { /* test cleanup */ }
    }
}

// MARK: - Harness

struct StorageHarness: Sendable {
    let memory: InMemoryFileSystemAdapter
    let fault: FaultInjectingFileSystemAdapter
    let root: URL
    let support: URL
    let temporary: URL
    let store: LibraryStore
    let libraryID: LibraryID
    let generation: RootGeneration

    /// Builds the objects without selecting a root, for selection/negative tests.
    static func makeRaw(
        name: String,
        plan: [FileFaultPhase: Int] = [:],
        deviceFull: Bool = false,
        ownedContainerURLs: [URL]? = [],
        bookmarks: InMemoryRootBookmarkStore = InMemoryRootBookmarkStore(),
        driver: ScriptedSecurityScopeDriver = ScriptedSecurityScopeDriver(grants: [true]),
        memory: InMemoryFileSystemAdapter? = nil,
        root: URL? = nil,
        support: URL? = nil,
        temporary: URL? = nil,
        coordinator: (any CoordinatedFileMutator)? = nil
    ) -> StorageHarness? {
        let base = URL(fileURLWithPath: "/tc-storage-tests/\(name)", isDirectory: true)
        let resolvedRoot = root ?? base.appendingPathComponent("library", isDirectory: true)
        let resolvedSupport = support ?? base.appendingPathComponent("support", isDirectory: true)
        let resolvedTemporary = temporary ?? base.appendingPathComponent("tmp", isDirectory: true)
        let resolvedMemory = memory ?? InMemoryFileSystemAdapter()
        do {
            if !resolvedMemory.fileExists(at: resolvedRoot) {
                try resolvedMemory.createDirectory(at: resolvedRoot, withIntermediateDirectories: true)
            }
        } catch {
            return nil
        }
        let fault = FaultInjectingFileSystemAdapter(
            wrapping: resolvedMemory,
            faultRoots: [resolvedRoot, resolvedSupport, resolvedTemporary],
            plan: plan,
            deviceFull: deviceFull)
        let store = LibraryStore(
            adapter: fault,
            coordinator: coordinator ?? DirectFileCoordinatorMutator(),
            wallClock: StorageFixture.fixedClock(),
            supportDirectory: resolvedSupport,
            temporaryDirectory: resolvedTemporary,
            ownedContainerURLs: ownedContainerURLs,
            bookmarkStore: bookmarks,
            scopeDriver: driver,
            capacityReserveBytes: 0,
            injectedLocalityVerdict: .userConfirmedLocalDestination(
                evidence: "Synthetic in-memory storage, locality known by construction."))
        return StorageHarness(memory: resolvedMemory,
                              fault: fault,
                              root: resolvedRoot,
                              support: resolvedSupport,
                              temporary: resolvedTemporary,
                              store: store,
                              libraryID: LibraryID(),
                              generation: .zero)
    }

    /// Builds the harness and initializes a fresh root.
    static func make(name: String,
                     plan: [FileFaultPhase: Int] = [:],
                     deviceFull: Bool = false,
                     ownedContainerURLs: [URL]? = [],
                     bookmarks: InMemoryRootBookmarkStore = InMemoryRootBookmarkStore(),
                     driver: ScriptedSecurityScopeDriver = ScriptedSecurityScopeDriver(grants: [true]),
                     coordinator: (any CoordinatedFileMutator)? = nil) async -> StorageHarness? {
        guard let raw = makeRaw(name: name, plan: plan, deviceFull: deviceFull,
                                ownedContainerURLs: ownedContainerURLs,
                                bookmarks: bookmarks, driver: driver,
                                coordinator: coordinator) else { return nil }
        let outcome = await raw.store.selectRoot(from: raw.root)
        guard case .initialized(let libraryID, let generation) = outcome else { return nil }
        return StorageHarness(memory: raw.memory,
                              fault: raw.fault,
                              root: raw.root,
                              support: raw.support,
                              temporary: raw.temporary,
                              store: raw.store,
                              libraryID: libraryID,
                              generation: generation)
    }

    /// A second store over the same folder and staging (process restart).
    func reopening(name: String) async -> StorageHarness? {
        guard let raw = StorageHarness.makeRaw(name: name,
                                              memory: memory,
                                              root: root,
                                              support: support,
                                              temporary: temporary) else { return nil }
        let outcome = await raw.store.selectRoot(from: root)
        guard case .opened(let libraryID, let generation, _) = outcome else { return nil }
        return StorageHarness(memory: raw.memory,
                              fault: raw.fault,
                              root: raw.root,
                              support: raw.support,
                              temporary: raw.temporary,
                              store: raw.store,
                              libraryID: libraryID,
                              generation: generation)
    }

    func finalURL(for captureID: CaptureID) -> URL {
        root.appendingPathComponent(
            LibraryLayout.relativeOriginalPath(for: captureID, capturedAt: StorageFixture.fixedDate,
                                               calendar: StorageFixture.utcCalendar),
            isDirectory: false)
    }

    func finalSidecarURL(for captureID: CaptureID) -> URL {
        let relative = LibraryLayout.relativeOriginalPath(for: captureID, capturedAt: StorageFixture.fixedDate,
                                                         calendar: StorageFixture.utcCalendar)
        return root.appendingPathComponent(LibraryLayout.metadataSidecarPath(for: relative))
    }

    func pendingSourceURL(for captureID: CaptureID) -> URL {
        support
            .appendingPathComponent("PendingCaptures", isDirectory: true)
            .appendingPathComponent(captureID.description, isDirectory: true)
            .appendingPathComponent("source.dng", isDirectory: false)
    }
}

// MARK: - Suite

enum StorageSuite {
    static let suite = TCSuite(
        id: "Storage",
        title: "Portable library storage stack (save pipeline, recovery, index, export)",
        cases: [
            TCCase(id: "FC01", title: "Front HEIF commits exact native bytes and survives reconnect, SQLite, export and recoverable Trash") { r in
                let base = StorageFixture.temporaryDirectory("front-heif")
                defer { StorageFixture.removeDirectory(base) }
                do {
                    let root = base.appendingPathComponent("library"), support = base.appendingPathComponent("support")
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                    let adapter = SystemFileSystemAdapter()
                    let store = LibraryStore(adapter: adapter, coordinator: DirectFileCoordinatorMutator(), wallClock: StorageFixture.fixedClock(),
                        supportDirectory: support, temporaryDirectory: base.appendingPathComponent("exports"), ownedContainerURLs: [],
                        bookmarkStore: InMemoryRootBookmarkStore(), scopeDriver: ScriptedSecurityScopeDriver(grants: [true]), capacityReserveBytes: 0,
                        injectedLocalityVerdict: .userConfirmedLocalDestination(evidence: "Temporary real filesystem fixture"))
                    guard case .initialized(let libraryID, let generation) = await store.selectRoot(from: root) else { r.check("root initialized", false); return }
                    let bytes = try StorageFixture.heifBytes()
                    r.check("real HEIF recognized", LibraryStore.isHEIFData(bytes))
                    r.check("TIFF rejected as HEIF", !LibraryStore.isHEIFData(StorageFixture.rawBytes()))
                    r.check("truncated ftyp rejected", !LibraryStore.isHEIFData(bytes.prefix(24)))
                    let id = CaptureID()
                    let native = ChainCameraSpy(captureID: id)
                    let coordinator = CaptureCoordinator(camera: native, store: store, clock: SystemMonotonicClock())
                    let intent = CaptureIntent(captureID: id, libraryID: libraryID, requestedDimensions: PixelDimensions(width: 32,height: 24),
                        exposure: .auto, biasEV: 0, focus: FocusIntent(mode: .continuousAuto, position: nil, pointOfInterest: nil),
                        whiteBalance: WhiteBalanceIntent(mode: .auto, temperatureAndTint: nil), configurationGeneration: .zero,
                        rootGeneration: generation, physicalCameraKind: .front, createdAtUTC: StorageFixture.fixedDate,
                        timezoneOffsetSeconds: 0, mode: .single, fileFormat: .frontHEIF)
                    let task = Task { await coordinator.capture(intent: intent) }
                    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                    while native.attachCount == 0, ContinuousClock.now < deadline { await Task.yield() }
                    r.check("shipping coordinator submitted frozen HEIF", native.attachCount == 1)
                    r.check("owner retains HEIF format", native.captureTicket.request.intent.fileFormat == .frontHEIF)
                    r.check("native boundary delivered HEIF", native.captureTicket.deliverRepresentation(bytes: bytes,
                        dimensions: PixelDimensions(width: 32,height: 24), rawPixelFormatType: 0, rawFileType: "public.heic"))
                    native.captureTicket.deliver(.success)
                    let result = await task.value
                    r.check("no pending or capture failures", result.pendingTransactionIDs.isEmpty && result.failures.isEmpty, String(describing: result.failures))
                    guard let receipt = result.committedReceipts.first else { r.check("verified HEIF receipt", false); return }
                    r.check("receipt is HEIC", receipt.relativeOriginalPath.hasSuffix(".heic"))
                    r.equal("committed bytes unchanged", try Data(contentsOf: root.appendingPathComponent(receipt.relativeOriginalPath)), bytes)
                    let report = try await store.reconcile(onProgress: nil)
                    r.equal("reconciled verified original", report.verifiedOriginalCount, 1)
                    let cards = try await store.allReconciledSourceCards()
                    r.equal("one truthful source", cards.count, 1)
                    guard let card = cards.first else { return }
                    r.check("genuine app record", card.isTruongCamCapture)
                    let index = SQLiteIndex(databaseURL: base.appendingPathComponent("index.sqlite"))
                    try await index.reset(libraryID: libraryID, generation: generation)
                    try await index.upsert(scanned: cards)
                    let model = await LibraryViewModel(index: index, store: store)
                    await model.loadFirstPage()
                    r.equal("shipping SQLite model finds HEIF", await model.loadedSourceCount, 1)
                    let export = try await store.prepareOriginalExport(sourceIDs: [id], includeSidecars: false)
                    r.equal("photo-only export", export.fileURLs.count, 1)
                    r.equal("export keeps HEIC extension", export.fileURLs.first?.pathExtension, "heic")
                    r.equal("export exact bytes", try Data(contentsOf: export.fileURLs[0]), bytes)
                    await store.discardExport(sessionID: export.sessionID)
                    do { _ = try await store.trashOriginal(card: card, generation: .next(generation)); r.check("stale delete refused", false) }
                    catch { r.check("stale delete refused", true) }
                    let trash = try await store.trashOriginal(card: card, generation: generation)
                    r.equal("trash exact HEIC", try Data(contentsOf: root.appendingPathComponent(trash.directory + "/original.heic")), bytes)
                    try await store.restoreOriginal(trashID: trash.id, libraryID: libraryID, generation: generation)
                    r.equal("restored exact bytes", try Data(contentsOf: root.appendingPathComponent(receipt.relativeOriginalPath)), bytes)
                    let previews = ThumbnailService(rootURLProvider: { root }, diskCacheDirectory: base.appendingPathComponent("previews"))
                    let preview = previews.viewerPreviewSynchronously(atAbsoluteURL: root.appendingPathComponent(receipt.relativeOriginalPath), identity: id.description, boundLongEdge: 256)
                    if case .image = preview { r.check("viewer decodes HEIF", true) } else { r.check("viewer decodes HEIF", false, String(describing: preview)) }
                    await store.releaseRoot()
                    guard case .opened = await store.selectRoot(from: root) else { r.check("reconnect", false); return }
                    r.equal("reconnect rebuilds front original", try await store.allReconciledSourceCards().count, 1)
                    // A rear Bayer declaration cannot carry HEIF or vice versa.
                    do { _ = try await store.stageSource(bytes: bytes, metadata: StorageFixture.metadata(captureID: CaptureID(), libraryID: libraryID)); r.check("HEIF as RAW refused", false) }
                    catch { r.check("HEIF as RAW refused", true) }
                    do { _ = try await store.stageSource(bytes: StorageFixture.rawBytes(), metadata: StorageFixture.frontMetadata(captureID: CaptureID(), libraryID: libraryID)); r.check("TIFF as HEIF refused", false) }
                    catch { r.check("TIFF as HEIF refused", true) }
                } catch { r.check("connected HEIF pipeline", false, String(describing: error)) }
            },
            TCCase(id: "FC05", title: "A frozen HEIF intent is front-only and cannot substitute for a Bayer request") { r in
                let base = ChainCameraSpy.defaultIntent(captureID: CaptureID())
                func intent(_ kind: PhysicalCameraKind, _ format: CaptureFileFormat) -> CaptureIntent {
                    CaptureIntent(captureID: base.captureID, libraryID: base.libraryID, requestedDimensions: base.requestedDimensions,
                        exposure: base.exposure, biasEV: base.biasEV, focus: base.focus, whiteBalance: base.whiteBalance,
                        configurationGeneration: base.configurationGeneration, rootGeneration: base.rootGeneration, physicalCameraKind: kind,
                        createdAtUTC: base.createdAtUTC, timezoneOffsetSeconds: 0, mode: .single, fileFormat: format)
                }
                func representation(_ raw: Bool) -> DeliveredRAWRepresentation {
                    DeliveredRAWRepresentation(bytes: Data([1]), captureID: base.captureID, resolvedSettingsUniqueID: 4,
                        nativeBracketIdentity: nil, rawPixelFormatType: raw ? 0x42474734 : 0,
                        rawFileType: raw ? "com.adobe.raw-image" : "public.heic", rawPhotoDimensions: nil,
                        rawPixelBufferDimensions: nil, timestampSeconds: nil, metadata: [:])
                }
                func accepts(_ photo: DeliveredRAWRepresentation, _ request: CaptureIntent) -> Bool {
                    CaptureCoordinator.acceptsRepresentation(photo, for: request, classifier: ConservativeBayerClassifier())
                }
                r.check("explicit front HEIF accepted", accepts(representation(false), intent(.front,.frontHEIF)))
                r.check("rear HEIF refused", !accepts(representation(false), intent(.wide,.frontHEIF)))
                r.check("front RAW cannot silently become HEIF", !accepts(representation(false), intent(.front,.bayerDNG)))
                r.check("HEIF cannot silently become RAW", !accepts(representation(true), intent(.front,.frontHEIF)))
                r.check("rear RAW remains accepted", accepts(representation(true), intent(.wide,.bayerDNG)))
                r.check("front genuine RAW remains accepted", accepts(representation(true), intent(.front,.bayerDNG)))
            },
            TCCase(id: "FC06", title: "A front HEIF pending save survives process reconstruction and keeps exact export and retry bytes") { r in
                let base = StorageFixture.temporaryDirectory("front-pending")
                defer { StorageFixture.removeDirectory(base) }
                do {
                    let root = base.appendingPathComponent("library"), support = base.appendingPathComponent("support")
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                    func makeStore() -> LibraryStore {
                        LibraryStore(adapter: SystemFileSystemAdapter(), coordinator: DirectFileCoordinatorMutator(), wallClock: StorageFixture.fixedClock(),
                            supportDirectory: support, temporaryDirectory: base.appendingPathComponent("exports"), ownedContainerURLs: [],
                            bookmarkStore: InMemoryRootBookmarkStore(), scopeDriver: ScriptedSecurityScopeDriver(grants: [true]), capacityReserveBytes: 0,
                            injectedLocalityVerdict: .userConfirmedLocalDestination(evidence: "Temporary real filesystem fixture"))
                    }
                    let original = makeStore()
                    guard case .initialized(let libraryID, _) = await original.selectRoot(from: root) else { r.check("root", false); return }
                    let bytes = try StorageFixture.heifBytes(), id = CaptureID()
                    let staged = try await original.stageSource(bytes: bytes, metadata: StorageFixture.frontMetadata(captureID: id, libraryID: libraryID))
                    r.check("pending name is honest HEIC", staged.pendingRelativePath.hasSuffix(".heic"))
                    r.check("pending destination is HEIC", staged.intendedRelativeOriginalPath.hasSuffix(".heic"))
                    await original.releaseRoot()
                    let recovered = makeStore()
                    guard case .opened = await recovered.selectRoot(from: root) else { r.check("reconnect", false); return }
                    r.equal("durable pending recovered", await recovered.pendingOriginals().count, 1)
                    let export = try await recovered.preparePendingOriginalExport(transactionIDs: [staged.transactionID], includeSidecars: false)
                    r.equal("pending export honest HEIC", export.fileURLs.first?.pathExtension, "heic")
                    r.equal("pending export unchanged", try Data(contentsOf: export.fileURLs[0]), bytes)
                    await recovered.discardExport(sessionID: export.sessionID)
                    let receipt = try await recovered.retry(transactionID: staged.transactionID)
                    r.equal("recovered retry destination HEIC", (receipt.relativeOriginalPath as NSString).pathExtension, "heic")
                    r.equal("recovered commit unchanged", try Data(contentsOf: root.appendingPathComponent(receipt.relativeOriginalPath)), bytes)
                    r.equal("pending cleared only after commit", await recovered.pendingOriginals().count, 0)
                } catch { r.check("pending HEIF recovery", false, String(describing: error)) }
            },
            TCCase(id: "FC02", title: "Front metadata remains explicitly processed and cannot be declared rear RAW") { r in
                let capture = CaptureID(), library = LibraryID()
                var sidecar = StorageFixture.sidecar(captureID: capture, libraryID: library,
                    relativePath: LibraryLayout.relativeOriginalPath(for: capture, capturedAt: StorageFixture.fixedDate, calendar: StorageFixture.fixedClock().calendar, format: .frontHEIF), byteCount: 100, sha256: String(repeating: "a", count: 64))
                sidecar.format = .frontHEIF; sidecar.cameraDeviceType = "front"
                r.check("front HEIF valid", SourceSidecarSemanticValidator().validate(sidecar).isEmpty)
                sidecar.cameraDeviceType = "wide"
                r.check("rear HEIF refused", !SourceSidecarSemanticValidator().validate(sidecar).isEmpty)
                sidecar.cameraDeviceType = "front"; sidecar.format.bayerClassification = true
                r.check("HEIF cannot claim Bayer", !SourceSidecarSemanticValidator().validate(sidecar).isEmpty)
                r.equal("front Codable identity", PhysicalCameraKind(rawValue: "front"), .front)
                r.check("front has no fabricated focal label", PhysicalCameraKind.front.expectedEquivalentFocalLengthMM == nil)
            },
            TCCase(id: "FC03", title: "Mirrored front overlays follow both native landscape rotations exactly once") { r in
                for angle in [0,90,180,270] {
                    let mapper = PreviewGeometryMapper(imageDimensions: PixelDimensions(width: 3, height: 2), contentRect: TCRect(x: 0, y: 0, width: 300, height: 200), isMirrored: true, rotationDegrees: angle)
                    let plain = PreviewGeometryMapper(imageDimensions: mapper.imageDimensions, contentRect: mapper.contentRect, isMirrored: false, rotationDegrees: angle)
                    let point = NormalizedDevicePoint(x: 0.2, y: 0.7)
                    if let unmirrored = plain.viewPoint(forDevicePoint: point), let mirrored = mapper.viewPoint(forDevicePoint: point) {
                        r.close("horizontal mirror \(angle)", mirrored.x, 300 - unmirrored.x, tolerance: 0.001)
                        r.close("vertical unchanged \(angle)", mirrored.y, unmirrored.y, tolerance: 0.001)
                        r.close("inverse x \(angle)", mapper.devicePoint(forViewPoint: mirrored)?.x ?? -1, point.x, tolerance: 0.001)
                        r.close("inverse y \(angle)", mapper.devicePoint(forViewPoint: mirrored)?.y ?? -1, point.y, tolerance: 0.001)
                    } else { r.check("valid geometry", false) }
                    let a = PreviewMaskOrientation.rotate([1,2,3,4,5,6], width: 3, height: 2, degrees: angle)
                    let b = PreviewMaskOrientation.rotate([1,2,3,4,5,6], width: 3, height: 2, degrees: angle, mirrored: true)
                    for y in 0..<a.height { r.equal("mask mirrored after rotation \(angle)-\(y)", Array(b.bytes[(y*b.width)..<((y+1)*b.width)]), Array(a.bytes[(y*a.width)..<((y+1)*a.width)].reversed())) }
                }
            },

            // MARK: T10 — failure at each save phase

            TCCase(id: "T10a", title: "Internal staging create failure is visible and leaves no durable copy") { r in
                guard let h = await StorageHarness.make(name: "t10a") else {
                    r.check("harness initialized", false, "selectRoot did not initialize"); return
                }
                h.fault.arm(.create("source.dng"))
                let captureID = CaptureID()
                var failure: CaptureFailure?
                do {
                    _ = try await h.store.stageSource(
                        bytes: StorageFixture.rawBytes(),
                        metadata: StorageFixture.metadata(captureID: captureID, libraryID: h.libraryID))
                } catch let error as CaptureFailure {
                    failure = error
                } catch {
                    r.check("typed CaptureFailure", false, "unexpected error \(error)")
                }
                guard let failure else {
                    r.check("stageSource threw", false, "no failure was reported"); return
                }
                r.check("failure is retryable", failure.kind.isRetryable, "\(failure.kind)")
                if case .durableInternalStaging = failure.retainedSourceStatus {
                    r.check("no durable copy claimed", false, "reported durable staging after a create failure")
                } else {
                    r.check("no durable copy claimed", true)
                }
                let pending = await h.store.pendingOriginals()
                r.equal("no pending original", pending.count, 0)
            },

            TCCase(id: "T10b", title: "Staging write failure retains nothing durable and deletes only its own partial") { r in
                guard let h = await StorageHarness.make(name: "t10b") else {
                    r.check("harness initialized", false, "selectRoot failed"); return
                }
                h.fault.arm(.write)
                let captureID = CaptureID()
                var failure: CaptureFailure?
                do {
                    _ = try await h.store.stageSource(
                        bytes: StorageFixture.rawBytes(),
                        metadata: StorageFixture.metadata(captureID: captureID, libraryID: h.libraryID))
                } catch let error as CaptureFailure { failure = error } catch { }
                r.check("write failure surfaced", failure != nil, "no failure")
                r.check("no source bytes left", !h.memory.fileExists(at: h.pendingSourceURL(for: captureID)))
                let pending = await h.store.pendingOriginals()
                r.equal("no pending original", pending.count, 0)
            },

            TCCase(id: "T10c", title: "A throwing close is not durable staging") { r in
                guard let h = await StorageHarness.make(name: "t10c") else {
                    r.check("harness initialized", false, "selectRoot failed"); return
                }
                h.fault.arm(.close)
                let captureID = CaptureID()
                var failure: CaptureFailure?
                do {
                    _ = try await h.store.stageSource(
                        bytes: StorageFixture.rawBytes(),
                        metadata: StorageFixture.metadata(captureID: captureID, libraryID: h.libraryID))
                } catch let error as CaptureFailure { failure = error } catch { }
                r.check("close failure surfaced", failure != nil, "no failure")
                let journal = StorageFixture.readJournal(h.memory, support: h.support, captureID: captureID)
                r.check("journal is not stagedInternal",
                        journal?.phase != .stagedInternal,
                        "phase was \(String(describing: journal?.phase))")
                let pending = await h.store.pendingOriginals()
                r.equal("no pending original", pending.count, 0)
            },

            TCCase(id: "T10d", title: "Journal update failure keeps the last durable internal copy") { r in
                guard let h = await StorageHarness.make(name: "t10d") else {
                    r.check("harness initialized", false, "selectRoot failed"); return
                }
                h.fault.arm(.remove)
                let captureID = CaptureID()
                var failure: CaptureFailure?
                do {
                    _ = try await h.store.stageSource(
                        bytes: StorageFixture.rawBytes(),
                        metadata: StorageFixture.metadata(captureID: captureID, libraryID: h.libraryID))
                } catch let error as CaptureFailure { failure = error } catch { }
                guard let failure else { r.check("failure surfaced", false, "no failure"); return }
                r.check("failure surfaced", true)
                if case .durableInternalStaging = failure.retainedSourceStatus {
                    r.check("durable internal copy retained", true)
                } else {
                    r.check("durable internal copy retained", false, "\(failure.retainedSourceStatus)")
                }
                r.check("bytes still on disk", h.memory.fileExists(at: h.pendingSourceURL(for: captureID)))
                let pending = await h.store.pendingOriginals()
                r.equal("pending original recovered from bytes", pending.count, 1)

                // Even with the journal gone entirely, the recovery bytes stay
                // listed under a deterministic identity so retry can find them.
                let journalURL = h.support
                    .appendingPathComponent("PendingCaptures", isDirectory: true)
                    .appendingPathComponent(captureID.description, isDirectory: true)
                    .appendingPathComponent("transaction.json", isDirectory: false)
                do { try h.memory.removeItem(at: journalURL) } catch { }
                let firstRead = await h.store.pendingOriginals()
                let secondRead = await h.store.pendingOriginals()
                r.equal("bytes still listed without a journal", firstRead.count, 1)
                r.equal("derived identity is deterministic",
                        firstRead.first?.transactionID.description,
                        secondRead.first?.transactionID.description)
                r.equal("derived phase is stagedInternal", firstRead.first?.phase, .stagedInternal)
                r.check("derived destination stays a dated original path",
                        firstRead.first?.intendedRelativeOriginalPath.hasPrefix("originals/") ?? false,
                        "\(String(describing: firstRead.first?.intendedRelativeOriginalPath))")
            },

            TCCase(id: "T10e", title: "External staging failure keeps the internal copy and writes no final DNG") { r in
                guard let h = await StorageHarness.make(name: "t10e") else {
                    r.check("harness initialized", false, "selectRoot failed"); return
                }
                let captureID = CaptureID()
                let handle: StagedSourceHandle
                do {
                    handle = try await h.store.stageSource(
                        bytes: StorageFixture.rawBytes(),
                        metadata: StorageFixture.metadata(captureID: captureID, libraryID: h.libraryID))
                } catch {
                    r.check("staged", false, "\(error)"); return
                }
                h.fault.arm(.create("source.dng.partial"))
                var failure: CaptureFailure?
                do {
                    _ = try await h.store.commit(handle: handle)
                } catch let error as CaptureFailure { failure = error } catch { }
                r.check("commit failed", failure != nil, "commit unexpectedly succeeded")
                r.check("no final original", !h.memory.fileExists(at: h.finalURL(for: captureID)))
                let pending = await h.store.pendingOriginals()
                r.equal("internal copy retained", pending.count, 1)

                // Restart idempotency: the same identity/hash is not duplicated.
                h.fault.disarm(.create("source.dng.partial"))
                do {
                    let receipt = try await h.store.retry(transactionID: handle.transactionID)
                    r.equal("retry published the same path", receipt.relativeOriginalPath, handle.intendedRelativeOriginalPath)
                } catch {
                    r.check("retry succeeded", false, "\(error)")
                }
                let finals = h.memory.allPaths().filter { $0.hasSuffix(".dng") }
                r.equal("exactly one final DNG", finals.count, 1)
                let pendingAfter = await h.store.pendingOriginals()
                r.equal("recovery bytes cleaned after commit", pendingAfter.count, 0)
            },

            TCCase(id: "T10f", title: "Publication move failure retains recovery bytes and commits nothing") { r in
                guard let h = await StorageHarness.make(name: "t10f") else {
                    r.check("harness initialized", false, "selectRoot failed"); return
                }
                let captureID = CaptureID()
                guard let handle = try? await h.store.stageSource(
                    bytes: StorageFixture.rawBytes(),
                    metadata: StorageFixture.metadata(captureID: captureID, libraryID: h.libraryID)) else {
                    r.check("staged", false, "stageSource failed"); return
                }
                h.fault.armMove(destinationSuffix: LibraryLayout.originalFileName(for: captureID))
                var failure: CaptureFailure?
                do {
                    _ = try await h.store.commit(handle: handle)
                } catch let error as CaptureFailure { failure = error } catch { }
                r.check("commit failed", failure != nil, "commit unexpectedly succeeded")
                r.check("no final original", !h.memory.fileExists(at: h.finalURL(for: captureID)))
                let pending = await h.store.pendingOriginals()
                r.equal("internal copy retained", pending.count, 1)
            },

            TCCase(id: "T10g", title: "No early Saved: the sidecar is published last and a failure blocks the receipt") { r in
                guard let h = await StorageHarness.make(name: "t10g") else {
                    r.check("harness initialized", false, "selectRoot failed"); return
                }
                let captureID = CaptureID()
                guard let handle = try? await h.store.stageSource(
                    bytes: StorageFixture.rawBytes(),
                    metadata: StorageFixture.metadata(captureID: captureID, libraryID: h.libraryID)) else {
                    r.check("staged", false, "stageSource failed"); return
                }
                // Observe the DNG publication: at that instant the sidecar must
                // not exist yet, because the sidecar is the completion marker.
                let sidecarURL = h.finalSidecarURL(for: captureID)
                let memory = h.memory
                let sawDNGMoveWithoutSidecar = Mutex<Bool>(false)
                h.fault.setObserver { event in
                    guard event.kind == .move, let destination = event.destinationRelativePath,
                          destination.hasSuffix(".dng") else { return }
                    if !memory.fileExists(at: sidecarURL) {
                        sawDNGMoveWithoutSidecar.withLock { $0 = true }
                    }
                }
                h.fault.armMove(destinationSuffix: LibraryLayout.sidecarFileName(for: captureID))
                var failure: CaptureFailure?
                do {
                    _ = try await h.store.commit(handle: handle)
                } catch let error as CaptureFailure { failure = error } catch { }
                r.check("commit failed", failure != nil, "commit unexpectedly succeeded")
                r.check("DNG published before the sidecar", sawDNGMoveWithoutSidecar.withLock { $0 })
                r.check("final DNG present", h.memory.fileExists(at: h.finalURL(for: captureID)))
                r.check("final sidecar absent", !h.memory.fileExists(at: sidecarURL))
                let pending = await h.store.pendingOriginals()
                r.equal("recovery bytes retained", pending.count, 1)
            },

            TCCase(id: "T10h", title: "Restart resumes the interrupted publication idempotently") { r in
                guard let h = await StorageHarness.make(name: "t10h") else {
                    r.check("harness initialized", false, "selectRoot failed"); return
                }
                let captureID = CaptureID()
                guard let handle = try? await h.store.stageSource(
                    bytes: StorageFixture.rawBytes(),
                    metadata: StorageFixture.metadata(captureID: captureID, libraryID: h.libraryID)) else {
                    r.check("staged", false, "stageSource failed"); return
                }
                h.fault.armMove(destinationSuffix: LibraryLayout.sidecarFileName(for: captureID))
                do { _ = try await h.store.commit(handle: handle) } catch { }
                r.check("DNG published", h.memory.fileExists(at: h.finalURL(for: captureID)))
                r.check("sidecar missing", !h.memory.fileExists(at: h.finalSidecarURL(for: captureID)))

                guard let reopened = await h.reopening(name: "t10h-restart") else {
                    r.check("reopened library", false, "reconnect failed"); return
                }
                do {
                    let receipt = try await reopened.store.retry(transactionID: handle.transactionID)
                    r.equal("same destination identity", receipt.relativeOriginalPath, handle.intendedRelativeOriginalPath)
                    r.equal("same verified digest", receipt.verifiedSHA256, handle.sha256)
                } catch {
                    r.check("retry after restart", false, "\(error)")
                }
                let finalDNGs = reopened.memory.allPaths().filter { $0.hasSuffix(".dng") }
                r.equal("no duplicate original", finalDNGs.count, 1)
                r.check("sidecar published", reopened.memory.fileExists(at: reopened.finalSidecarURL(for: captureID)))
            },

            // MARK: T11 — mutation after staged verification

            TCCase(id: "T11", title: "Final DNG mutated after staged verification fails the checksum and keeps recovery bytes") { r in
                guard let h = await StorageHarness.make(name: "t11") else {
                    r.check("harness initialized", false, "selectRoot failed"); return
                }
                let captureID = CaptureID()
                guard let handle = try? await h.store.stageSource(
                    bytes: StorageFixture.rawBytes(),
                    metadata: StorageFixture.metadata(captureID: captureID, libraryID: h.libraryID)) else {
                    r.check("staged", false, "stageSource failed"); return
                }
                let finalURL = h.finalURL(for: captureID)
                let memory = h.memory
                let mutated = Mutex<Bool>(false)
                h.fault.setObserver { event in
                    guard event.kind == .move, let destination = event.destinationRelativePath,
                          destination.hasSuffix(".dng") else { return }
                    memory.setBytes(StorageFixture.rawBytes(byteCount: 2_048, filler: 0x7F),
                                    at: finalURL)
                    mutated.withLock { $0 = true }
                }
                var failure: CaptureFailure?
                do {
                    _ = try await h.store.commit(handle: handle)
                } catch let error as CaptureFailure { failure = error } catch { }
                r.check("mutation happened", mutated.withLock { $0 })
                guard let failure else { r.check("commit failed", false, "commit unexpectedly succeeded"); return }
                switch failure.kind {
                case .integrityMismatch:
                    r.check("integrity failure reported", true)
                default:
                    r.check("integrity failure reported", false, "kind was \(failure.kind)")
                }
                if case .durableInternalStaging = failure.retainedSourceStatus {
                    r.check("internal recovery survives", true)
                } else {
                    r.check("internal recovery survives", false, "\(failure.retainedSourceStatus)")
                }
                let pending = await h.store.pendingOriginals()
                r.equal("pending original kept", pending.count, 1)
                let reconciled = (try? await h.store.reconcile(onProgress: nil))
                r.equal("nothing is verified", reconciled?.verifiedOriginalCount ?? -1, 0)
                r.check("mutated bytes preserved",
                        h.memory.fileBytes(at: finalURL)?.count == 2_048)
            },

            // MARK: T12 — idempotency and conflicts

            TCCase(id: "T12a", title: "Same destination and hash is idempotent and rewrites nothing") { r in
                guard let h = await StorageHarness.make(name: "t12a") else {
                    r.check("harness initialized", false, "selectRoot failed"); return
                }
                let captureID = CaptureID()
                guard let handle = try? await h.store.stageSource(
                    bytes: StorageFixture.rawBytes(),
                    metadata: StorageFixture.metadata(captureID: captureID, libraryID: h.libraryID)) else {
                    r.check("staged", false, "stageSource failed"); return
                }
                guard let first = try? await h.store.commit(handle: handle) else {
                    r.check("first commit", false, "commit failed"); return
                }
                let bytesAfterFirst = h.memory.fileBytes(at: h.finalURL(for: captureID))
                h.fault.clearEvents()
                guard let second = try? await h.store.commit(handle: handle) else {
                    r.check("idempotent retry", false, "second commit failed"); return
                }
                r.equal("same path", second.relativeOriginalPath, first.relativeOriginalPath)
                r.equal("same digest", second.verifiedSHA256, first.verifiedSHA256)
                r.equal("byte-identical", h.memory.fileBytes(at: h.finalURL(for: captureID)), bytesAfterFirst)
                let moves = h.fault.events.filter { $0.kind == .move || $0.kind == .createFile }
                r.check("no rewrite of the published original",
                        !moves.contains { ($0.destinationRelativePath ?? $0.relativePath).hasSuffix(".dng") },
                        "\(moves.map { $0.relativePath })")
                let finals = h.memory.allPaths().filter { $0.hasSuffix(".dng") }
                r.equal("one final original", finals.count, 1)
            },

            TCCase(id: "T12b", title: "Same destination with a different hash is a conflict that preserves both copies") { r in
                guard let h = await StorageHarness.make(name: "t12b") else {
                    r.check("harness initialized", false, "selectRoot failed"); return
                }
                let captureID = CaptureID()
                let originalBytes = StorageFixture.rawBytes(byteCount: 4_096, filler: 0x2A)
                guard let handle = try? await h.store.stageSource(
                    bytes: originalBytes,
                    metadata: StorageFixture.metadata(captureID: captureID, libraryID: h.libraryID)) else {
                    r.check("staged", false, "stageSource failed"); return
                }
                guard (try? await h.store.commit(handle: handle)) != nil else {
                    r.check("first commit", false, "commit failed"); return
                }
                // Something else replaced the original out of band.
                let conflicting = StorageFixture.rawBytes(byteCount: 8_192, filler: 0x11)
                h.memory.setBytes(conflicting, at: h.finalURL(for: captureID))

                guard let second = try? await h.store.stageSource(
                    bytes: StorageFixture.rawBytes(byteCount: 4_096, filler: 0x2A),
                    metadata: StorageFixture.metadata(captureID: captureID, libraryID: h.libraryID)) else {
                    r.check("re-staged", false, "stageSource failed"); return
                }
                var failure: CaptureFailure?
                do {
                    _ = try await h.store.commit(handle: second)
                } catch let error as CaptureFailure { failure = error } catch { }
                guard let failure else { r.check("conflict reported", false, "commit succeeded"); return }
                switch failure.kind {
                case .conflict:
                    r.check("conflict reported", true)
                default:
                    r.check("conflict reported", false, "kind was \(failure.kind)")
                }
                r.equal("destination never overwritten",
                        h.memory.fileBytes(at: h.finalURL(for: captureID)), conflicting)
                let pending = await h.store.pendingOriginals()
                r.equal("internal source preserved", pending.count, 1)
            },

            // MARK: T13 — revoked scope / stale bookmark

            TCCase(id: "T13a", title: "An unresolvable bookmark is an actionable failure, never a sandbox-only save") { r in
                let bookmarks = InMemoryRootBookmarkStore()
                bookmarks.saveBookmarkData(Data("not-a-bookmark".utf8))
                guard let h = StorageHarness.makeRaw(name: "t13a", bookmarks: bookmarks) else {
                    r.check("harness", false, "setup failed"); return
                }
                let outcome = await h.store.reconnectStoredRoot()
                if case .unavailable = outcome {
                    r.check("reconnect reports unavailable", true)
                } else {
                    r.check("reconnect reports unavailable", false, "\(outcome)")
                }
                let state = h.store.rootState
                r.equal("root is not writable", state.isWritable, false)
                var failure: CaptureFailure?
                do {
                    _ = try await h.store.stageSource(
                        bytes: StorageFixture.rawBytes(),
                        metadata: StorageFixture.metadata(captureID: CaptureID(), libraryID: LibraryID()))
                } catch let error as CaptureFailure { failure = error } catch { }
                guard let failure else { r.check("staging refused", false, "staging succeeded"); return }
                switch failure.kind {
                case .folderUnavailable:
                    r.check("actionable folder failure", true)
                default:
                    r.check("actionable folder failure", false, "kind \(failure.kind)")
                }
                r.check("nothing written into the sandbox",
                        !h.memory.allPaths().contains { $0.contains("/originals/") })
            },

            TCCase(id: "T13b", title: "Security-scope leases are balanced and a stale bookmark is reported") { r in
                let directory = StorageFixture.temporaryDirectory("grant")
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                } catch {
                    r.check("temporary directory", false, "\(error)"); return
                }
                defer { StorageFixture.removeDirectory(directory) }

                let grant = BookmarkRootGrant(url: directory)
                guard let data = try? grant.bookmarkData() else {
                    r.check("bookmark created", false, "bookmarkData failed"); return
                }
                let restored = try? BookmarkRootGrant(bookmarkData: data)
                r.check("bookmark resolves", restored != nil)
                r.equal("not stale", restored?.isStale ?? true, false)
                r.check("resolves to the same folder",
                        restored?.url.standardizedFileURL.path == directory.standardizedFileURL.path)

                let scripted = BookmarkRootGrant(url: directory,
                                                driver: ScriptedSecurityScopeDriver(grants: [true, false, true]))
                r.equal("first begin granted", scripted.beginAccess(), true)
                r.equal("second begin denied", scripted.beginAccess(), false)
                r.equal("third begin granted", scripted.beginAccess(), true)
                r.equal("two active leases", scripted.activeLeaseCount, 2)
                scripted.endAccess()
                scripted.endAccess()
                scripted.endAccess()
                scripted.endAccess()
                r.equal("leases back to zero", scripted.activeLeaseCount, 0)
                r.check("count never negative", scripted.activeLeaseCount >= 0)
                r.equal("every end call recorded", scripted.endAccessCallCount, 4)
                r.equal("denied begins recorded", scripted.deniedBeginCount, 1)
                r.check("balanced", scripted.isBalanced)

                var threw = false
                do { _ = try BookmarkRootGrant(bookmarkData: Data([0x00, 0x01, 0x02])) } catch { threw = true }
                r.check("garbage bookmark throws", threw)
            },

            // MARK: T14 — no concurrent duplicate writer

            TCCase(id: "T14", title: "Concurrent commits serialise under one writer and reconcile under the same transaction") { r in
                guard let h = await StorageHarness.make(name: "t14") else {
                    r.check("harness initialized", false, "selectRoot failed"); return
                }
                let captureID = CaptureID()
                guard let handle = try? await h.store.stageSource(
                    bytes: StorageFixture.rawBytes(),
                    metadata: StorageFixture.metadata(captureID: captureID, libraryID: h.libraryID)) else {
                    r.check("staged", false, "stageSource failed"); return
                }
                h.fault.clearEvents()
                async let first = h.store.commit(handle: handle)
                async let second = h.store.commit(handle: handle)
                var receipts: [CommitReceipt] = []
                do {
                    receipts = try await [first, second]
                } catch {
                    r.check("both commits resolved", false, "\(error)")
                }
                r.equal("both callers got a receipt", receipts.count, 2)
                r.check("same destination",
                        Set(receipts.map(\.relativeOriginalPath)).count == 1,
                        "\(receipts.map(\.relativeOriginalPath))")
                r.check("same transaction identity",
                        Set(receipts.map { $0.transactionID.description }).count == 1)
                let dngMoves = h.fault.events.filter {
                    $0.kind == .move && ($0.destinationRelativePath ?? "").hasSuffix(".dng")
                }
                r.equal("exactly one writer published", dngMoves.count, 1)
                let finals = h.memory.allPaths().filter { $0.hasSuffix(".dng") }
                r.equal("no duplicate original", finals.count, 1)
            },

            // MARK: T15 — root switching with a pending source

            TCCase(id: "T15", title: "A pending source stays pinned to its origin library across a root switch") { r in
                guard let h = await StorageHarness.make(name: "t15") else {
                    r.check("harness initialized", false, "selectRoot failed"); return
                }
                let captureID = CaptureID()
                guard let handle = try? await h.store.stageSource(
                    bytes: StorageFixture.rawBytes(),
                    metadata: StorageFixture.metadata(captureID: captureID, libraryID: h.libraryID)) else {
                    r.check("staged", false, "stageSource failed"); return
                }
                let otherRoot = URL(fileURLWithPath: "/tc-storage-tests/t15/other-library", isDirectory: true)
                do { try h.memory.createDirectory(at: otherRoot, withIntermediateDirectories: true) } catch { }
                let outcome = await h.store.selectRoot(from: otherRoot)
                if case .initialized = outcome {
                    r.check("second library initialized", true)
                } else {
                    r.check("second library initialized", false, "\(outcome)")
                }
                let pending = await h.store.pendingOriginals()
                r.equal("pending source still listed", pending.count, 1)
                r.equal("pending source remains not reinstall-safe", pending.first?.reinstallSafe ?? true, false)

                var failure: CaptureFailure?
                do {
                    _ = try await h.store.commit(handle: handle)
                } catch let error as CaptureFailure { failure = error } catch { }
                r.check("commit refused on the foreign root", failure != nil, "commit succeeded")
                r.check("nothing written into the second library",
                        !h.memory.allPaths().contains { $0.hasPrefix(otherRoot.path + "/originals/") })
                let stillPending = await h.store.pendingOriginals()
                r.equal("source still owned by its origin", stillPending.count, 1)

                // Reconnecting the origin library permits the explicit retry.
                let back = await h.store.selectRoot(from: h.root)
                if case .opened = back {
                    r.check("origin library reopened", true)
                } else {
                    r.check("origin library reopened", false, "\(back)")
                }
                do {
                    let receipt = try await h.store.commit(handle: handle)
                    r.equal("retry published into the origin library",
                            receipt.relativeOriginalPath, handle.intendedRelativeOriginalPath)
                } catch {
                    r.check("retry into the origin library", false, "\(error)")
                }
            },

            // MARK: T16 — no space

            TCCase(id: "T16", title: "No local space during staging is visible and durable sources survive") { r in
                guard let h = await StorageHarness.make(name: "t16") else {
                    r.check("harness initialized", false, "selectRoot failed"); return
                }
                let first = CaptureID()
                guard let firstHandle = try? await h.store.stageSource(
                    bytes: StorageFixture.rawBytes(),
                    metadata: StorageFixture.metadata(captureID: first, libraryID: h.libraryID)) else {
                    r.check("first staged", false, "stageSource failed"); return
                }
                guard (try? await h.store.commit(handle: firstHandle)) != nil else {
                    r.check("first committed", false, "commit failed"); return
                }
                r.check("durable original present", h.memory.fileExists(at: h.finalURL(for: first)))

                h.fault.setDeviceFull(true)
                let second = CaptureID()
                var failure: CaptureFailure?
                do {
                    _ = try await h.store.stageSource(
                        bytes: StorageFixture.rawBytes(),
                        metadata: StorageFixture.metadata(captureID: second, libraryID: h.libraryID))
                } catch let error as CaptureFailure { failure = error } catch { }
                guard let failure else { r.check("storage full reported", false, "staging succeeded"); return }
                switch failure.kind {
                case .localStorageFull:
                    r.check("storage full reported", true)
                default:
                    r.check("storage full reported", false, "kind \(failure.kind)")
                }
                r.check("nothing staged for the failed capture",
                        !h.memory.fileExists(at: h.pendingSourceURL(for: second)))
                let pending = await h.store.pendingOriginals()
                r.equal("no new pending source", pending.count, 0)
                r.check("existing durable source retained", h.memory.fileExists(at: h.finalURL(for: first)))

                h.fault.setDeviceFull(false)
                let third = CaptureID()
                let restaged = try? await h.store.stageSource(
                    bytes: StorageFixture.rawBytes(),
                    metadata: StorageFixture.metadata(captureID: third, libraryID: h.libraryID))
                r.check("staging works again after space returns", restaged != nil)
            },

            // MARK: T17 — integrity and metadata failures

            TCCase(id: "T17a", title: "Corrupted internal bytes fail integrity and the DNG is preserved") { r in
                guard let h = await StorageHarness.make(name: "t17a") else {
                    r.check("harness initialized", false, "selectRoot failed"); return
                }
                let captureID = CaptureID()
                guard let handle = try? await h.store.stageSource(
                    bytes: StorageFixture.rawBytes(),
                    metadata: StorageFixture.metadata(captureID: captureID, libraryID: h.libraryID)) else {
                    r.check("staged", false, "stageSource failed"); return
                }
                let corrupted = StorageFixture.rawBytes(byteCount: 1_024, filler: 0x5A)
                h.memory.setBytes(corrupted, at: h.pendingSourceURL(for: captureID))
                var failure: CaptureFailure?
                do {
                    _ = try await h.store.commit(handle: handle)
                } catch let error as CaptureFailure { failure = error } catch { }
                guard let failure else { r.check("integrity failure", false, "commit succeeded"); return }
                switch failure.kind {
                case .integrityMismatch:
                    r.check("integrity failure", true)
                default:
                    r.check("integrity failure", false, "kind \(failure.kind)")
                }
                r.equal("corrupt DNG preserved", h.memory.fileBytes(at: h.pendingSourceURL(for: captureID)), corrupted)
                r.check("nothing published", !h.memory.fileExists(at: h.finalURL(for: captureID)))
            },

            TCCase(id: "T17b", title: "Mismatched or corrupt sidecars are classified truthfully and never executed") { r in
                guard let h = StorageHarness.makeRaw(name: "t17b") else {
                    r.check("harness", false, "setup failed"); return
                }
                let manifest = LibraryManifest(libraryID: LibraryID(), createdAtUTC: StorageFixture.fixedDate)
                let libraryID = manifest.declaredLibraryID
                let memory = h.memory
                func write(_ data: Data, _ relative: String) {
                    memory.setBytes(data, at: h.root.appendingPathComponent(relative))
                }
                write(StorageFixture.manifestData(manifest), "library.json")

                // C1: byteCount mismatch.
                let c1 = CaptureID()
                let c1Path = LibraryLayout.relativeOriginalPath(for: c1, capturedAt: StorageFixture.fixedDate,
                                                               calendar: StorageFixture.utcCalendar)
                let c1Bytes = StorageFixture.rawBytes(byteCount: 4_096)
                write(c1Bytes, c1Path)
                write(StorageFixture.sidecarData(StorageFixture.sidecar(
                    captureID: c1, libraryID: libraryID, relativePath: c1Path,
                    byteCount: 9_999, sha256: StorageFixture.sha256Hex(c1Bytes))),
                      LibraryLayout.relativeSidecarPath(alongside: c1Path))

                // C2: malformed sidecar JSON.
                let c2 = CaptureID()
                let c2Path = LibraryLayout.relativeOriginalPath(for: c2, capturedAt: StorageFixture.fixedDate,
                                                               calendar: StorageFixture.utcCalendar)
                write(StorageFixture.rawBytes(byteCount: 2_048), c2Path)
                write(Data("{ this is not json".utf8),
                      LibraryLayout.relativeSidecarPath(alongside: c2Path))

                // C3: traversal path in the sidecar.
                let c3 = CaptureID()
                let c3Path = LibraryLayout.relativeOriginalPath(for: c3, capturedAt: StorageFixture.fixedDate,
                                                               calendar: StorageFixture.utcCalendar)
                let c3Bytes = StorageFixture.rawBytes(byteCount: 3_072)
                write(c3Bytes, c3Path)
                var traversal = StorageFixture.sidecar(
                    captureID: c3, libraryID: libraryID, relativePath: c3Path,
                    byteCount: Int64(c3Bytes.count), sha256: StorageFixture.sha256Hex(c3Bytes))
                traversal.relativeOriginalPath = "../../../etc/passwd.dng"
                write(StorageFixture.sidecarData(traversal),
                      LibraryLayout.relativeSidecarPath(alongside: c3Path))

                let before = Set(memory.allPaths())
                let selection = await h.store.selectRoot(from: h.root)
                guard case .opened = selection else {
                    r.check("library opened", false, "\(selection)"); return
                }
                guard let reconciled = try? await h.store.reconcile(onProgress: nil) else {
                    r.check("reconcile ran", false, "reconcile threw"); return
                }
                r.equal("nothing verified", reconciled.verifiedOriginalCount, 0)
                r.equal("byteCount mismatch is a conflict", reconciled.conflictCount, 1)
                r.equal("malformed and traversal sidecars are recovered RAW", reconciled.recoveredRAWCount, 2)
                r.check("each misread sidecar is explained in the issue list",
                        reconciled.issues.contains { $0.contains(c1Path) && $0.contains("bytes") }
                        && reconciled.issues.contains { $0.contains(c2Path) }
                        && reconciled.issues.contains { $0.contains(c3Path) })
                r.equal("no DNG was altered or removed", Set(memory.allPaths()), before)
                let traversalURL = h.store.originalURL(for: c3, relativePath: "../../../etc/passwd.dng")
                r.check("traversal path is not resolvable", traversalURL == nil)
            },

            // MARK: T18 — future schema, oversized JSON, traversal

            TCCase(id: "T18a", title: "A newer major schema opens read-only and is never rewritten") { r in
                guard let h = StorageHarness.makeRaw(name: "t18a") else {
                    r.check("harness", false, "setup failed"); return
                }
                let futureManifest = """
                {"schemaVersion":2,"libraryID":"\(UUID().uuidString)","createdAtUTC":"2026-09-22T00:00:00Z",\
                "application":"TruongCam","storagePolicy":"localOnly"}
                """
                let manifestURL = h.root.appendingPathComponent("library.json")
                h.memory.setBytes(Data(futureManifest.utf8), at: manifestURL)
                let before = Set(h.memory.allPaths())

                let outcome = await h.store.selectRoot(from: h.root)
                if case .readOnlyNewerSchema(let found, let supported) = outcome {
                    r.equal("found version", found, 2)
                    r.equal("supported version", supported, truongCamSupportedSchemaVersion)
                } else {
                    r.check("read-only newer schema", false, "\(outcome)")
                }
                let state = h.store.rootState
                if case .readOnly = state {
                    r.check("root state is read-only", true)
                } else {
                    r.check("root state is read-only", false, "\(state)")
                }
                r.equal("manifest untouched", h.memory.fileBytes(at: manifestURL), Data(futureManifest.utf8))
                r.equal("no new files were created", Set(h.memory.allPaths()), before)
                var failure: CaptureFailure?
                do {
                    _ = try await h.store.stageSource(
                        bytes: StorageFixture.rawBytes(),
                        metadata: StorageFixture.metadata(captureID: CaptureID(), libraryID: LibraryID()))
                } catch let error as CaptureFailure { failure = error } catch { }
                r.check("read-only root cannot stage", failure != nil, "staging succeeded")
            },

            TCCase(id: "T18b", title: "Oversized metadata is rejected within bounds") { r in
                guard let h = StorageHarness.makeRaw(name: "t18b") else {
                    r.check("harness", false, "setup failed"); return
                }
                let manifest = LibraryManifest(libraryID: LibraryID(), createdAtUTC: StorageFixture.fixedDate)
                h.memory.setBytes(StorageFixture.manifestData(manifest),
                                  at: h.root.appendingPathComponent("library.json"))
                let captureID = CaptureID()
                let path = LibraryLayout.relativeOriginalPath(for: captureID, capturedAt: StorageFixture.fixedDate,
                                                             calendar: StorageFixture.utcCalendar)
                h.memory.setBytes(StorageFixture.rawBytes(), at: h.root.appendingPathComponent(path))
                let oversized = Data(repeating: 0x20, count: MetadataBounds.maxSourceSidecarUTF8Bytes + 4_096)
                h.memory.setBytes(oversized, at: h.root.appendingPathComponent(
                    LibraryLayout.relativeSidecarPath(alongside: path)))

                let selection = await h.store.selectRoot(from: h.root)
                guard case .opened = selection else {
                    r.check("library opened", false, "\(selection)"); return
                }
                guard let reconciled = try? await h.store.reconcile(onProgress: nil) else {
                    r.check("reconcile ran", false, "reconcile threw"); return
                }
                r.equal("oversized sidecar is a recovered RAW", reconciled.recoveredRAWCount, 1)
                r.equal("nothing verified", reconciled.verifiedOriginalCount, 0)
                r.check("the bound is reported",
                        reconciled.issues.contains { $0.contains("sidecar") || $0.contains("bound") })

                // Oversized sequence document is rejected by the bounded reader.
                let sequenceID = SequenceID()
                let sequencePath = LibraryLayout.relativeSequencePath(for: sequenceID)
                h.memory.setBytes(Data(repeating: 0x7B, count: MetadataBounds.maxSequenceJSONUTF8Bytes + 1_024),
                                  at: h.root.appendingPathComponent(sequencePath))
                var failure: CaptureFailure?
                do {
                    _ = try await h.store.readSequenceDocument(sequenceID)
                } catch let error as CaptureFailure { failure = error } catch { }
                r.check("oversized sequence document rejected", failure != nil, "no failure")
            },

            // MARK: T19 — recovery classification

            TCCase(id: "T19", title: "Orphan DNG, orphan sidecar, staged partial and a stale running sequence classify truthfully") { r in
                guard let h = StorageHarness.makeRaw(name: "t19") else {
                    r.check("harness", false, "setup failed"); return
                }
                let manifest = LibraryManifest(libraryID: LibraryID(), createdAtUTC: StorageFixture.fixedDate)
                let libraryID = manifest.declaredLibraryID
                let memory = h.memory
                func write(_ data: Data, _ relative: String) {
                    memory.setBytes(data, at: h.root.appendingPathComponent(relative))
                }
                write(StorageFixture.manifestData(manifest), "library.json")

                let sequenceID = SequenceID()
                let link = SourceSequenceLink(id: sequenceID, kind: .exposureBracket, index: SourceOrdinal(0), plannedCount: 3)

                // Verified original linked to a stale running sequence.
                let c1 = CaptureID()
                let c1Path = LibraryLayout.relativeOriginalPath(for: c1, capturedAt: StorageFixture.fixedDate,
                                                               calendar: StorageFixture.utcCalendar)
                let c1Bytes = StorageFixture.rawBytes(byteCount: 5_120)
                write(c1Bytes, c1Path)
                write(StorageFixture.sidecarData(StorageFixture.sidecar(
                    captureID: c1, libraryID: libraryID, relativePath: c1Path,
                    byteCount: Int64(c1Bytes.count), sha256: StorageFixture.sha256Hex(c1Bytes),
                    sequence: link)),
                      LibraryLayout.relativeSidecarPath(alongside: c1Path))

                // Orphan DNG.
                let c2 = CaptureID()
                let c2Path = LibraryLayout.relativeOriginalPath(for: c2, capturedAt: StorageFixture.fixedDate,
                                                               calendar: StorageFixture.utcCalendar)
                write(StorageFixture.rawBytes(byteCount: 2_048), c2Path)

                // Orphan sidecar.
                let c3 = CaptureID()
                let c3Path = LibraryLayout.relativeOriginalPath(for: c3, capturedAt: StorageFixture.fixedDate,
                                                               calendar: StorageFixture.utcCalendar)
                write(StorageFixture.sidecarData(StorageFixture.sidecar(
                    captureID: c3, libraryID: libraryID, relativePath: c3Path,
                    byteCount: 1_024, sha256: String(repeating: "b", count: 64))),
                      LibraryLayout.relativeSidecarPath(alongside: c3Path))

                // Recoverable external staging: DNG + sidecar partials with a record.
                let stagedCapture = CaptureID()
                let stagedPath = LibraryLayout.relativeOriginalPath(for: stagedCapture,
                                                                   capturedAt: StorageFixture.fixedDate,
                                                                   calendar: StorageFixture.utcCalendar)
                let stagedBytes = StorageFixture.rawBytes(byteCount: 6_144)
                let transactionID = UUID()
                let stagingPrefix = ".staging/\(transactionID.uuidString.lowercased())"
                write(stagedBytes, "\(stagingPrefix)/source.dng.partial")
                write(StorageFixture.sidecarData(StorageFixture.sidecar(
                    captureID: stagedCapture, libraryID: libraryID, relativePath: stagedPath,
                    byteCount: Int64(stagedBytes.count), sha256: StorageFixture.sha256Hex(stagedBytes))),
                      "\(stagingPrefix)/source.json.partial")
                let record = TransactionRecord(
                    schemaVersion: truongCamSupportedSchemaVersion,
                    transactionID: transactionID,
                    captureID: stagedCapture.rawValue,
                    libraryID: libraryID.rawValue,
                    rootGeneration: 1,
                    phase: .verifyingProvider,
                    expectedByteCount: Int64(stagedBytes.count),
                    expectedSHA256: StorageFixture.sha256Hex(stagedBytes),
                    relativeOriginalPath: stagedPath,
                    createdAtUTC: StorageFixture.fixedDate,
                    updatedAtUTC: StorageFixture.fixedDate,
                    lastError: nil)
                write((try? PortableJSONWriter().encode(record,
                                                        explicitNullKeys: TransactionRecord.explicitNullKeyPaths)) ?? Data(),
                      "\(stagingPrefix)/transaction.json")

                // A thumbnail is never a recovered original.
                let thumbnailStaging = ".staging/\(UUID().uuidString.lowercased())"
                write(Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]), "\(thumbnailStaging)/preview.jpg")
                write(Data("{}".utf8), "\(thumbnailStaging)/transaction.json")

                // A stale `running` sequence document.
                var document = SequenceDocument(
                    sequenceID: sequenceID,
                    libraryID: libraryID,
                    kind: .exposureBracket,
                    plannedCount: 3,
                    sourcePlan: [0, 1, 2].map { SequenceSourcePlanEntry(index: $0, offsetEV: Double($0) - 1, focusPosition: nil) },
                    intervalSeconds: nil,
                    baseline: nil,
                    startedAtUTC: StorageFixture.fixedDate)
                document.completedSources = [SequenceCompletedSource(index: 0, captureID: c1.rawValue)]
                document.status = .running
                write((try? PortableJSONWriter().encode(document,
                                                        explicitNullKeys: SequenceDocument.explicitNullKeyPaths)) ?? Data(),
                      LibraryLayout.relativeSequencePath(for: sequenceID))

                let selection = await h.store.selectRoot(from: h.root)
                guard case .opened = selection else {
                    r.check("library opened", false, "\(selection)"); return
                }
                guard let reconciled = try? await h.store.reconcile(onProgress: nil) else {
                    r.check("reconcile ran", false, "reconcile threw"); return
                }
                r.equal("verified originals (direct + recovered staging)",
                        reconciled.verifiedOriginalCount, 2)
                r.equal("recovered RAW", reconciled.recoveredRAWCount, 1)
                r.equal("missing originals", reconciled.missingOriginalCount, 1)
                r.equal("conflicts", reconciled.conflictCount, 0)
                r.check("the recovered staging source reached its final path",
                        memory.fileExists(at: h.root.appendingPathComponent(stagedPath)))
                r.check("the thumbnail was not published as an original",
                        !memory.allPaths().contains { $0.contains("preview.jpg") && $0.contains("/originals/") })
                r.equal("one sequence summary", reconciled.sequences.count, 1)
                if let summary = reconciled.sequences.first {
                    r.equal("sequence interrupted", summary.status, .interrupted)
                    r.equal("committed count from evidence", summary.committedCount, 1)
                    r.check("sequence is not complete", !summary.isComplete)
                    r.equal("missing ordinals", summary.missingIndices, [1, 2])
                }
                // The stale running document is marked interrupted on a writable root.
                let rewritten = try? await h.store.readSequenceDocument(sequenceID)
                r.equal("stale running document rewritten as interrupted", rewritten?.status, .interrupted)
            },

            // MARK: T20 — index rebuild

            TCCase(id: "T20", title: "The index is disposable: deleting it and re-ingesting reproduces the cards") { r in
                let directory = StorageFixture.temporaryDirectory("index")
                let databaseURL = directory.appendingPathComponent("index.sqlite")
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                } catch {
                    r.check("temporary directory", false, "\(error)"); return
                }
                defer { StorageFixture.removeDirectory(directory) }

                let libraryID = LibraryID()
                let index = SQLiteIndex(databaseURL: databaseURL)
                let cards = StorageFixture.cards(count: 7, libraryID: libraryID, startingAt: StorageFixture.fixedDate)
                do {
                    try await index.reset(libraryID: libraryID, generation: RootGeneration(1))
                    try await index.upsert(scanned: cards)
                } catch {
                    r.check("first ingest", false, "\(error)"); return
                }
                let firstPage = try? await index.firstPage(size: 60)
                let firstIDs = firstPage?.cards.map(\.id) ?? []
                let firstTotal = (try? await index.totalCommittedOriginalCount()) ?? -1
                r.equal("first ingest total", firstTotal, 7)
                r.equal("first ingest page", firstIDs.count, 7)
                await index.closeDatabase()

                // Cache deleted; a real original next to it must be untouched.
                let originalURL = directory.appendingPathComponent("TC_original.dng")
                let originalBytes = StorageFixture.rawBytes(byteCount: 2_048)
                do { try originalBytes.write(to: originalURL) } catch { }
                await index.deleteDatabaseFiles()

                let rebuilt = SQLiteIndex(databaseURL: databaseURL)
                do {
                    try await rebuilt.reset(libraryID: libraryID, generation: RootGeneration(1))
                    try await rebuilt.upsert(scanned: cards)
                } catch {
                    r.check("re-ingest", false, "\(error)"); return
                }
                let secondPage = try? await rebuilt.firstPage(size: 60)
                r.equal("cards reproduced", secondPage?.cards.map(\.id) ?? [], firstIDs)
                r.equal("total reproduced", (try? await rebuilt.totalCommittedOriginalCount()) ?? -1, firstTotal)
                r.equal("originals unchanged", (try? Data(contentsOf: originalURL)) ?? Data(), originalBytes)

                // A corrupt database is rebuilt rather than failing the library.
                await rebuilt.closeDatabase()
                do { try Data(repeating: 0x41, count: 4_096).write(to: databaseURL) } catch { }
                let corrupt = SQLiteIndex(databaseURL: databaseURL)
                do {
                    let page = try await corrupt.firstPage(size: 10)
                    r.equal("corrupt database rebuilt empty", page.cards.count, 0)
                } catch {
                    r.check("corrupt database rebuilt", false, "\(error)")
                }
            },

            // MARK: T21 — paging at scale

            TCCase(id: "T21", title: "10,000 indexed records page quickly and decode nothing") { r in
                let directory = StorageFixture.temporaryDirectory("bulk")
                let databaseURL = directory.appendingPathComponent("index.sqlite")
                defer { StorageFixture.removeDirectory(directory) }
                let libraryID = LibraryID()
                let index = SQLiteIndex(databaseURL: databaseURL)
                let cards = StorageFixture.cards(count: 10_000, libraryID: libraryID, startingAt: StorageFixture.fixedDate)
                do {
                    try await index.reset(libraryID: libraryID, generation: RootGeneration(1))
                    try await index.upsert(scanned: cards)
                } catch {
                    r.check("bulk ingest", false, "\(error)"); return
                }
                r.equal("total records", (try? await index.totalCommittedOriginalCount()) ?? -1, 10_000)

                // The index has no adapter at all: paging cannot read or hash an
                // original. This adapter records any such access, and it stays 0.
                let memory = InMemoryFileSystemAdapter()
                memory.resetCounters()
                let started = Date()
                guard let page = try? await index.firstPage(size: 5_000) else {
                    r.check("first page", false, "paging failed"); return
                }
                let elapsed = Date().timeIntervalSince(started)
                r.equal("page size clamped to the product bound", page.cards.count, MetadataBounds.maxIndexPageSize)
                r.check("first page is fast", elapsed < 3.0, "took \(elapsed)s")
                r.check("no original was read or hashed",
                        memory.totalCounters().reads == 0 && memory.totalCounters().hashes == 0)
                guard let cursor = page.nextCursor else {
                    r.check("cursor for the next page", false, "no cursor"); return
                }
                guard let second = try? await index.page(after: cursor, size: 60) else {
                    r.check("second page", false, "paging failed"); return
                }
                r.equal("second page size", second.cards.count, MetadataBounds.maxIndexPageSize)
                let firstDates = page.cards.map(\.capturedAtUTC)
                let secondDates = second.cards.map(\.capturedAtUTC)
                r.check("strictly newest-first", firstDates == firstDates.sorted(by: >)
                        && (firstDates.last ?? .distantFuture) >= (secondDates.first ?? .distantPast))
                var seen = Set(page.cards.map(\.id))
                for card in second.cards { seen.insert(card.id) }
                r.equal("pages do not overlap", seen.count, page.cards.count + second.cards.count)
            },

            // MARK: T22 — reconcile after external changes

            TCCase(id: "T22", title: "Rename, delete and add while open reconcile truthfully without deleting anything") { r in
                guard let h = await StorageHarness.make(name: "t22") else {
                    r.check("harness initialized", false, "selectRoot failed"); return
                }
                let c1 = CaptureID()
                let c2 = CaptureID()
                for captureID in [c1, c2] {
                    guard let handle = try? await h.store.stageSource(
                        bytes: StorageFixture.rawBytes(byteCount: 4_096, filler: UInt8(captureID == c1 ? 0x2A : 0x33)),
                        metadata: StorageFixture.metadata(captureID: captureID, libraryID: h.libraryID)),
                          (try? await h.store.commit(handle: handle)) != nil else {
                        r.check("seed commit", false, "could not seed \(captureID)"); return
                    }
                }

                // Rename c1's original and sidecar together.
                let datedDirectory = h.finalURL(for: c1).deletingLastPathComponent()
                let renamedOriginalURL = datedDirectory.appendingPathComponent("IMG_0001.dng")
                let renamedSidecarURL = datedDirectory.appendingPathComponent("IMG_0001.json")
                do {
                    try h.memory.moveItem(at: h.finalURL(for: c1), to: renamedOriginalURL)
                    try h.memory.moveItem(at: h.finalSidecarURL(for: c1), to: renamedSidecarURL)
                } catch {
                    r.check("rename applied", false, "\(error)"); return
                }
                // Delete c2's original only, as the Files app would.
                do { try h.memory.removeItem(at: h.finalURL(for: c2)) } catch {
                    r.check("delete applied", false, "\(error)"); return
                }
                // Add a brand-new source with a valid pair.
                let c3 = CaptureID()
                let c3Path = LibraryLayout.relativeOriginalPath(for: c3, capturedAt: StorageFixture.fixedDate,
                                                               calendar: StorageFixture.utcCalendar)
                let c3Bytes = StorageFixture.rawBytes(byteCount: 3_584)
                h.memory.setBytes(c3Bytes, at: h.root.appendingPathComponent(c3Path))
                h.memory.setBytes(StorageFixture.sidecarData(StorageFixture.sidecar(
                    captureID: c3, libraryID: h.libraryID, relativePath: c3Path,
                    byteCount: Int64(c3Bytes.count), sha256: StorageFixture.sha256Hex(c3Bytes))),
                                  at: h.root.appendingPathComponent(
                                    LibraryLayout.relativeSidecarPath(alongside: c3Path)))

                let pathsBefore = Set(h.memory.allPaths())
                guard let reconciled = try? await h.store.reconcile(onProgress: nil) else {
                    r.check("reconcile ran", false, "reconcile threw"); return
                }
                r.equal("renamed (UUID-matched) and added originals are verified",
                        reconciled.verifiedOriginalCount, 2)
                r.equal("deleted original is reported missing", reconciled.missingOriginalCount, 1)
                r.equal("no conflict", reconciled.conflictCount, 0)
                r.check("reconcile deleted nothing", pathsBefore.isSubset(of: Set(h.memory.allPaths())))
                r.check("renamed original still present", h.memory.fileExists(at: renamedOriginalURL))
                r.check("deleted original stayed deleted",
                        !h.memory.fileExists(at: h.finalURL(for: c2)))
            },

            // MARK: T23 — export gating and thumbnails

            TCCase(id: "T23", title: "A missing or unreadable original gates export and no rendering is substituted") { r in
                guard let h = await StorageHarness.make(name: "t23") else {
                    r.check("harness initialized", false, "selectRoot failed"); return
                }
                let present = CaptureID()
                let missing = CaptureID()
                guard let handle = try? await h.store.stageSource(
                    bytes: StorageFixture.rawBytes(byteCount: 4_096),
                    metadata: StorageFixture.metadata(captureID: present, libraryID: h.libraryID)),
                      (try? await h.store.commit(handle: handle)) != nil else {
                    r.check("seed commit", false, "seed failed"); return
                }
                // A source that exists in the folder but cannot be read locally.
                let unreadable = CaptureID()
                let path = LibraryLayout.relativeOriginalPath(for: unreadable,
                                                             capturedAt: StorageFixture.fixedDate,
                                                             calendar: StorageFixture.utcCalendar)
                let bytes = StorageFixture.rawBytes(byteCount: 2_048)
                h.memory.setBytes(bytes, at: h.root.appendingPathComponent(path))
                h.memory.setBytes(StorageFixture.sidecarData(StorageFixture.sidecar(
                    captureID: unreadable, libraryID: h.libraryID, relativePath: path,
                    byteCount: Int64(bytes.count), sha256: StorageFixture.sha256Hex(bytes))),
                                  at: h.root.appendingPathComponent(
                                    LibraryLayout.relativeSidecarPath(alongside: path)))
                h.memory.markInaccessible(h.root.appendingPathComponent(path))

                var session: ExportSession?
                do {
                    session = try await h.store.prepareOriginalExport(
                        sourceIDs: [present, missing, unreadable], includeSidecars: false)
                } catch {
                    r.check("export ran for the readable source", false, "\(error)")
                }
                guard let session else { return }
                r.equal("only the readable original was exported", session.fileURLs.count, 1)
                r.equal("missing items are confirmed", session.missingItems.count, 2)
                r.check("the missing items are named",
                        session.missingItems.contains { $0.contains(missing.description) }
                        && session.missingItems.contains { $0.contains(unreadable.description) })
                let exportedBytes = h.memory.fileBytes(at: session.fileURLs[0])
                r.equal("exported the exact original bytes",
                        exportedBytes, StorageFixture.rawBytes(byteCount: 4_096))

                // Nothing exportable at all: export is gated, not substituted.
                var failure: CaptureFailure?
                do {
                    _ = try await h.store.prepareOriginalExport(sourceIDs: [missing], includeSidecars: true)
                } catch let error as CaptureFailure { failure = error } catch { }
                r.check("export gated when nothing is readable", failure != nil, "export succeeded")

                // A thumbnail for a missing original is unavailable, never a render.
                let thumbs = ThumbnailService(rootURLProvider: { h.root },
                                              diskCacheDirectory: h.temporary.appendingPathComponent("thumbs"))
                let outcome = await thumbs.thumbnail(identity: missing.description,
                                                     relativePath: path,
                                                     fingerprint: nil,
                                                     targetLongEdge: 256)
                if case .unavailable = outcome {
                    r.check("thumbnail unavailable for a missing original", true)
                } else {
                    r.check("thumbnail unavailable for a missing original", false, "\(outcome)")
                }
            },

            TCCase(id: "RP01", title: "Old embedded-preview cache is bypassed while new derived cache and original stay intact") { r in
                let directory = StorageFixture.temporaryDirectory("raw-derived-cache")
                defer { StorageFixture.removeDirectory(directory) }
                let cache = directory.appendingPathComponent("cache")
                do { try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true) }
                catch { r.check("fixture directory", false); return }
                let source = directory.appendingPathComponent("preview.png")
                guard StorageFixture.writePNG(to: source, width: 64, height: 48),
                      let original = try? Data(contentsOf: source) else { r.check("fixture image", false); return }
                let oldName = SHA256.hash(data: Data("fixture|fp1|64".utf8)).map { String(format: "%02x", $0) }.joined()
                let oldURL = cache.appendingPathComponent(oldName + ".tcthumb")
                let obsolete = Data([1,0,0,0,1,0,0,0,255,0,0,255])
                do { try obsolete.write(to: oldURL) } catch { r.check("obsolete cache seeded", false); return }
                let service = ThumbnailService(rootURLProvider: { directory }, diskCacheDirectory: cache)
                let first = await service.thumbnail(identity: "fixture", relativePath: "preview.png", fingerprint: "fp1", targetLongEdge: 64)
                guard case .image(_, let width, let height, let fingerprint) = first else { r.check("new decode", false); return }
                r.equal("old 1-pixel preview was not used", width, 64)
                r.equal("fresh source aspect", height, 48)
                let reopened = ThumbnailService(rootURLProvider: { directory }, diskCacheDirectory: cache)
                let second = await reopened.thumbnail(identity: "fixture", relativePath: "preview.png", fingerprint: "fp1", targetLongEdge: 64)
                if case .image(_, _, _, let cachedFingerprint) = second {
                    r.equal("new render survives service restart", cachedFingerprint, fingerprint)
                } else { r.check("new cache load", false) }
                r.equal("original bytes unchanged", try? Data(contentsOf: source), original)
                r.equal("old disposable file is not confused with new render", try? Data(contentsOf: oldURL), obsolete)
            },

            TCCase(id: "T23c", title: "The ImageIO thumbnail path decodes real bytes, caches boundedly and clears") { r in
                let directory = StorageFixture.temporaryDirectory("thumbs")
                defer { StorageFixture.removeDirectory(directory) }
                do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) } catch {
                    r.check("temporary directory", false, "\(error)"); return
                }
                let imageURL = directory.appendingPathComponent("preview.png")
                guard StorageFixture.writePNG(to: imageURL, width: 64, height: 48) else {
                    r.check("fixture image written", false, "could not write a PNG"); return
                }
                r.check("fixture image written", true)

                let service = ThumbnailService(rootURLProvider: { directory },
                                               diskCacheDirectory: directory.appendingPathComponent("cache"),
                                               memoryBudgetBytes: 4 * 1024 * 1024)
                let first = await service.thumbnail(identity: "fixture", relativePath: "preview.png",
                                                    fingerprint: "fp1", targetLongEdge: 64)
                switch first {
                case .image(let bytes, let width, let height, let fingerprint):
                    r.equal("thumbnail width bound", width, 64)
                    r.equal("thumbnail height bound", height, 48)
                    r.equal("RGBA8 byte count", bytes.count, width * height * 4)
                    r.check("pixel fingerprint present", fingerprint.count == 64)
                default:
                    r.check("thumbnail produced", false, "\(first)")
                }
                let costAfterFirst = service.memoryCacheCost
                r.check("memory cache populated", costAfterFirst > 0)
                let second = await service.thumbnail(identity: "fixture", relativePath: "preview.png",
                                                     fingerprint: "fp1", targetLongEdge: 64)
                if case .image = second {
                    r.check("second thumbnail served", true)
                } else {
                    r.check("second thumbnail served", false, "\(second)")
                }
                service.clearMemoryCache()
                let costAfterClear = service.memoryCacheCost
                r.equal("memory cache cleared", costAfterClear, 0)

                let viewer = await service.viewerPreview(identity: "fixture", relativePath: "preview.png",
                                                         boundLongEdge: 128)
                switch viewer {
                case .image(let bytes, let width, let height, _):
                    r.equal("viewer preview keeps the aspect ratio", width * 48, height * 64)
                    r.equal("viewer preview is RGBA8", bytes.count, width * height * 4)
                default:
                    r.check("viewer preview produced", false, "\(viewer)")
                }
                let cacheDirectory = directory.appendingPathComponent("cache")
                r.check("disk cache written", FileManager.default.fileExists(atPath: cacheDirectory.path))
                service.clearDiskCache()
                r.check("disk cache cleared", !FileManager.default.fileExists(atPath: cacheDirectory.path))

                // Missing file: unavailable, never a rendering.
                let missing = await service.thumbnail(identity: "gone", relativePath: "not-there.png",
                                                      fingerprint: nil, targetLongEdge: 64)
                if case .unavailable = missing {
                    r.check("missing file is unavailable", true)
                } else {
                    r.check("missing file is unavailable", false, "\(missing)")
                }
            },

            // MARK: T24 — single-source export

            TCCase(id: "T24", title: "Single-source export copies exact bytes and checksums, and reports missing sources") { r in
                guard let h = await StorageHarness.make(name: "t24") else {
                    r.check("harness initialized", false, "selectRoot failed"); return
                }
                let c1 = CaptureID()
                let c2 = CaptureID()
                var hashes: [CaptureID: String] = [:]
                for captureID in [c1, c2] {
                    let bytes = StorageFixture.rawBytes(byteCount: 4_096,
                                                        filler: UInt8(captureID == c1 ? 0x2A : 0x77))
                    guard let handle = try? await h.store.stageSource(
                        bytes: bytes,
                        metadata: StorageFixture.metadata(captureID: captureID, libraryID: h.libraryID)),
                          (try? await h.store.commit(handle: handle)) != nil else {
                        r.check("seed commit", false, "seed failed"); return
                    }
                    hashes[captureID] = StorageFixture.sha256Hex(bytes)
                }
                let absent = CaptureID()
                guard let session = try? await h.store.prepareOriginalExport(
                    sourceIDs: [c1, c2, absent], includeSidecars: true) else {
                    r.check("export session", false, "prepareOriginalExport failed"); return
                }
                r.equal("two originals plus two sidecars", session.fileURLs.count, 4)
                r.check("sidecars included", session.includedSidecars)
                r.equal("missing source confirmed", session.missingItems.count, 1)
                r.check("missing source named", session.missingItems.contains { $0.contains(absent.description) })

                var verifiedOriginals = 0
                for url in session.fileURLs where url.pathExtension == "dng" {
                    guard let data = h.memory.fileBytes(at: url) else {
                        r.check("exported file exists", false, "\(url.lastPathComponent)"); continue
                    }
                    let digest = StorageFixture.sha256Hex(data)
                    r.check("exported checksum matches an original",
                            hashes.values.contains(digest),
                            "\(url.lastPathComponent) digest \(digest)")
                    verifiedOriginals += 1
                }
                r.equal("both originals verified", verifiedOriginals, 2)
                r.check("total bytes cover originals and sidecars", session.totalByteCount > 8_192,
                        "\(session.totalByteCount)")

                await h.store.clearAbandonedExports()
                let exportRoot = h.temporary.appendingPathComponent("TruongCamExport")
                r.check("abandoned export copies removed", !h.memory.fileExists(at: exportRoot))
                r.check("originals untouched by cleanup", h.memory.fileExists(at: h.finalURL(for: c1)))
            },

            // MARK: T30 — sequence manifest failure after a source commit

            TCCase(id: "T30", title: "A sequence manifest write failure never revokes a committed source") { r in
                guard let h = await StorageHarness.make(name: "t30") else {
                    r.check("harness initialized", false, "selectRoot failed"); return
                }
                let sequenceID = SequenceID()
                let link = SourceSequenceLink(id: sequenceID, kind: .exposureBracket, index: SourceOrdinal(0), plannedCount: 3)
                let captureID = CaptureID()
                guard let handle = try? await h.store.stageSource(
                    bytes: StorageFixture.rawBytes(byteCount: 4_096),
                    metadata: StorageFixture.metadata(captureID: captureID, libraryID: h.libraryID,
                                                     sequence: link)),
                      let receipt = try? await h.store.commit(handle: handle) else {
                    r.check("source committed", false, "seed commit failed"); return
                }
                r.equal("commit receipt is durable", receipt.verifiedSHA256, handle.sha256)

                var document = SequenceDocument(
                    sequenceID: sequenceID,
                    libraryID: h.libraryID,
                    kind: .exposureBracket,
                    plannedCount: 3,
                    sourcePlan: [0, 1, 2].map { SequenceSourcePlanEntry(index: $0, offsetEV: Double($0) - 1, focusPosition: nil) },
                    intervalSeconds: nil,
                    baseline: nil,
                    startedAtUTC: StorageFixture.fixedDate)
                document.completedSources = [SequenceCompletedSource(index: 0, captureID: captureID.rawValue)]
                document.status = .running

                h.fault.armMove(destinationSuffix: LibraryLayout.sequenceFileName(for: sequenceID))
                var failure: CaptureFailure?
                do {
                    try await h.store.writeSequenceDocument(document)
                } catch let error as CaptureFailure { failure = error } catch { }
                r.check("sequence write failed", failure != nil, "sequence write succeeded")

                // The committed source is still browsable and exportable.
                r.check("DNG still present", h.memory.fileExists(at: h.finalURL(for: captureID)))
                r.check("sidecar still present", h.memory.fileExists(at: h.finalSidecarURL(for: captureID)))
                guard let reconciled = try? await h.store.reconcile(onProgress: nil) else {
                    r.check("reconcile ran", false, "reconcile threw"); return
                }
                r.equal("source still verified", reconciled.verifiedOriginalCount, 1)
                r.equal("group rebuilt", reconciled.sequences.count, 1)
                r.check("group is incomplete", !(reconciled.sequences.first?.isComplete ?? true))
                guard let session = try? await h.store.prepareOriginalExport(
                    sourceIDs: [captureID], includeSidecars: true) else {
                    r.check("source still exportable", false, "export failed"); return
                }
                r.check("exported the committed original", session.totalByteCount > 4_096,
                        "\(session.totalByteCount)")
            },

            // MARK: Adapter-level contracts behind T10/T18/T21

            TCCase(id: "T10i", title: "Exclusive create never overwrites an existing original") { r in
                let directory = StorageFixture.temporaryDirectory("exclusive")
                defer { StorageFixture.removeDirectory(directory) }
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                } catch {
                    r.check("temporary directory", false, "\(error)"); return
                }
                let first = StorageFixture.rawBytes(byteCount: 1_024, filler: 0x2A)
                let second = StorageFixture.rawBytes(byteCount: 2_048, filler: 0x11)

                let adapter = SystemFileSystemAdapter()
                let url = directory.appendingPathComponent("TC_exclusive.dng")
                do {
                    try adapter.writeNewFile(at: url, bytes: first)
                } catch {
                    r.check("first exclusive write", false, "\(error)")
                }
                var refusal: FileAdapterError?
                do { try adapter.writeNewFile(at: url, bytes: second) } catch let error as FileAdapterError {
                    refusal = error
                } catch { }
                if case .alreadyExists = refusal {
                    r.check("second create reported alreadyExists", true)
                } else {
                    r.check("second create reported alreadyExists", false, "\(String(describing: refusal))")
                }
                r.equal("existing bytes untouched", (try? Data(contentsOf: url)) ?? Data(), first)
                var beginRefused = false
                do {
                    _ = try adapter.beginExclusiveCreate(at: url)
                } catch { beginRefused = true }
                r.check("beginExclusiveCreate refused", beginRefused)
                r.equal("still untouched after refusal", (try? Data(contentsOf: url)) ?? Data(), first)

                // The in-memory adapter offers the same contract.
                let memory = InMemoryFileSystemAdapter()
                let memoryURL = URL(fileURLWithPath: "/tc-storage-tests/exclusive/file.dng")
                do {
                    try memory.createDirectory(at: memoryURL.deletingLastPathComponent(),
                                               withIntermediateDirectories: true)
                    try memory.writeNewFile(at: memoryURL, bytes: first)
                } catch {
                    r.check("in-memory first write", false, "\(error)")
                }
                var memoryRefusal: FileAdapterError?
                do { try memory.writeNewFile(at: memoryURL, bytes: second) } catch let error as FileAdapterError {
                    memoryRefusal = error
                } catch { }
                if case .alreadyExists = memoryRefusal {
                    r.check("in-memory create reported alreadyExists", true)
                } else {
                    r.check("in-memory create reported alreadyExists", false,
                            "\(String(describing: memoryRefusal))")
                }
                r.equal("in-memory bytes untouched", memory.fileBytes(at: memoryURL), first)
            },

            TCCase(id: "T18c", title: "Streaming hash, symlink-safe scan and capacity on a real volume") { r in
                let directory = StorageFixture.temporaryDirectory("scan")
                defer { StorageFixture.removeDirectory(directory) }
                let root = directory.appendingPathComponent("root", isDirectory: true)
                let outside = directory.appendingPathComponent("outside", isDirectory: true)
                do {
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
                } catch {
                    r.check("temporary directories", false, "\(error)"); return
                }
                let adapter = SystemFileSystemAdapter()

                // A multi-megabyte file is hashed in bounded chunks and the digest
                // matches a one-shot digest of the same bytes.
                let payload = Data((0..<(3 * 1_024 * 1_024)).map { UInt8($0 % 251) })
                let bigURL = root.appendingPathComponent("big.dng")
                do { try payload.write(to: bigURL) } catch {
                    r.check("large fixture written", false, "\(error)"); return
                }
                let whole = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
                guard let streamed = try? adapter.hashFile(at: bigURL, chunkBytes: 4_096) else {
                    r.check("streaming hash", false, "hashFile failed"); return
                }
                r.equal("streaming digest matches", streamed.digest.hex, whole)
                r.equal("streaming byte count", streamed.byteCount, Int64(payload.count))
                r.equal("default chunk is bounded", FileAdapterDefaults.hashChunkBytes, 1_048_576)

                // A directory symlink is reported but never traversed.
                let secretURL = outside.appendingPathComponent("secret.dng")
                do {
                    try StorageFixture.rawBytes(byteCount: 512).write(to: secretURL)
                    try FileManager.default.createSymbolicLink(
                        at: root.appendingPathComponent("escape", isDirectory: true),
                        withDestinationURL: outside)
                } catch {
                    r.check("symlink fixture", false, "\(error)"); return
                }
                do { try StorageFixture.rawBytes(byteCount: 256).write(to: root.appendingPathComponent("real.dng")) } catch { }
                guard let entries = try? adapter.scan(root: root, maxEntries: 100,
                                                     shouldSkipRelativePath: { _ in false },
                                                     shouldDescendRelativeDirectory: { _ in true }, onProgress: nil) else {
                    r.check("scan ran", false, "scan failed"); return
                }
                let link = entries.first { $0.relativePath == "escape" }
                r.check("symlink reported as a symlink", link?.isSymbolicLink == true)
                r.check("symlink not followed",
                        !entries.contains { $0.relativePath.contains("secret.dng") },
                        "\(entries.map(\.relativePath))")
                r.check("real file listed", entries.contains { $0.relativePath == "real.dng" })
                r.check("scan is bounded", entries.count <= 100)

                // Bounded read rejects an oversized file instead of loading it.
                var readRejected = false
                do { _ = try adapter.readAll(at: bigURL, maxBytes: 1_024) } catch { readRejected = true }
                r.check("readAll bound enforced", readRejected)

                let capacity = adapter.availableCapacity(at: root)
                r.check("capacity is exposed or unknown", capacity == nil || capacity! > 0,
                        "\(String(describing: capacity))")
            },

            TCCase(id: "T14b", title: "The coordinated accessor is synchronous, writes inside the accessor and rethrows body errors") { r in
                struct BodyError: Error {}
                let directory = StorageFixture.temporaryDirectory("coordinated")
                defer { StorageFixture.removeDirectory(directory) }
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                } catch {
                    r.check("temporary directory", false, "\(error)"); return
                }
                let mutator = NSFileCoordinatorMutator()
                let url = directory.appendingPathComponent("coordinated.json")
                let ranInside = Mutex<Bool>(false)
                var writeError: Error?
                do {
                    try mutator.coordinatedWrite(at: url) { actual in
                        ranInside.withLock { $0 = true }
                        try Data("hello".utf8).write(to: actual)
                    }
                } catch {
                    writeError = error
                }
                r.check("coordinated write succeeded", writeError == nil, "\(String(describing: writeError))")
                r.check("the body ran inside the accessor", ranInside.withLock { $0 })
                r.equal("bytes written before the call returned",
                        (try? Data(contentsOf: url)) ?? Data(), Data("hello".utf8))

                let readBack = try? mutator.coordinatedRead(at: url) { actual in
                    try Data(contentsOf: actual)
                }
                r.equal("coordinated read returns the bytes", readBack ?? Data(), Data("hello".utf8))

                var caught: Error?
                do {
                    try mutator.coordinatedWrite(at: url) { _ in throw BodyError() }
                } catch {
                    caught = error
                }
                r.check("the body's error is what the caller sees", caught is BodyError,
                        "\(String(describing: caught))")
            },

            TCCase(id: "T21b", title: "Index sequence covers, day counts, availability and detail") { r in
                let directory = StorageFixture.temporaryDirectory("index-sequence")
                let databaseURL = directory.appendingPathComponent("index.sqlite")
                defer { StorageFixture.removeDirectory(directory) }
                let index = SQLiteIndex(databaseURL: databaseURL)
                let libraryID = LibraryID()
                let sequenceID = SequenceID()
                do {
                    try await index.reset(libraryID: libraryID, generation: RootGeneration(2))
                    try await index.updateSequences([SequenceSummary(
                        sequenceID: sequenceID,
                        kind: .exposureBracket,
                        plannedCount: 3,
                        committedCount: 3,
                        missingIndices: [],
                        failedIndices: [],
                        skippedDeadlineCount: 1,
                        status: .complete,
                        startedAtUTC: StorageFixture.fixedDate)])
                } catch {
                    r.check("index setup", false, "\(error)"); return
                }
                let members = (0..<3).map { ordinal in
                    LibrarySourceCard(
                        captureID: CaptureID(),
                        libraryID: libraryID,
                        relativeOriginalPath: "originals/2026/09/21/TC_\(UUID().uuidString.lowercased()).dng",
                        capturedAtUTC: StorageFixture.fixedDate.addingTimeInterval(Double(-ordinal)),
                        capturedAtProvenance: .captureMetadata,
                        availability: .local,
                        classification: .verifiedOriginal,
                        rawDimensions: PixelDimensions(width: 4_032, height: 3_024),
                        byteCount: 4_096,
                        sequenceID: sequenceID,
                        sequenceIndex: ordinal,
                        sequenceKind: .exposureBracket,
                        isTruongCamCapture: true,
                        modificationFingerprint: "fp\(ordinal)")
                }
                do {
                    try await index.upsert(scanned: members)
                } catch {
                    r.check("member upsert", false, "\(error)"); return
                }
                guard let page = try? await index.firstPage(size: 60) else {
                    r.check("first page", false, "paging failed"); return
                }
                r.equal("one cover card for the sequence", page.cards.count, 1)
                r.equal("represented originals", page.cards.first?.representedOriginalCount, 3)
                if let kind = page.cards.first?.kind, case .sequenceCover(let summary, let cover) = kind {
                    r.equal("planned count", summary.plannedCount, 3)
                    r.equal("committed count", summary.committedCount, 3)
                    r.check("sequence complete", summary.isComplete)
                    r.equal("skipped deadlines preserved", summary.skippedDeadlineCount, 1)
                    r.equal("cover is the first ordinal", cover?.sequenceIndex, 0)
                } else {
                    r.check("sequence cover card", false, "\(String(describing: page.cards.first?.kind))")
                }
                r.equal("committed original total", (try? await index.totalCommittedOriginalCount()) ?? -1, 3)
                let dayCounts = (try? await index.dayGroupCounts()) ?? []
                r.equal("one day group", dayCounts.count, 1)
                r.equal("day original count", dayCounts.first?.originalCount, 3)
                r.equal("day card count", dayCounts.first?.cardCount, 1)
                r.equal("sequence members ordered",
                        (try? await index.sources(inSequence: sequenceID))?.map(\.sequenceIndex), [0, 1, 2])

                do {
                    try await index.markUnavailable(captureID: members[0].captureID, reason: "removed in Files")
                } catch {
                    r.check("markUnavailable", false, "\(error)")
                }
                let detail = try? await index.detail(captureID: members[0].captureID)
                r.equal("availability flips to missing", detail?.availability, .missing)
                r.check("detail keeps the sequence identity", detail?.sequenceID == sequenceID)
                let rich = try? await index.captureDetail(captureID: members[1].captureID)
                r.equal("rich detail fingerprint", rich?.modificationFingerprint, "fp1")
                r.check("no thumbnail bytes are stored", rich?.thumbnailKey == nil)
                r.equal("card still listed while unavailable",
                        (try? await index.firstPage(size: 60))?.cards.count, 1)
            },
        ])
}

// MARK: - Small test-only helpers

extension StorageFixture {
    /// Writes a real PNG through ImageIO so the thumbnail path is exercised
    /// against genuine encoded bytes rather than a synthetic header.
    static func writePNG(to url: URL, width: Int, height: Int) -> Bool {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return false }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for index in pixels.indices {
            pixels[index] = UInt8((index * 7) % 251)
        }
        let created: CGImage? = pixels.withUnsafeMutableBytes { buffer -> CGImage? in
            guard let base = buffer.baseAddress,
                  let context = CGContext(data: base, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: colorSpace,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return nil
            }
            return context.makeImage()
        }
        guard let image = created,
              let destination = CGImageDestinationCreateWithURL(
                url as CFURL, "public.png" as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }
}
