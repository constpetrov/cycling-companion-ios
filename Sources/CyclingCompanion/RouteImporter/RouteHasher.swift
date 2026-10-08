import CryptoKit
import Foundation

/// SHA-256 of the simplified, resampled polyline coordinates (RULE-10's iOS counterpart;
/// AC-10 in spec/criteria.md). Coordinates are rounded to 6 decimal places (~0.11 m) before
/// serializing so floating-point representation noise can't change the hash.
enum RouteHasher {
    static func hash(_ points: [ResampledPoint]) -> String {
        let serialized = points
            .map { String(format: "%.6f,%.6f", $0.latitude, $0.longitude) }
            .joined(separator: ";")
        let digest = SHA256.hash(data: Data(serialized.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
