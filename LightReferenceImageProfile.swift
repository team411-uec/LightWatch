import AppKit
import Foundation

extension LightSceneProfileBuilder {
    static func makeProfile(scene: LightScene, imageURL: URL, rois: [LightROI]) throws -> LightReferenceProfile {
        let edgePositiveROIs = rois.filter { $0.kind == .positive && $0.isEdgeArea }
        guard !edgePositiveROIs.isEmpty else {
            throw LightReferenceProfileError.emptyEdgeROI
        }

        let image = try LightReferenceImagePixels(imageURL: imageURL)
        let samples = try edgePositiveROIs.map { roi in
            let stats = try LightReferenceImageAnalyzer.analyzeROI(roi, image: image)
            return LightReferenceSample(
                roiName: stats.name,
                medianLuma: stats.medianLuma,
                brightRatio: stats.brightRatio,
                darkRatio: stats.darkRatio
            )
        }

        return LightReferenceProfile(scene: scene, samples: samples)
    }
}

private enum LightReferenceImageAnalyzer {
    static func analyzeROI(_ roi: LightROI, image: LightReferenceImagePixels) throws -> ROIStats {
        let brightThreshold = 180
        let darkThreshold = 50
        let xStart = max(0, min(image.width - 1, Int(roi.x * Double(image.width))))
        let yStart = max(0, min(image.height - 1, Int(roi.y * Double(image.height))))
        let xEnd = max(xStart + 1, min(image.width, Int((roi.x + roi.width) * Double(image.width))))
        let yEnd = max(yStart + 1, min(image.height, Int((roi.y + roi.height) * Double(image.height))))
        let step = max(1, min(image.width, image.height) / 80)

        var histogram = Array(repeating: 0, count: 256)
        var brightCount = 0
        var darkCount = 0
        var sampleCount = 0

        var y = yStart
        while y < yEnd {
            var x = xStart
            while x < xEnd {
                let luma = image.luma(x: x, y: y)
                histogram[luma] += 1
                if luma >= brightThreshold {
                    brightCount += 1
                }
                if luma <= darkThreshold {
                    darkCount += 1
                }
                sampleCount += 1
                x += step
            }
            y += step
        }

        guard sampleCount > 0 else {
            throw LightAnalyzerError.emptyROI
        }

        let medianLuma = median(from: histogram, sampleCount: sampleCount)
        return ROIStats(
            name: roi.name,
            kind: roi.kind,
            medianLuma: medianLuma,
            brightRatio: Double(brightCount) / Double(sampleCount),
            darkRatio: Double(darkCount) / Double(sampleCount),
            isDark: medianLuma <= Double(darkThreshold)
        )
    }

    private static func median(from histogram: [Int], sampleCount: Int) -> Double {
        let midpoint = (sampleCount + 1) / 2
        var running = 0
        for (luma, count) in histogram.enumerated() {
            running += count
            if running >= midpoint {
                return Double(luma)
            }
        }
        return 0
    }
}

private struct LightReferenceImagePixels {
    let width: Int
    let height: Int
    private let bytes: [UInt8]
    private let bytesPerPixel = 4

    init(imageURL: URL) throws {
        guard let nsImage = NSImage(contentsOf: imageURL),
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw LightReferenceProfileError.imageLoadFailed(imageURL.path)
        }

        width = cgImage.width
        height = cgImage.height
        var renderedBytes = Array(repeating: UInt8(0), count: width * height * bytesPerPixel)
        guard let context = CGContext(
            data: &renderedBytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * bytesPerPixel,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw LightReferenceProfileError.imageRenderFailed(imageURL.path)
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        bytes = renderedBytes
    }

    func luma(x: Int, y: Int) -> Int {
        let offset = (y * width + x) * bytesPerPixel
        let red = Double(bytes[offset])
        let green = Double(bytes[offset + 1])
        let blue = Double(bytes[offset + 2])
        return Int((0.2126 * red + 0.7152 * green + 0.0722 * blue).rounded())
    }
}
