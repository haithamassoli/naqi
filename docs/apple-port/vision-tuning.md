# Vision vs ML Kit — what the analyze pass had to re-tune, and why

Scope: M3, `naqi/Analyze/`. Everything here is a deliberate deviation from
`spec-analyze.md`, which is otherwise ported number-for-number. Anything not
listed below is unchanged from the Android contract.

Android detector: `com.google.mlkit:face-detection:16.1.7`, `PERFORMANCE_MODE_FAST`,
`enableTracking()`, no landmarks, no classification.
Apple detector: `Vision.DetectFaceRectanglesRequest` (revision 3, the iOS 18+
Swift API), `perform(on: CVPixelBuffer, orientation:)`, one request value reused
for the whole pass.

---

## 1. Track identity — the one that actually had to be rebuilt

`spec-analyze.md` §9.6 calls this the highest-risk item, and it is: the entire
EDL design (per-track spans, `VOTE_CAP`, the 2 s eviction, the spared/censored
verdict) is keyed on ML Kit's `trackingId`. Vision has nothing equivalent.

Evaluated and rejected:

| Option | Why not |
|---|---|
| `FaceObservation.uuid` | Fresh per observation. It identifies a *detection*, not a face. |
| `TrackObjectRequest` + `ImageRequestHandler` sequence | Needs one stateful tracker instantiated per face and torn down by hand, wants near-consecutive frames, and drifts badly at the 100 ms steps a 10 fps sampler produces. It also re-detects nothing: a tracker that loses its subject keeps reporting a stale box at falling confidence, which would extend a censor span over frames with no face. |

**Shipped:** detect on every sampled frame, then rebuild identity by association
against the live tracks (`FaceTracker.associate`). Two passes, greedy:

1. **IoU >= 0.3** against each candidate track's last box, best-first.
2. **Centre distance** for whatever pass 1 could not place: centres within
   `0.6 x` the larger box's long side, and only when the two boxes are within a
   `0.6` size ratio of each other.

Pass 2 exists because at 10 fps a fast pan can leave two boxes of the same face
with literally zero overlap — the case ML Kit's motion tracker used to absorb.
The size-ratio guard stops a foreground close-up from swallowing a background
face that happens to sit behind it.

A track is only an association candidate for **300 ms** after its last sample
(`associateWindowMs`, 3 sample slots). Beyond that its box is stale enough that
matching is noise, and a wrong match is worse than a missed one here: two
different faces glued into one track make `FaceTrackEdl.rect(at:)` interpolate a
censor rect straight across a hole where no face was.

Consequences that are *not* problems: a face that reappears after >300 ms
becomes a second track, which is exactly what ML Kit did with a reused id after
eviction (§4.2) — two EDL spans, each covering its own samples, coverage
identical. In whole-frame mode the 400 ms bridge merges them again anyway.

**Not validated against Android yet.** ML Kit's tracker is itself
nondeterministic (4786 vs 4550 faces on identical input, `ml/Models.kt:64-66`),
so face counts cannot score this port either way — only a censored-timeline diff
on the QA suite can, and that is M7's parity run.

## 2. Guard 2 (`id < 0` is never classified) has no direct analogue

Android assigned untracked detections a synthetic negative id and refused to
gender-classify them, because a synthetic id is fresh every frame so `VOTE_CAP`
could not bound the cost (§10.8). Here every detection joins a real track, so
that specific hole does not exist — but the cost blow-up does: a fast pan that
starts a fresh track per frame would spend one classification per frame.

**Shipped:** a track must have **at least 2 samples** before it can spend a
vote. A one-sample track is precisely this port's untracked detection — censored
like any other, never classified. Semantics are preserved (no vote cast ⇒ 0/0 ⇒
censor) and so is the per-track cost bound. The cost is the first sample of every
track, which is usually the smallest crop in it and would normally lose to
guard 5 anyway.

## 3. Frontality stays size-ordered, even though Vision could do better

`DetectFaceRectanglesRequest` returns `roll` / `yaw` / `pitch` for free —
Android had no equivalent without paying for `LANDMARK_MODE_ALL` on every frame,
which is why §5.1's "frontal" is really just "biggest crop in the track".

Deliberately **not** used. The `CONF_FLOOR = 0.60` sweep and the 80 px floor were
measured against crops selected by size ordering; adding a yaw gate changes which
crops vote and invalidates that table. It is the obvious first lever if the
parity run shows the vote disagreeing with Android, and it is the cheapest
available answer to the known caveat that 23 % of what Android's vote classified
was not a face at all.

## 4. `minFaceSize` is not exposed, so §11.3 stays open

ML Kit's default `minFaceSize = 0.1` (fraction of the shorter side) was
**[INFERRED]** on Android and never written down. `DetectFaceRectanglesRequest`
has no equivalent knob, so the smallest detected face is whatever Vision decides.
This moves both coverage and the effective reach of the 80 px vote floor, and it
cannot be tuned — only measured. Carried forward to the M7 parity run.

## 5. Coordinate space and the flip

Vision returns **normalised, bottom-left-origin** rects over the *oriented*
image; ML Kit returned **top-left-origin pixels** in upright space. The flip
happens in exactly one place, `VideoTransform.uprightRectFromVision`, and
nowhere else.

The transform handed to it is built over the **detector buffer's** size
(640 long side), not the source's, because that is the space ML Kit reported in:
`MIN_FACE_PX = 80` is 80 px *of a 640-px-long-side image* (12.5 % of the long
side), and measuring it against a 1080p frame would loosen the vote floor by
~2.8x. Same for the InsightFace crop's `step`. `NRect` is normalised, so the EDL
itself is resolution-independent either way.

Rotation is still handed over as metadata, never baked into pixels: unrotated
buffer + `CGImagePropertyOrientation` in, upright boxes out — ML Kit's contract
(§9.7), preserved so every `NRect` keeps its space. Mapping is
`0 -> .up, 90 -> .right, 180 -> .down, 270 -> .left`.

## 6. Ring and queue depths

Android: `QUEUE = 2`, `RING = QUEUE + 2 = 4` (§0.6-0.7), sized so the decoder
cannot overwrite pixels the consumer is still reading.

Here the detector buffers come from a `CVPixelBufferPool` with a minimum count of
4 — the same ring — but the producer/consumer queue is **depth 1**: exactly one
decode-and-convert task runs ahead of the consumer. AVAssetReader already decodes
ahead into its own internal queue, so the second slot Android needed to absorb
`MediaCodec` dequeue jitter has no work to do. The §1.5 buffer-lifetime rule is
unchanged and still load-bearing: Vision is awaited inside the consume call, so
the pool slot is alive for the whole detection.

## 7. Colour range (§9.3 / §11.1) — still unresolved, and deliberately so

The pass reads `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange` and applies
Android's integer BT.601 **full-range** math to those bytes without a 16-235
expansion — the same mismatch Android has, on the same kind of bytes, which is
the only way the strictness table transfers. `…FullRange` would have
VideoToolbox expand the samples and change every RGB value, hence every gate
probability. Not verified against Android's raw decoder output yet; that is the
M7 bit-exactness check.
