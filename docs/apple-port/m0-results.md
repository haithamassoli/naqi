# M0 results — Apple port de-risk

Measured on **iPhone 17 Pro simulator** (iOS 26.5, Xcode 26.6, Swift 6.3.3) on an Apple Silicon Mac,
via `naqiTests/BenchTests.swift` and `naqiTests/ModelContractTests.swift`. Reproduce with:

```
scripts/fetch-models.sh
xcodebuild test -project naqi.xcodeproj -scheme naqi \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath build/DD
```

> **Simulator ≠ phone.** The simulator runs arm64 code on the Mac's CPU, so these are effectively
> *M-series Mac* numbers, and there is **no Apple Neural Engine** — the CoreML rows exercise the
> CPU/GPU partition only. They bound the problem and prove the code paths; the acceptance numbers in
> M7 must be re-taken on a real iPhone.

## Decision 1 — inference runtime → **ORT 1.24.2 via SPM, CPU EP for v1**

`https://github.com/microsoft/onnxruntime-swift-package-manager` at `1.24.2`, product `onnxruntime`
(static, ObjC bindings module `OnnxRuntimeBindings`). Ships an iOS-simulator arm64 slice; builds
clean under Swift 6 strict concurrency.

The CoreML EP **is available on the simulator** and is wired up behind `ComputeUnit.coreML`
(`naqi/ML/Ort.swift`), using `createMLProgram = true` and `onlyAllowStaticInputShapes = true`. It is
not the default because on CPU the graphs are already far past parity and the CPU EP is the path
that matches Android numerics exactly. Flipping the default is a one-line change once a device
measurement justifies it.

**No coremltools conversion is needed for v1.** That was the expected big lift; the measurements
below removed the need for it.

## Decision 2 — the fp16 NaN risk → **did not fire**

`htdemucs_s26_f16.onnx` carries 552 fp16 initializers with fp32 graph IO. Android's fp16 *execution*
path produced NaN. On Apple ORT the runtime up-casts and output is finite — verified not just on a
zero tensor (which can pass through a graph that still NaNs on signal) but on a 440 Hz tone:

```
htdemucs: fp16 weights produce finite fp32 output — PASSED
  out_wave [1,4,2,114660]  all finite, non-silent
  out_spec [1,4,4,2048,112] all finite
```

No fp32 re-export required. The `.onnx` artifacts ship unchanged from Android.

## Decision 3 — htdemucs throughput → **~8x the Android baseline**

2.6 s segment, single session, 1 intra-op thread:

| provider | load ms | infer ms | x-realtime | finite |
|---|---|---|---|---|
| ORT CPU EP | 810 | 617 | **4.21x** | yes |
| ORT CoreML EP | 111 | 564 | **4.61x** | yes |
| *(S23 baseline)* | — | — | *0.55x* | — |

Observed range across runs: 256–906 ms/segment (3.0x–10.1x realtime), varying with concurrent load.

`x-realtime > 1` means faster than playback. The audio wall — the dominant cost on two of the three
job shapes — is therefore **not** the problem on Apple that it is on Android. The PRD's proposed
Core ML/ANE spike is **deferred**: it was gated on "only if measured wall demands it", and it does
not.

## Decision 4 — NSFW gate batching → **free analyze-wall win, adopted**

The exported graph has a **dynamic batch dimension** (`input['unk__615',3,224,224]`), which Android
never exploited. Batched inference is bit-identical to single-frame (verified to 1e-4, four distinct
inputs), and throughput improves monotonically:

| batch | total ms | ms/frame |
|---|---|---|
| 1 | 50.3 | 50.28 |
| 4 | 172.8 | 43.20 |
| 8 | 295.3 | **36.91** |

**27 % less time per frame at batch 8.** `Models.Nsfw.maxBatch = 8`.

## Graph IO — dumped from the shipped artifacts, not from docs

| model | opset | inputs | outputs |
|---|---|---|---|
| `nsfw_mnv2_140_f32` | 17 | `input[N,3,224,224]` f32 | `prediction[N,5]` f32 |
| `genderage` | 12 | `data[N,3,96,96]` f32 | `fc1[1,3]` f32 |
| `htdemucs_s26_f16` | 18 | `input[1,2,114660]` f32, `x[1,4,2048,112]` f32 | `out_spec[1,4,4,2048,112]`, `out_wave[1,4,2,114660]` f32 |

sha256 matches the Android reference for all three (`df8a2c2c…` htdemucs, `049ce7c5…` NSFW).

## Two bugs the M0 tests caught

1. **Concurrent `CreateSession` on one graph segfaults ORT.** `ModelRegistry` now holds its lock
   across construction, not just the dictionary access. Loading htdemucs twice is not a slow path —
   it is an OOM kill on a phone.
2. **`AVAssetReader.addOutput:` raises an uncatchable ObjC exception** when the output's track came
   from a different `AVAsset` instance. `TrackReader` now derives the asset from the track, so the
   mismatch is unrepresentable.

## Open / carried forward

| item | status |
|---|---|
| Q1 device floor (4 GB iPhone RAM) | **open** — needs a device. `phys_footprint` on the simulator reports the host process and is not a phone number; only the delta is meaningful. Instrumentation is in place (`naqi/Core/MemoryFootprint.swift`). |
| htdemucs peak RAM vs the 1.5 GB budget | **open** — same reason. The 2.6 s segment was chosen on Android precisely to clear it (1.30 GB there). |
| Vision vs ML Kit recall/track continuity | in M3; findings go to `vision-tuning.md` |
| MKV/Opus ingest | **not started** — AVFoundation cannot demux Matroska; the drop-in-v1 vs embedded-demuxer decision is still open |
| Photos picker hands over originals, not transcodes | **not started** |
| Deployment floor set to iOS 18.0 / macOS 15.0 | provisional, pending Q1 |
