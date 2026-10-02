import CoreGraphics
import CoreImage
import CoreML
import CoreVideo
import Foundation

enum PersonDetectionError: Error, LocalizedError {
    case modelMissing
    case modelContract
    case invalidOutput
    case invalidFrame
    case pixelBuffer(CVReturn)

    var errorDescription: String? {
        switch self {
        case .modelMissing: "The person detection model is missing. Run scripts/fetch-person-model.py before building."
        case .modelContract: "The person detection model does not match the validated YOLO11 contract."
        case .invalidOutput: "Person detection returned invalid values."
        case .invalidFrame: "The video frame has invalid person detection coordinates."
        case .pixelBuffer(let code): "The person detection image buffer could not be allocated (\(code))."
        }
    }
}

/// The actor owns the reusable RGB input and model; calls finish while the
/// sampler still owns its YUV slot. Results use FaceDetector's upright pixels.
actor PersonDetector {
    static let side = 640
    static let confidence: Float = 0.25
    static let nmsIoU: CGFloat = 0.7
    private let model: MLModel
    private let outputName: String
    private let input: CVPixelBuffer
    private let context: CIContext

    init(modelURL: URL? = Models.personURL) throws {
        guard let modelURL else { throw PersonDetectionError.modelMissing }
        let configuration = MLModelConfiguration()
        #if targetEnvironment(simulator)
        configuration.computeUnits = .cpuOnly
        #else
        configuration.computeUnits = .cpuAndGPU
        #endif
        model = try MLModel(contentsOf: modelURL, configuration: configuration)
        guard let image = model.modelDescription.inputDescriptionsByName["image"]?.imageConstraint,
              image.pixelsWide == Self.side, image.pixelsHigh == Self.side,
              let output = model.modelDescription.outputDescriptionsByName.first(where: {
                  $0.value.multiArrayConstraint?.shape.map(\.intValue) == [1, 116, 8400]
              }), output.value.multiArrayConstraint?.dataType == .float32 else {
            throw PersonDetectionError.modelContract
        }
        outputName = output.key
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(nil, Self.side, Self.side, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let buffer else { throw PersonDetectionError.pixelBuffer(status) }
        input = buffer
        // Ultralytics resizes electrical RGB values rather than linear light.
        context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(),
                                      .cacheIntermediates: false, .highQualityDownsample: false])
    }

    func detect(_ frame: SampledFrame) throws -> [CGRect] {
        try Task.checkCancellation()
        // Core ML/CI create autoreleased tensors and images. Bound their life
        // to one frame rather than the long-lived analysis task's outer pool.
        return try autoreleasepool {
            let layout = try Self.prepare(frame, into: input, context: context)
            let provider = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: input)])
            let prediction = try model.prediction(from: provider)
            guard let output = prediction.featureValue(for: outputName)?.multiArrayValue else {
                throw PersonDetectionError.modelContract
            }
            try Task.checkCancellation()
            return try Self.decode(output, layout: layout)
        }
    }

    struct Letterbox: Sendable {
        let source: CGSize
        let scale: CGFloat
        let width: Int, height: Int, left: Int, top: Int

        init(source: CGSize) throws {
            guard source.width.isFinite, source.height.isFinite, source.width > 0, source.height > 0 else {
                throw PersonDetectionError.invalidFrame
            }
            self.source = source
            scale = min(CGFloat(PersonDetector.side) / source.width, CGFloat(PersonDetector.side) / source.height)
            width = Int((source.width * scale).rounded())
            height = Int((source.height * scale).rounded())
            // Matches LetterBox(center=True,auto=False), including odd padding.
            left = Int((CGFloat(PersonDetector.side - width) / 2 - 0.1).rounded())
            top = Int((CGFloat(PersonDetector.side - height) / 2 - 0.1).rounded())
        }

        func upright(_ rect: CGRect) -> CGRect {
            CGRect(x: (rect.minX - CGFloat(left)) / scale,
                   y: (rect.minY - CGFloat(top)) / scale,
                   width: rect.width / scale, height: rect.height / scale)
                .intersection(CGRect(origin: .zero, size: source))
        }
    }

    static func prepare(_ frame: SampledFrame, into input: CVPixelBuffer, context: CIContext) throws -> Letterbox {
        let layout = try Letterbox(source: frame.transform.uprightSize)
        let oriented = CIImage(cvPixelBuffer: frame.detect).oriented(frame.orientation)
        guard abs(oriented.extent.width - layout.source.width) < 0.5,
              abs(oriented.extent.height - layout.source.height) < 0.5 else { throw PersonDetectionError.invalidFrame }
        let upright = oriented.transformed(by: CGAffineTransform(translationX: -oriented.extent.minX, y: -oriented.extent.minY))
        let resized = upright.transformed(by: CGAffineTransform(scaleX: CGFloat(layout.width) / layout.source.width,
                                                               y: CGFloat(layout.height) / layout.source.height))
        // Core Image uses bottom-left coordinates; model boxes use top-left.
        let placed = resized.transformed(by: CGAffineTransform(translationX: CGFloat(layout.left),
            y: CGFloat(Self.side - layout.height - layout.top)))
        let bounds = CGRect(x: 0, y: 0, width: Self.side, height: Self.side)
        let background = CIImage(color: CIColor(red: 114.0 / 255, green: 114.0 / 255, blue: 114.0 / 255, alpha: 1)).cropped(to: bounds)
        context.render(placed.composited(over: background), to: input, bounds: bounds, colorSpace: nil)
        return layout
    }

    static func decode(_ output: MLMultiArray, layout: Letterbox) throws -> [CGRect] {
        guard output.shape.map(\.intValue) == [1, 116, 8400], output.dataType == .float32 else {
            throw PersonDetectionError.modelContract
        }
        let strides = output.strides.map(\.intValue)
        let values = output.dataPointer.assumingMemoryBound(to: Float.self)
        var candidates: [(rect: CGRect, score: Float, index: Int)] = []
        for i in 0..<8400 {
            let person = values[4 * strides[1] + i * strides[2]]
            guard person.isFinite else { throw PersonDetectionError.invalidOutput }
            guard person > Self.confidence else { continue }
            // classes=[0],multi_label=False keeps only anchors whose best class
            // is person; accepting its score alone differs from the benchmark.
            var personIsBest = true
            for c in 1..<80 {
                let score = values[(4 + c) * strides[1] + i * strides[2]]
                guard score.isFinite else { throw PersonDetectionError.invalidOutput }
                if score > person { personIsBest = false }
            }
            guard personIsBest else { continue }
            let x = values[i * strides[2]], y = values[strides[1] + i * strides[2]]
            let width = values[2 * strides[1] + i * strides[2]], height = values[3 * strides[1] + i * strides[2]]
            guard x.isFinite, y.isFinite, width.isFinite, height.isFinite, width > 0, height > 0 else {
                throw PersonDetectionError.invalidOutput
            }
            candidates.append((CGRect(x: CGFloat(x - width / 2), y: CGFloat(y - height / 2),
                                      width: CGFloat(width), height: CGFloat(height)), person, i))
        }
        candidates.sort { $0.score == $1.score ? $0.index < $1.index : $0.score > $1.score }
        var kept: [CGRect] = []
        for candidate in candidates {
            guard kept.allSatisfy({ Self.iou($0, candidate.rect) <= Self.nmsIoU }) else { continue }
            kept.append(candidate.rect)
            if kept.count == 300 { break } // Same max_det as the validated reference.
        }
        return kept.map(layout.upright).filter { !$0.isNull && !$0.isEmpty }
    }

    private static func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        guard !intersection.isNull, !intersection.isEmpty else { return 0 }
        let area = intersection.width * intersection.height
        return area / (a.width * a.height + b.width * b.height - area)
    }
}
