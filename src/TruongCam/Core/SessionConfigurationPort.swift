import Foundation

/// The session-configuration operations whose ORDERING is part of the discovery
/// contract.
///
/// REVIEW.md H03: `AVCaptureSession` only adopts a nested `beginConfiguration`/
/// `commitConfiguration` pair at the OUTERMOST commit, so the configuration depth at
/// the moment a camera fact is queried is a correctness property, not an
/// implementation detail. Funnelling those calls through a port lets a fake record the
/// depth and the call order, so the ordering is tested rather than asserted in a
/// comment.
protocol SessionConfiguring: AnyObject, Sendable {
    func beginConfiguration()
    func commitConfiguration()
    /// The number of `beginConfiguration` calls not yet matched by a commit.
    var configurationDepth: Int { get }
}
