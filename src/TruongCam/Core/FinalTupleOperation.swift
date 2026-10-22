import Foundation
import Synchronization

/// A previously validated ceiling may share the next input-swap commit only
/// while every native identity and dimension precondition still matches. This
/// is a setter plan, never capability evidence or capture authorization. The
/// adapter must still freshly select and validate the committed RAW tuple.
struct WarmPhotoCeilingEvidence: Sendable {
    let deviceIdentity: String
    let formatIdentity: String
    let analysisOutputAttached: Bool
    let candidateDimensions: [[PixelDimensions]]
    let ceiling: PixelDimensions

    func plannedCeiling(deviceIdentity: String, formatIdentity: String,
                        analysisOutputAttached: Bool,
                        candidateDimensions: [[PixelDimensions]],
                        currentFormatDimensions: [PixelDimensions]) -> PixelDimensions? {
        guard self.deviceIdentity == deviceIdentity,
              self.formatIdentity == formatIdentity,
              self.analysisOutputAttached == analysisOutputAttached,
              self.candidateDimensions == candidateDimensions,
              let ceilingPixels = Self.nativePixelCount(ceiling),
              currentFormatDimensions.contains(ceiling) else { return nil }
        var largestPixels: Int64 = 0
        for dimensions in candidateDimensions {
            for dimension in dimensions {
                if let pixels = Self.nativePixelCount(dimension) {
                    largestPixels = max(largestPixels, pixels)
                }
            }
        }
        guard largestPixels == ceilingPixels else { return nil }
        return ceiling
    }

    private static func nativePixelCount(_ dimensions: PixelDimensions) -> Int64? {
        guard dimensions.isValid, dimensions.width <= Int(Int32.max),
              dimensions.height <= Int(Int32.max) else { return nil }
        return Int64(dimensions.width) * Int64(dimensions.height)
    }
}

/// Owns the balanced configure → query → publish-or-reject → rollback sequence for a final
/// RAW tuple.
///
/// X03: this is the SEQUENCING of the shipping operation, in Core, so the registered suite
/// executes the same order the adapter uses rather than restating it. The SDK work is supplied
/// by a narrow port; the ordering, the balance accounting and the publish/refuse/rollback
/// decision are owned here.
///
/// The depth counter is what makes "balanced" checkable: a query issued while a configuration
/// is open would observe a half-applied topology, so it is refused rather than silently
/// producing facts for a tuple that is not the one in force.
final class FinalTupleOperation: @unchecked Sendable {
    /// No-op configuration commits can restart the running sensor. This shared
    /// path skips them entirely, and balances real mutations even when they throw.
    static func configureIfNeeded(_ needed: Bool, begin: () -> Void, commit: () -> Void,
                                  apply: () throws -> Void) rethrows {
        guard needed else { return }
        begin()
        defer { commit() }
        try apply()
    }

    /// What the operation ended up doing.
    enum Disposition: Equatable, Sendable {
        /// The final query was accepted and its facts were published.
        case published
        /// The final query was refused because THIS tuple is invalid; it revokes.
        case refused
        /// A newer configuration superseded this query; nothing may be published AND the
        /// newer capability must NOT be revoked.
        case superseded
        /// The port itself failed while configuring.
        case configureFailed
    }

    /// The facts the final query reports for the committed tuple.
    struct FinalFacts: Sendable {
        var bayer: [UInt32] = []
        var fileTypes: [String] = []
        var bracketCount: Int = 0
        var dimensions: PixelDimensions?
        var formatSubType: String?
        var requestCeiling: [PixelDimensions]?
        var exposureLimits: ExposureLimits?
        var priorityCombinations: Set<ExposureModeKind>?
        var cleanAperture: PixelDimensions??
        var frameRates: [ClosedRange<Double>]?
    }

    /// A lock-guarded carrier so the port can report the full facts out of its async query.
    final class FactsBox: @unchecked Sendable {
        private let mutex = Mutex<FinalFacts?>(nil)
        func set(_ facts: FinalFacts) { mutex.withLock { $0 = facts } }
        var value: FinalFacts? { mutex.withLock { $0 } }
    }

