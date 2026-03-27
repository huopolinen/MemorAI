import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// CGWindowListCreateImage still exists in CoreGraphics but Swift marks it unavailable.
// We call it directly via symbol name.
@_silgen_name("CGWindowListCreateImage")
private func _CGWindowListCreateImage(
    _ screenBounds: CGRect,
    _ listOption: UInt32,
    _ windowID: UInt32,
    _ imageOption: UInt32
) -> Unmanaged<CGImage>?

class ScreenCapturer {

    /// Capture the entire screen at full (Retina 2x) resolution for better OCR
    func capture() -> CGImage? {
        // kCGWindowListOptionOnScreenOnly = 1, kCGNullWindowID = 0
        // kCGWindowImageBestResolution = 0x100
        _CGWindowListCreateImage(CGRect.null, 1, 0, 0x100)?.takeRetainedValue()
    }

    /// Difference hash: resize to 9x8 grayscale, compare adjacent pixels → 64-bit hash
    func dhash(_ image: CGImage) -> UInt64 {
        let w = 9, h = 8
        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return 0 }

        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return 0 }
        let px = data.bindMemory(to: UInt8.self, capacity: w * h)

        var hash: UInt64 = 0
        for y in 0..<h {
            for x in 0..<(w - 1) {
                let bit = y * (w - 1) + x
                if px[y * w + x] < px[y * w + x + 1] {
                    hash |= 1 << bit
                }
            }
        }
        return hash
    }

    /// Hamming distance between two hashes
    func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }

    /// Save image as HEIF (preferred) or JPEG (fallback). Returns saved URL or nil.
    func saveImage(_ image: CGImage, to preferredURL: URL, quality: Float = 0.5) -> URL? {
        let formats: [(UTType, String)] = [(.heif, "heif"), (.jpeg, "jpg")]
        for (format, ext) in formats {
            let url = preferredURL.deletingPathExtension().appendingPathExtension(ext)
            guard let dest = CGImageDestinationCreateWithURL(
                url as CFURL,
                format.identifier as CFString,
                1, nil
            ) else { continue }

            let opts: [CFString: Any] = [
                kCGImageDestinationLossyCompressionQuality: quality
            ]
            CGImageDestinationAddImage(dest, image, opts as CFDictionary)
            if CGImageDestinationFinalize(dest) {
                return url
            }
        }
        return nil
    }
}
