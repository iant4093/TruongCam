import Foundation

// Portable JSON coding for the v1 integration contract.
//
// schemas/source.schema.json and schemas/sequence.schema.json require several
// nullable fields to be *present* (possibly `null`); Swift's synthesized Codable
// omits nil optionals instead. Unknown additional fields are ignored on read.
// JSON must never contain NaN or Infinity, and non-finite input is rejected
// before a value can reach a native setter.

enum PortableJSONError: Error, Hashable, Sendable, CustomStringConvertible {
    case payloadTooLarge(actualBytes: Int, limitBytes: Int)
    case nonFiniteNumber(field: String)
    case malformedJSON(String)
    case unsupportedMajorSchema(found: Int, supported: Int)
    case missingRequiredField(String)
    case semanticValidation([String])

    var description: String {
        switch self {
        case .payloadTooLarge(let a, let l):
            return "Metadata payload is \(a) bytes, above the \(l)-byte bound."
        case .nonFiniteNumber(let f):
            return "Field \(f) was NaN or Infinity; JSON must contain only finite numbers."
        case .malformedJSON(let d):
            return "Metadata JSON could not be decoded: \(d)"
        case .unsupportedMajorSchema(let f, let s):
            return "Metadata schemaVersion \(f) is newer than the supported version \(s); opened read-only."
        case .missingRequiredField(let f):
            return "Metadata is missing the required field \(f)."
        case .semanticValidation(let problems):
            return "Metadata failed semantic validation: \(problems.joined(separator: "; "))"
        }
    }
}

/// A JSON encoder that (a) uses ISO-8601 UTC dates, (b) refuses non-finite
/// numbers up front, and (c) writes `null` for the keys listed by the caller so
/// the emitted document matches the checked-in schemas.
struct PortableJSONWriter {
    private let encoder: JSONEncoder

    init() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(PortableJSONWriter.iso8601.string(from: date))
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder
    }

    static let iso8601 = ISO8601Coding.shared

    /// Encodes a document, then re-parses it to insert explicit nulls for the
    /// requested dotted key paths and to verify the payload is finite.
    func encode<T: Encodable>(_ value: T, explicitNullKeys: [String]) throws -> Data {
        let data: Data
        do {
            data = try encoder.encode(value)
        } catch let error as EncodingError {
            throw PortableJSONWriter.classifyEncodingError(error)
        }
        guard explicitNullKeys.isEmpty else {
            return try PortableJSONWriter.insertingExplicitNulls(into: data, keys: explicitNullKeys)
        }
        try PortableJSONWriter.assertFiniteNumbers(in: data)
        return data
    }

    static func classifyEncodingError(_ error: EncodingError) -> PortableJSONError {
        if case .invalidValue(_, let context) = error {
            return .nonFiniteNumber(field: context.codingPath.map(\.stringValue).joined(separator: "."))
        }
        return .malformedJSON(error.localizedDescription)
    }

    /// Walks the encoded object tree and inserts `null` for any listed top-level
    /// or nested key that is absent.
    static func insertingExplicitNulls(into data: Data, keys: [String]) throws -> Data {
        let object = try jsonObject(from: data)
        guard var root = object as? [String: Any] else {
            throw PortableJSONError.malformedJSON("root is not a JSON object")
        }
        for key in keys {
            insertNull(path: key.split(separator: ".").map(String.init), into: &root)
        }
        let out = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try assertFiniteNumbers(in: out)
        return out
    }

    private static func insertNull(path: [String], into object: inout [String: Any]) {
        guard let head = path.first else { return }
        if path.count == 1 {
            if object[head] == nil { object[head] = NSNull() }
            return
        }
        guard var child = object[head] as? [String: Any] else {
            // Only recurse into containers that exist; absent parents stay absent.
            return
        }
        insertNull(path: Array(path.dropFirst()), into: &child)
        object[head] = child
    }

    static func jsonObject(from data: Data) throws -> Any {
        do {
            return try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw PortableJSONError.malformedJSON((error as NSError).localizedDescription)
        }
    }

    /// Rejects NaN/Infinity anywhere in the encoded document by walking the
    /// parsed numeric values. A textual scan would false-positive on ordinary
    /// words (for example a key containing "inf"), so the check is structural.
    static func assertFiniteNumbers(in data: Data) throws {
        let object = try jsonObject(from: data)
        try assertFiniteNumbers(inObject: object, path: "<root>")
    }

    private static func assertFiniteNumbers(inObject object: Any, path: String) throws {
        switch object {
        case let number as NSNumber:
            // `NSNumber` bridges booleans too; only inspect the double value of
            // real numbers.
            let type = String(cString: number.objCType)
            if type != "c" && type != "B" {
                let value = number.doubleValue
                if !value.isFinite {
                    throw PortableJSONError.nonFiniteNumber(field: path)
                }
            }
        case let dictionary as [String: Any]:
            for (key, value) in dictionary {
                try assertFiniteNumbers(inObject: value, path: "\(path).\(key)")
            }
        case let array as [Any]:
            for (index, value) in array.enumerated() {
                try assertFiniteNumbers(inObject: value, path: "\(path)[\(index)]")
            }
        default:
            break
        }
    }
}

