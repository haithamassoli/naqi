# Integration hazards — things that cross scope boundaries

Distilled from the M0 research dives. Each of these is a place where two
independently-correct pieces of code produce a wrong result together, or where a
number carried over from Android is no longer the right number. Check every one
at integration; do not take a green unit test as evidence.

## 1. The A/V sync constant is stale — it is 46.44 ms, not 42.67 ms

Android's measured "42.67 ms of pure AAC priming" was taken at commit `6bd549e`,
when `AacWriter` encoded at **48 kHz**: `2048 / 48000 = 42.67 ms`. A later commit
(`b0d8792`) moved the encoder to **44.1 kHz**. The same 2048-sample priming is
now `2048 / 44100 = 46.44 ms` — and it was never re-measured. That leaves ~3.6 ms
of margin against the PRD's 50 ms budget, not 7.3 ms.

**The Apple divergence:** `AVAssetWriter` compensates encoder priming
automatically. So the Swift output should land ~46 ms *earlier* than the Android
output on the same input, and that is **correct behaviour, not a regression**.
Any A/V parity check against Android reference output must expect this offset
rather than flagging it.

Action: do not hard-code 42.67 anywhere. Measure the actual offset by
cross-correlation at start/middle/end (PRD M2 exit criterion) and assert against
the 50 ms budget, not against Android's number.

## 2. Colour range — the highest bit-exactness risk in the analyze pass

Android applies **BT.601 full-range** math to whatever raw bytes MediaCodec
emits, with **no 16–235 expansion**. For a limited-range bt709 source that is
technically wrong, but it is what produced every threshold in the shipped gate.

To reproduce the same gate probabilities, Apple must:
1. Request `kCVPixelFormatType_420YpCbCr8BiPlanar**VideoRange**` (which
   `TrackReader.decodedVideo` does), so the raw bytes match, and
2. Apply the **same full-range BT.601 coefficients** to them — i.e. deliberately
   *not* the correct video-range expansion.

Choosing `FullRange` at the decoder, or "fixing" the conversion to be
colorimetrically correct, shifts every NSFW class probability and silently
invalidates the strictness thresholds. If the gate is ever re-tuned on Apple,
this is the first thing to re-derive.

Related: `(1436 * v) shr 10` in the Kotlin is an **arithmetic shift on a signed
Int**, not `/ 1024`. They differ for negative values. Swift's `>>` on `Int` is
also arithmetic, so a direct port is right — but `/ 1024` is not.

## 3. STFT packing is bin-major, frame-minor

The complex-as-channels tensor is C-order `[4][bins][le]` with planes
`[ch0.re, ch0.im, ch1.re, ch1.im]`, indexed `c*bins*le + b*le + t`. The research
flagged this as the single most likely transposition bug in the port: a
frame-major layout has the same element count and will run without error,
producing plausible-sounding garbage.

The round-trip test (`iSTFT(STFT(x)) == x`) does **not** catch a transposition if
both directions use the same wrong layout. Only feeding the real graph and
checking the separated stems catches it.

## 4. FFT precision

`Dsp.kt` explicitly refuses f32 twiddle factors, with a four-assertion argument,
at `atol 1e-4`. vDSP single precision lands *at* that floor rather than
comfortably inside it. If parity fails marginally, move the twiddles to
double-precision Accelerate before assuming the driver is wrong.

## 5. Byte-parity with Android is impossible for non-44.1 kHz sources

media3's Sonic resampler is 2-tap linear (~−27 dB in-band distortion). Any Apple
sample-rate converter is *better*, so the outputs legitimately differ. Restrict
audio parity gating to sources that are already 44.1 kHz.

## 6. Face counts are not a parity metric

ML Kit is nondeterministic — the Android QA runs recorded 4786 vs 4550 faces on
*identical* input. The Vision port can therefore only be validated on the
**censored timeline** (which intervals ended up censored), never on face or track
counts. A test that asserts a face count is testing noise.

