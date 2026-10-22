import Foundation
import SQLite3

// LIBRARY.md "Gallery rebuilding and local availability" + CONTRACTS.md
// "Browsing, export, lifecycle and UI".
//
// The index is a *disposable cache*. Deleting the database and rescanning the
// folder must reproduce the same cards; nothing here is authoritative and no
// original bytes, thumbnails or raw DNG data are ever stored. Pagination uses
// prepared statements and bounded batches, and never hashes or decodes an
// original.

enum SQLiteIndexError: Error, CustomStringConvertible {
    case openFailed(path: String, code: Int32, message: String)
    case statementFailed(sql: String, code: Int32, message: String)
    case bindingFailed(index: Int32, code: Int32, message: String)

    var description: String {
        switch self {
        case .openFailed(let path, let code, let message):
            return "Could not open the local index at \(path) (sqlite \(code): \(message))"
        case .statementFailed(let sql, let code, let message):
            return "Local index statement failed (sqlite \(code): \(message)) for \(sql)"
        case .bindingFailed(let index, let code, let message):
            return "Local index bind \(index) failed (sqlite \(code): \(message))"
        }
    }

    var isCorruption: Bool {
        switch self {
        case .openFailed(_, let code, _), .statementFailed(_, let code, _), .bindingFailed(_, let code, _):
            return code == SQLITE_CORRUPT || code == SQLITE_NOTADB
        }
    }
}

/// One normalized source row, including the capture fields the detail inspector
/// needs. Value-only: never original bytes.
struct IndexedSourceDetail: Hashable, Sendable {
    let card: LibrarySourceCard
    let byteCount: Int64?
    let modificationFingerprint: String?
    let thumbnailKey: String?
    let deviceModel: String?
    let osVersion: String?
    let cameraDeviceType: String?
    let formatKind: String?
    let rawPixelFormat: UInt32?
    let requestedExposureMode: String?
    let requestedDurationSeconds: Double?
    let requestedISO: Double?
    let requestedBiasEV: Double?
    let requestedFocusMode: String?
    let requestedFocusPosition: Double?
    let requestedWhiteBalanceMode: String?
    let requestedWhiteBalanceTemperatureKelvin: Double?
    let requestedWhiteBalanceTint: Double?
    let observedDurationSeconds: Double?
    let observedISO: Double?
    let observedAperture: Double?
    let observedFocalLengthMM: Double?
    let observedOrientation: Int?
    let observedFocusPosition: Double?
    let observedFocusProvenance: String?
    let whiteBalanceGainRed: Double?
    let whiteBalanceGainGreen: Double?
    let whiteBalanceGainBlue: Double?
    let whiteBalanceProvenance: String?
    let equivalentFocalLengthMM: Double?
    let cropGuide: String?
    let requestedMaxWidth: Int?
    let requestedMaxHeight: Int?
}