/// A JSON decoder that accepts only supported major versions and bounds its
/// input size before decoding.
struct PortableJSONReader {
    private let decoder: JSONDecoder

    init() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = PortableJSONWriter.iso8601.date(from: text) else {
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "Not an ISO-8601 UTC timestamp: \(text)")
            }
            return date
        }
        self.decoder = decoder
    }

    func decode<T: Decodable>(_ type: T.Type, from data: Data, limitBytes: Int) throws -> T {
        guard data.count <= limitBytes else {
            throw PortableJSONError.payloadTooLarge(actualBytes: data.count, limitBytes: limitBytes)
        }
        do {
            return try decoder.decode(type, from: data)
        } catch let error as DecodingError {
            throw PortableJSONError.malformedJSON(Self.describe(error))
        }
    }

    /// Reads only `schemaVersion` so a newer major version can be detected and
    /// reported as read-only without attempting a migration.
    static func peekMajorVersion(in data: Data) throws -> Int? {
        let object = try PortableJSONWriter.jsonObject(from: data)
        guard let dict = object as? [String: Any] else { return nil }
        return dict["schemaVersion"] as? Int
    }

    static func describe(_ error: DecodingError) -> String {
        switch error {
        case .typeMismatch(let type, let context):
            return "type mismatch for \(type) at \(path(context.codingPath)): \(context.debugDescription)"
        case .valueNotFound(let type, let context):
            return "missing value for \(type) at \(path(context.codingPath)): \(context.debugDescription)"
        case .keyNotFound(let key, let context):
            return "missing key \(key.stringValue) at \(path(context.codingPath))"
        case .dataCorrupted(let context):
            return "corrupt data at \(path(context.codingPath)): \(context.debugDescription)"
        @unknown default:
            return "unknown decoding error"
        }
    }

    static func path(_ codingPath: [CodingKey]) -> String {
        codingPath.isEmpty ? "<root>" : codingPath.map(\.stringValue).joined(separator: ".")
    }
}

extension ExposureRequestRecord {
    private enum ApertureCodingKeys: String, CodingKey {
        case mode, durationSeconds, iso, biasEV, apertureMode, aperture
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ApertureCodingKeys.self)
        mode = try container.decode(ExposureModeKind.self, forKey: .mode)
        durationSeconds = try container.decodeIfPresent(Double.self, forKey: .durationSeconds)
        iso = try container.decodeIfPresent(Double.self, forKey: .iso)
        biasEV = try container.decode(Double.self, forKey: .biasEV)
        apertureMode = try container.decodeIfPresent(String.self, forKey: .apertureMode)
        aperture = try container.decodeIfPresent(Double.self, forKey: .aperture)
        let problems = apertureValidationProblems(context: "exposure")
        if !problems.isEmpty { throw PortableJSONError.semanticValidation(problems) }
    }

    func encode(to encoder: Encoder) throws {
        let problems = apertureValidationProblems(context: "exposure")
        if !problems.isEmpty { throw PortableJSONError.semanticValidation(problems) }
        var container = encoder.container(keyedBy: ApertureCodingKeys.self)
        try container.encode(mode, forKey: .mode)
        try container.encodeIfPresent(durationSeconds, forKey: .durationSeconds)
        try container.encodeIfPresent(iso, forKey: .iso)
        try container.encode(biasEV, forKey: .biasEV)
        try container.encodeIfPresent(apertureMode, forKey: .apertureMode)
        // Keep historical absence intact. A new Auto request explicitly has no
        // numeric target; the observed image aperture remains a separate field.
        if apertureMode != nil { try container.encode(aperture, forKey: .aperture) }
    }
}

// MARK: - Explicit-null key paths for each v1 document

extension SourceSidecar {
    /// Keys the v1 source schema requires to be present even when null.
    static let explicitNullKeyPaths: [String] = [
        "observed.durationSeconds",
        "observed.iso",
        "observed.aperture",
        "observed.focalLengthMM",
        "observed.orientation",
        "observed.focus.position",
        "observed.whiteBalance.gains",
        "requested.exposure.durationSeconds",
        "requested.exposure.iso",
        "requested.focus.position",
        "requested.whiteBalance.temperatureKelvin",
        "requested.whiteBalance.tint",
        "sequence",
        "ui",
    ]
}

extension SequenceDocument {
    static let explicitNullKeyPaths: [String] = [
        "intervalSeconds",
        "baseline",
        "endedAtUTC",
        "errorSummary",
    ]
}

extension TransactionRecord {
    static let explicitNullKeyPaths: [String] = ["lastError"]
}
