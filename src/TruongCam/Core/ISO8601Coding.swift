import Foundation

/// Thread-safe ISO-8601 UTC formatting.
///
/// `ISO8601DateFormatter` is not `Sendable`, so it cannot be a shared global.
/// This wrapper owns a lock around a single instance, which is both cheaper than
/// allocating a formatter per call and safe under Swift 6 strict concurrency.
///
/// Ownership invariant for the narrow `@unchecked Sendable`: `formatter` is only
/// ever touched while `lock` is held.
final class ISO8601Coding: @unchecked Sendable {
    static let shared = ISO8601Coding()

    private let lock = NSLock()
    private let formatter: ISO8601DateFormatter

    init() {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        formatter = f
    }

    func string(from date: Date) -> String {
        lock.lock(); defer { lock.unlock() }
        return formatter.string(from: date)
    }

    func date(from text: String) -> Date? {
        lock.lock(); defer { lock.unlock() }
        return formatter.date(from: text)
    }
}