actor SQLiteIndex: LibraryIndexing {
    private let databaseURL: URL
    private var database: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]
    private var libraryID: LibraryID?
    private var generation = RootGeneration.zero
    private var indexRevision = UUID()

    static func defaultDatabaseURL(applicationSupportDirectory: URL? = nil) -> URL {
        let base = applicationSupportDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("TruongCamIndex", isDirectory: true)
            .appendingPathComponent("library-index.sqlite", isDirectory: false)
    }

    init(databaseURL: URL) {
        self.databaseURL = databaseURL.standardizedFileURL
    }

    // MARK: - LibraryIndexing

    func reset(libraryID: LibraryID, generation: RootGeneration) async throws {
        try withDatabase { _ in
            self.indexRevision = UUID()
            try execute("DELETE FROM sources")
            try execute("DELETE FROM sequences")
            try execute("DELETE FROM meta")
            try insertMeta(key: "libraryID", value: libraryID.description)
            try insertMeta(key: "generation", value: String(generation.value))
            self.libraryID = libraryID
            self.generation = generation
        }
    }

    func ingest(_ receipts: [CommitReceipt]) async throws {
        guard !receipts.isEmpty else { return }
        try withDatabase { _ in
            self.indexRevision = UUID()
            for batch in receipts.tcChunked(into: MetadataBounds.maxScanBatchEntries) {
                try execute("BEGIN IMMEDIATE")
                do {
                    for receipt in batch {
                        try self.writeReceipt(receipt)
                    }
                    try execute("COMMIT")
                } catch {
                    do { try execute("ROLLBACK") } catch { /* the original failure is reported */ }
                    throw error
                }
            }
        }
    }

    func upsert(scanned: [LibrarySourceCard]) async throws {
        guard !scanned.isEmpty else { return }
        try withDatabase { _ in
            self.indexRevision = UUID()
            for batch in scanned.tcChunked(into: MetadataBounds.maxScanBatchEntries) {
                try execute("BEGIN IMMEDIATE")
                do {
                    for card in batch {
                        try self.writeCard(card)
                    }
                    try execute("COMMIT")
                } catch {
                    do { try execute("ROLLBACK") } catch { /* the original failure is reported */ }
                    throw error
                }
            }
        }
    }

    func markUnavailable(captureID: CaptureID, reason: String) async throws {
        try withDatabase { _ in
            self.indexRevision = UUID()
            // A source that is not indexed yet is not an error: the gallery can
            // still show it as missing once the next reconcile upserts it.
            try execute(
                "UPDATE sources SET availability = ?, missingReason = ? WHERE captureID = ?",
                bind: [.text(Self.availabilityCode(.missing)), .text(reason), .text(captureID.description)])
        }
    }

    func firstPage(size: Int) async throws -> LibraryPage {
        try pageQuery(cursor: nil, size: size)
    }

    func page(after cursor: LibraryCursor, size: Int) async throws -> LibraryPage {
        return try pageQuery(cursor: cursor, size: size)
    }

    func detail(captureID: CaptureID) async throws -> LibrarySourceCard? {
        try withDatabase { _ in
            let rows = try self.queryCards(whereClause: "AND s.captureID = ?",
                                           bind: [.text(captureID.description)],
                                           orderAndLimit: "ORDER BY s.capturedAtUTC DESC, s.identityKey DESC LIMIT 1",
                                           extraCursorBind: [])
            return try rows.first.map { try self.sourceCard(from: $0) }
        }
    }

    func sources(inSequence sequenceID: SequenceID) async throws -> [LibrarySourceCard] {
        try withDatabase { _ in
            let rows = try self.queryCards(
                whereClause: "AND s.sequenceID = ?",
                bind: [.text(sequenceID.description)],
                orderAndLimit: "ORDER BY IFNULL(s.sequenceOrdinal, 2147483647) ASC, s.capturedAtUTC ASC",
                extraCursorBind: [],
                collapseSequences: false)
            return try rows.map { try self.sourceCard(from: $0) }
        }
    }

    func dayGroupCounts() async throws -> [DayGroupCount] {
        try withDatabase { _ in
            let sql = """
            SELECT dayKey, SUM(represented), COUNT(*) FROM (
              SELECT s.dayKey AS dayKey,
                     CASE WHEN s.sequenceID IS NULL THEN 1
                          ELSE (SELECT COUNT(*) FROM sources t WHERE t.sequenceID = s.sequenceID) END AS represented
              \(Self.cardFrom)
            ) GROUP BY dayKey ORDER BY dayKey DESC
            """
            let statement = try self.prepare(sql)
            defer { sqlite3_reset(statement) }
            var counts: [DayGroupCount] = []
            while true {
                let step = sqlite3_step(statement)
                if step == SQLITE_DONE { break }
                guard step == SQLITE_ROW else { throw self.statementError(sql, step) }
                counts.append(DayGroupCount(
                    dayKey: Self.text(statement, 0) ?? "",
                    originalCount: Int(sqlite3_column_int64(statement, 1)),
                    cardCount: Int(sqlite3_column_int64(statement, 2))))
            }
            return counts
        }
    }

    func totalCommittedOriginalCount() async throws -> Int {
        try withDatabase { _ in try committedOriginalCount() }
    }

    private func committedOriginalCount() throws -> Int {
        let statement = try prepare("SELECT COUNT(*) FROM sources WHERE countsAsCommittedOriginal = 1")
        defer { sqlite3_reset(statement) }
        let step = sqlite3_step(statement)
        guard step == SQLITE_ROW || step == SQLITE_DONE else { throw statementError("count", step) }
        return Int(sqlite3_column_int64(statement, 0))
    }

    // MARK: - Extra (non-protocol) queries used by the gallery and tests

    /// Stores sequence summaries derived from sequence documents and sidecars.
    /// Without this the index never claims a sequence is complete.
    func updateSequences(_ summaries: [SequenceSummary]) async throws {
        guard !summaries.isEmpty else { return }
        try withDatabase { _ in
            self.indexRevision = UUID()
            try execute("BEGIN IMMEDIATE")
            do {
                for summary in summaries {
                    try execute("""
                    INSERT OR REPLACE INTO sequences
                    (sequenceID, kind, plannedCount, committedCount, missingIndices, failedIndices,
                     skippedDeadlineCount, status, startedAtUTC)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, bind: [
                        .text(summary.sequenceID.description),
                        .text(summary.kind.rawValue),
                        .int(summary.plannedCount),
                        .int(summary.committedCount),
                        .text(Self.encodeIndices(summary.missingIndices)),
                        .text(Self.encodeIndices(summary.failedIndices)),
                        .int(summary.skippedDeadlineCount),
                        .text(summary.status.rawValue),
                        .double(summary.startedAtUTC.timeIntervalSince1970),
                    ])
                }
                try execute("COMMIT")
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    /// Rich detail for the inspector. The thumbnail is identified by key, never
    /// by bytes.
    func captureDetail(captureID: CaptureID) async throws -> IndexedSourceDetail? {
        try withDatabase { _ in
            let sql = """
            SELECT \(Self.detailColumns) FROM sources s WHERE s.captureID = ? LIMIT 1
            """
            let statement = try self.prepare(sql)
            defer { sqlite3_reset(statement) }
            try Self.bind(statement, [.text(captureID.description)])
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return nil }
            guard step == SQLITE_ROW else { throw self.statementError(sql, step) }
            let row = try self.detailRow(from: statement)
            return row
        }
    }

    /// Closes the database handle. Reopening rebuilds the schema on next use; a
    /// corrupt file is deleted and rebuilt instead of failing the library.
    func closeDatabase() {
        for (_, statement) in statements { sqlite3_finalize(statement) }
        statements.removeAll()
        if let database { sqlite3_close(database) }
        database = nil
    }

    /// Deletes the disposable database files. Used by tests to prove cards can
    /// be rebuilt from the folder alone.
    func deleteDatabaseFiles() {
        closeDatabase()
        let fileManager = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let url = URL(fileURLWithPath: databaseURL.path + suffix)
            if fileManager.fileExists(atPath: url.path) {
                do { try fileManager.removeItem(at: url) } catch { /* disposable cache */ }
            }
        }
    }

    // MARK: - Schema

    private static let sourceColumns: [String] = [
        "identityKey", "captureID", "libraryID", "relativePath", "sidecarPath",
        "modificationFingerprint", "capturedAtUTC", "capturedAtProvenance", "dayKey",
        "rawWidth", "rawHeight", "availability", "missingReason", "classification",
        "sequenceID", "sequenceKind", "sequenceOrdinal", "thumbnailKey", "byteCount",
        "isTruongCamCapture", "inGallery", "countsAsCommittedOriginal",
        "deviceModel", "osVersion", "cameraDeviceType", "formatKind", "rawPixelFormat",
        "requestedExposureMode", "requestedDurationSeconds", "requestedISO", "requestedBiasEV",
        "requestedFocusMode", "requestedFocusPosition", "requestedWBMode",
        "requestedWBTemperature", "requestedWBTint",
        "observedDurationSeconds", "observedISO", "observedAperture", "observedFocalLengthMM",
        "observedOrientation", "observedFocusPosition", "observedFocusProvenance",
        "wbGainR", "wbGainG", "wbGainB", "wbProvenance",
        "equivalentFocalLengthMM", "cropGuide", "maxWidth", "maxHeight",
    ]

    /// Detail-inspector columns are preserved across a plain card upsert so a
    /// rescan never downgrades richer metadata that is already known.
    private static let preservedOnUpsert: Set<String> = [
        "deviceModel", "osVersion", "cameraDeviceType", "formatKind", "rawPixelFormat",
        "requestedExposureMode", "requestedDurationSeconds", "requestedISO", "requestedBiasEV",
        "requestedFocusMode", "requestedFocusPosition", "requestedWBMode",
        "requestedWBTemperature", "requestedWBTint",
        "observedDurationSeconds", "observedISO", "observedAperture", "observedFocalLengthMM",
        "observedOrientation", "observedFocusPosition", "observedFocusProvenance",
        "wbGainR", "wbGainG", "wbGainB", "wbProvenance",
        "equivalentFocalLengthMM", "cropGuide", "maxWidth", "maxHeight",
    ]

    /// All rows of one sequence, for `sources(inSequence:)`.
    private static let memberFrom = """
    FROM sources s
    WHERE s.inGallery = 1
    """

    private static let cardFrom = """
    FROM sources s
    WHERE s.inGallery = 1
      AND (s.sequenceID IS NULL
           OR IFNULL(s.sequenceOrdinal, 2147483647) =
              (SELECT MIN(IFNULL(t.sequenceOrdinal, 2147483647)) FROM sources t WHERE t.sequenceID = s.sequenceID))
    """

    private static let cardSelectColumns = """
    s.identityKey, s.captureID, s.libraryID, s.relativePath, s.capturedAtUTC, s.capturedAtProvenance,
    s.availability, s.missingReason, s.classification, s.rawWidth, s.rawHeight, s.byteCount,
    s.sequenceID, s.sequenceOrdinal, s.sequenceKind, s.modificationFingerprint, s.isTruongCamCapture
    """

    private static let detailColumns = """
    s.identityKey, s.captureID, s.libraryID, s.relativePath, s.capturedAtUTC, s.capturedAtProvenance,
    s.availability, s.missingReason, s.classification, s.rawWidth, s.rawHeight, s.byteCount,
    s.sequenceID, s.sequenceOrdinal, s.sequenceKind, s.modificationFingerprint, s.isTruongCamCapture,
    s.thumbnailKey, s.deviceModel, s.osVersion, s.cameraDeviceType, s.formatKind, s.rawPixelFormat,
    s.requestedExposureMode, s.requestedDurationSeconds, s.requestedISO, s.requestedBiasEV,
    s.requestedFocusMode, s.requestedFocusPosition, s.requestedWBMode, s.requestedWBTemperature,
    s.requestedWBTint, s.observedDurationSeconds, s.observedISO, s.observedAperture,
    s.observedFocalLengthMM, s.observedOrientation, s.observedFocusPosition,
    s.observedFocusProvenance, s.wbGainR, s.wbGainG, s.wbGainB, s.wbProvenance,
    s.equivalentFocalLengthMM, s.cropGuide, s.maxWidth, s.maxHeight
    """

    private static let schemaStatements: [String] = [
        "PRAGMA journal_mode = WAL",
        "PRAGMA synchronous = NORMAL",
        """
        CREATE TABLE IF NOT EXISTS meta (
          key TEXT PRIMARY KEY NOT NULL,
          value TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS sources (
          identityKey TEXT PRIMARY KEY NOT NULL,
          captureID TEXT NOT NULL,
          libraryID TEXT NOT NULL,
          relativePath TEXT NOT NULL,
          sidecarPath TEXT,
          modificationFingerprint TEXT,
          capturedAtUTC REAL NOT NULL,
          capturedAtProvenance TEXT NOT NULL,
          dayKey TEXT NOT NULL,
          rawWidth INTEGER,
          rawHeight INTEGER,
          availability TEXT NOT NULL,
          missingReason TEXT,
          classification TEXT NOT NULL,
          sequenceID TEXT,
          sequenceKind TEXT,
          sequenceOrdinal INTEGER,
          thumbnailKey TEXT,
          byteCount INTEGER,
          isTruongCamCapture INTEGER NOT NULL DEFAULT 0,
          inGallery INTEGER NOT NULL DEFAULT 1,
          countsAsCommittedOriginal INTEGER NOT NULL DEFAULT 0,
          deviceModel TEXT, osVersion TEXT, cameraDeviceType TEXT,
          formatKind TEXT, rawPixelFormat INTEGER,
          requestedExposureMode TEXT, requestedDurationSeconds REAL, requestedISO REAL,
          requestedBiasEV REAL, requestedFocusMode TEXT, requestedFocusPosition REAL,
          requestedWBMode TEXT, requestedWBTemperature REAL, requestedWBTint REAL,
          observedDurationSeconds REAL, observedISO REAL, observedAperture REAL,
          observedFocalLengthMM REAL, observedOrientation INTEGER,
          observedFocusPosition REAL, observedFocusProvenance TEXT,
          wbGainR REAL, wbGainG REAL, wbGainB REAL, wbProvenance TEXT,
          equivalentFocalLengthMM REAL, cropGuide TEXT,
          maxWidth INTEGER, maxHeight INTEGER
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_sources_order ON sources(capturedAtUTC DESC, identityKey DESC)",
        "CREATE INDEX IF NOT EXISTS idx_sources_sequence ON sources(sequenceID, sequenceOrdinal)",
        "CREATE INDEX IF NOT EXISTS idx_sources_capture ON sources(captureID)",
        "CREATE INDEX IF NOT EXISTS idx_sources_day ON sources(dayKey)",
        """
        CREATE TABLE IF NOT EXISTS sequences (
          sequenceID TEXT PRIMARY KEY NOT NULL,
          kind TEXT NOT NULL,
          plannedCount INTEGER NOT NULL,
          committedCount INTEGER NOT NULL,
          missingIndices TEXT NOT NULL,
          failedIndices TEXT NOT NULL,
          skippedDeadlineCount INTEGER NOT NULL,
          status TEXT NOT NULL,
          startedAtUTC REAL NOT NULL
        )
        """,
    ]

    // MARK: - Database plumbing

    private static var sqliteTransient: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }

    private func withDatabase<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        do {
            let handle = try ensureDatabase()
            return try body(handle)
        } catch let error as SQLiteIndexError where error.isCorruption {
            // A corrupt index is disposable: rebuild it and retry once. The
            // library itself never fails because its cache was damaged.
            rebuildDatabase()
            let handle = try ensureDatabase()
            do {
                return try body(handle)
            } catch {
                throw self.indexFailure(error)
            }
        } catch {
            throw indexFailure(error)
        }
    }

    private func indexFailure(_ error: Error) -> Error {
        if error is LibraryIndexPagingError { return error }
        if let failure = error as? CaptureFailure { return failure }
        let description = (error as? SQLiteIndexError)?.description ?? "\(error)"
        return CaptureFailure(kind: .providerIOFailed(detail: "Local index: \(description)"),
                              operation: "SQLiteIndex",
                              retainedSourceStatus: .none)
    }

    private func ensureDatabase() throws -> OpaquePointer {
        if let database { return database }
        let fileManager = FileManager.default
        let directory = databaseURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                throw SQLiteIndexError.openFailed(path: directory.path, code: 0, message: "\(error)")
            }
        }
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let openResult = sqlite3_open_v2(databaseURL.path, &handle, flags, nil)
        guard openResult == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let handle { sqlite3_close(handle) }
            throw SQLiteIndexError.openFailed(path: databaseURL.path, code: openResult, message: message)
        }
        database = handle
        do {
            for statement in Self.schemaStatements {
                try execute(statement)
            }
            try loadMeta()
            indexRevision = UUID()
        } catch {
            if let handle = database {
                sqlite3_close(handle)
                database = nil
            }
            statements.removeAll()
            throw error
        }
        return handle
    }

    private func rebuildDatabase() {
        closeDatabase()
        let fileManager = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let url = URL(fileURLWithPath: databaseURL.path + suffix)
            if fileManager.fileExists(atPath: url.path) {
                // Only the app's own disposable index files are removed.
                do { try fileManager.removeItem(at: url) } catch { /* rebuilt on next open */ }
            }
        }
        libraryID = nil
        generation = .zero
    }

    private func loadMeta() throws {
        // A reopened/replaced cache may have no identity rows at all. Do not
        // inherit the metadata of the closed database handle.
        libraryID = nil
        generation = .zero
        let statement = try prepare("SELECT key, value FROM meta")
        defer { sqlite3_reset(statement) }
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw statementError("SELECT meta", step) }
            guard let key = Self.text(statement, 0), let value = Self.text(statement, 1) else { continue }
            switch key {
            case "libraryID": libraryID = UUID(uuidString: value).map { LibraryID($0) }
            case "generation": generation = RootGeneration(UInt64(value) ?? 0)
            default: break
            }
        }
    }

    private func insertMeta(key: String, value: String) throws {
        try execute("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)",
                    bind: [.text(key), .text(value)])
    }

    private func execute(_ sql: String, bind values: [SQLiteValue] = []) throws {
        let statement = try prepare(sql)
        defer { sqlite3_reset(statement) }
        if !values.isEmpty { try Self.bind(statement, values) }
        let step = sqlite3_step(statement)
        guard step == SQLITE_DONE || step == SQLITE_ROW else { throw statementError(sql, step) }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        if let cached = statements[sql] {
            sqlite3_reset(cached)
            sqlite3_clear_bindings(cached)
            return cached
        }
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(try ensureDatabase(), sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            throw SQLiteIndexError.statementFailed(sql: sql, code: result, message: lastErrorMessage())
        }
        statements[sql] = statement
        return statement
    }

    private func lastErrorMessage() -> String {
        guard let database else { return "no database handle" }
        return String(cString: sqlite3_errmsg(database))
    }

    private func statementError(_ sql: String, _ code: Int32) -> SQLiteIndexError {
        .statementFailed(sql: sql, code: code, message: lastErrorMessage())
    }

    // MARK: - Values

    enum SQLiteValue {
        case text(String?)
        case int(Int?)
        case int64(Int64?)
        case double(Double?)
        case null
    }

    static func bind(_ statement: OpaquePointer, _ values: [SQLiteValue]) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .text(let text):
                result = text.map { sqlite3_bind_text(statement, index, $0, -1, sqliteTransient) } ?? sqlite3_bind_null(statement, index)
            case .int(let number):
                result = number.map { sqlite3_bind_int64(statement, index, Int64($0)) } ?? sqlite3_bind_null(statement, index)
            case .int64(let number):
                result = number.map { sqlite3_bind_int64(statement, index, $0) } ?? sqlite3_bind_null(statement, index)
            case .double(let number):
                result = number.map { sqlite3_bind_double(statement, index, $0) } ?? sqlite3_bind_null(statement, index)
            case .null:
                result = sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else {
                throw SQLiteIndexError.bindingFailed(index: index, code: result, message: "bind failed")
            }
        }
    }

    static func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: pointer)
    }

    static func optionalDouble(_ statement: OpaquePointer, _ index: Int32) -> Double? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(statement, index)
    }

    static func optionalInt(_ statement: OpaquePointer, _ index: Int32) -> Int? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int64(statement, index))
    }

    static func optionalInt64(_ statement: OpaquePointer, _ index: Int32) -> Int64? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(statement, index)
    }

    // MARK: - Classification / availability coding

    static func classificationCode(_ classification: SourceClassification) -> String {
        switch classification {
        case .verifiedOriginal: return "verifiedOriginal"
        case .recoveredRAW: return "recoveredRAW"
        case .missingOriginal: return "missingOriginal"
        case .stagedExternal: return "stagedExternal"
        case .conflict: return "conflict"
        }
    }

    static func classificationReason(_ classification: SourceClassification) -> String? {
        switch classification {
        case .recoveredRAW(let issue): return issue
        case .missingOriginal(let reason): return reason
        case .conflict(let reason): return reason
        case .verifiedOriginal, .stagedExternal: return nil
        }
    }

    static func classification(from code: String, reason: String?) -> SourceClassification {
        switch code {
        case "verifiedOriginal": return .verifiedOriginal
        case "recoveredRAW": return .recoveredRAW(metadataIssue: reason)
        case "missingOriginal": return .missingOriginal(reason: reason ?? "The original is missing.")
        case "stagedExternal": return .stagedExternal
        case "conflict": return .conflict(reason: reason ?? "Conflicting bytes for the same identity.")
        default: return .recoveredRAW(metadataIssue: reason ?? "Unknown index classification \(code).")
        }
    }

    static func availabilityCode(_ availability: SourceAvailability) -> String {
        switch availability {
        case .local: return "local"
        case .missing: return "missing"
        case .inaccessible: return "inaccessible"
        case .unknown: return "unknown"
        }
    }

    static func availability(from code: String, reason: String?) -> SourceAvailability {
        switch code {
        case "local": return .local
        case "missing": return .missing
        case "inaccessible": return .inaccessible(reason: reason ?? "inaccessible")
        default: return .unknown
        }
    }

    static func encodeIndices(_ indices: [Int]) -> String {
        indices.map(String.init).joined(separator: ",")
    }

    static func decodeIndices(_ text: String?) -> [Int] {
        guard let text, !text.isEmpty else { return [] }
        return text.split(separator: ",").compactMap { Int($0) }
    }

    static func dayKey(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 1970, components.month ?? 1, components.day ?? 1)
    }

    // MARK: - Writes

    private func writeReceipt(_ receipt: CommitReceipt) throws {
        let metadata = receipt.metadata
        let values: [String: SQLiteValue] = [
            "identityKey": .text(receipt.captureID.description),
            "captureID": .text(receipt.captureID.description),
            "libraryID": .text(receipt.libraryID.description),
            "relativePath": .text(receipt.relativeOriginalPath),
            "sidecarPath": .text(receipt.relativeSidecarPath),
            "modificationFingerprint": .text("sha256:\(receipt.verifiedSHA256.hex)"),
            "capturedAtUTC": .double(metadata.capturedAtUTC.timeIntervalSince1970),
            "capturedAtProvenance": .text(metadata.capturedAtProvenance.rawValue),
            "dayKey": .text(Self.dayKey(for: metadata.capturedAtUTC, calendar: Calendar.current)),
            "rawWidth": .int(metadata.observed.rawDimensions?.width),
            "rawHeight": .int(metadata.observed.rawDimensions?.height),
            "availability": .text(Self.availabilityCode(.local)),
            "missingReason": .null,
            "classification": .text(Self.classificationCode(.verifiedOriginal)),
            "sequenceID": .text(metadata.sequence?.id.uuidString.lowercased()),
            "sequenceKind": .text(metadata.sequence?.kind.rawValue),
            "sequenceOrdinal": .int(metadata.sequence?.index),
            "thumbnailKey": .null,
            "byteCount": .int64(receipt.verifiedByteCount),
            "isTruongCamCapture": .int(1),
            "inGallery": .int(1),
            "countsAsCommittedOriginal": .int(1),
            "deviceModel": .text(metadata.deviceModel),
            "osVersion": .text(metadata.osVersion),
            "cameraDeviceType": .text(metadata.cameraDeviceType),
            "formatKind": .text(metadata.format.kind),
            "rawPixelFormat": .int(Int(metadata.format.rawPixelFormat)),
            "requestedExposureMode": .text(metadata.requested.exposure.mode.rawValue),
            "requestedDurationSeconds": .double(metadata.requested.exposure.durationSeconds),
            "requestedISO": .double(metadata.requested.exposure.iso),
            "requestedBiasEV": .double(metadata.requested.exposure.biasEV),
            "requestedFocusMode": .text(metadata.requested.focus.mode.rawValue),
            "requestedFocusPosition": .double(metadata.requested.focus.position),
            "requestedWBMode": .text(metadata.requested.whiteBalance.mode.rawValue),
            "requestedWBTemperature": .double(metadata.requested.whiteBalance.temperatureKelvin),
            "requestedWBTint": .double(metadata.requested.whiteBalance.tint),
            "observedDurationSeconds": .double(metadata.observed.durationSeconds),
            "observedISO": .double(metadata.observed.iso),
            "observedAperture": .double(metadata.observed.aperture),
            "observedFocalLengthMM": .double(metadata.observed.focalLengthMM),
            "observedOrientation": .int(metadata.observed.orientation),
            "observedFocusPosition": .double(metadata.observed.focus?.position),
            "observedFocusProvenance": .text(metadata.observed.focus?.provenance.rawValue),
            "wbGainR": .double(metadata.observed.whiteBalance?.gains?.red),
            "wbGainG": .double(metadata.observed.whiteBalance?.gains?.green),
            "wbGainB": .double(metadata.observed.whiteBalance?.gains?.blue),
            "wbProvenance": .text(metadata.observed.whiteBalance?.provenance.rawValue),
            "equivalentFocalLengthMM": .double(metadata.equivalentFocalLengthMM),
            "cropGuide": .text(nil),
            "maxWidth": .int(metadata.requested.maxDimensions.width),
            "maxHeight": .int(metadata.requested.maxDimensions.height),
        ]
        try writeRow(values)
    }

    private func writeCard(_ card: LibrarySourceCard) throws {
        let values: [String: SQLiteValue] = [
            "identityKey": .text(card.captureID.description),
            "captureID": .text(card.captureID.description),
            "libraryID": .text(card.libraryID.description),
            "relativePath": .text(card.relativeOriginalPath),
            "sidecarPath": .text(LibraryLayout.relativeSidecarPath(alongside: card.relativeOriginalPath)),
            "modificationFingerprint": .text(card.modificationFingerprint),
            "capturedAtUTC": .double(card.capturedAtUTC.timeIntervalSince1970),
            "capturedAtProvenance": .text(card.capturedAtProvenance.rawValue),
            "dayKey": .text(Self.dayKey(for: card.capturedAtUTC, calendar: Calendar.current)),
            "rawWidth": .int(card.rawDimensions?.width),
            "rawHeight": .int(card.rawDimensions?.height),
            "availability": .text(Self.availabilityCode(card.availability)),
            "missingReason": .text(Self.classificationReason(card.classification)),
            "classification": .text(Self.classificationCode(card.classification)),
            "sequenceID": .text(card.sequenceID?.description),
            "sequenceKind": .text(card.sequenceKind?.rawValue),
            "sequenceOrdinal": .int(card.sequenceIndex),
            "thumbnailKey": .null,
            "byteCount": .int64(card.byteCount),
            "isTruongCamCapture": .int(card.isTruongCamCapture ? 1 : 0),
            "inGallery": .int(Self.isInGallery(card.classification) ? 1 : 0),
            "countsAsCommittedOriginal": .int(Self.countsAsCommittedOriginal(card) ? 1 : 0),
            "deviceModel": .text(nil),
            "osVersion": .text(nil),
            "cameraDeviceType": .text(nil),
            "formatKind": .text(nil),
            "rawPixelFormat": .int(nil),
            "requestedExposureMode": .text(nil),
            "requestedDurationSeconds": .double(nil),
            "requestedISO": .double(nil),
            "requestedBiasEV": .double(nil),
            "requestedFocusMode": .text(nil),
            "requestedFocusPosition": .double(nil),
            "requestedWBMode": .text(nil),
            "requestedWBTemperature": .double(nil),
            "requestedWBTint": .double(nil),
            "observedDurationSeconds": .double(nil),
            "observedISO": .double(nil),
            "observedAperture": .double(nil),
            "observedFocalLengthMM": .double(nil),
            "observedOrientation": .int(nil),
            "observedFocusPosition": .double(nil),
            "observedFocusProvenance": .text(nil),
            "wbGainR": .double(nil),
            "wbGainG": .double(nil),
            "wbGainB": .double(nil),
            "wbProvenance": .text(nil),
            "equivalentFocalLengthMM": .double(nil),
            "cropGuide": .text(nil),
            "maxWidth": .int(nil),
            "maxHeight": .int(nil),
        ]
        try writeRow(values)
    }

    private static func isInGallery(_ classification: SourceClassification) -> Bool {
        if case .stagedExternal = classification { return false }
        return true
    }

    private static func countsAsCommittedOriginal(_ card: LibrarySourceCard) -> Bool {
        switch card.classification {
        case .verifiedOriginal, .recoveredRAW, .conflict: return true
        case .missingOriginal, .stagedExternal: return false
        }
    }

    private func writeRow(_ values: [String: SQLiteValue]) throws {
        let columns = Self.sourceColumns
        let placeholders = Array(repeating: "?", count: columns.count).joined(separator: ", ")
        let updates = columns.map { column -> String in
            if Self.preservedOnUpsert.contains(column) {
                return "\(column) = COALESCE(excluded.\(column), sources.\(column))"
            }
            return "\(column) = excluded.\(column)"
        }.joined(separator: ", ")
        let sql = """
        INSERT INTO sources (\(columns.joined(separator: ", "))) VALUES (\(placeholders))
        ON CONFLICT(identityKey) DO UPDATE SET \(updates)
        """
        let statement = try prepare(sql)
        defer { sqlite3_reset(statement) }
        let ordered = columns.map { values[$0] ?? .null }
        try Self.bind(statement, ordered)
        let step = sqlite3_step(statement)
        guard step == SQLITE_DONE else { throw statementError(sql, step) }
    }

    // MARK: - Reads

    private struct CardRow {
        var identityKey: String
        var captureID: String
        var libraryID: String
        var relativePath: String
        var capturedAtUTC: Date
        var capturedAtProvenance: String
        var availability: String
        var missingReason: String?
        var classification: String
        var rawWidth: Int?
        var rawHeight: Int?
        var byteCount: Int64?
        var sequenceID: String?
        var sequenceOrdinal: Int?
        var sequenceKind: String?
        var modificationFingerprint: String?
        var isTruongCamCapture: Bool
        var thumbnailKey: String?
    }

    private func readCardRow(_ statement: OpaquePointer) -> CardRow {
        CardRow(
            identityKey: Self.text(statement, 0) ?? "",
            captureID: Self.text(statement, 1) ?? "",
            libraryID: Self.text(statement, 2) ?? "",
            relativePath: Self.text(statement, 3) ?? "",
            capturedAtUTC: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
            capturedAtProvenance: Self.text(statement, 5) ?? CaptureTimeProvenance.requestTimestamp.rawValue,
            availability: Self.text(statement, 6) ?? "unknown",
            missingReason: Self.text(statement, 7),
            classification: Self.text(statement, 8) ?? "recoveredRAW",
            rawWidth: Self.optionalInt(statement, 9),
            rawHeight: Self.optionalInt(statement, 10),
            byteCount: Self.optionalInt64(statement, 11),
            sequenceID: Self.text(statement, 12),
            sequenceOrdinal: Self.optionalInt(statement, 13),
            sequenceKind: Self.text(statement, 14),
            modificationFingerprint: Self.text(statement, 15),
            isTruongCamCapture: sqlite3_column_int(statement, 16) != 0,
            thumbnailKey: nil)
    }

    private func sourceCard(from row: CardRow) throws -> LibrarySourceCard {
        let classification = Self.classification(from: row.classification, reason: row.missingReason)
        let availability = Self.availability(from: row.availability, reason: row.missingReason)
        let captureID = UUID(uuidString: row.captureID).map { CaptureID($0) }
            ?? LibraryStore.derivedIndexIdentity(for: row.relativePath)
        return LibrarySourceCard(
            captureID: captureID,
            libraryID: UUID(uuidString: row.libraryID).map { LibraryID($0) } ?? LibraryID(),
            relativeOriginalPath: row.relativePath,
            capturedAtUTC: row.capturedAtUTC,
            capturedAtProvenance: CaptureTimeProvenance(rawValue: row.capturedAtProvenance) ?? .requestTimestamp,
            availability: availability,
            classification: classification,
            rawDimensions: row.rawWidth.flatMap { width in
                row.rawHeight.map { PixelDimensions(width: width, height: $0) }
            },
            byteCount: row.byteCount,
            sequenceID: row.sequenceID.flatMap { UUID(uuidString: $0) }.map { SequenceID($0) },
            sequenceIndex: row.sequenceOrdinal,
            sequenceKind: row.sequenceKind.flatMap { SequenceKind(rawValue: $0) },
            isTruongCamCapture: row.isTruongCamCapture,
            modificationFingerprint: row.modificationFingerprint)
    }

    /// A sequence member collapses into one cover card; everything else is a
    /// single-source card.
    private func card(from row: CardRow) throws -> LibraryCard {
        let sourceCard = try sourceCard(from: row)
        if let sequenceID = sourceCard.sequenceID {
            let summary = try sequenceSummary(for: sequenceID, fallbackKind: sourceCard.sequenceKind)
            return LibraryCard(id: row.identityKey,
                               kind: .sequenceCover(summary, cover: sourceCard),
                               capturedAtUTC: summary.startedAtUTC,
                               representedOriginalCount: max(summary.committedCount, 1))
        }
        return LibraryCard(id: row.identityKey,
                           kind: .single(sourceCard),
                           capturedAtUTC: row.capturedAtUTC,
                           representedOriginalCount: 1)
    }

    /// `collapseSequences` is true for gallery pages, where every member of a
    /// sequence collapses into one cover card, and false for
    /// `sources(inSequence:)`, which must list every member.
    private func queryCards(whereClause: String,
                            bind values: [SQLiteValue],
                            orderAndLimit: String,
                            extraCursorBind: [SQLiteValue],
                            collapseSequences: Bool = true) throws -> [CardRow] {
        let sql = """
        SELECT \(Self.cardSelectColumns)
        \(collapseSequences ? Self.cardFrom : Self.memberFrom)
        \(whereClause)
        \(orderAndLimit)
        """
        let statement = try prepare(sql)
        defer { sqlite3_reset(statement) }
        try Self.bind(statement, values + extraCursorBind)
        var rows: [CardRow] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw statementError(sql, step) }
            rows.append(readCardRow(statement))
        }
        return rows
    }

    private func pageQuery(cursor: LibraryCursor?, size: Int) throws -> LibraryPage {
        try withDatabase { _ in
            if let cursor {
                guard cursor.libraryGeneration == self.generation,
                      cursor.indexRevision == self.indexRevision else {
                    throw LibraryIndexPagingError.expiredCursor
                }
            }
            let limit = max(1, min(size, MetadataBounds.maxIndexPageSize))
            var whereClause = ""
            var bindValues: [SQLiteValue] = []
            if let cursor {
                whereClause = "AND (s.capturedAtUTC < ? OR (s.capturedAtUTC = ? AND s.identityKey < ?))"
                bindValues = [
                    .double(cursor.capturedAtUTC.timeIntervalSince1970),
                    .double(cursor.capturedAtUTC.timeIntervalSince1970),
                    .text(cursor.tieBreaker),
                ]
            }
            let rows = try self.queryCards(
                whereClause: whereClause,
                bind: bindValues,
                orderAndLimit: "ORDER BY s.capturedAtUTC DESC, s.identityKey DESC LIMIT \(limit + 1)",
                extraCursorBind: [])
            let hasMore = rows.count > limit
            let visible = hasMore ? Array(rows.prefix(limit)) : rows
            let cards = try visible.map { try self.card(from: $0) }
            let nextCursor: LibraryCursor?
            if hasMore, let last = visible.last {
                nextCursor = LibraryCursor(capturedAtUTC: last.capturedAtUTC,
                                           tieBreaker: last.identityKey,
                                           libraryGeneration: self.generation,
                                           indexRevision: self.indexRevision)
            } else {
                nextCursor = nil
            }
            let total: Int? = cursor == nil ? try self.committedOriginalCount() : nil
            // A sequence cover is its first ordinal, not its newest photo. Keep
            // the camera shortcut correct without loading every sequence member
            // or decoding anything while reading the disposable index.
            let newest: LibrarySourceCard?
            if cursor == nil {
                let latest = try self.queryCards(whereClause: "", bind: [],
                    orderAndLimit: "ORDER BY s.capturedAtUTC DESC, s.identityKey DESC LIMIT 1",
                    extraCursorBind: [], collapseSequences: false)
                newest = try latest.first.map { try self.sourceCard(from: $0) }
            } else { newest = nil }
            return LibraryPage(cards: cards, nextCursor: nextCursor, libraryGeneration: self.generation,
                               indexedLibraryID: self.libraryID,
                               totalCommittedOriginalCount: total, newestOriginal: newest)
        }
    }

    private func sequenceSummary(for sequenceID: SequenceID, fallbackKind: SequenceKind?) throws -> SequenceSummary {
        let members = try memberStats(sequenceID: sequenceID)
        let stored = try storedSequence(sequenceID: sequenceID)
        let kind = stored?.kind ?? fallbackKind ?? .interval
        let plannedCount = stored?.plannedCount ?? ((members.maxOrdinal ?? -1) + 1)
        var missing = (stored?.missingIndices ?? []).filter { !members.indices.contains($0) }
        if stored == nil {
            missing = (0..<max(plannedCount, 0)).filter { !members.indices.contains($0) }
        }
        let failed = stored?.failedIndices ?? []
        var status = stored?.status ?? .interrupted
        if status == .complete {
            if members.count != plannedCount || !missing.isEmpty || !failed.isEmpty {
                status = .interrupted
            }
        }
        return SequenceSummary(
            sequenceID: sequenceID,
            kind: kind,
            plannedCount: plannedCount,
            committedCount: members.count,
            missingIndices: missing.sorted(),
            failedIndices: failed.sorted(),
            skippedDeadlineCount: stored?.skippedDeadlineCount ?? 0,
            status: status,
            startedAtUTC: stored?.startedAtUTC ?? members.earliest ?? Date(timeIntervalSince1970: 0))
    }

    private struct MemberStats {
        var count = 0
        var maxOrdinal: Int?
        var earliest: Date?
        var indices: Set<Int> = []
    }

    private func memberStats(sequenceID: SequenceID) throws -> MemberStats {
        let sql = """
        SELECT COUNT(*), MAX(s.sequenceOrdinal), MIN(s.capturedAtUTC), GROUP_CONCAT(s.sequenceOrdinal)
        FROM sources s WHERE s.sequenceID = ? AND s.countsAsCommittedOriginal = 1
        """
        let statement = try prepare(sql)
        defer { sqlite3_reset(statement) }
        try Self.bind(statement, [.text(sequenceID.description)])
        let step = sqlite3_step(statement)
        guard step == SQLITE_ROW else {
            if step == SQLITE_DONE { return MemberStats() }
            throw statementError(sql, step)
        }
        var stats = MemberStats()
        stats.count = Int(sqlite3_column_int64(statement, 0))
        stats.maxOrdinal = Self.optionalInt(statement, 1)
        if let earliest = Self.optionalDouble(statement, 2) {
            stats.earliest = Date(timeIntervalSince1970: earliest)
        }
        stats.indices = Set(Self.decodeIndices(Self.text(statement, 3)))
        return stats
    }

    private struct StoredSequence {
        var kind: SequenceKind
        var plannedCount: Int
        var missingIndices: [Int]
        var failedIndices: [Int]
        var skippedDeadlineCount: Int
        var status: SequenceStatus
        var startedAtUTC: Date
    }

    private func storedSequence(sequenceID: SequenceID) throws -> StoredSequence? {
        let statement = try prepare("""
        SELECT kind, plannedCount, missingIndices, failedIndices, skippedDeadlineCount, status, startedAtUTC
        FROM sequences WHERE sequenceID = ?
        """)
        defer { sqlite3_reset(statement) }
        try Self.bind(statement, [.text(sequenceID.description)])
        let step = sqlite3_step(statement)
        if step == SQLITE_DONE { return nil }
        guard step == SQLITE_ROW else { throw statementError("SELECT sequences", step) }
        return StoredSequence(
            kind: Self.text(statement, 0).flatMap { SequenceKind(rawValue: $0) } ?? .interval,
            plannedCount: Int(sqlite3_column_int64(statement, 1)),
            missingIndices: Self.decodeIndices(Self.text(statement, 2)),
            failedIndices: Self.decodeIndices(Self.text(statement, 3)),
            skippedDeadlineCount: Int(sqlite3_column_int64(statement, 4)),
            status: Self.text(statement, 5).flatMap { SequenceStatus(rawValue: $0) } ?? .interrupted,
            startedAtUTC: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)))
    }

    private func detailRow(from statement: OpaquePointer) throws -> IndexedSourceDetail {
        var row = readCardRow(statement)
        row.thumbnailKey = Self.text(statement, 17)
        let sourceCard = try sourceCard(from: row)
        return IndexedSourceDetail(
            card: sourceCard,
            byteCount: row.byteCount,
            modificationFingerprint: row.modificationFingerprint,
            thumbnailKey: row.thumbnailKey,
            deviceModel: Self.text(statement, 18),
            osVersion: Self.text(statement, 19),
            cameraDeviceType: Self.text(statement, 20),
            formatKind: Self.text(statement, 21),
            rawPixelFormat: Self.optionalInt(statement, 22).map { UInt32($0) },
            requestedExposureMode: Self.text(statement, 23),
            requestedDurationSeconds: Self.optionalDouble(statement, 24),
            requestedISO: Self.optionalDouble(statement, 25),
            requestedBiasEV: Self.optionalDouble(statement, 26),
            requestedFocusMode: Self.text(statement, 27),
            requestedFocusPosition: Self.optionalDouble(statement, 28),
            requestedWhiteBalanceMode: Self.text(statement, 29),
            requestedWhiteBalanceTemperatureKelvin: Self.optionalDouble(statement, 30),
            requestedWhiteBalanceTint: Self.optionalDouble(statement, 31),
            observedDurationSeconds: Self.optionalDouble(statement, 32),
            observedISO: Self.optionalDouble(statement, 33),
            observedAperture: Self.optionalDouble(statement, 34),
            observedFocalLengthMM: Self.optionalDouble(statement, 35),
            observedOrientation: Self.optionalInt(statement, 36),
            observedFocusPosition: Self.optionalDouble(statement, 37),
            observedFocusProvenance: Self.text(statement, 38),
            whiteBalanceGainRed: Self.optionalDouble(statement, 39),
            whiteBalanceGainGreen: Self.optionalDouble(statement, 40),
            whiteBalanceGainBlue: Self.optionalDouble(statement, 41),
            whiteBalanceProvenance: Self.text(statement, 42),
            equivalentFocalLengthMM: Self.optionalDouble(statement, 43),
            cropGuide: Self.text(statement, 44),
            requestedMaxWidth: Self.optionalInt(statement, 45),
            requestedMaxHeight: Self.optionalInt(statement, 46))
    }
}

extension Array {
    /// Bounded batches: the index never builds one unbounded statement.
    func tcChunked(into size: Int) -> [[Element]] {
        guard size > 0, !isEmpty else { return isEmpty ? [] : [self] }
        var chunks: [[Element]] = []
        var index = 0
        while index < count {
            let end = Swift.min(index + size, count)
            chunks.append(Array(self[index..<end]))
            index = end
        }
        return chunks
    }
}
