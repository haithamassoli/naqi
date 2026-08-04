# tasks.md — Naqi Halal Video Filter (Apple)

Source: `prd-video-filter-apple.md`. Milestones are dependency-ordered. M0 burns down the PRD's flagged risks (htdemucs on ORT-iOS, Vision≠ML Kit, iPhone RAM floor) before feature work — nothing UI-shaped is built until stems parity is proven. M2 ships the music-removal slice first: it is the simplest complete job, exercises the wall (audio), and delivers standalone value.

Decision gates (PRD open questions): Q1 device floor → answered inside M0. Q2 Mac ambition (checkbox vs batch) → needed before M6. Q3 iPhone long-film UX → needed before M5 UI copy. Q4 pricing → needed before M7 submission.

Android carry-overs are cited inline — they are measured findings, not guesses; do not re-litigate them.

## M0 — Foundations & de-risk spikes
**Results: `apple-port/m0-results.md`.** Legend: `[x]` done · `[~]` partially done, remainder noted.
**Exit:** all three models produce Android-parity outputs on Apple hardware; htdemucs ×realtime + peak RAM measured on the candidate floor iPhone and the floor is decided; Vision tuning constants written down; MKV decision made.

- [x] Repo scaffold: one multiplatform SwiftUI target (iPhone/iPad/Mac), Swift 6, SPM only, models fetched by script (gitignored, as on Android)
- [x] ONNX Runtime integrated on iOS + macOS; smoke-infer all three `.onnx` taken unchanged from Android `assets/models/`; pin fp32 execution for htdemucs (Android: fp16 path → NaN)
- [x] Port qa-assets + Android reference outputs into a parity suite (stems SNR, EDL interval diff); define tolerances from `m0-spikes.md` numbers — qa clip staged by `scripts/fetch-models.sh`; graph-contract + passthrough parity green (`m0-results.md`)
- [~] SPIKE: htdemucs chunked driver parity — graph-level parity proven (finite fp32 from fp16 weights, exact IO shapes); the chunked driver itself lands in M2
- [~] SPIKE: htdemucs bench — **4.21×–4.61× realtime on simulator vs S23's 0.55×**; peak-RAM/thermal and the Q1 floor still need a physical device (`m0-results.md`)
- [x] NSFW classifier + genderage parity: same crops through ORT-Apple vs Android outputs, max|Δ| within m0 tolerance; class order + preprocessing contracts locked in one file
- [ ] SPIKE: Vision face detect+track on qa-assets vs Android ML Kit tracks — measure recall/track continuity; re-tune sampling fps, padding %, vote-crop count; write `vision-tuning.md`
- [ ] SPIKE: MKV/Opus ingest — AVFoundation cannot demux MKV; decide drop-MKV-v1 vs embedded demuxer, amend PRD input line with the outcome
- [ ] Photos picker vs Files: confirm picker hands over originals (not transcodes) for large/HDR files; document the ingest path

## M1 — Video pipeline core
**Exit:** decode→encode round-trip on iPhone + Mac; passthrough bit-identical; HDR→SDR and >4 GiB verified.

- [x] AVAssetReader decode: pooled decoder-native 4:2:0 CVPixelBuffers, timestamps, `preferredTransform` rotation handling (Android: rotation was decoder-dependent — verify per-source here too)
- [x] AVAssetWriter encode: H.264/HEVC, bitrate = min(source, resolution-tier cap) — reuse Android cap table; rotation preserved
- [x] Passthrough fast paths via `outputSettings: nil` compressed append; verify bit-identical (elementary-stream MD5 + packet PTS/size sequence, as Android did)
- [~] implemented (BT.709 tone-map path in CensorEffect); **unverified — no HDR clip in qa-assets**
- [ ] not verified — needs a feature-length source. AVAssetWriter emits co64 itself, so this is a test gap, not a code gap
- [~] skipped — the xcodebuild test suite is the iteration loop; a second harness would be a second thing to keep working

## M2 — Audio pipeline: music-removal slice end-to-end
**Exit:** pick video → music-only job → saved copy on iPhone + Mac; video passthrough bit-identical; A/V lag < 50 ms with no progressive drift.

- [x] Demux + decode audio to f32 stereo PCM 44.1 kHz; >2 ch folds via ITU-R BS.775 with center at −3 dB (Android finding: naive ch0/ch1 drops the dialogue channel on 5.1 films)
- [x] Port chunked overlap-add htdemucs driver: ring buffer, padded tail, `emitted == totalFrames` invariant, streaming stem sum (never 4 full stems in memory), soft-clip guard
- [x] Keep-stems option: `vocals` | `vocals + other`; drums/bass never
- [x] Streaming AAC-LC encode + mux with passthrough video; temp disk O(1) in track length; account for a full-size mux copy in the free-space preflight (Android finding)
- [x] measured 16 ms of 50 ms budget; AVAssetWriter's edit list already removes priming, so no compensation added (the Android constant is also stale — 46.44 ms at 44.1 kHz, not 42.67)
- [x] Cancel mid-job: ≤ one-chunk latency, no partial file in output, temp cleaned
- [~] simulator: htdemucs 3.57x realtime vs S23 0.55x. **Device run outstanding.** ANE spike deferred — CoreML EP measured *slower* here

## M3 — Analyze pass (EDL)
**Exit:** censor-only analysis produces EDLs within agreed tolerance of Android on the qa suite.

- [x] Frame sampler: one sequential decode pass @ 10 fps upright frames; gate consumes every 2nd sample (5 fps)
- [x] NSFW gate: strictness→per-class threshold interpolation in one config object; fire iff `nsfw ≥ 0 && nsfw > sfw`; unit tests on synthetic probability sequences
- [x] Hysteresis `[t−0.5 s, t+1.5 s]` + interval merge; unit tests
- [x] Vision has no track ids — greedy IoU + centre-distance association, documented in `apple-port/vision-tuning.md`
- [~] implemented; **the QA clip's faces are too small to trigger a vote**, so every track resolves 0/0 ⇒ censor (correct, but the vote path is untested on real data)
- [x] EDL build + serialization: censor intervals + per-frame regions; precedence full-frame ⇒ skip regions
- [x] Whole-frame mode: EDL-time promotion + min-duration floor (kills sub-second full-screen flashes)
- [ ] blocked — the Android repo ships qa **videos** but no reference EDL outputs to diff against

## M4 — Render pass + combined jobs
**Exit:** censor-only and both-ops jobs green on the qa suite; audio passthrough bit-identical on censor-only.

- [x] Core Image censor effect: Gaussian blur with downscale→blur→upscale for large sigma, grayscale, combinable; sigma keyed on short side per blur-amount
- [x] all four rotations pixel-tested; **synthetic buffers, not real rotated clips** — a rot-90 fixture is still wanted
- [x] Censor-only fast path: audio passthrough, bit-identical verify
- [x] entry point wired (`RenderPass.run(replacedAudio:)`); the wasteful temp video copy is tracked separately
- [~] simulator render 46–63 fps (1.5–2.1x realtime); **'whole-frame ≈ free' unconfirmed — simulator noise swamps the effect cost**

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
