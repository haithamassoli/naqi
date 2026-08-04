import Testing
import Foundation
import OnnxRuntimeBindings
@testable import naqi

/// Records the numbers the PRD asks for next to the Android S23 baselines.
/// These are measurements, not pass/fail gates — the only assertion is that
/// each path produces finite output, because a fast NaN is worse than a slow
/// correct answer. Read the printed table.
///
/// **Every timing is a min-of-N.** A wall-clock mean on a developer machine
/// measures the machine, not the code: the same htdemucs segment read 617 ms
/// idle and 4231 ms with parallel builds running, and a 1-minute load average
/// lags far too much to gate on. Contention can only ever make a sample slower,
/// so the minimum is the closest thing to the true cost that a shared machine
/// can report.
///
/// ⚠ SIMULATOR CAVEATS: no Apple Neural Engine (the CoreML rows exercise
/// CPU/GPU only), no hardware H.264 decoder, and Vision falls back to CPU.
/// These bound the problem and prove the code paths; M7's acceptance numbers
/// must be taken on a device.
@Suite("Bench", .serialized)
struct BenchTests {

    static let baselineS23 = "0.55x realtime (S23, ORT-Android CPU + XNNPACK)"

    /// Swift's String(format:) has no %s; pad explicitly.
    private func row(_ cols: String...) -> String {
        cols.map { $0.padding(toLength: max(13, $0.count + 1), withPad: " ", startingAt: 0) }.joined()
    }

    /// Runs `body` `n` times and returns the fastest, in milliseconds.
    private func best(_ n: Int, _ body: () throws -> Void) rethrows -> Double {
        var ms = Double.infinity
        for _ in 0..<n {
            let t = ContinuousClock.now
            try body()
            ms = min(ms, t.duration(to: .now).milliseconds)
        }
        return ms
    }

    @Test("htdemucs: CPU vs CoreML execution provider")
    func demucsProviders() throws {
        let D = Models.Demucs.self
        let audioSeconds = Double(D.segmentFrames) / Double(D.sampleRate)
        let wave = try ORTValue.zeros(shape: [1, D.channels, D.segmentFrames])
        let spec = try ORTValue.zeros(shape: [1, 4, D.specBins, D.specFrames])

        print("\n=== htdemucs, one 2.6 s segment · Android baseline \(Self.baselineS23) ===")
        print(row("provider", "session ms", "best infer", "x-realtime", "finite"))

        for unit in [ComputeUnit.cpu, .coreML] {
            // Session creation is reported separately: the CoreML EP compiles
            // the graph to an MLModel here, which is a one-off cost on device
            // (it caches) but dominates a cold measurement.
            let t0 = ContinuousClock.now
            let m: OrtModel
            do { m = try ModelRegistry.model(D.file, compute: unit, threads: Ort.computeThreads) }
            catch { print(row("\(unit)", "FAILED", "\(error)")); continue }
            let sessionMs = t0.duration(to: .now).milliseconds

            var out: [String: ORTValue] = [:]
            let inferMs = try best(3) {
                out = try m.run([D.waveInput: wave, D.specInput: spec])
            }
            let finite = try (out[D.waveOutput]?.floats() ?? []).allSatisfy { $0.isFinite }
            print(row("\(unit)",
                      String(format: "%.0f", sessionMs),
                      String(format: "%.0f", inferMs),
                      String(format: "%.2fx", audioSeconds / (inferMs / 1000)),
                      finite ? "yes" : "NO"))
            #expect(finite, "\(unit) produced non-finite output")
        }
        // Leave nothing resident: the next suite should not inherit 1.3 GB.
        ModelRegistry.evict(D.file)
    }

    @Test("NSFW gate: does batching help?")
    func nsfwBatching() throws {
        // Thread count matters more than batch size, and measuring batching at
        // 1 thread flatters it: a lone frame cannot saturate the cores, so
        // batching looks like a win that vanishes once the session is threaded
        // correctly. Measure at the real setting.
        let m = try ModelRegistry.model(Models.Nsfw.file, threads: Ort.computeThreads)
        let side = Models.Nsfw.side, per = 3 * side * side
        print("\n=== NSFW gate batching, threads=\(Ort.computeThreads) (analyze wall) ===")
        print(row("batch", "best ms", "ms/frame"))

        for n in [1, 2, 4, 8] {
            let input = try ORTValue.float([Float](repeating: 0.5, count: per * n),
                                           shape: [n, 3, side, side])
            var out: [String: ORTValue] = [:]
            let ms = try best(5) { out = try m.run([Models.Nsfw.input: input]) }
            #expect(out[Models.Nsfw.output]?.shape == [n, 5])
            print(row("\(n)", String(format: "%.1f", ms), String(format: "%.2f", ms / Double(n))))
        }
    }

    /// The 1.5 GB jetsam budget. `phys_footprint` is the number iOS actually
    /// kills on — `resident_size` understates it and is the usual mistake.
    ///
    /// ⚠ On the SIMULATOR this reads the host process's footprint, which shares
    /// the Mac's address space and moves for reasons unrelated to this app.
    /// Only the DELTA means anything here; the absolute figure against the
    /// budget must come from a device.
    @Test("htdemucs resident cost")
    func footprint() throws {
        ModelRegistry.evict(Models.Demucs.file)
        let before = MemoryFootprint.current()
        _ = try ModelRegistry.model(Models.Demucs.file, threads: Ort.computeThreads)
        _ = ModelSmoke.demucs(.cpu)
        let loaded = MemoryFootprint.current()
        ModelRegistry.evict(Models.Demucs.file)

        print("\n=== htdemucs resident cost (delta is the only usable figure here) ===")
        print(String(format: "before %.0f MB → loaded %.0f MB → delta %+.0f MB   (device budget 1536 MB)",
                     Double(before) / 1_048_576, Double(loaded) / 1_048_576,
                     (Double(loaded) - Double(before)) / 1_048_576))
        #expect(loaded > 0, "phys_footprint unavailable")
    }
}
