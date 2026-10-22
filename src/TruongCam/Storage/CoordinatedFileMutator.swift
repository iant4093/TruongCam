import Foundation

// CONTRACTS.md "Folder protocol hardening": "Provider access is
// NSFileCoordinator-owned; do not dispatch asynchronous work out of its accessor
// and then report accessor success."

/// Real `NSFileCoordinator` implementation of the frozen
/// `CoordinatedFileMutator` protocol.
///
/// SYNCHRONOUS ACCESSOR INVARIANT: `NSFileCoordinator`'s accessor block is
/// imported `NS_NOESCAPE` and is executed synchronously on this thread before
/// `coordinate(...)` returns. The generic `body` passed by the caller is also
/// synchronous and non-escaping, and this type never starts a `Task`, never
/// hands the accessor URL to another queue, and never returns before the accessor
/// has finished. Consequently no asynchronous work can escape the accessor and
/// no "access" result is ever reported for work that is still running.
final class NSFileCoordinatorMutator: CoordinatedFileMutator {
    init() {}

    func coordinatedWrite<T>(at url: URL, _ body: (URL) throws -> T) throws -> T {
        try coordinate(writing: true, at: url, body)
    }

    func coordinatedRead<T>(at url: URL, _ body: (URL) throws -> T) throws -> T {
        try coordinate(writing: false, at: url, body)
    }

    private func coordinate<T>(writing: Bool, at url: URL, _ body: (URL) throws -> T) throws -> T {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinatorError: NSError?
        var thrownByBody: Error?
        var result: T?

        let accessor: (URL) -> Void = { actualURL in
            do {
                result = try body(actualURL)
            } catch {
                thrownByBody = error
            }
        }

        if writing {
            coordinator.coordinate(writingItemAt: url, options: [], error: &coordinatorError, byAccessor: accessor)
        } else {
            coordinator.coordinate(readingItemAt: url, options: [], error: &coordinatorError, byAccessor: accessor)
        }

        if let coordinatorError {
            throw FileAdapterError.classify(coordinatorError)
        }
        if let thrownByBody {
            throw thrownByBody
        }
        guard let result else {
            throw FileAdapterError.coordinationFailure(
                "The coordinated accessor for \(url.lastPathComponent) produced no result")
        }
        return result
    }
}

/// Pass-through coordinator for the in-memory adapter and other providers that
/// need no coordination. It is still strictly synchronous by construction: the
/// body runs on the caller's thread and the call returns only after it finished.
struct DirectFileCoordinatorMutator: CoordinatedFileMutator {
    func coordinatedWrite<T>(at url: URL, _ body: (URL) throws -> T) throws -> T {
        try body(url)
    }

    func coordinatedRead<T>(at url: URL, _ body: (URL) throws -> T) throws -> T {
        try body(url)
    }
}
