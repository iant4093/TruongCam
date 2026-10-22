import Foundation
import OSLog

/// Detailed local diagnostics stay separate from the copy shown in the app.
/// Logging is enabled in Release as well as Debug; no remote service is used.
enum AppDiagnostics {
    private static let logger = Logger(subsystem: "com.iantruong.TruongCam", category: "Errors")

    static func description(for error: Error, operation: String) -> String {
        if let failure = error as? CaptureFailure { return "\(operation): \(failure.description)" }
        let native = error as NSError
        return "\(operation): \(String(reflecting: error)); \(native.description)"
    }

    static func record(_ error: Error, operation: String) {
        record(description(for: error, operation: operation), operation: "diagnostic")
    }

    static func record(_ detail: String, operation: String) {
        logger.error("\(operation, privacy: .public): \(detail, privacy: .public)")
    }
}
