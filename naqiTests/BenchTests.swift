import Testing
import Foundation
@testable import naqi

/// Records the numbers the PRD asks for next to the Android S23 baselines.
/// These are measurements, not pass/fail gates — the only assertion is that
/// each path produces finite output, because a fast NaN is worse than a slow
/// correct answer. Read the printed table.
///
/// On the SIMULATOR there is no Apple Neural Engine, so the CoreML rows
/// exercise the CPU/GPU partition only. The same test on a device is the real
/// ANE number.
@Suite("Bench", .serialized)
struct BenchTests {

    static let baselineS23 = "htdemucs 0.55x realtime (S23, ORT-Android CPU + XNNPACK)"

    /// Swift's String(format:) has no %s; pad explicitly.
    private func row(_ cols: String...) -> String {
        cols.map { $0.padding(toLength: max(14, $0.count + 1), withPad: " ", startingAt: 0) }.joined()
    }

    @Test("htdemucs: CPU vs CoreML execution provider")
    func demucsProviders() throws {
        print("\n=== htdemucs 2.6 s segment · baseline: \(Self.baselineS23) ===")
        print(row("provider", "load ms", "infer ms", "x-realtime", "finite"))

        var anyRan = false
        for unit in [ComputeUnit.cpu, .coreML] {
            let r = ModelSmoke.demucs(unit)
            guard r.ok else {
                print("\(unit)".padding(toLength: 14, withPad: " ", startingAt: 0) + " FAILED: " + (r.error ?? ""))
                continue
            }
            anyRan = true
            let seconds = Double(Models.Demucs.segmentFrames) / Double(Models.Demucs.sampleRate)
            print(row("\(unit)",
                      String(format: "%.0f", r.loadMs),
                      String(format: "%.0f", r.inferMs),
                      String(format: "%.2fx", seconds / (r.inferMs / 1000)),
                      r.detail.contains("finite=true") ? "yes" : "NO"))
            #expect(r.detail.contains("finite=true"), "\(unit) produced non-finite output")
        }
        #expect(anyRan, "no execution provider ran htdemucs")
    }

    @Test("NSFW gate: batching throughput")
    func nsfwBatching() throws {
        let m = try ModelRegistry.model(Models.Nsfw.file)
        let side = Models.Nsfw.side, per = 3 * side * side
        print("\n=== NSFW gate batching (analyze wall) ===")
        print(row("batch", "total ms", "ms/frame"))

        for n in [1, 4, 8] {
            let input = [Float](repeating: 0.5, count: per * n)
            let t = ContinuousClock.now
            let out = try m.run([Models.Nsfw.input: .float(input, shape: [n, 3, side, side])])
            let ms = Double((ContinuousClock.now - t).components.attoseconds) / 1e15
            #expect(out[Models.Nsfw.output]?.shape == [n, 5])
            print(row("\(n)", String(format: "%.1f", ms), String(format: "%.2f", ms / Double(n))))
        }
    }

    /// The 1.5 GB jetsam budget. `phys_footprint` is the number iOS actually
    /// kills on — `resident_size` understates it and is the usual mistake.
    ///
    /// ⚠ On the SIMULATOR this reads the host process's footprint, which shares
    /// the Mac's address space and comes back in the multi-GB range regardless
    /// of what the app allocates. Only the DELTA is meaningful here; the
    /// absolute number against the 1.5 GB budget must be taken on a device.
    @Test("peak memory footprint after loading every model")
    func footprint() throws {
        let before = MemoryFootprint.current()
        for f in Models.bundled { _ = try ModelRegistry.model(f) }
        _ = ModelSmoke.demucs(.cpu)
        let after = MemoryFootprint.current()
        print("\n=== footprint ===")
        print(String(format: "before %.0f MB  after %.0f MB  (budget 1536 MB)",
                     Double(before) / 1_048_576, Double(after) / 1_048_576))
        MemoryFootprint.note("after all models")
        #expect(after > 0, "phys_footprint unavailable")
    }
}
