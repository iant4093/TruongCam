import Foundation

extension ExposureRequestRecord {
    /// Optional request-only fields introduced for variable-aperture cameras.
    /// Source EXIF is validated independently and is never filled from a target.
    func apertureValidationProblems(context: String) -> [String] {
        var problems: [String] = []
        if let aperture, !aperture.isFinite || aperture <= 0 {
            problems.append("\(context) aperture must be positive and finite")
        }
        switch apertureMode {
        case nil:
            if aperture != nil { problems.append("\(context) aperture requires an apertureMode") }
        case "auto":
            if aperture != nil { problems.append("\(context) auto aperture must not carry a numeric target") }
        case "manual":
            if aperture == nil { problems.append("\(context) manual aperture requires a numeric target") }
        default:
            problems.append("\(context) apertureMode must be auto or manual when present")
        }
        return problems
    }
}

// schemas/README.md: "use native Codable plus explicit runtime validation in the
// iOS app". These validators enforce the semantic rules that JSON Schema cannot
// express. They never mutate data and never attempt a migration.

/// Semantic validation of a per-source sidecar.
struct SourceSidecarSemanticValidator: Sendable {
    init() {}

    func validate(_ sidecar: SourceSidecar) -> [String] {
        var problems: [String] = []

        if sidecar.schemaVersion != truongCamSupportedSchemaVersion {
            problems.append("schemaVersion \(sidecar.schemaVersion) is not the supported \(truongCamSupportedSchemaVersion)")
        }

        // Path safety and dated-filename shape.
        do {
            try PathSafety.validateRelativePath(sidecar.relativeOriginalPath)
        } catch {
            problems.append("path is not a safe relative path: \(error)")
        }
        if !sidecar.relativeOriginalPath.hasPrefix(LibraryLayout.originalsDirectoryName + "/") {
            problems.append("path is not beneath the originals directory")
        }
        let expectedName = LibraryLayout.originalFileName(for: CaptureID(sidecar.captureID), format: sidecar.format)
        if !sidecar.relativeOriginalPath.hasSuffix(expectedName) {
            problems.append("path filename does not match the capture UUID")
        }

        // Integrity fields.
        if sidecar.byteCount <= 0 {
            problems.append("byteCount must be positive (got \(sidecar.byteCount))")
        }
        if SHA256Digest(hex: sidecar.sha256) == nil {
            problems.append("sha256 is not 64 lowercase hex characters")
        } else if sidecar.sha256 == String(repeating: "0", count: 64) {
            problems.append("sha256 is the synthetic zero placeholder and cannot prove integrity")
        }

        // Bayer truth must be declared consistently.
        if !sidecar.format.isBayerRAWDeclaration && !sidecar.format.isJPEGDeclaration
            && !(sidecar.format.isHEIFDeclaration && sidecar.cameraDeviceType == "front") {
            problems.append("format does not declare a bayer RAW capture")
        }
        if sidecar.format.isBayerRAWDeclaration && sidecar.format.rawPixelFormat == 0 {
            problems.append("bayer pixel format 0 is not a valid Bayer four-character code")
        }

        // Observed RAW dimensions come from RAW capture truth, never from a
        // preview or thumbnail.
        if let dimensions = sidecar.observed.rawDimensions {
            if !dimensions.isValid {
                problems.append("rawDimensions must be positive integers")
            }
        } else {
            problems.append("rawDimensions is required for a Bayer source")
        }

        // Finite numbers before any value can reach a native setter.
        if let iso = sidecar.requested.exposure.iso, !iso.isFinite || iso <= 0 {
            problems.append("requested exposure iso must be a positive finite number")
        }
        if let duration = sidecar.requested.exposure.durationSeconds, !duration.isFinite || duration <= 0 {
            problems.append("requested durationSeconds must be a positive finite number")
        }
        if !sidecar.requested.exposure.biasEV.isFinite {
            problems.append("requested biasEV must be finite")
        }
        problems.append(contentsOf: sidecar.requested.exposure.apertureValidationProblems(context: "requested exposure"))
        if let iso = sidecar.observed.iso, !iso.isFinite || iso <= 0 {
            problems.append("observed iso must be positive and finite when present")
        }
        if let duration = sidecar.observed.durationSeconds, !duration.isFinite || duration <= 0 {
            problems.append("observed durationSeconds must be positive and finite when present")
        }
        if let aperture = sidecar.observed.aperture, !aperture.isFinite || aperture <= 0 {
            problems.append("observed aperture must be positive and finite when present")
        }
        if let focal = sidecar.observed.focalLengthMM, !focal.isFinite || focal <= 0 {
            problems.append("observed focalLengthMM must be positive and finite when present")
        }
        if let orientation = sidecar.observed.orientation, !(1...8).contains(orientation) {
            problems.append("observed orientation must be in 1...8")
        }
        if let position = sidecar.observed.focus?.position, !position.isFinite || position < 0 || position > 1 {
            problems.append("observed focus position must be finite and within 0...1")
        }
        if let gains = sidecar.observed.whiteBalance?.gains, !gains.isFinite {
            problems.append("observed white balance gains must be finite")
        }
        if let kelvin = sidecar.requested.whiteBalance.temperatureKelvin,
           !kelvin.isFinite || kelvin <= 0 {
            problems.append("requested white balance temperature must be positive and finite")
        }
        if let tint = sidecar.requested.whiteBalance.tint, !tint.isFinite {
            problems.append("requested white balance tint must be finite")
        }

        // Exposure-case shape: the case decides which targets are present.
        switch sidecar.requested.exposure.mode {
        case .auto:
            if sidecar.requested.exposure.durationSeconds != nil || sidecar.requested.exposure.iso != nil {
                problems.append("auto exposure must not carry manual duration or ISO targets")
            }
        case .shutterPriority:
            if sidecar.requested.exposure.durationSeconds == nil {
                problems.append("shutter priority requires a duration target")
            }
            if sidecar.requested.exposure.iso != nil {
                problems.append("shutter priority must not carry an ISO target")
            }
        case .isoPriority:
            if sidecar.requested.exposure.iso == nil {
                problems.append("ISO priority requires an ISO target")
            }
            if sidecar.requested.exposure.durationSeconds != nil {
                problems.append("ISO priority must not carry a duration target")
            }
        case .manual:
            if sidecar.requested.exposure.durationSeconds == nil || sidecar.requested.exposure.iso == nil {
                problems.append("manual exposure requires both duration and ISO targets")
            }
        }

        // Focus-case shape.
        switch sidecar.requested.focus.mode {
        case .manual:
            if let position = sidecar.requested.focus.position {
                if !position.isFinite || position < 0 || position > 1 {
                    problems.append("manual focus position must be finite and within 0...1")
                }
            } else {
                problems.append("manual focus requires a position target")
            }
        case .continuousAuto, .lockedAuto:
            break
        }

        // WB-case shape.
        switch sidecar.requested.whiteBalance.mode {
        case .manual:
            if sidecar.requested.whiteBalance.temperatureKelvin == nil || sidecar.requested.whiteBalance.tint == nil {
                problems.append("manual white balance requires both temperature and tint targets")
            }
        case .auto:
            break
        }

        // Sequence membership must be consistent.
        if let sequence = sidecar.sequence {
            if sequence.index < 0 || sequence.index >= sequence.plannedCount {
                problems.append("sequence index must be within 0..<plannedCount")
            }
            if sequence.plannedCount < 1 || sequence.plannedCount > MetadataBounds.maxSequenceSources {
                problems.append("sequence plannedCount is outside the supported bound")
            }
            if let offset = sequence.requestedOffsetEV, !offset.isFinite {
                problems.append("sequence requestedOffsetEV must be finite")
            }
            if let offset = sequence.actualOffsetEV, !offset.isFinite {
                problems.append("sequence actualOffsetEV must be finite")
            }
            if let ordinal = sequence.deadlineOrdinal, ordinal < 0 {
                problems.append("sequence deadlineOrdinal must be non-negative")
            }
        }

        // Diagnostic string bounds.
        if sidecar.deviceModel.utf8.count > MetadataBounds.maxDeviceModelLength {
            problems.append("deviceModel exceeds the supported length")
        }
        if sidecar.osVersion.utf8.count > MetadataBounds.maxDeviceModelLength {
            problems.append("osVersion exceeds the supported length")
        }
        if sidecar.cameraDeviceType.utf8.count > MetadataBounds.maxDeviceModelLength {
            problems.append("cameraDeviceType exceeds the supported length")
        }

        return problems
    }

