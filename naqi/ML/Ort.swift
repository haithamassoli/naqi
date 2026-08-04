import Foundation
import os
import OnnxRuntimeBindings

/// Which execution provider a session should try. Falling back to CPU is always
/// allowed — ORT partitions the graph and leaves unsupported nodes on CPU.
enum ComputeUnit: Sendable {
    /// CPU only. The reference path: matches Android numerics exactly.
    case cpu
    /// CoreML EP, ANE + GPU + CPU. No ANE on the simulator — it silently runs CPU/GPU there.
    case coreML
    /// CoreML EP restricted to CPU+GPU. Useful when ANE quantization skews outputs.
    case coreMLNoANE
}

enum OrtError: Error, CustomStringConvertible {
    case modelMissing(String)
    case shapeMismatch(expected: [Int], got: [Int])
    case outputMissing(String)

    var description: String {
        switch self {
        case .modelMissing(let n): "model not found in bundle: \(n)"
        case .shapeMismatch(let e, let g): "tensor shape mismatch: expected \(e), got \(g)"
        case .outputMissing(let n): "session produced no output named \(n)"
        }
    }
}

/// Process-wide ORT environment. ORT wants exactly one.
enum Ort {
    nonisolated(unsafe) static let env: ORTEnv = {
        // swiftlint:disable:next force_try — a failure here means the binary is broken.
        try! ORTEnv(loggingLevel: .warning)
    }()

    static var coreMLAvailable: Bool { ORTIsCoreMLExecutionProviderAvailable() }
}

/// A loaded ONNX graph plus its IO names. Not an actor: ORT sessions are
/// thread-safe for concurrent `Run` calls, and making this an actor would
/// serialize inference that we explicitly want to overlap with decode.
final class OrtModel: @unchecked Sendable {
    let name: String
    let session: ORTSession
    let inputNames: [String]
    let outputNames: [String]
    let compute: ComputeUnit

    /// - Parameters:
    ///   - threads: intra-op threads. 1 matches Android (`ml/Models.kt` pins it
    ///     to 1 with spinning disabled) and keeps N concurrent sessions from
    ///     oversubscribing the P-cores.
    convenience init(bundledModel name: String, compute: ComputeUnit = .cpu, threads: Int = 1) throws {
        guard let path = Bundle.main.path(forResource: name, ofType: "onnx", inDirectory: "Models")
                ?? Bundle.main.path(forResource: name, ofType: "onnx") else {
            throw OrtError.modelMissing(name)
        }
        try self.init(name: name, path: path, compute: compute, threads: threads)
    }

    init(name: String, path: String, compute: ComputeUnit, threads: Int = 1) throws {
        self.name = name
        self.compute = compute

        let opts = try ORTSessionOptions()
        try opts.setLogSeverityLevel(.warning)
        try opts.setGraphOptimizationLevel(.all)
        try opts.setIntraOpNumThreads(Int32(threads))
        // Android pins spinning off so idle worker threads don't burn battery
        // between chunks; the same applies under iOS thermal pressure.
        try opts.addConfigEntry(withKey: "session.intra_op.allow_spinning", value: "0")

        var resolved = compute
        if compute != .cpu {
            if Ort.coreMLAvailable {
                let ml = ORTCoreMLExecutionProviderOptions()
                ml.createMLProgram = true          // MLProgram, not the legacy NeuralNetwork format
                ml.useCPUAndGPU = (compute == .coreMLNoANE)
                ml.onlyAllowStaticInputShapes = true // every graph we run has fixed shapes
                do { try opts.appendCoreMLExecutionProvider(with: ml) }
                catch {
                    Log.ml.warning("\(name, privacy: .public): CoreML EP rejected (\(error.localizedDescription, privacy: .public)); CPU")
                    resolved = .cpu
                }
            } else {
                Log.ml.notice("\(name, privacy: .public): CoreML EP unavailable; CPU")
                resolved = .cpu
            }
        }

        self.session = try ORTSession(env: Ort.env, modelPath: path, sessionOptions: opts)
        self.inputNames = try session.inputNames()
        self.outputNames = try session.outputNames()
        Log.ml.info("loaded \(name, privacy: .public) ep=\(String(describing: resolved), privacy: .public) in=\(self.inputNames, privacy: .public) out=\(self.outputNames, privacy: .public)")
    }

    func run(_ inputs: [String: ORTValue], outputs: Set<String>? = nil) throws -> [String: ORTValue] {
        try session.run(withInputs: inputs,
                        outputNames: outputs ?? Set(outputNames),
                        runOptions: nil)
    }
}

/// Process-wide cache of loaded graphs.
///
/// htdemucs alone is 88 MB on disk and roughly 1.3 GB of working set once
/// resident, so loading it twice is not a slow path — it is an out-of-memory
/// kill on a phone. Every consumer goes through here.
enum ModelRegistry {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: OrtModel] = [:]

    /// The lock is held across construction, not just the dictionary access.
    /// Two threads calling `CreateSession` on the same graph concurrently
    /// segfaults inside ORT, and the cost of serialising is one 300 ms load per
    /// model per process.
    static func model(_ file: String, compute: ComputeUnit = .cpu, threads: Int = 1) throws -> OrtModel {
        let key = "\(file)#\(compute)#\(threads)"
        lock.lock()
        defer { lock.unlock() }
        if let m = cache[key] { return m }
        let built = try OrtModel(bundledModel: file, compute: compute, threads: threads)
        cache[key] = built
        return built
    }

    /// Drops cached sessions. Called when a job finishes so a 1.3 GB htdemucs
    /// arena is not held while the user is just browsing the UI.
    static func evictAll() {
        lock.lock(); defer { lock.unlock() }
        cache.removeAll()
    }
}

// MARK: - Tensor helpers

extension ORTValue {
    /// Wraps a float buffer as a tensor. `data` is copied into the NSMutableData
    /// ORT takes ownership of, so the caller's storage can be reused immediately.
    static func float(_ data: [Float], shape: [Int]) throws -> ORTValue {
        let count = shape.reduce(1, *)
        precondition(data.count == count, "float tensor: \(data.count) values for shape \(shape)")
        let bytes = data.withUnsafeBufferPointer { NSMutableData(bytes: $0.baseAddress!, length: $0.count * 4) }
        return try ORTValue(tensorData: bytes,
                            elementType: .float,
                            shape: shape.map(NSNumber.init(value:)))
    }

    /// Zero tensor of the given shape — the smoke-test input.
    static func zeros(shape: [Int]) throws -> ORTValue {
        try .float([Float](repeating: 0, count: shape.reduce(1, *)), shape: shape)
    }

    var shape: [Int] {
        (try? tensorTypeAndShapeInfo().shape.map(\.intValue)) ?? []
    }

    /// Copies the tensor payload out as floats.
    func floats() throws -> [Float] {
        let d = try tensorData() as Data
        return d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}
