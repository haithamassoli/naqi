#!/usr/bin/env bash
# Stage the ONNX models into naqi/Resources/Models (gitignored, as on Android).
# Source of truth is the Android repo's assets; regeneration pipelines live in
# the Android docs/m0-spikes.md "Regen pipelines" section.
set -euo pipefail

ANDROID="${NAQI_ANDROID_REPO:-$HOME/AndroidStudioProjects/NaqiHalalVideoFilter}"
SRC="$ANDROID/app/src/main/assets/models"
DST="$(cd "$(dirname "$0")/.." && pwd)/naqi/Resources/Models"

# Only the models the Apple app actually runs. yamnet + nsfw int8 are Android-only
# (int8 gate was an Android CPU workaround; ORT CoreML EP prefers f32).
WANT=(htdemucs_s26_f16.onnx nsfw_mnv2_140_f32.onnx genderage.onnx)

[ -d "$SRC" ] || { echo "error: Android assets not found at $SRC" >&2
                   echo "       set NAQI_ANDROID_REPO to the checkout root" >&2; exit 1; }
mkdir -p "$DST"

for m in "${WANT[@]}"; do
  if [ ! -f "$SRC/$m" ]; then echo "error: missing $SRC/$m" >&2; exit 1; fi
  if [ -f "$DST/$m" ] && cmp -s "$SRC/$m" "$DST/$m"; then echo "ok   $m (unchanged)"; continue; fi
  cp "$SRC/$m" "$DST/$m"
  echo "copy $m ($(du -h "$DST/$m" | cut -f1))"
done

shasum -a 256 "$DST"/*.onnx

# QA fixtures for the parity/round-trip tests (gitignored, same as the models).
QA_SRC="$ANDROID/qa-assets"
QA_DST="$(cd "$(dirname "$0")/.." && pwd)/naqiTests/Fixtures"
mkdir -p "$QA_DST"
for f in test-video.mp4; do
  [ -f "$QA_SRC/$f" ] || continue
  cmp -s "$QA_SRC/$f" "$QA_DST/$f" 2>/dev/null || cp "$QA_SRC/$f" "$QA_DST/$f"
  echo "qa   $f"
done
