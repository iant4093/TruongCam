import Foundation

/// Owns the SEQUENCE a delayed consumer must perform: check the captured identity and, only
/// if it is still current, mutate the consumer's state.
///
/// AC01: the check-and-write is the part that must be atomic within one owner turn. Owning it
/// in Core makes the actual consumer boundary executable in the verifier instead of only
/// living in the AVFoundation adapter, and it keeps the check adjacent to the mutation with no
/// suspension between them.
enum ConsumerCommit {
    /// Whether the captured identity was still current when the commit was attempted.
    enum Decision: Equatable, Sendable {
        case committed
        case superseded
    }

    /// Commits `mutation` only if `snapshot` still matches `identity`.
    ///
    /// The synchronous signature is deliberate: no `await` may separate the check from the
    /// mutation, or a newer result could land in between.
    @discardableResult
    static func commit(
        identity: PublicationIdentity,
        snapshot: PublicationIdentity.Snapshot,
        mutation: () -> Void
    ) -> Decision {
        guard identity.isCurrent(snapshot) else { return .superseded }
        mutation()
        // The commit itself is a publication, so any older in-flight work is now obsolete.
        identity.notePublished()
        return .committed
    }

    /// The readback variant: the publication dimension AND the generation must both still
    /// match, and the mutation performs the cache write, the return value and the broadcast.
    ///
    /// `generationMatches` is passed in separately because the generation is the service's own
    /// state; the check still happens in the same synchronous turn as the mutation.
    @discardableResult
    static func commitReadback(
        identity: PublicationIdentity,
        snapshot: PublicationIdentity.Snapshot,
        generationMatches: Bool,
        mutation: () -> Void
    ) -> Decision {
        guard generationMatches, identity.isCurrent(snapshot) else { return .superseded }
        mutation()
        identity.notePublished()
        return .committed
    }

    /// The control-invocation variant the service uses: only the control dimension decides.
    @discardableResult
    static func commitControl(
        identity: PublicationIdentity,
        invocation: UInt64,
        mutation: () -> Void
    ) -> Decision {
        guard invocation == identity.controlSequence else { return .superseded }
        mutation()
        identity.notePublished()
        return .committed
    }
}
