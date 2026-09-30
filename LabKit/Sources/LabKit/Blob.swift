import CryptoKit
import Foundation

/// Random bytes stand in for images: like HEIC and JPEG, they do not compress.
enum Blob {
    static func random(_ count: Int) -> Data {
        var data = Data(count: count)
        if count > 0 {
            data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, count) }
        }
        return data
    }

    static func random(in range: ClosedRange<Int>) -> Data {
        random(Int.random(in: range))
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Sizes taken from Mix's sample mixes. Photos are HEIC capped at 2560 px, each with a 300 px
/// thumbnail, and the preview is a JPEG render of about 880 by 1170 px.
enum Sizes {
    static let photo = 250_000...900_000
    static let photoThumbnail = 15_000...90_000
    static let preview = 180_000...330_000
    static let mixThumbnail = 15_000...40_000
}

extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
