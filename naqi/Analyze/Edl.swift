import CoreGraphics
import Foundation

/// A rect in **upright-normalised** `[0,1]` space, already 25 %-padded and
/// clamped. Matches Android `analysis/Contracts.kt:11` `NRect`.
struct NRect: Codable, Sendable, Equatable {
    var left: Float, top: Float, right: Float, bottom: Float

    var width: Float { right - left }
    var height: Float { bottom - top }
    var isEmpty: Bool { width <= 0 || height <= 0 }

    /// Denormalise into a pixel rect in the given upright frame size.
    func rect(in size: CGSize) -> CGRect {
        CGRect(x: CGFloat(left) * size.width,
               y: CGFloat(top) * size.height,
               width: CGFloat(width) * size.width,
               height: CGFloat(height) * size.height)
    }

    static func lerp(_ a: NRect, _ b: NRect, _ t: Float) -> NRect {
        NRect(left: a.left + (b.left - a.left) * t,
              top: a.top + (b.top - a.top) * t,
              right: a.right + (b.right - a.right) * t,
              bottom: a.bottom + (b.bottom - a.bottom) * t)
    }
}

/// One face's on-screen span plus its sampled boxes. Between keyframes the box
/// is linearly interpolated, which is what turns a 10 fps detection pass into a
/// full-frame-rate censor (Android `analysis/FaceTracker.kt` §4.5).
struct FaceTrackEdl: Codable, Sendable, Equatable {
    /// First sample − 50 ms, clamped at 0.
    var startMs: Int64
    /// Last sample + 50 ms.
    var endMs: Int64
    /// Ascending by time. `(timeMs, rect)`.
    var keyframes: [Keyframe]

    struct Keyframe: Codable, Sendable, Equatable {
        var timeMs: Int64
        var rect: NRect
    }

    /// Interpolated box at `t`, or nil outside the span / with no keyframes.
    /// Before the first and after the last keyframe the nearest box is held,
    /// so the pad around the span never renders an empty region.
    func rect(at t: Int64) -> NRect? {
        guard t >= startMs, t <= endMs, let first = keyframes.first, let last = keyframes.last
        else { return nil }
        if t <= first.timeMs { return first.rect }
        if t >= last.timeMs { return last.rect }
        // Keyframes are ascending; a linear scan is cheaper than a binary
        // search at the few-dozen keyframes a real track carries, and this runs
        // once per rendered frame.
        var prev = first
        for k in keyframes.dropFirst() {
            if k.timeMs >= t {
                let span = Float(k.timeMs - prev.timeMs)
                guard span > 0 else { return k.rect }
                return NRect.lerp(prev.rect, k.rect, Float(t - prev.timeMs) / span)
            }
            prev = k
        }
        return last.rect
    }
}

/// The analyze pass's whole output: whole-frame censor intervals plus per-face
/// tracks. Pass 2 consumes only this.
struct Edl: Codable, Sendable, Equatable {
    /// Inclusive `[first, last]` ranges in absolute source milliseconds.
    /// **Not required to be sorted or disjoint** — the lookup is a pure OR, and
    /// in region mode this is the plain concatenation of gate intervals and
    /// track-overflow spans (Android `work/FilterWorker.kt:1167`).
    var censorIntervalsMs: [ClosedRange<Int64>] = []
    /// Sorted by `startMs` at build time.
    var faceTracks: [FaceTrackEdl] = []

    var isEmpty: Bool { censorIntervalsMs.isEmpty && faceTracks.isEmpty }

    /// Inclusive at both ends.
    func fullFrame(at t: Int64) -> Bool {
        censorIntervalsMs.contains { $0.contains(t) }
    }

    /// **The precedence rule**: a whole-frame interval blanks the frame and
    /// suppresses every face region at that timestamp. Pass 2 depends on this,
    /// so it lives here rather than at the call site.
    func regions(at t: Int64) -> [NRect] {
        guard !fullFrame(at: t) else { return [] }
        var out: [NRect] = []
        out.reserveCapacity(2)
        for tr in faceTracks where t >= tr.startMs && t <= tr.endMs {
            if let r = tr.rect(at: t) { out.append(r) }
        }
        return out
    }

