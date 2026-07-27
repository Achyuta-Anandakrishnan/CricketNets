import CoreVideo
import CoreGraphics
import Foundation

/// Finds the ball in a **single frame** by its colour. No motion, no parabola, no history.
///
/// This exists because `VNDetectTrajectoriesRequest` answers the wrong question first. It only
/// reports objects already moving on a parabola across several frames with a still camera, so it
/// says nothing at all about a ball you are holding, rolling, or waving — and when it says nothing
/// there is no way to tell "I can't see the ball" apart from "the ball isn't flying yet".
///
/// A per-frame detector splits those apart. If this finds the ball, detection works and anything
/// still broken is downstream. If it doesn't, nothing built on top of it can possibly work.
///
/// It also yields something the trajectory path never had: the ball's **apparent size**, which
/// gives an optical distance estimate completely independent of LiDAR. Two disagreeing estimates
/// tell you which sensor to stop trusting.
enum BallDetector {

    /// Inclusive pixel bounds of the area being scanned.
    private struct PixelBounds {
        let x0: Int, y0: Int, x1: Int, y1: Int
    }

    struct Detection: Equatable {
        /// Blob centre, normalized with a top-left origin.
        var center: CGPoint
        /// Equivalent-circle radius, as a fraction of frame width.
        var radiusNormalized: Double
        /// Matching pixels in the winning blob, at scan resolution.
        var pixelCount: Int
        /// Matching pixels anywhere in the frame — much larger than `pixelCount` means the colour
        /// is scattered across the scene rather than concentrated on a ball.
        var totalMatched: Int
        /// Pixels actually inspected, so the blob can be judged against the size of the frame.
        var scannedPixels: Int

        /// How much of the matched colour ended up in this one blob. Low values mean the profile
        /// matches several separate things and only one of them can be the ball.
        var concentration: Double {
            totalMatched > 0 ? Double(pixelCount) / Double(totalMatched) : 0
        }

        /// Share of the whole frame the blob covers.
        ///
        /// This is the check `concentration` cannot make: a profile loose enough to match
        /// *everything* produces one enormous blob, so concentration reads a perfect 1.0 while the
        /// detection is meaningless. A real ball is a small part of the frame, so anything large
        /// here means the calibration is too permissive.
        var frameCoverage: Double {
            scannedPixels > 0 ? Double(pixelCount) / Double(scannedPixels) : 0
        }

        /// Big enough to be worth believing, small enough to actually be a ball.
        var looksLikeABall: Bool { frameCoverage < 0.25 && concentration > 0.3 }
    }

