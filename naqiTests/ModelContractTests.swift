import Testing
import Foundation
@testable import naqi

/// The M0 gate. If any of these fail, no downstream stage can be trusted:
/// the graphs are the same artifacts Android ships, so shape/finiteness
/// disagreement means the Apple runtime is doing something different.
@Suite("Model contracts", .serialized)
struct ModelContractTests {

    @Test("all bundled models are present")
    func modelsPresent() throws {
        for m in Models.bundled {
            #expect(Models.url(m) != nil, "missing \(m).onnx — run scripts/fetch-models.sh")
        }
    }

    @Test("smoke: every graph loads and runs on CPU")
    func smokeCPU() throws {
        for r in ModelSmoke.runAll(compute: .cpu) {
            #expect(r.ok, "\(r.model): \(r.error ?? "")")
            print("[smoke cpu] \(r.model) load=\(Int(r.loadMs))ms infer=\(Int(r.inferMs))ms \(r.detail)")
        }
    }

    @Test("NSFW gate: 5 classes, softmax sums to 1")
    func nsfwContract() throws {
        let m = try ModelRegistry.model( Models.Nsfw.file)
        #expect(m.inputNames == [Models.Nsfw.input])
        #expect(m.outputNames == [Models.Nsfw.output])
        let side = Models.Nsfw.side
        let out = try m.run([Models.Nsfw.input: .zeros(shape: [1, 3, side, side])])
        let y = try #require(out[Models.Nsfw.output])
        #expect(y.shape == [1, 5])
        let p = try y.floats()
        #expect(abs(p.reduce(0, +) - 1.0) < 1e-4, "not a softmax: \(p)")
        #expect(p.allSatisfy { $0.isFinite })
    }

    /// The dynamic batch dim is the analyze-wall lever — prove it actually works
    /// and that batched results equal single-frame results.
    @Test("NSFW gate: dynamic batch matches single-frame")
    func nsfwBatch() throws {
        let m = try ModelRegistry.model( Models.Nsfw.file)
        let side = Models.Nsfw.side, n = 4
        let per = 3 * side * side

        // Four distinguishable constant-value frames.
        var batch = [Float]()
        for i in 0..<n { batch += [Float](repeating: Float(i) * 0.25, count: per) }

        let bOut = try m.run([Models.Nsfw.input: .float(batch, shape: [n, 3, side, side])])
        let by = try #require(bOut[Models.Nsfw.output])
        #expect(by.shape == [n, 5])
        let bp = try by.floats()

        for i in 0..<n {
            let single = [Float](repeating: Float(i) * 0.25, count: per)
            let sOut = try m.run([Models.Nsfw.input: .float(single, shape: [1, 3, side, side])])
            let sp = try #require(sOut[Models.Nsfw.output]).floats().get()
            for c in 0..<5 {
                #expect(abs(bp[i * 5 + c] - sp[c]) < 1e-4,
                        "batch row \(i) class \(c): \(bp[i * 5 + c]) vs \(sp[c])")
            }
        }
    }

    @Test("genderage: [1,3] output")
    func genderAgeContract() throws {
        let m = try ModelRegistry.model( Models.GenderAge.file)
        #expect(m.inputNames == [Models.GenderAge.input])
        let side = Models.GenderAge.side
        let out = try m.run([Models.GenderAge.input: .zeros(shape: [1, 3, side, side])])
        let y = try #require(out[Models.GenderAge.output])
        #expect(y.shape == [1, 3])
        #expect(try y.floats().allSatisfy { $0.isFinite })
    }

    /// The PRD's headline risk: fp16 execution produced NaN on Android. The
    /// graph has fp16 initializers but fp32 IO, so the runtime must up-cast.
    @Test("htdemucs: fp16 weights produce finite fp32 output")
    func demucsFinite() throws {
        let D = Models.Demucs.self
        let m = try ModelRegistry.model( D.file)
        #expect(Set(m.inputNames) == [D.waveInput, D.specInput])

        // Non-zero input: zeros can be finite through a graph that still NaNs
        // on real signal, so drive it with a deterministic tone + noise-free ramp.
        var wave = [Float](repeating: 0, count: 2 * D.segmentFrames)
        for i in 0..<D.segmentFrames {
            let s = sinf(2 * .pi * 440 * Float(i) / Float(D.sampleRate)) * 0.5
            wave[i] = s
            wave[D.segmentFrames + i] = s
        }
        var spec = [Float](repeating: 0, count: 4 * D.specBins * D.specFrames)
        for i in stride(from: 0, to: spec.count, by: 7) { spec[i] = 0.01 }

        let out = try m.run([
            D.waveInput: .float(wave, shape: [1, D.channels, D.segmentFrames]),
            D.specInput: .float(spec, shape: [1, 4, D.specBins, D.specFrames]),
        ])
        let w = try #require(out[D.waveOutput])
        let s = try #require(out[D.specOutput])
        #expect(w.shape == [1, 4, D.channels, D.segmentFrames])
        #expect(s.shape == [1, 4, 4, D.specBins, D.specFrames])

        let wf = try w.floats()
        #expect(wf.allSatisfy { $0.isFinite }, "htdemucs wave output has NaN/Inf — the fp16 risk fired")
        let sf = try s.floats()
        #expect(sf.allSatisfy { $0.isFinite }, "htdemucs spec output has NaN/Inf")
        // A real separation must not be silent.
        #expect(wf.contains { abs($0) > 1e-6 }, "htdemucs produced digital silence")
    }
}

private extension Array where Element == Float {
    func get() -> [Float] { self }
}