    /// The renderer applies at most this many regions per frame; a frame with
    /// more is promoted to whole-frame at EDL build. Must match the shader's
    /// region array size (Android `render/CensorEffect.kt:30`).
    static let maxRegionsPerFrame = 8
}

// MARK: - JSON, byte-compatible with Android

/// Android writes `censorIntervalsMs` as `[[first,last],…]` and each keyframe
/// as a flat `[timeMs, l, t, r, b]`, with the rect components widened from
/// Float32 to Double. Matching that exactly keeps EDL diffs against Android
/// runs meaningful, which is how the parity suite is scored.
extension Edl {
    func toJSONData() throws -> Data {
        let obj: [String: Any] = [
            "censorIntervalsMs": censorIntervalsMs.map { [$0.lowerBound, $0.upperBound] },
            "faceTracks": faceTracks.map { tr -> [String: Any] in
                [
                    "startMs": tr.startMs,
                    "endMs": tr.endMs,
                    "keyframes": tr.keyframes.map { k -> [Any] in
                        [k.timeMs, Double(k.rect.left), Double(k.rect.top),
                         Double(k.rect.right), Double(k.rect.bottom)]
                    },
                ]
            },
        ]
        return try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    }

    static func fromJSONData(_ d: Data) throws -> Edl {
        guard let root = try JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            throw EdlError.malformed("root is not an object")
        }
        var edl = Edl()
        for p in root["censorIntervalsMs"] as? [[NSNumber]] ?? [] where p.count == 2 {
            let lo = p[0].int64Value, hi = p[1].int64Value
            guard lo <= hi else { throw EdlError.malformed("interval \(lo)..\(hi) is inverted") }
            edl.censorIntervalsMs.append(lo...hi)
        }
        for t in root["faceTracks"] as? [[String: Any]] ?? [] {
            guard let s = (t["startMs"] as? NSNumber)?.int64Value,
                  let e = (t["endMs"] as? NSNumber)?.int64Value else {
                throw EdlError.malformed("face track missing startMs/endMs")
            }
            var kfs: [FaceTrackEdl.Keyframe] = []
            for k in t["keyframes"] as? [[NSNumber]] ?? [] where k.count == 5 {
                kfs.append(.init(timeMs: k[0].int64Value,
                                 rect: NRect(left: k[1].floatValue, top: k[2].floatValue,
                                             right: k[3].floatValue, bottom: k[4].floatValue)))
            }
            edl.faceTracks.append(FaceTrackEdl(startMs: s, endMs: e, keyframes: kfs))
        }
        return edl
    }
}

enum EdlError: Error, CustomStringConvertible {
    case malformed(String)
    var description: String { if case .malformed(let s) = self { "malformed EDL: \(s)" } else { "" } }
}

/// Tuning constants shared by the analyze and render passes. Values are the
/// Android ones (`docs/apple-port/spec-analyze.md` §0); anything re-tuned for
/// Vision is marked and recorded in `vision-tuning.md`.
enum AnalyzeConstants {
    /// Decode/emit rate for the sampler.
    static let sampleFPS = 10.0
    /// The gate consumes every 2nd emitted frame.
    static let gateStride = 2
    /// Detector input long side.
    static let detectMaxDim = 640
    /// Hysteresis around a gate firing.
    static let preRollMs: Int64 = 500
    static let postRollMs: Int64 = 1500
    /// Pad applied to a face track's span.
    static let spanPadMs: Int64 = 50
    /// Per-side pad on a face box: 1.5x per axis.
    static let keyframePad: CGFloat = 0.25
    /// A track with no sample for this long is closed out.
    static let evictAfterMs: Int64 = 2_000
    static let voteCap = 5
    /// Min upright face size (max side, px) to be worth a gender vote.
    static let minFacePx: CGFloat = 80
    static let genderConfidenceFloor: Float = 0.60
    /// Whole-frame mode: gaps shorter than this are bridged...
    static let bridgeMs: Int64 = 400
    /// ...and spans shorter than this are dropped, which is what kills
    /// sub-second full-screen flashes from detector false positives.
    static let minFullFrameMs: Int64 = 500
}