Related: `minFaceSize = 0.1` is the one **inferred** value in the analyze spec —
it is never written in the Kotlin, it is the ML Kit default, and Vision has no
equivalent knob.

## 7. `censorIntervalsMs` must not be sorted or merged in region mode

In region mode the list is literally `intervalsFor(firings) + overflowSpans(tracks)`
with no merge, so it is unsorted and may overlap. `fullFrame(at:)` is an OR scan
and tolerates that. "Helpfully" sorting or merging it changes the serialized JSON
and breaks the diff against Android reference output. Only whole-frame mode
merges. `Edl.swift` preserves this — keep it that way.

## 8. yamnet is absent, so the music gate degrades to "separate everything"

`yamnet.onnx` has `downloadUrl = null` on Android and is gitignored; a fresh
install silently separates every chunk, measured at 57 % slower. The Apple port
deliberately does not ship yamnet (`scripts/fetch-models.sh`).

That is an acceptable v1 call **only because** htdemucs measured 4.2–4.6×
realtime here versus 0.55× on the S23 — the gate was a Snapdragon-era
optimisation for a wall that no longer exists. Revisit if a device measurement
brings the audio wall back.

## 9. ORT CPU arena / memory pattern cannot be disabled through the ObjC API

Android had to disable both to avoid an lmkd kill at 5.6 GB RSS on the htdemucs
graph. ORT's Objective-C wrapper exposes neither `DisableCpuMemArena` nor
`DisableMemPattern` — only the C API does. `Ort.swift` sets the one reachable
config entry (`session.use_device_allocator_for_initializers`) and marks the gap.
If a device run reproduces the blow-up, the fix is a small ObjC shim over the C
API.

## 10. The CoreML EP sits in the same fp16-kernel class that already broke this graph

XNNPACK's fp16 kernels corrupted htdemucs' spectral branch on Android. The CoreML
EP is a different implementation of the same idea and is **unvalidated** on this
graph beyond "output is finite". Before making it the default, compare its stems
against the CPU EP's, not just against NaN.

## 11. Segment concat: place segments at intended starts, not at a running cursor

Android measured this one rather than reasoning about it
(`docs/long-film-plan.md:123`). Offsetting each segment by the **accumulated
measured duration** of the ones before it folds a sub-frame rounding error into
every following segment — up to **~1 s of A/V drift across 31 joins**, 20× past
the PRD's 50 ms budget. Their fix: offset by the *intended* segment start.

`AVMutableComposition.insertTimeRange(_:of:at:)` at a running cursor is exactly
the accumulating form, so this is the natural thing to write.

**It only bites the shapes where audio is not per-segment.** If each `seg-NNN.mp4`
carries its own video *and* its own audio for that window, A/V stays locked
inside each segment and the only artifact is total timeline length. The
dangerous shape is **combined**, where the audio is a single whole-film
`audio.m4a` muxed against N video segments — Android's exact configuration.
Check which one the port builds before deciding this is handled.

## 12. Concat loses ~2 frames per seam, and that is a known accepted cost

Android measured 4 619 frames out where 4 625 went in, with the largest
inter-frame gap 148 ms at a seam against a normal 41.7 ms — a ~100 ms freeze at
each join (`long-film-plan.md:124`). They deliberately did not chase it: the fix
is a per-segment overlap plus a drop rule, to buy back 1–3 frames per five
minutes.

Consequence for **testing**: a frame-count assertion comparing a segmented
render against a monolithic one will be off by roughly `2 × (segments - 1)`.
If such a test passes exactly, either the Apple path genuinely does not drop
frames — which is worth confirming and writing down, since AVAssetWriter and
MediaMuxer are different implementations — or the test is not counting what it
claims to.

## 13. Segment length is a constant on purpose

The plan called for deriving it from the measured per-segment fixed cost; the
measurement came back at ~0.5–0.7 s per export, so 31 segments cost ~19 s on a
film and anything between 1 and 10 min performs the same
(`long-film-plan.md:122`). `Checkpoint.segmentMs = 300000` is that constant. Do
not add a tuning knob for a parameter with no measurable slope.
