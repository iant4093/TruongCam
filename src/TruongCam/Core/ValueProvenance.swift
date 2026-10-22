import Foundation

// CONTRACTS.md "Identity, values and provenance": keep desired, applied,
// observed and per-capture metadata separate, and label the provenance of any
// value that is not proven by capture metadata.

/// Where a displayed or persisted value actually came from.
enum ValueProvenance: String, Hashable, Sendable, Codable, CaseIterable {
    /// Read out of the captured still's own metadata. The only per-source truth.
    case captureMetadata
    /// Device readback after the setter settled. Not the earlier image's state.
    case settledDeviceReadback
    /// The value the user (or plan) requested. May not have been applied.
    case requested
    /// No evidence. Rendered as Unknown, never as zero or a mock constant.
    case unknown

    var displayLabel: String {
        switch self {
        case .captureMetadata: return "from capture metadata"
        case .settledDeviceReadback: return "device readback"
        case .requested: return "requested (not verified)"
        case .unknown: return "unknown"
        }
    }
}

/// A numeric value plus the evidence that produced it. Unknown values never
/// become zero-filled placeholders.
struct ProvenancedValue<Value: Hashable & Sendable>: Hashable, Sendable {
    let value: Value?
    let provenance: ValueProvenance

    init(value: Value?, provenance: ValueProvenance) {
        self.value = value
        self.provenance = value == nil ? .unknown : provenance
    }

    static var unknown: ProvenancedValue<Value> { .init(value: nil, provenance: .unknown) }
    static func known(_ value: Value, _ provenance: ValueProvenance) -> Self {
        .init(value: value, provenance: provenance)
    }
    var isKnown: Bool { value != nil }
}

/// The three-way control state from CONTRACTS.md: what the user wants, what the
/// device last accepted, and what the device most recently reported.
struct ControlReading<Value: Hashable & Sendable>: Hashable, Sendable {
    /// Latest user/plan intent. May be unsupported or unapplied.
    var desired: ProvenancedValue<Value>
    /// Last value the device accepted. A failed setter must not update this.
    var applied: ProvenancedValue<Value>
    /// Most recent observed readback, continuous for automatic parameters.
    var observed: ProvenancedValue<Value>

    init(desired: ProvenancedValue<Value> = .unknown,
         applied: ProvenancedValue<Value> = .unknown,
         observed: ProvenancedValue<Value> = .unknown) {
        self.desired = desired
        self.applied = applied
        self.observed = observed
    }

    /// Records a successful setter: desired and applied both move; observed is
    /// left for the next readback.
    mutating func recordApplied(_ value: Value) {
        desired = .known(value, .requested)
        applied = .known(value, .settledDeviceReadback)
    }

    /// Records a failed setter: only the desired target moves. Applied and
    /// observed keep their previous, still-true values.
    mutating func recordDesiredOnly(_ value: Value?) {
        desired = value.map { ProvenancedValue.known($0, .requested) } ?? .unknown
    }

    mutating func recordObserved(_ value: Value?, _ provenance: ValueProvenance) {
        observed = value.map { ProvenancedValue.known($0, provenance) } ?? .unknown
    }
}
