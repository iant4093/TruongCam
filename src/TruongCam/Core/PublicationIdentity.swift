import Foundation
import Synchronization

/// The service-owned identity that decides whether an in-flight command or readback may still
/// commit its result.
///
/// AB01: this lives in Core so the delayed-publication lifecycle is executable in the
/// verifier rather than only in the AVFoundation adapter. Both counters are monotonic and are
/// bumped at the boundaries that invalidate in-flight work — a committed publication and a
/// terminal stop/reset — so a result that returns after either boundary is obsolete.
final class PublicationIdentity: @unchecked Sendable {
    private let publication = Mutex<UInt64>(0)
    private let control = Mutex<UInt64>(0)

    init() {}

    /// A publication the service committed.
    func notePublished() { publication.withLock { $0 &+= 1 } }
    /// A control invocation began.
    func noteControlInvocation() { control.withLock { $0 &+= 1 } }
    /// A terminal boundary (stop/reset) invalidated everything in flight.
    func noteTerminal() {
        publication.withLock { $0 &+= 1 }
        control.withLock { $0 &+= 1 }
    }

    var publicationSequence: UInt64 { publication.withLock { $0 } }
    var controlSequence: UInt64 { control.withLock { $0 } }

    /// A snapshot taken BEFORE a suspension. Committing is permitted only while the identity
    /// still matches in BOTH dimensions, so neither a newer publication nor a terminal
    /// boundary can be missed.
    struct Snapshot: Equatable, Sendable {
        let publication: UInt64
        let control: UInt64
    }

    func snapshot() -> Snapshot {
        Snapshot(publication: publicationSequence, control: controlSequence)
    }

    func isCurrent(_ snapshot: Snapshot) -> Bool {
        snapshot.publication == publicationSequence && snapshot.control == controlSequence
    }
}