    /// The native port. Every method is the thin bridge to the SDK.
    struct Port {
        var beginConfiguration: () async -> Void
        var commitConfiguration: () async -> Void
        var queryFinalTuple: () async -> FinalFacts
        var rollbackConfiguration: (_ transactionAtQuery: UInt64) async -> Bool
        var publish: (_ facts: FinalFacts, _ transactionAtQuery: UInt64) async -> Bool
        var fail: (_ reason: String, _ transactionAtQuery: UInt64) async -> Void
    }

    private let depth = Mutex<Int>(0)
    /// Increments on every configuration transition, so a query taken before a newer balanced
    /// configuration can be recognised as superseded even though the depth is back to zero.
    private let transaction = Mutex<UInt64>(0)

    init() {}

    /// Records that the ADAPTER opened a real native configuration (Y03).
    func noteConfigurationOpened() {
        depth.withLock { $0 += 1 }
        transaction.withLock { $0 &+= 1 }
    }

    /// Records that the adapter committed a real native configuration. Balanced.
    func noteConfigurationCommitted() {
        depth.withLock { if $0 > 0 { $0 -= 1 } }
        transaction.withLock { $0 &+= 1 }
    }

    /// The configuration transaction currently in force.
    var currentTransaction: UInt64 { transaction.withLock { $0 } }

    /// Configuration depth. Non-zero means a tuple is being changed.
    var configurationDepth: Int { depth.withLock { $0 } }

    /// Runs the whole sequence: balanced outer configuration, then the final query, then
    /// publish-or-reject with a rollback that leaves no half-applied claim behind.
    func run(port: Port, candidateFileTypes: [String]) async -> Disposition {
        depth.withLock { $0 += 1 }
        await port.beginConfiguration()

        // Y03: the outer configuration is COMMITTED before the final query, so the query
        // observes the tuple actually in force rather than a half-applied topology.
        depth.withLock { $0 -= 1 }
        await port.commitConfiguration()

        // An open configuration would mean the query below sees a partially applied topology.
        guard configurationDepth == 0 else {
            // AD03: ONE captured identity for both callbacks, and the rollback's result is
            // honoured — a consumer that declines because a newer configuration took over
            // makes this pass superseded rather than refused.
            let openConfigTransaction = currentTransaction
            await port.fail("A final query was attempted inside an open configuration.",
                            openConfigTransaction)
            let revokedOpen = await port.rollbackConfiguration(openConfigTransaction)
            return revokedOpen ? .refused : .superseded
        }

        // Z03: the transaction is captured BEFORE the query and validated at PUBLICATION, so
        // a tuple that changed and settled while this query was in flight cannot publish over
        // the newer committed facts.
        let transactionAtQuery = currentTransaction

        let queried = await port.queryFinalTuple()

        guard transactionAtQuery == currentTransaction else {
            // Superseded: refuse WITHOUT reverting or revoking the legitimate newer facts.
            return .superseded
        }
        let decision = FinalTupleValidation.validate(
            finalBayerFormats: queried.bayer,
            finalFileTypes: queried.fileTypes,
            candidateFileTypes: candidateFileTypes)

        switch decision {
        case .publish:
            // The PUBLISH step receives the facts the query actually reported. If the
            // consumer's synchronous re-validation declines, this operation was superseded at
            // the publication boundary and must NOT claim current success (AB03).
            let committed = await port.publish(queried, transactionAtQuery)
            return committed ? .published : .superseded
        case .rejectNoBayerRAW:
            // AC03: the refusal carries the captured transaction. If the consumer declines
            // because a NEWER configuration registered in the meantime, this pass was
            // superseded and must not revoke the newer capability; only a genuinely current
            // invalid tuple revokes and reports refused.
            await port.fail("The committed configuration cannot produce a Bayer RAW DNG.",
                            transactionAtQuery)
            let revoked = await port.rollbackConfiguration(transactionAtQuery)
            return revoked ? .refused : .superseded
        }
    }
}
