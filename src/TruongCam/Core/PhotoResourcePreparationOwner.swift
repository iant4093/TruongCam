import Foundation
import Synchronization

/// Identity of an optional native resource hint, never capture capability or
/// shutter readiness. Native settings persist across input changes, so the
/// outgoing request must be retired before replacing its connected tuple.
final class PhotoResourcePreparationOwner: Sendable {
    struct Signature: Equatable, Sendable {
        let deviceIdentity: String
        let formatIdentity: String
        let rawPixelFormat: UInt32
        let rawFileType: String
        let dimensions: PixelDimensions
    }
    struct Token: Equatable, Sendable { fileprivate let revision: UInt64 }
    enum Phase: Equatable, Sendable { case preparing, prepared, failed }
    struct Snapshot: Equatable, Sendable {
        let signature: Signature
        let token: Token
        var phase: Phase
    }
    private struct State: Sendable {
        var revision: UInt64 = 0
        var current: Snapshot?
    }
    private let state = Mutex(State())
    var snapshot: Snapshot? { state.withLock { $0.current } }

    /// Same connected request keeps its resources through an unchanged reopen.
    /// A failed optional hint may be retried; it never prevents real capture.
    func reserve(_ signature: Signature) -> Token? {
        state.withLock { value in
            if let current = value.current, current.signature == signature,
               current.phase != .failed { return nil }
            value.revision &+= 1
            let token = Token(revision: value.revision)
            value.current = Snapshot(signature: signature, token: token, phase: .preparing)
            return token
        }
    }

    /// Mark obsolete before calling the SDK, whose previous completion may run
    /// immediately on another queue. No owner lock spans a native API call.
    @discardableResult func retire(ifOwnedBy token: Token? = nil) -> Bool {
        state.withLock { value in
            guard let current = value.current,
                  token == nil || current.token == token else { return false }
            value.revision &+= 1
            value.current = nil
            return true
        }
    }

    /// A late old-camera callback cannot label replacement resources prepared.
    @discardableResult func complete(_ token: Token, prepared: Bool) -> Bool {
        state.withLock { value in
            guard var current = value.current, current.token == token,
                  current.phase == .preparing else { return false }
            current.phase = prepared ? .prepared : .failed
            value.current = current
            return true
        }
    }
}
