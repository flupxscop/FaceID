import CoreGraphics
import Foundation

public enum ImageMetricsCalculator {
    /// Measures brightness and sharpness (variance of the Laplacian) inside `region`.
    ///
    /// - Parameters:
    ///   - width/height: image size in pixels.
    ///   - region: pixel rect with a top-left origin.
    ///   - maxSamplesPerAxis: subsampling limit to keep this cheap per frame.
    ///   - luma: returns the 0...255 luma at (x, y), top-left origin.
    public static func measure(
        width: Int,
        height: Int,
        region: CGRect,
        maxSamplesPerAxis: Int = 96,
        luma: (_ x: Int, _ y: Int) -> UInt8
    ) -> ImageMetrics? {
        guard width >= 3, height >= 3 else { return nil }
        let bounds = CGRect(x: 1, y: 1, width: width - 2, height: height - 2)
        let clipped = region.integral.intersection(bounds)
        guard !clipped.isNull, clipped.width >= 3, clipped.height >= 3 else { return nil }

        let minX = Int(clipped.minX), maxX = Int(clipped.maxX) - 1
        let minY = Int(clipped.minY), maxY = Int(clipped.maxY) - 1
        let stepX = max(1, (maxX - minX + 1) / max(1, maxSamplesPerAxis))
        let stepY = max(1, (maxY - minY + 1) / max(1, maxSamplesPerAxis))

        var count = 0.0
        var lumaSum = 0.0
        var lapSum = 0.0
        var lapSquares = 0.0
        var y = minY
        while y <= maxY {
            var x = minX
            while x <= maxX {
                let center = Double(luma(x, y))
                let laplacian = 4 * center
                    - Double(luma(x - 1, y)) - Double(luma(x + 1, y))
                    - Double(luma(x, y - 1)) - Double(luma(x, y + 1))
                lumaSum += center
                lapSum += laplacian
                lapSquares += laplacian * laplacian
                count += 1
                x += stepX
            }
            y += stepY
        }
        guard count >= 9 else { return nil }

        let lapMean = lapSum / count
        let variance = max(0, lapSquares / count - lapMean * lapMean)
        return ImageMetrics(brightness: lumaSum / count / 255, sharpness: variance)
    }
}