    /// Scan for the largest blob of ball-coloured pixels.
    ///
    /// - Parameter region: normalized area to search (top-left origin). `nil` scans the whole frame.
    ///   Restricting it is what makes following a ball cheap — a small window can be sampled finely
    ///   and matched loosely without any risk of grabbing something on the other side of the net.
    /// - Parameter step: sampling stride in pixels. 8 turns a 1920-wide frame into a 240-wide mask,
    ///   which is ample for acquiring a ball and cheap enough to run every frame.
    /// - Parameter minPixels: reject specks; below this a blob is noise, not a ball.
    static func detect(in buffer: CVPixelBuffer,
                       profile: BallProfile,
                       region: CGRect? = nil,
                       step: Int = 8,
                       minPixels: Int = 4) -> Detection? {
        BallColor.withPixelReader(buffer) { reader -> Detection? in
            // Pixel bounds of the search area, clamped into the frame.
            let bounds: PixelBounds
            if let r = region {
                bounds = PixelBounds(
                    x0: max(0, Int(r.minX * CGFloat(reader.width))),
                    y0: max(0, Int(r.minY * CGFloat(reader.height))),
                    x1: min(reader.width - 1, Int(r.maxX * CGFloat(reader.width))),
                    y1: min(reader.height - 1, Int(r.maxY * CGFloat(reader.height))))
            } else {
                bounds = PixelBounds(x0: 0, y0: 0, x1: reader.width - 1, y1: reader.height - 1)
            }
            guard bounds.x1 > bounds.x0, bounds.y1 > bounds.y0 else { return nil }

            let cols = (bounds.x1 - bounds.x0) / step + 1
            let rows = (bounds.y1 - bounds.y0) / step + 1
            guard cols > 2, rows > 2 else { return nil }

            // 1. Binary mask of ball-coloured samples.
            var mask = [Bool](repeating: false, count: cols * rows)
            var totalMatched = 0
            for row in 0..<rows {
                let y = bounds.y0 + row * step
                guard y <= bounds.y1 else { break }
                for col in 0..<cols {
                    let x = bounds.x0 + col * step
                    guard x <= bounds.x1 else { break }
                    let (r, g, b) = reader.rgb(x: x, y: y)
                    let hsv = BallColor.rgbToHSV(r, g, b)
                    if profile.matches(h: hsv.h, s: hsv.s, v: hsv.v) {
                        mask[row * cols + col] = true
                        totalMatched += 1
                    }
                }
            }
            guard totalMatched >= minPixels else { return nil }

            // 2. Largest connected blob, so a stray patch of the same colour elsewhere in the frame
            //    can't drag the centre off the ball.
            var visited = [Bool](repeating: false, count: cols * rows)
            var best: (count: Int, sumX: Int, sumY: Int) = (0, 0, 0)
            var queue: [Int] = []

            for start in 0..<(cols * rows) where mask[start] && !visited[start] {
                queue.removeAll(keepingCapacity: true)
                queue.append(start)
                visited[start] = true
                var count = 0, sumX = 0, sumY = 0

                var head = 0
                while head < queue.count {
                    let index = queue[head]; head += 1
                    let cx = index % cols, cy = index / cols
                    count += 1; sumX += cx; sumY += cy

                    // 8-connected, so a ball broken up by a highlight still reads as one blob.
                    for dy in -1...1 {
                        for dx in -1...1 where dx != 0 || dy != 0 {
                            let nx = cx + dx, ny = cy + dy
                            guard nx >= 0, nx < cols, ny >= 0, ny < rows else { continue }
                            let n = ny * cols + nx
                            guard mask[n], !visited[n] else { continue }
                            visited[n] = true
                            queue.append(n)
                        }
                    }
                }
                if count > best.count { best = (count, sumX, sumY) }
            }

            guard best.count >= minPixels else { return nil }

            // 3. Centre and equivalent-circle radius, back in FULL-FRAME terms — mask coordinates
            //    are relative to the search region, so its origin has to be added back.
            let meanCol = Double(best.sumX) / Double(best.count)
            let meanRow = Double(best.sumY) / Double(best.count)
            let pixelX = Double(bounds.x0) + meanCol * Double(step)
            let pixelY = Double(bounds.y0) + meanRow * Double(step)
            let center = CGPoint(x: (pixelX + Double(step) / 2) / Double(reader.width),
                                 y: (pixelY + Double(step) / 2) / Double(reader.height))
            let radiusPx = (Double(best.count) / .pi).squareRoot() * Double(step)

            return Detection(center: center,
                             radiusNormalized: radiusPx / Double(reader.width),
                             pixelCount: best.count,
                             totalMatched: totalMatched,
                             scannedPixels: cols * rows)
        } ?? nil
    }

    /// Distance to the ball implied by how big it looks, independent of any depth sensor.
    ///
    /// Straight pinhole: distance = (real diameter · focal) / apparent diameter. Useful as a second
    /// opinion — if this and LiDAR disagree badly, the depth patch is landing on something else.
    static func opticalDistance(radiusNormalized: Double, frameWidthPx: Double, focalLengthPx: Double) -> Double? {
        let radiusPx = radiusNormalized * frameWidthPx
        guard radiusPx > 0.5, focalLengthPx > 0 else { return nil }
        return CricketConstants.ballDiameter / 2 * focalLengthPx / radiusPx
    }
}
