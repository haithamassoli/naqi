# tasks.md — Naqi Halal Video Filter (Apple)

Source: `prd-video-filter-apple.md`. Milestones are dependency-ordered. M0 burns down the PRD's flagged risks (htdemucs on ORT-iOS, Vision≠ML Kit, iPhone RAM floor) before feature work — nothing UI-shaped is built until stems parity is proven. M2 ships the music-removal slice first: it is the simplest complete job, exercises the wall (audio), and delivers standalone value.

Decision gates (PRD open questions): Q1 device floor → answered inside M0. Q2 Mac ambition (checkbox vs batch) → needed before M6. Q3 iPhone long-film UX → needed before M5 UI copy. Q4 pricing → needed before M7 submission.

Android carry-overs are cited inline — they are measured findings, not guesses; do not re-litigate them.

## M0 — Foundations & de-risk spikes
**Exit:** all three models produce Android-parity outputs on Apple hardware; htdemucs ×realtime + peak RAM measured on the candidate floor iPhone and the floor is decided; Vision tuning constants written down; MKV decision made.

- [x] Repo scaffold: one multiplatform SwiftUI target (iPhone/iPad/Mac), Swift 6, SPM only, models fetched by script (gitignored, as on Android)
- [x] ONNX Runtime integrated on iOS + macOS; smoke-infer all three `.onnx` taken unchanged from Android `assets/models/`; pin fp32 execution for htdemucs (Android: fp16 path → NaN)
- [ ] Port qa-assets + Android reference outputs into a parity suite (stems SNR, EDL interval diff); define tolerances from `m0-spikes.md` numbers
- [ ] SPIKE: htdemucs chunked driver parity — 2.6 s segments, overlap-add, qa clip stems vs Android reference on Mac, then iPhone
- [ ] SPIKE: htdemucs bench on 4 GB iPhone — ×realtime, peak RAM vs 1.5 GB budget, thermal; decide device floor (Q1: 4 GB in, or floor at 6 GB)
- [x] NSFW classifier + genderage parity: same crops through ORT-Apple vs Android outputs, max|Δ| within m0 tolerance; class order + preprocessing contracts locked in one file
- [ ] SPIKE: Vision face detect+track on qa-assets vs Android ML Kit tracks — measure recall/track continuity; re-tune sampling fps, padding %, vote-crop count; write `vision-tuning.md`
- [ ] SPIKE: MKV/Opus ingest — AVFoundation cannot demux MKV; decide drop-MKV-v1 vs embedded demuxer, amend PRD input line with the outcome
- [ ] Photos picker vs Files: confirm picker hands over originals (not transcodes) for large/HDR files; document the ingest path

## M1 — Video pipeline core
**Exit:** decode→encode round-trip on iPhone + Mac; passthrough bit-identical; HDR→SDR and >4 GiB verified.

- [ ] AVAssetReader decode: pooled decoder-native 4:2:0 CVPixelBuffers, timestamps, `preferredTransform` rotation handling (Android: rotation was decoder-dependent — verify per-source here too)
- [ ] AVAssetWriter encode: H.264/HEVC, bitrate = min(source, resolution-tier cap) — reuse Android cap table; rotation preserved
- [ ] Passthrough fast paths via `outputSettings: nil` compressed append; verify bit-identical (elementary-stream MD5 + packet PTS/size sequence, as Android did)
- [ ] HDR input → SDR tonemap; verify on the qa HDR clip
- [ ] Feature-length: >4 GiB output writes and plays end-to-end
- [ ] Throwaway CLI harness on Mac driving the pipeline — fastest iteration loop for M1–M4, not shipped

## M2 — Audio pipeline: music-removal slice end-to-end
**Exit:** pick video → music-only job → saved copy on iPhone + Mac; video passthrough bit-identical; A/V lag < 50 ms with no progressive drift.

- [ ] Demux + decode audio to f32 stereo PCM 44.1 kHz; >2 ch folds via ITU-R BS.775 with center at −3 dB (Android finding: naive ch0/ch1 drops the dialogue channel on 5.1 films)
- [ ] Port chunked overlap-add htdemucs driver: ring buffer, padded tail, `emitted == totalFrames` invariant, streaming stem sum (never 4 full stems in memory), soft-clip guard
- [ ] Keep-stems option: `vocals` | `vocals + other`; drums/bass never
- [ ] Streaming AAC-LC encode + mux with passthrough video; temp disk O(1) in track length; account for a full-size mux copy in the free-space preflight (Android finding)
- [ ] A/V sync: measure by cross-correlation at start/middle/end; compensate AAC encoder priming if lag near budget (Android measured a constant 42.67 ms of pure priming)
- [ ] Cancel mid-job: ≤ one-chunk latency, no partial file in output, temp cleaned
- [ ] Bench on floor iPhone + M1: record ×realtime for the wall; compare vs S23 0.55× baseline; ANE/Core ML spike only if worse than parity

