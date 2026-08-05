# M7 — performance and memory, measured

> **Headline:** on the iPhone 17 Pro simulator the port runs the Android baseline clip **5.4×
> slower** than the S23. Almost all of that is the simulator, not the port — and the evidence for
> that claim is in §2, not an assertion. The memory findings are the ones that need action.

## 0. What was run

`qa-assets/tv1-h264.mp4` — the **same clip** Android published its numbers against
(`docs/perf-plan-v3.md` §0): 643.0 s, 1920×1080, **29.97 fps**, H.264 + AAC. Transcoded from the
repo's `test-video-1.webm` (AV1 + Opus) because AVFoundation cannot demux WebM.

Censor-only, default options, via `BenchTests.tv1EndToEnd`, **Release configuration**.

## 1. The number

| stage | Apple (Release) | ×realtime | S23 | ×realtime | ratio |
|---|---:|---:|---:|---:|---:|
| analyze | 337 172 ms | 1.91× | 114 648 ms | 5.61× | **0.34×** |
| render | 767 335 ms | 0.84× | 89 411 ms | 7.19× | **0.12×** |
| **total** | **1 104 507 ms** | **0.58×** | **204 752 ms** | **3.14×** | **0.19×** |

Per frame: analyze **52.4 ms** per sampled frame against the S23's 17.8 ms; render **39.8 ms** per
frame against **4.6 ms**.

## 2. Why this is not a verdict on the port

### 2.1 The Debug→Release delta localizes the cost, and it is not in our Swift

The first run of this benchmark was accidentally a **Debug** build. That mistake turned out to be
the most informative measurement of the session, because comparing the two says *where the time
lives* without a profiler:

| stage | Debug (`-Onone`) | Release (`-O`) | improvement |
|---|---:|---:|---:|
| analyze | 410 932 ms | 337 172 ms | 18 % |
| render | 776 254 ms | 767 335 ms | **1.2 %** |

Turning off every Swift optimization changes the render pass by **1.2 %**. Our per-frame Swift is
therefore ~1 % of render; the other ~99 % is inside Core Image and the H.264 encoder. Analyze gains
18 %, so the sampler and the gate kernel are real but minor next to Vision itself.

**Optimising this port's Swift cannot move these numbers.** That is a measurement, not an excuse.

### 2.2 Both dominant costs are paths the simulator cannot accelerate

- **No hardware video encoder or decoder.** Render is 19 271 frames of 1080p encoded in software.
  The S23's 4.6 ms/frame is its hardware encoder.
- **Vision is pinned to CPU.** The log carries `Vision default compute device cannot run here;
  pinned to CPU` every run — the simulator cannot build a GPU inference context
  (`Code=9 "Could not create inference context"`). Android's ML Kit ran on GPU/NNAPI.

These are the two stages, and they are exactly the two things an A19 Pro has dedicated silicon for.

### 2.3 Directions the comparison is unfair, both ways

Flattering Apple: an M-series Mac, not a phone; AV1→H.264 is cheaper to decode.
Penalising Apple: no hardware codec; Vision on CPU; Android ran `censorWho=everyone`, which skips
the gender vote entirely, so this run does strictly more work per track.

### 2.4 Contamination, disclosed

A stale `musicOnly` row in the persisted queue drained inside the test host and ran **11 s during a
767 s render** (11:27:58→11:28:09). Under 1 % of wall time, so the timing stands; it did load
htdemucs into the process, so that run's 2209 MB peak is **not** a censor-only figure and is not
used anywhere below.

## 3. Memory — one clean pass, one real violation

`phys_footprint` is this app's own task, not the host's. See the CORRECTION in `m0-results.md`; the
old "only the delta is trustworthy" note is what kept the violation below invisible for a milestone.

| workload | peak | budget | |
|---|---:|---:|---|
| censor-only, 643 s @ 1920×1080 | 472 MB | 1536 MB | ✅ comfortable |
| **music separation, 12.8 s clip** | **1721–1774 MB** | 1536 MB | ❌ **over** |

