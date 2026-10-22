import Foundation

/// Owns the SEQUENCE a media-services reset performs when it rebuilds the graph: prepare the
/// camera, then revalidate the in-process controls under the NEW generation.
///
/// AJ03: the sequence is the contract. Owning it in Core means the shipping rebuild and the
/// registered recovery test execute the SAME order rather than the test advancing a counter that
/// only resembles it. The native work is supplied by a narrow port.
enum ResetRebuild {
    /// What the rebuild achieved.
    enum Outcome: Equatable, Sendable {
        /// Prepared AND the controls were revalidated.
        case rebuilt
        /// Native preparation failed.
        case prepareFailed
        /// The graph rebuilt but the controls could not be restored.
        case controlsFailed
    }

    /// The thin native port for one rebuild.
    struct Port: @unchecked Sendable {
        /// Prepares the desired camera. False means native preparation failed.
        var prepare: () async -> Bool
        /// Re-applies and verifies the in-process controls under the new generation.
        var revalidateControls: () async -> Bool
    }

    /// Runs the rebuild. Preparation MUST succeed before the controls are revalidated, and a
    /// failed revalidation is a distinct, actionable outcome rather than a silent success.
    static func run(port: Port) async -> Outcome {
        guard await port.prepare() else { return .prepareFailed }
        guard await port.revalidateControls() else { return .controlsFailed }
        return .rebuilt
    }
}
