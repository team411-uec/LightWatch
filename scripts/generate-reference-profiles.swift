#!/usr/bin/env swift

import AppKit
import Foundation

struct LightWatchSettings: Codable {
    var discordWebhookURL: String
    var cameraUniqueID: String
    var launchAtLogin: Bool
    var captureIntervalSec: TimeInterval
    var shortDiffSec: TimeInterval
    var onConfirmSec: TimeInterval
    var offConfirmSec: TimeInterval
    var minDeltaOn: Double
    var minDeltaOff: Double
    var requiredPositiveROICount: Int
    var darkReferenceProfile: LightReferenceProfile?
    var brightReferenceProfile: LightReferenceProfile?
    var rois: [LightROI]

    static let `default` = LightWatchSettings(
        discordWebhookURL: "",
        cameraUniqueID: "",
        launchAtLogin: false,
        captureIntervalSec: 1,
        shortDiffSec: 5,
        onConfirmSec: 60,
        offConfirmSec: 600,
        minDeltaOn: 18,
        minDeltaOff: -18,
        requiredPositiveROICount: 2,
        darkReferenceProfile: nil,
        brightReferenceProfile: nil,
        rois: [
            LightROI(name: "topLeftEdge", kind: .positive, x: 0.02, y: 0.02, width: 0.26, height: 0.22),
            LightROI(name: "topRightEdge", kind: .positive, x: 0.72, y: 0.02, width: 0.26, height: 0.22),
            LightROI(name: "bottomLeftEdge", kind: .positive, x: 0.02, y: 0.76, width: 0.26, height: 0.22),
            LightROI(name: "bottomRightEdge", kind: .positive, x: 0.72, y: 0.76, width: 0.26, height: 0.22)
        ]
    )
}

struct LightROI: Codable {
    let name: String
    let kind: ROIKind
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

enum ROIKind: String, Codable {
    case positive
    case negative
}

enum LightScene: String, Codable {
    case dark
    case bright
}

struct LightReferenceProfile: Codable {
    let scene: LightScene
    let samples: [LightReferenceSample]
}

struct LightReferenceSample: Codable {
    let roiName: String
    let medianLuma: Double
    let brightRatio: Double
    let darkRatio: Double
}

struct ROIStats {
    let name: String
    let medianLuma: Double
    let brightRatio: Double
    let darkRatio: Double
}

enum ScriptError: LocalizedError {
    case missingArgument(String)
    case imageLoadFailed(String)
    case imageRenderFailed(String)
    case emptyEdgeROI
    case emptyROI(String)

    var errorDescription: String? {
        switch self {
        case .missingArgument(let name):
            return "\(name)を指定してください。"
        case .imageLoadFailed(let path):
            return "画像を読み込めません: \(path)"
        case .imageRenderFailed(let path):
            return "画像を解析用に変換できません: \(path)"
        case .emptyEdgeROI:
            return "端にあるpositive ROIがありません。"
        case .emptyROI(let name):
            return "ROIの解析対象ピクセルがありません: \(name)"
        }
    }
}

do {
    try main()
} catch {
    fputs("エラー: \(error.localizedDescription)\n", stderr)
    exit(1)
}

func main() throws {
    let defaultConfigURL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("LightWatch/config.json")

    let arguments = parseArguments(CommandLine.arguments.dropFirst())
    let darkImagePath = try requiredValue(arguments["dark"], name: "--dark")
    let brightImagePath = try requiredValue(arguments["bright"], name: "--bright")
    let configURL = URL(fileURLWithPath: arguments["config"] ?? defaultConfigURL.path)

    var settings = try loadSettings(configURL: configURL)
    settings.darkReferenceProfile = try makeProfile(scene: .dark, imagePath: darkImagePath, rois: settings.rois)
    settings.brightReferenceProfile = try makeProfile(scene: .bright, imagePath: brightImagePath, rois: settings.rois)
    try saveSettings(settings, configURL: configURL)

    print("基準を保存しました: \(configURL.path)")
}

func parseArguments(_ arguments: ArraySlice<String>) -> [String: String] {
    var result: [String: String] = [:]
    var iterator = arguments.makeIterator()
    while let key = iterator.next() {
        guard key.hasPrefix("--"), let value = iterator.next() else {
            continue
        }
        result[String(key.dropFirst(2))] = value
    }
    return result
}

func requiredValue(_ value: String?, name: String) throws -> String {
    guard let value, !value.isEmpty else {
        throw ScriptError.missingArgument(name)
    }
    return value
}

func loadSettings(configURL: URL) throws -> LightWatchSettings {
    guard FileManager.default.fileExists(atPath: configURL.path) else {
        return .default
    }
    let data = try Data(contentsOf: configURL)
    return try JSONDecoder().decode(LightWatchSettings.self, from: data)
}

func saveSettings(_ settings: LightWatchSettings, configURL: URL) throws {
    try FileManager.default.createDirectory(
        at: configURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(settings)
    try data.write(to: configURL, options: .atomic)
}

func makeProfile(scene: LightScene, imagePath: String, rois: [LightROI]) throws -> LightReferenceProfile {
    let edgePositiveROIs = rois.filter { $0.kind == .positive && $0.isEdgeArea }
    guard !edgePositiveROIs.isEmpty else {
        throw ScriptError.emptyEdgeROI
    }

    let image = try ImagePixels(imagePath: imagePath)
    let samples = try edgePositiveROIs.map { roi in
        let stats = try analyzeROI(roi, image: image)
        return LightReferenceSample(
            roiName: stats.name,
            medianLuma: stats.medianLuma,
            brightRatio: stats.brightRatio,
            darkRatio: stats.darkRatio
        )
    }

    return LightReferenceProfile(scene: scene, samples: samples)
}

func analyzeROI(_ roi: LightROI, image: ImagePixels) throws -> ROIStats {
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
        throw ScriptError.emptyROI(roi.name)
    }

    return ROIStats(
        name: roi.name,
        medianLuma: median(from: histogram, sampleCount: sampleCount),
        brightRatio: Double(brightCount) / Double(sampleCount),
        darkRatio: Double(darkCount) / Double(sampleCount)
    )
}

func median(from histogram: [Int], sampleCount: Int) -> Double {
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

struct ImagePixels {
    let width: Int
    let height: Int
    private let bytes: [UInt8]
    private let bytesPerPixel = 4

    init(imagePath: String) throws {
        guard let nsImage = NSImage(contentsOfFile: imagePath),
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ScriptError.imageLoadFailed(imagePath)
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
            throw ScriptError.imageRenderFailed(imagePath)
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

private extension LightROI {
    var isEdgeArea: Bool {
        x <= 0.12 || y <= 0.12 || x + width >= 0.88 || y + height >= 0.88
    }
}
