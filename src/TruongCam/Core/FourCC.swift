import Foundation

/// Four-character-code formatting for diagnostics and metadata.
///
/// Deliberately named `FourCC` rather than `FourCharCode`: CoreAudio exports a
/// `FourCharCode` type alias for `UInt32`, which shadows a same-named enum in
/// files that also import ImageIO or AudioToolbox.
enum FourCC {
    /// Renders a FourCC as text, substituting `?` for non-printable bytes.
    static func string(from value: UInt32) -> String {
        let bytes = [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ]
        let scalars = bytes.map { byte -> Character in
            (48...126).contains(byte) ? Character(UnicodeScalar(byte)) : "?"
        }
        return String(scalars)
    }
}