## M3 — Analyze pass (EDL)
**Exit:** censor-only analysis produces EDLs within agreed tolerance of Android on the qa suite.

- [ ] Frame sampler: one sequential decode pass @ 10 fps upright frames; gate consumes every 2nd sample (5 fps)
- [ ] NSFW gate: strictness→per-class threshold interpolation in one config object; fire iff `nsfw ≥ 0 && nsfw > sfw`; unit tests on synthetic probability sequences
- [ ] Hysteresis `[t−0.5 s, t+1.5 s]` + interval merge; unit tests
- [ ] Vision face tracking with M0-tuned constants; box interpolation to full fps; 25 % padding (or M0's re-tuned value)
- [ ] Gender per track: ≤5 frontal crops → genderage majority vote; Who = women | men selects which tracks censor
- [ ] EDL build + serialization: censor intervals + per-frame regions; precedence full-frame ⇒ skip regions
- [ ] Whole-frame mode: EDL-time promotion + min-duration floor (kills sub-second full-screen flashes)
- [ ] Parity run: EDL diff vs Android outputs on qa suite; tune until within tolerance; record deltas in `vision-tuning.md`

## M4 — Render pass + combined jobs
**Exit:** censor-only and both-ops jobs green on the qa suite; audio passthrough bit-identical on censor-only.

- [ ] Core Image censor effect: Gaussian blur with downscale→blur→upscale for large sigma, grayscale, combinable; sigma keyed on short side per blur-amount
- [ ] EDL-driven per-frame application inside the writer pipeline; upright↔stored-space rect mapping under `preferredTransform` (Android's rotation landmine — test rot-90 and rot-270 clips)
- [ ] Censor-only fast path: audio passthrough, bit-identical verify
- [ ] Both-ops job: censor render + replaced audio in one output
- [ ] Perf sanity on device: render is encoder-paced; whole-frame ≈ free; log per-stage wall to confirm the three job-shape walls match the Android model

## M5 — Jobs, resilience & share-in
**Exit:** 90-min film survives a forced kill + relaunch and resumes to a playable output; share-in queues with last-used options.

- [ ] Serial job queue; per-segment checkpoints; resume across app kill and reboot (Q3 answer drives the iPhone UI copy)
- [ ] iOS lifecycle: keep-awake toggle, graceful suspension (checkpoint flush on background), honest "phone must stay open" messaging
- [ ] Live Activity progress on iOS; plain progress window on Mac
- [ ] Share Extension → App Group handoff to main-app queue; extension never touches models or video bytes (~120 MB cap); multiple shares run in order
- [ ] Cancel semantics everywhere: no partial output file, temp cleaned
- [ ] Long-film verify on device: forced kill mid-both-ops job on a 90-min file → resume → output plays end-to-end, original untouched

## M6 — App UI & polish
**Exit:** full user flow on iPhone, iPad, Mac; EN/AR with RTL; options persist. (Q2 decides whether Mac batch lands here.)

- [ ] Screens: pick → ops `[Remove music] [Censor] (≥1 required)` → options (last-used preselected) → progress → done (Open / Share / Delete-original)
- [ ] Options persistence incl. Who pick and censor mode
- [ ] Export: Photos or user folder; original untouched
- [ ] Port Naqi design language from Android (pass strip, ink = interaction / jade = video-truth)
- [ ] EN + AR localization; RTL audit on every screen
- [ ] Mac: file drag-drop; batch queue if Q2 = first-class
- [ ] iPad: verify layouts are not stretched-phone

## M7 — QA & App Store
**Exit:** submitted for review.

- [ ] Full parity suite on floor iPhone + M-series Mac; record numbers next to S23 baselines
- [ ] 90-min film on passively cooled iPhone: completes despite throttling; peak RAM ≤ 1.5 GB
- [ ] Kill/reboot/resume matrix re-run on release build
- [ ] Privacy nutrition label: no data collected; review notes: all inference on-device, nothing uploaded
- [ ] Pricing implemented per Q4; App Store listing (EN/AR screenshots, description from Android `store-listing.md`)
- [ ] TestFlight beta pass → submit
