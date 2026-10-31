import Foundation

/// Parses the Bluetooth Heart Rate Measurement characteristic (0x2A37) — RULE-2 in milestone 12's
/// rules.md, AC-27 to AC-29. Bit 0 of the flags byte picks an 8-bit or a little-endian 16-bit value;
/// the optional fields after it (energy expended, RR intervals) are ignored.
enum HeartRateMeasurement {
    /// The heart rate in bpm, or `nil` for a malformed payload or 0 bpm (straps send 0 while they
    /// lose skin contact).
    static func bpm(from data: Data) -> Int? {
        let bytes = [UInt8](data)
        guard let flags = bytes.first else { return nil }
        let value: Int
        if flags & 0x01 == 0 {
            guard bytes.count >= 2 else { return nil }
            value = Int(bytes[1])
        } else {
            guard bytes.count >= 3 else { return nil }
            value = Int(bytes[1]) | Int(bytes[2]) << 8
        }
        return value == 0 ? nil : value
    }
}
