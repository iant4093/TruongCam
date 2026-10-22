import Foundation

/// Bayer-versus-ProRAW discrimination for DNG pixel formats.
///
/// Apple's ProRAW uses its own pixel format (`'pror'`) carried in a DNG wrapper.
/// Project rules forbid ProRAW substitution, so a ProRAW-capable format must never
/// be counted as Bayer RAW support (REVIEW.md S04).
enum BayerPixelFormat {
    /// FourCC for Apple ProRAW ("pror").
    static let proRAWFourCC: UInt32 = 0x7072_6F72

    /// True when the format is Apple ProRAW rather than a Bayer sensor format.
    static func isProRAW(_ pixelFormat: UInt32) -> Bool {
        pixelFormat == proRAWFourCC
    }

    /// The subset that is genuinely Bayer RAW for the DNG container.
    static func bayerOnly(_ formats: [UInt32]) -> [UInt32] {
        formats.filter { !isProRAW($0) }
    }

    /// A diagnostic label for a pixel format, without inventing vendor names.
    static func describe(_ pixelFormat: UInt32) -> String {
        let bytes = [
            UInt8((pixelFormat >> 24) & 0xFF),
            UInt8((pixelFormat >> 16) & 0xFF),
            UInt8((pixelFormat >> 8) & 0xFF),
            UInt8(pixelFormat & 0xFF),
        ]
        let printable = bytes.allSatisfy { $0 >= 32 && $0 < 127 }
        let fourCC = printable ? String(bytes: bytes, encoding: .ascii) ?? "?" : "?"
        return String(format: "0x%08X ('%@')", pixelFormat, fourCC)
    }
}
