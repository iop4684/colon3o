import Accelerate
import CoreGraphics

/// A small blurred copy of a picture, done on the CPU with Accelerate.
///
/// CoreImage used to do this (the player's background, the blurred sides of covers that aren't
/// square), but every render opened more of CoreImage's and Metal's files and kept them open,
/// until the app ran out of file descriptors and couldn't open covers, songs or anything else.
/// These images are tiny, so the CPU is quick and opens nothing.
enum SoftBlur {
    /// `image` scaled to fill `width` × `height` pixels (centred, cropped to fit), blurred by
    /// about `sigma` pixels, with its saturation multiplied and brightness shifted (−1…1).
    nonisolated static func make(_ image: CGImage, width: Int, height: Int, sigma: Double,
                                 saturation: Float = 1, brightness: Float = 0) -> CGImage? {
        guard width > 0, height > 0, image.width > 0, image.height > 0 else { return nil }
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space, bitmapInfo: info),
              let pixels = context.data else { return nil }
        let rowBytes = context.bytesPerRow

        let w = CGFloat(image.width), h = CGFloat(image.height)
        let scale = max(CGFloat(width) / w, CGFloat(height) / h)
        let drawn = CGSize(width: w * scale, height: h * scale)
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: (CGFloat(width) - drawn.width) / 2, y: (CGFloat(height) - drawn.height) / 2,
                                       width: drawn.width, height: drawn.height))

        // Four box blurs in a row look like a Gaussian blur: each adds r(r+1)/3 to the variance.
        let radius = Int((((1 + 3 * sigma * sigma).squareRoot() - 1) / 2).rounded())
        if radius > 0 {
            guard let scratch = malloc(rowBytes * height) else { return nil }
            defer { free(scratch) }
            var a = vImage_Buffer(data: pixels, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: rowBytes)
            var b = vImage_Buffer(data: scratch, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: rowBytes)
            let size = UInt32(radius * 2 + 1)
            for _ in 0..<2 {
                vImageBoxConvolve_ARGB8888(&a, &b, nil, 0, 0, size, size, nil, vImage_Flags(kvImageEdgeExtend))
                vImageBoxConvolve_ARGB8888(&b, &a, nil, 0, 0, size, size, nil, vImage_Flags(kvImageEdgeExtend))
            }
        }

        if saturation != 1 || brightness != 0 {
            let bytes = pixels.assumingMemoryBound(to: UInt8.self)
            for y in 0..<height {
                let row = bytes + y * rowBytes
                for x in 0..<width {
                    let p = row + x * 4  // blue, green, red, alpha (premultiplied)
                    let alpha = Float(p[3])
                    let blue = Float(p[0]), green = Float(p[1]), red = Float(p[2])
                    let luma = 0.2126 * red + 0.7152 * green + 0.0722 * blue
                    let shift = brightness * alpha
                    func adjust(_ value: Float) -> UInt8 {
                        UInt8(min(max(luma + (value - luma) * saturation + shift, 0), alpha))
                    }
                    p[0] = adjust(blue); p[1] = adjust(green); p[2] = adjust(red)
                }
            }
        }
        return context.makeImage()
    }
}