Note the shape: the *90-minute* censor job peaks lower than a *12.8-second* music job. Footprint
tracks frame area and model working set, not duration — which is why `m5-soak-results.md`'s 236 MB
proves no per-segment leak but says nothing about the budget.

### 3.1 Fixed: 1639 MB was being retained after the job

`m0-results.md` said "`ModelRegistry.evict(_:)` exists so the arena is released once a job ends
rather than held while the user browses." **It was never called from the job path** — the only
app-side caller was `AboutScreen`. So every music job left htdemucs resident for the life of the
process:

```
still held after separation 1639 MB → after evict 59 MB   (gave back 1580 MB)
```

`JobRunner.separate` now evicts on a `defer`, so a cancelled or failed job releases it too.
Guarded by a live assertion in `BenchTests.demucsFootprint`.

### 3.2 Not fixed: the peak during separation is 1721–1774 MB

Eviction cannot touch this — it is the working set, not retention. Neither is `Demucs.seg` a lever:
114 660 frames is the graph's own segment length.

Android hit the same wall on the same graph and needed `DisableCpuMemArena` **and**
`DisableMemPattern`; without them lmkd killed it at 5.6 GB RSS. ORT's Objective-C wrapper exposes
neither — `ort_session.h` offers only `addConfigEntryWithKey`, `setIntraOpNumThreads`,
`setGraphOptimizationLevel` — so the fix is the C-API shim `Ort.swift` already names in its
`ponytail:` comment.

Recorded as a **`withKnownIssue`**, not a skipped test: it fails if the peak ever comes *under*
budget, so whoever lands the shim is told to delete the wrapper.

**Risk if unfixed:** the PRD's ceiling exists for the 4 GB device floor (open question Q1). A
1.77 GB peak on a 4 GB iPhone is a plausible jetsam kill, and jetsam gives no warning.

## 3.5 The one algorithmic lever, and why it was not pulled

Every frame is decoded and re-encoded, including the ones needing no censor: the "skip" path
(`sink.append(src, …)`) skips the *blur*, not the encode, because `AVAssetWriter` cannot copy a
compressed sample through mid-stream.

So there is a real optimisation available — split the timeline at keyframes, passthrough-remux the
uncensored ranges, re-encode only the censored ones, concat. The machinery already exists
(`Remux.concat`, the segment path).

**It would have saved ~10 % on this clip**, because analyze censored **17 261 of 19 271 frames
(89.6 %)**. It only pays on sparsely-censored content, it can only cut on keyframe boundaries, and
it buys those seams the costs in hazards 11–13. Not worth it on this evidence; worth revisiting if
device numbers show render still dominating on lightly-censored sources.

## 4. What still needs hardware

Everything in §1, and the device half of §3. A phone-to-phone claim needs the phone; the simulator
bounds the problem and proves the paths, which is what it is good for. The two M7 exit criteria that
say "needs hardware" are unchanged by this document.

## 5. How to re-run

```bash
xcodebuild -scheme naqi -configuration Release -destination 'platform=iOS Simulator,id=<udid>' \
  -derivedDataPath build.noindex ENABLE_TESTABILITY=YES build-for-testing

D=$(xcrun simctl get_app_container <udid> com.haithamassoli.naqi data)
cp qa-assets/tv1-h264.mp4 "$D/Documents/bench-tv1.mp4"

xcodebuild test-without-building -scheme naqi -configuration Release \
  -destination 'platform=iOS Simulator,id=<udid>' -derivedDataPath build.noindex \
  "-only-testing:naqiTests/BenchTests/tv1EndToEnd()"
```

Two traps, both hit while producing this document:

- **`-configuration Release` is not optional.** The app's `-naqiScreen` harness is `#if DEBUG`, so
  driving the app binary measures `-Onone` and reports ~5.8× slower than Android for no reason but
  the compiler flag.
- **The `()` on the test identifier is not optional.** Without it — and with three other gating
  mechanisms that were tried first — the run reports `Test run with 0 tests in 1 suite passed`,
  which is indistinguishable from a benchmark that ran and succeeded.

The staged clip **is** the opt-in, and the test deletes it on the way out. Leaving it in place makes
every later full-suite run take 25 minutes instead of 2.5, with nothing in the output saying why.
