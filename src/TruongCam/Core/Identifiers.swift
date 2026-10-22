import Foundation

// CONTRACTS.md "Identity, values and provenance": UUID for library/capture/
// sequence/transaction identity; nonnegative integers for configuration
// generation, source ordinal and configuration revision.

/// Stable identity of a user-selected library root.
struct LibraryID: Hashable, Sendable, Codable, CustomStringConvertible {
    let rawValue: UUID
    init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
    var description: String { rawValue.uuidString.lowercased() }
}

/// Identity of one acquired source (one DNG + one sidecar).
struct CaptureID: Hashable, Sendable, Codable, CustomStringConvertible {
    let rawValue: UUID
    init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
    var description: String { rawValue.uuidString.lowercased() }
}

/// Identity of one sequence run (bracket / focus bracket / interval).
struct SequenceID: Hashable, Sendable, Codable, CustomStringConvertible {
    let rawValue: UUID
    init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
    var description: String { rawValue.uuidString.lowercased() }
}

/// Identity of one save transaction. Pinned to its originating root generation.
struct TransactionID: Hashable, Sendable, Codable, CustomStringConvertible {
    let rawValue: UUID
    init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
    var description: String { rawValue.uuidString.lowercased() }
}

/// Monotonic camera/format/input configuration generation. Increments for
/// physical input, format or media-services reset changes — never for
/// layout-only rotation.
struct ConfigurationGeneration: Hashable, Sendable, Comparable, Codable {
    let value: UInt64
    init(_ value: UInt64) { self.value = value }
    static let zero = ConfigurationGeneration(0)
    static func next(_ prior: ConfigurationGeneration) -> ConfigurationGeneration {
        ConfigurationGeneration(prior.value &+ 1)
    }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.value < rhs.value }
}

/// Generation of a granted library root (bookmark/scope re-grant, root switch).
struct RootGeneration: Hashable, Sendable, Comparable, Codable {
    let value: UInt64
    init(_ value: UInt64) { self.value = value }
    static let zero = RootGeneration(0)
    static func next(_ prior: RootGeneration) -> RootGeneration {
        RootGeneration(prior.value &+ 1)
    }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.value < rhs.value }
}

/// Zero-based source ordinal inside a sequence plan.
struct SourceOrdinal: Hashable, Sendable, Comparable, Codable {
    let value: Int
    init(_ value: Int) { self.value = value }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.value < rhs.value }
}

/// Zero-based deadline ordinal for interval scheduling. Independent of the
/// retained-source ordinal (CONTRACTS.md "Interval policy").
struct DeadlineOrdinal: Hashable, Sendable, Comparable, Codable {
    let value: Int
    init(_ value: Int) { self.value = value }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.value < rhs.value }
}

/// SHA-256 digest rendered as 64 lowercase hex characters.
struct SHA256Digest: Hashable, Sendable, Codable, CustomStringConvertible {
    let hex: String
    /// Returns nil unless `hex` is exactly 64 lowercase hexadecimal characters.
    init?(hex: String) {
        guard hex.count == 64 else { return nil }
        for scalar in hex.unicodeScalars {
            let v = scalar.value
            let isDigit = v >= 48 && v <= 57
            let isLower = v >= 97 && v <= 102
            guard isDigit || isLower else { return nil }
        }
        self.hex = hex
    }
    var description: String { hex }
}

/// The result of hashing a byte stream.
struct HashAndByteCount: Hashable, Sendable {
    let digest: SHA256Digest
    let byteCount: Int64
    init(digest: SHA256Digest, byteCount: Int64) {
        self.digest = digest
        self.byteCount = byteCount
    }
}

/// Integer pixel dimensions. Never inferred from a megapixel label.
struct PixelDimensions: Hashable, Sendable, Codable {
    let width: Int
    let height: Int
    init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
    var pixelCount: Int64 {
        let (count, overflow) = Int64(width).multipliedReportingOverflow(by: Int64(height))
        return overflow ? 0 : count
    }
    var isValid: Bool { width > 0 && height > 0 && pixelCount > 0 }
}
