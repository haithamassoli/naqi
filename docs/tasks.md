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

- [x] Serial job queue; per-segment checkpoints; resume across app kill and reboot. Only the **render** is segmented — splitting analyze at a 5-min boundary splits a face track, and its two halves can reach opposite gender verdicts, censoring the same face in one segment and not the next
- [x] iOS lifecycle: keep-awake toggle, checkpoint flush on background, `beginBackgroundTask` grace whose expiry marks `.interrupted` so a short app switch does not kill a job
- [x] Live Activity progress on iOS (`NaqiWidgets` target); Mac gets the in-app progress window — ActivityKit is iOS-only
- [x] Share Extension → App Group handoff (`NaqiShare` target). Copies bytes only; manifest written last as the completion marker. `ShareManifest` carries no options, so `FilterOps` never enters a 120 MB target
- [x] Cancel semantics: no partial output, temp cleaned, and the source proven byte-identical after a cancel (`OriginalIntegrityTests`)
- [x] Long-film verify — **passed on the simulator**, full write-up in `docs/apple-port/m5-soak-results.md`. Real 30-minute gate on a 90.2-min film, SIGKILL mid-render, resume skipped the whole analyze pass and every finished segment, published a 702 MB output. **0 duplicate-PTS frames in 162 049**, +1.95 ms drift over 17 seams against a 50 ms budget, peak footprint 236 MB of 1536 MB and flat across all 18 segments. On-device is still open — see M7
- [ ] A >30-min **29.97 fps** end-to-end soak. The 90-min asset is 30/1 fps, so every cut is an exact frame time and it never exercised the reader head-guard. That path is covered at unit level (cuts at 3010/7010, mutation-verified) but not end to end

**Two critical bugs the segmented route shipped with, both found by adversarial verify, both mutation-confirmed:**
- `AVAssetReader` does not drop the sample straddling `timeRange.start` — it **rewrites its PTS to the range start**, so the pre-roll guard let it through and wrote it into *both* neighbouring segments. Invisible at 30/25/24 fps where 5-minute cuts are exact frame times; **every seam gains a frame at 29.97 or 23.976**. `Remux.export` only guards against short output, so it would have shipped silently.
- `Checkpoint.plan` emitted a 1 ms trailing segment on a 35:00.001 source. No duplicate cut, so `distinct()` never saw it; `RenderPass` then refused to write an empty segment and the job died — identically on every resume. Android carries the same gap.

## M6 — App UI & polish
**Exit:** full user flow on iPhone, iPad, Mac; EN/AR with RTL; options persist. (Q2 decides whether Mac batch lands here.)

- [x] Screens: pick → ops → options → progress → done, all driving the real `JobQueue`
- [x] Options persistence incl. Who pick and censor mode — in the **App Group suite**, not `.standard`, so a share-in inherits them
- [x] Export: Photos or user folder. Audio-only sources are **forced** to folder, not defaulted — Photos rejects a bare audio file, and a default could be clicked back to a publish failure. The folder is bookmarked, so a job resumed after a cold start still reaches the folder it was queued for
- [x] Port Naqi design language from Android. **Kept as shipped**, which inverts this list's "ink = interaction / jade = video-truth" — the Android app uses jade for interaction; see `Theme.swift`
- [x] EN + AR (110 keys); RTL audit found two real bugs — SwiftUI mirrors `Shape` by default (backwards tick, flipped music slash) and `Canvas` filled the pass bar from the left in Arabic
- [x] Mac: file drag-drop, gated on `UTType.movie` so a dropped PDF is refused rather than queued to fail at preflight
- [~] Batch queue: only a "N more queued" line, driven by the real `JobQueue.observe()`. A full queue screen is **deliberately not built** — Q2 (Mac batch as first-class) is unanswered and it would be speculative
- [x] iPad: layouts verified, not stretched-phone
- [ ] Done screen offers Open / Share only on the folder destination. On Photos the app holds `.addOnly`, so after the temp is moved into the library there is genuinely no readable path to act on — correct, but still a product gap

## M7 — QA & App Store
**Exit:** submitted for review.

- [ ] Full parity suite on floor iPhone + M-series Mac; record numbers next to S23 baselines — **needs hardware**
- [ ] 90-min film on passively cooled iPhone: completes despite throttling; peak RAM ≤ 1.5 GB — **needs hardware** for the device figure, but the simulator number is real and already shows a problem. `phys_footprint` is this app's own task, not the host's (CORRECTION in `m0-results.md`): censor-only at 1920×1080 for 643 s peaks at **472 MB** (fine), music separation at **1721–1774 MB — over the 1536 MB budget**. The M5 soak's 236 MB does not clear this: that asset was 480×854, and footprint scales with frame area and model working set, not duration
- [x] Full parity/perf numbers next to the S23 baselines — `docs/apple-port/m7-perf-results.md`. **5.4x slower than the S23 on the simulator**, and the Debug→Release delta localizes why: turning off every Swift optimisation changes render by **1.2 %**, so ~99 % of render is Core Image + the software H.264 encoder, and Vision runs CPU-pinned. Both are simulator properties. A phone-to-phone claim needs the phone
- [ ] Kill/reboot/resume matrix re-run on **release** build. Debug-only coverage already hid one bug here (`AVAssetTrack.asset` is weak; an optimised build releases it before the reader is made). Release test bundle now builds (three DEBUG-only UI tests wrapped), so this is unblocked
- [ ] **htdemucs peaks at 1721–1774 MB against the 1536 MB budget** — over. Eviction cannot fix it (working set, not retention); needs `DisableCpuMemArena` via a C-API shim. Held as a `withKnownIssue` in `BenchTests.demucsFootprint`
- [x] Retained-memory leak after a music job: 1639 MB stayed resident because `ModelRegistry.evict` was never wired into the job path. `JobRunner.separate` now evicts on a `defer` — **1639 MB → 59 MB**
- [x] Privacy nutrition label — `naqi/PrivacyInfo.xcprivacy`: no tracking, no collected data, three required-reason APIs each traced to its call site. "No networking" **verified**, not asserted: no `URLSession` symbols in the binary, no networking framework linked
- [x] App Store listing EN/AR — `docs/apple-port/store-listing-apple.md`. Four Play-listing claims are false on Apple and are removed rather than softened (bundled models not a download; no MKV/WebM — AVFoundation cannot demux Matroska; iOS 18/macOS 15; resume rather than background work)
- [ ] Pricing per Q4 — **blocked**, Q4 unanswered
- [ ] Store screenshots need caption plates; per-extension privacy manifests if App Store Connect flags the App Group `UserDefaults` symbol in `NaqiShare`/`NaqiWidgets` at upload
- [ ] TestFlight beta pass → submit
