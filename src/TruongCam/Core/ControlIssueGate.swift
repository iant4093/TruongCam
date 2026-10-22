import Foundation

/// Decides whether a control application may reach the native setters at all.
///
/// AF01: rejecting an obsolete result AFTER the setters ran still let an old-generation
/// binding mutate the device. This gate is checked at the issue boundary — before any native
/// setter — so an obsolete request is never issued.
enum ControlIssueGate {
    /// True only when the configuration generation and the concrete invocation are BOTH still
    /// current.
    static func mayIssue(
        generationAtIssue: ConfigurationGeneration,
        currentGeneration: ConfigurationGeneration,
        invocationAtIssue: UInt64,
        currentInvocation: UInt64
    ) -> Bool {
        generationAtIssue == currentGeneration && invocationAtIssue == currentInvocation
    }
}
