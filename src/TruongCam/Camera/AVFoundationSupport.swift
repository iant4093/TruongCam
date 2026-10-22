import Foundation
@preconcurrency import AVFoundation

// AVFoundation's reference types are not `Sendable`. CONTRACTS.md and
// ARCHITECTURE.md require a dedicated serial session/configuration queue and
// forbid blanket annotations, so this file provides exactly one narrow wrapper
// with a stated ownership invariant.
//
// `@preconcurrency import AVFoundation` is used because Apple's AVFoundation
// interfaces are not annotated for Swift 6 concurrency. It does not weaken
// checks on our own types; it only stops the compiler from treating every
// AVFoundation type as cross-actor-unsafe. Every AVFoundation access in this app
// still happens on the serial queue below.

/// The one serial queue that owns session configuration.
///
/// Ownership invariant for the narrow `@unchecked Sendable`: every AVFoundation
/// object created, stored or mutated through this type is touched only inside
/// `perform`, which always runs on `DispatchQueue` `queue`. No AVFoundation
/// object escapes; callers receive value snapshots.
final class SerialSessionQueue: @unchecked Sendable {
    let queue: DispatchQueue

    init(label: String = "com.iantruong.TruongCam.session") {
        queue = DispatchQueue(label: label, qos: .userInitiated)
    }

    var isCurrent: Bool { DispatchQueue.getSpecific(key: SerialSessionQueue.key) != nil }

    private static let key = DispatchSpecificKey<UInt8>()
    private static let marker: UInt8 = 1

    /// Registers this queue so `isCurrent` can detect reentrancy.
    func activate() {
        queue.setSpecific(key: SerialSessionQueue.key, value: SerialSessionQueue.marker)
    }

    /// Runs `body` on the session queue and returns its result. Never blocks the
    /// caller's thread beyond the hop.
    func perform<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: body())
            }
        }
    }

    /// Runs a throwing body on the session queue.
    func performThrowing<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try body())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Synchronous variant used only from code that is already on this queue or
    /// during teardown, where an async hop would deadlock.
    func performSync<T>(_ body: () -> T) -> T {
        if isCurrent { return body() }
        return queue.sync(execute: body)
    }
}

/// Narrow box that lets one AVFoundation reference cross into the serial queue's
/// closures. The invariant is the queue ownership documented on
/// `SerialSessionQueue`: nothing reads or writes the boxed object off that queue.
struct SessionOwned<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) { self.value = value }
}

/// Maps an `NSError` from AVFoundation onto the normalized failure vocabulary.
enum AVFoundationFailureMapper {
    static func failure(
        _ error: Error,
        operation: String,
        retained: RetainedSourceStatus = .none
    ) -> CaptureFailure {
        let ns = error as NSError
        let kind: FailureKind
        switch ns.domain {
        case AVFoundationErrorDomain:
            switch ns.code {
            case AVError.deviceWasDisconnected.rawValue:
                kind = .cameraInterrupted(detail: "The camera device was disconnected.")
            case AVError.deviceNotConnected.rawValue:
                kind = .cameraInterrupted(detail: "The camera device is not connected.")
            case AVError.mediaServicesWereReset.rawValue:
                kind = .cameraInterrupted(detail: "Media services were reset.")
            case AVError.noDataCaptured.rawValue:
                kind = .representationUnavailable(detail: "No data was captured.")
            default:
                kind = .captureFailed(detail: ns.localizedDescription)
            }
        case NSCocoaErrorDomain:
            switch ns.code {
            case NSFileWriteOutOfSpaceError:
                kind = .localStorageFull(detail: ns.localizedDescription)
            default:
                kind = .captureFailed(detail: ns.localizedDescription)
            }
        default:
            if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ENOSPC) {
                kind = .localStorageFull(detail: ns.localizedDescription)
            } else {
                kind = .captureFailed(detail: ns.localizedDescription)
            }
        }
        return CaptureFailure(kind: kind,
                              operation: operation,
                              retainedSourceStatus: retained,
                              nsErrorDomain: ns.domain,
                              nsErrorCode: ns.code,
                              underlyingDescription: ns.localizedDescription)
    }
}

extension CMTime {
    /// Builds a CMTime from a validated positive duration. Returns `nil` for a
    /// non-finite or non-positive value, which must never reach a native setter.
    static func fromValidatedSeconds(_ seconds: Double, preferredTimescale: Int32 = 1_000_000) -> CMTime? {
        guard seconds.isFinite, seconds > 0 else { return nil }
        let time = CMTimeMakeWithSeconds(seconds, preferredTimescale: preferredTimescale)
        return time.isValid && !time.isIndefinite ? time : nil
    }

    /// Seconds for a usable CMTime; `nil` for invalid/indefinite values so an
    /// unusable reading is never reported as zero.
    var validatedSeconds: Double? {
        guard isValid, !isIndefinite, !isPositiveInfinity, !isNegativeInfinity else { return nil }
        let value = Double(value) / Double(timescale)
        return value.isFinite ? value : nil
    }
}

/// Process-wide, non-identifying build provenance used in metadata and
/// diagnostics. No serial or device identifiers.
enum DeviceProvenance {
    static var hardwareModel: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let identifier = withUnsafeBytes(of: &systemInfo.machine) { raw -> String in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
        return identifier.isEmpty ? "unknown" : identifier
    }

    static var osVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    static var sdkVersion: String {
        "iOS SDK \(UIDevicePlaceholder.sdkVersion)"
    }
}

/// Minimal indirection so this file stays usable when UIKit is unavailable in a
/// future test target.
enum UIDevicePlaceholder {
    static var sdkVersion: String {
        #if canImport(UIKit)
        return "27.0"
        #else
        return "unknown"
        #endif
    }
}
