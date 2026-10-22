import Foundation

// Native test bundles read the app's real types through the module; the
// standalone verifier compiles the app sources into the same executable and
// therefore cannot import a module. XCTest is only available in the native
// bundle, so it gates the import.
#if canImport(XCTest)
@testable import TruongCam
#endif


// TEST_PLAN.md T17/T18/T19/T39: schema version handling, malformed metadata,
// explicit nulls, semantic validation and unknown-field tolerance.

enum MetadataSchemaSuite {
    static let suite = TCSuite(
        id: "T17-T19",
        title: "Portable metadata schema read/write and semantic validation",
        cases: [
            TCCase(id: "T17a", title: "Library manifest round-trips with localOnly policy") { r in
                let manifest = LibraryManifest(libraryID: LibraryID(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!),
                                               createdAtUTC: Date(timeIntervalSince1970: 1_790_000_000))
                let writer = PortableJSONWriter()
                guard let data = try? writer.encode(manifest, explicitNullKeys: []) else {
                    r.check("encode", false, "manifest failed to encode"); return
                }
                let reader = PortableJSONReader()
                guard let decoded = try? reader.decode(LibraryManifest.self, from: data, limitBytes: 4096) else {
                    r.check("decode", false, String(decoding: data, as: UTF8.self)); return
                }
                r.equal("schema version", decoded.schemaVersion, 1)
                r.equal("application", decoded.application, "TruongCam")
                r.check("declares local-only", decoded.declaresLocalOnly)
                r.equal("library id preserved", decoded.declaredLibraryID, manifest.declaredLibraryID)
                let text = String(decoding: data, as: UTF8.self)
                r.check("no NaN token", !text.lowercased().contains("nan"))
            },

            TCCase(id: "T17b", title: "A newer major schema is detected and never migrated") { r in
                let future = """
                {"schemaVersion": 2, "libraryID": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
                 "createdAtUTC": "2026-10-06T12:00:00Z", "application": "TruongCam",
                 "storagePolicy": "localOnly"}
                """
                let data = Data(future.utf8)
                let major = try? PortableJSONReader.peekMajorVersion(in: data)
                r.equal("major version peeked", major ?? nil, 2)
                r.check("version 2 exceeds supported 1",
                        (major ?? nil ?? 0) > truongCamSupportedSchemaVersion)
            },

            TCCase(id: "T17c", title: "Malformed and oversized metadata is rejected safely") { r in
                let reader = PortableJSONReader()
                let malformed = Data("{ not json".utf8)
                var malformedThrew = false
                do { _ = try reader.decode(LibraryManifest.self, from: malformed, limitBytes: 4096) }
                catch { malformedThrew = true }
                r.check("malformed JSON rejected", malformedThrew)

                let oversized = Data(repeating: 0x20, count: 5000)
                var oversizedThrew = false
                do { _ = try reader.decode(LibraryManifest.self, from: oversized, limitBytes: 4096) }
                catch let error as PortableJSONError {
                    if case .payloadTooLarge = error { oversizedThrew = true }
                } catch { }
                r.check("oversized payload rejected before decoding", oversizedThrew)

                // Unknown additional fields must be ignored, not fatal.
                let withExtras = """
                {"schemaVersion": 1, "libraryID": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
                 "createdAtUTC": "2026-10-06T12:00:00Z", "application": "TruongCam",
                 "storagePolicy": "localOnly", "futureField": {"nested": [1,2,3]},
                 "anotherUnknown": "ignored"}
                """
                let decoded = try? reader.decode(LibraryManifest.self, from: Data(withExtras.utf8), limitBytes: 4096)
                r.check("unknown fields ignored", decoded != nil)
                r.equal("known field still read", decoded?.application, "TruongCam")
            },

            TCCase(id: "T17d", title: "Non-finite numbers never reach JSON") { r in
                let writer = PortableJSONWriter()
                struct Payload: Encodable { let iso: Double }
                var threw = false
                do { _ = try writer.encode(Payload(iso: .nan), explicitNullKeys: []) }
                catch { threw = true }
                r.check("NaN payload rejected", threw)

                var infThrew = false
                do { _ = try writer.encode(Payload(iso: .infinity), explicitNullKeys: []) }
                catch { infThrew = true }
                r.check("Infinity payload rejected", infThrew)

                let finite = try? writer.encode(Payload(iso: 400), explicitNullKeys: [])
                r.check("finite payload encodes", finite != nil)
            },

            TCCase(id: "T17e", title: "Source sidecar writes schema-required explicit nulls") { r in
                let sidecar = MetadataFixtures.minimalSourceSidecar()
                let writer = PortableJSONWriter()
                guard let data = try? writer.encode(
                    sidecar, explicitNullKeys: SourceSidecar.explicitNullKeyPaths) else {
                    r.check("encode", false, "sidecar failed to encode"); return
                }
                let text = String(decoding: data, as: UTF8.self)
                // The schema requires these keys to be present, possibly null.
                r.check("observed.durationSeconds present", text.contains("\"durationSeconds\""))
                r.check("observed.iso key present", text.contains("\"iso\""))
                r.check("sequence key present", text.contains("\"sequence\""))
                r.check("tint key present", text.contains("\"tint\""))

                guard let decoded = try? PortableJSONReader().decode(
                    SourceSidecar.self, from: data,
                    limitBytes: MetadataBounds.maxSourceSidecarUTF8Bytes) else {
                    r.check("round trip decode", false); return
                }
                r.equal("capture id preserved", decoded.captureID, sidecar.captureID)
                r.check("bayer declaration preserved", decoded.format.isBayerRAWDeclaration)
                r.equal("unknown optional stays nil, not zero", decoded.observed.iso, nil)
                r.equal("captured-at provenance preserved",
                        decoded.capturedAtProvenance, sidecar.capturedAtProvenance)
            },

            TCCase(id: "T19a", title: "Semantic validation catches integrity and identity problems") { r in
                let validator = SourceSidecarSemanticValidator()

                r.check("valid sidecar passes",
                        validator.validate(MetadataFixtures.minimalSourceSidecar()).isEmpty)

                var badPath = MetadataFixtures.minimalSourceSidecar()
                badPath.relativeOriginalPath = "../outside.dng"
                r.check("traversal path flagged",
                        validator.validate(badPath).contains { $0.contains("path") })

                var zeroBytes = MetadataFixtures.minimalSourceSidecar()
                zeroBytes.byteCount = 0
                r.check("zero byte count flagged",
                        validator.validate(zeroBytes).contains { $0.contains("byteCount") })

                var badHash = MetadataFixtures.minimalSourceSidecar()
                badHash.sha256 = String(repeating: "0", count: 64)
                // A zero placeholder hash is structurally valid but is explicitly
                // synthetic: it must be reported, never treated as integrity proof.
                r.check("placeholder checksum flagged as synthetic",
                        validator.validate(badHash).contains { $0.contains("synthetic") })

                var notBayer = MetadataFixtures.minimalSourceSidecar()
                notBayer.format = SourceFormatRecord(rawPixelFormat: 0)
                notBayer.format.kind = "processed"
                r.check("non-Bayer format flagged",
                        validator.validate(notBayer).contains { $0.contains("bayer") })

                var badDimensions = MetadataFixtures.minimalSourceSidecar()
                badDimensions.observed.rawDimensions = PixelDimensions(width: 0, height: 0)
                r.check("zero RAW dimensions flagged",
                        validator.validate(badDimensions).contains { $0.contains("rawDimensions") })

                var nonFiniteExposure = MetadataFixtures.minimalSourceSidecar()
                nonFiniteExposure.requested.exposure.iso = .nan
                r.check("NaN requested ISO flagged",
                        validator.validate(nonFiniteExposure).contains { $0.contains("iso") })
            },

            TCCase(id: "T19b", title: "Sequence semantic validation enforces ordinal and completeness rules") { r in
                let validator = SequenceDocumentSemanticValidator()
                let valid = MetadataFixtures.completeBracketSequence()
                r.check("complete bracket passes", validator.validate(valid).isEmpty)

                var ordinalOutOfRange = MetadataFixtures.completeBracketSequence()
                ordinalOutOfRange.completedSources = [
                    SequenceCompletedSource(index: 5, captureID: UUID())
                ]
                r.check("ordinal beyond plannedCount flagged",
                        validator.validate(ordinalOutOfRange).contains { $0.contains("index") })

                var duplicateOrdinal = MetadataFixtures.completeBracketSequence()
                duplicateOrdinal.completedSources.append(
                    SequenceCompletedSource(index: 0, captureID: UUID()))
                r.check("duplicate ordinal flagged",
                        validator.validate(duplicateOrdinal).contains { $0.contains("duplicate") })

                var completeButMissing = MetadataFixtures.completeBracketSequence()
                completeButMissing.missingIndices = [1]
                r.check("complete status with a missing ordinal flagged",
                        validator.validate(completeButMissing).contains { $0.contains("missing") })

                var intervalWrongCount = MetadataFixtures.completeIntervalSequence(retained: 2, planned: 3)
                r.check("interval complete without full retained count flagged",
                        validator.validate(intervalWrongCount).contains { $0.contains("plannedCount") })

                intervalWrongCount.completedSources.append(
                    SequenceCompletedSource(index: 2, captureID: UUID()))
                r.check("interval complete with full retained count passes",
                        validator.validate(intervalWrongCount).isEmpty)

                var failedAlsoCompleted = MetadataFixtures.completeBracketSequence()
                failedAlsoCompleted.failedIndices = [0]
                r.check("ordinal both failed and completed flagged",
                        validator.validate(failedAlsoCompleted).contains { $0.contains("failed") })

                var badPlan = MetadataFixtures.completeBracketSequence()
                badPlan.plannedCount = 3
                badPlan.sourcePlan = [SequenceSourcePlanEntry(index: 0, offsetEV: -1, focusPosition: nil)]
                r.check("plan index count mismatch flagged",
                        validator.validate(badPlan).contains { $0.contains("sourcePlan") })
            },

            TCCase(id: "T39", title: "Unknown optional values are omitted, never zero-filled") { r in
                let sidecar = MetadataFixtures.minimalSourceSidecar()
                r.equal("focus position unknown", sidecar.observed.focus?.position, nil)
                r.equal("WB gains unknown", sidecar.observed.whiteBalance?.gains, nil)
                r.equal("orientation unknown", sidecar.observed.orientation, nil)
                r.equal("focus provenance is explicit", sidecar.observed.focus?.provenance, .unknown)
                r.equal("WB provenance is explicit", sidecar.observed.whiteBalance?.provenance, .unknown)
                r.equal("sequence link omitted", sidecar.sequence, nil)
                r.equal("equivalent focal length omitted", sidecar.ui?.equivalentFocalLengthMM, nil)
                // Mandatory truth is still present.
                r.check("RAW dimensions known", sidecar.observed.rawDimensions != nil)
                r.equal("capture-time provenance is not fabricated",
                        sidecar.capturedAtProvenance, .requestTimestamp)
            },
        ])
}