    /// Non-blocking status reminders. Kept in a separate channel so a status note
    /// can never be mistaken for a defect (and vice versa). A source with
    /// `partialWithRetainedSource` is a valid, retained source; the sequence as a
    /// whole simply cannot be reported complete until the terminal error is
    /// resolved.
    func notices(_ sidecar: SourceSidecar) -> [String] {
        var notices: [String] = []
        if sidecar.acquisitionStatus == .partialWithRetainedSource {
            notices.append(
                "This source was retained from a request whose terminal callback reported an error; the sequence cannot be reported complete until that error is resolved.")
        }
        return notices
    }

    /// Convenience: everything a caller may want to surface, tagged so a status
    /// note can never be treated as a blocking problem.
    func report(_ sidecar: SourceSidecar) -> SourceValidationReport {
        SourceValidationReport(problems: validate(sidecar), notices: notices(sidecar))
    }
}

/// Blocking problems and non-blocking status notices, kept separate.
struct SourceValidationReport: Hashable, Sendable {
    let problems: [String]
    let notices: [String]

    var isCommittable: Bool { problems.isEmpty }
}

/// Semantic validation of a sequence document.
struct SequenceDocumentSemanticValidator: Sendable {
    init() {}

    func validate(_ document: SequenceDocument) -> [String] {
        var problems: [String] = []

        if document.schemaVersion != truongCamSupportedSchemaVersion {
            problems.append("schemaVersion \(document.schemaVersion) is not supported")
        }
        if document.plannedCount < 1 || document.plannedCount > MetadataBounds.maxSequenceSources {
            problems.append("plannedCount is outside the supported bound")
            // Never form ranges or allocate from a rejected untrusted count.
            return problems
        }

        let completedIndices = document.completedSources.map(\.index)
        if Set(completedIndices).count != completedIndices.count {
            problems.append("duplicate completed index present")
        }
        let completedIDs = document.completedSources.map(\.captureID)
        if Set(completedIDs).count != completedIDs.count {
            problems.append("duplicate completed capture UUID present")
        }
        for entry in document.completedSources where entry.index < 0 || entry.index >= document.plannedCount {
            problems.append("completed index \(entry.index) is outside 0..<plannedCount")
        }
        let completedSet = Set(completedIndices)
        let missingSet = Set(document.missingIndices)
        let failedSet = Set(document.failedIndices)
        if !completedSet.isDisjoint(with: failedSet) {
            problems.append("an ordinal is both completed and failed")
        }
        if !completedSet.isDisjoint(with: missingSet) {
            problems.append("an ordinal is both completed and missing")
        }
        if completedSet.count + missingSet.count + failedSet.count > document.plannedCount {
            problems.append("completed, missing and failed ordinals overlap beyond plannedCount")
        }
        if document.missingIndices.contains(where: { $0 < 0 || $0 >= document.plannedCount }) {
            problems.append("a missing index is outside 0..<plannedCount")
        }
        if document.failedIndices.contains(where: { $0 < 0 || $0 >= document.plannedCount }) {
            problems.append("a failed index is outside 0..<plannedCount")
        }

        // Plan shape: brackets enumerate every ordinal; interval may leave the
        // plan empty and specify a cadence instead.
        switch document.kind {
        case .exposureBracket, .focusBracket:
            if document.sourcePlan.count != document.plannedCount {
                problems.append("sourcePlan must cover every ordinal for a bracket (plannedCount \(document.plannedCount), sourcePlan \(document.sourcePlan.count))")
            }
            let planIndices = Set(document.sourcePlan.map(\.index))
            if planIndices != Set(0..<document.plannedCount) {
                problems.append("sourcePlan indices must be exactly 0..<plannedCount")
            }
        case .interval:
            if let interval = document.intervalSeconds {
                if !interval.isFinite || interval <= 0 {
                    problems.append("intervalSeconds must be a positive finite number")
                }
            } else {
                problems.append("an interval sequence must record intervalSeconds")
            }
        }

        if document.skippedDeadlineCount < 0 {
            problems.append("skippedDeadlineCount must be non-negative")
        }

        // Completion rules: exactly plannedCount committed sources, nothing
        // missing or failed, and no unresolved acquisition error.
        if document.status == .complete {
            if completedSet.count != document.plannedCount {
                problems.append("complete status requires exactly plannedCount committed sources")
            }
            if !missingSet.isEmpty {
                problems.append("complete status cannot have missing ordinals")
            }
            if !failedSet.isEmpty {
                problems.append("complete status cannot have failed ordinals")
            }
            if let summary = document.errorSummary, !summary.isEmpty {
                problems.append("complete status cannot carry an unresolved error summary")
            }
            if document.endedAtUTC == nil {
                problems.append("complete status requires endedAtUTC")
            }
        }

        if document.status == .running && document.endedAtUTC != nil {
            problems.append("running status must not have endedAtUTC")
        }
        if document.status != .running && document.endedAtUTC == nil {
            problems.append("a terminal sequence must record endedAtUTC")
        }

        if let summary = document.errorSummary, summary.utf8.count > MetadataBounds.maxStringFieldLength {
            problems.append("errorSummary exceeds the supported length")
        }

        if let baseline = document.baseline {
            if !baseline.maxDimensions.isValid {
                problems.append("baseline maxDimensions must be positive")
            }
            if !baseline.exposure.biasEV.isFinite {
                problems.append("baseline biasEV must be finite")
            }
            problems.append(contentsOf: baseline.exposure.apertureValidationProblems(context: "baseline exposure"))
            switch baseline.exposure.mode {
            case .auto:
                if baseline.exposure.iso != nil || baseline.exposure.durationSeconds != nil {
                    problems.append("auto baseline must not freeze numeric duration or ISO")
                }
            case .shutterPriority:
                if baseline.exposure.durationSeconds == nil {
                    problems.append("shutter-priority baseline requires a duration")
                }
            case .isoPriority:
                if baseline.exposure.iso == nil {
                    problems.append("ISO-priority baseline requires an ISO value")
                }
            case .manual:
                if baseline.exposure.durationSeconds == nil || baseline.exposure.iso == nil {
                    problems.append("manual baseline requires duration and ISO")
                }
            }
        }

        return problems
    }
}
