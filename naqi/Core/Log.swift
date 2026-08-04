import Foundation
import os

/// One logger per subsystem area. `Log.perf` is also the signpost source, so
/// Instruments picks up the pipeline stages without extra wiring.
enum Log {
    static let subsystem = "com.haithamassoli.naqi"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let ml = Logger(subsystem: subsystem, category: "ml")
    static let media = Logger(subsystem: subsystem, category: "media")
    static let audio = Logger(subsystem: subsystem, category: "audio")
    static let analyze = Logger(subsystem: subsystem, category: "analyze")
    static let render = Logger(subsystem: subsystem, category: "render")
    static let job = Logger(subsystem: subsystem, category: "job")
    static let perf = Logger(subsystem: subsystem, category: "perf")

    static let signposter = OSSignposter(subsystem: subsystem, category: "perf")
}

/// Wall-clock timer that logs on `stop()`. Every pipeline stage reports through
/// this so the per-shape wall breakdown (perf-plan-v4's framing) is always
/// available from a release build, not just under Instruments.
struct Stage: ~Copyable {
    private let name: StaticString
    private let start: ContinuousClock.Instant
    private let state: OSSignpostIntervalState
    private let id: OSSignpostID

    init(_ name: StaticString) {
        self.name = name
        self.start = ContinuousClock.now
        self.id = Log.signposter.makeSignpostID()
        self.state = Log.signposter.beginInterval(name, id: id)
    }

    /// Milliseconds elapsed so far.
    var elapsedMs: Double { Double((ContinuousClock.now - start).components.attoseconds) / 1e15 }

    consuming func stop(_ detail: String = "") {
        let ms = elapsedMs
        Log.signposter.endInterval(name, state)
        Log.perf.info("\(String(describing: name), privacy: .public) \(ms, format: .fixed(precision: 1))ms \(detail, privacy: .public)")
    }
}
