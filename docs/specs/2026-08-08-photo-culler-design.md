# Photo Culler (working name) — Design

**Date:** 2026-08-08 · **Status:** Approved by user ("focus on the MVP")

## Problem
Burst-style photos (5–6 shots in seconds) clutter the Photos library. macOS duplicate
detection misses them because they differ in pixels. Goal: a native macOS app that
clusters similar photos and uses a local LLM (Gemma via LM Studio) to advise which to
keep. Strictly human-in-the-loop: the model annotates, the user decides, deletion goes
through the macOS system confirmation into Photos' Recently Deleted.

## Decisions (user-confirmed)
- **Source:** Photos library via PhotoKit (read/write authorization).
- **Model role:** judge only. Clustering is native and deterministic.
- **Discard action:** PhotoKit delete → system confirmation → Recently Deleted.

## Architecture
1. **Scanner/Clusterer (native):** fetch image PHAssets in a user-selected range
   (month / 6 months / year / all). Temporal pass: consecutive shots ≤ 10s apart form
   candidate groups. Visual pass: Vision feature-prints on 512px thumbnails; split
   groups where distance exceeds threshold. Keep clusters of ≥ 2.
2. **Judge (LM Studio):** per cluster, send ~768px JPEGs (base64 data URLs) to
   `http://127.0.0.1:1234/v1/chat/completions`, model `google/gemma-4-12b-qat`
   (fallback `zai-org/glm-4.6v-flash`). Structured JSON out: keep index + per-photo
   one-line reason. Rendered as a badge + captions. Never marks or deletes.
3. **Review UI (SwiftUI):** cluster list left, side-by-side photos right, Keep/Discard
   per photo (K/D keys), bottom bar "Delete N discarded…" → PHAssetChangeRequest.deleteAssets.

## Error handling
- LM Studio down → clustering still works; judge panel shows retry.
- Permission denied → guidance screen linking to System Settings.
- iCloud-only originals → PHImageManager with networkAccessAllowed + spinner.

## Build
Swift Package executable → assembled `.app` (Info.plist with
NSPhotoLibraryUsageDescription) → ad-hoc codesign. No Xcode required (CLT SDK has
SwiftUI/Photos/Vision). Unit tests for clustering logic.
