# Packaging a local VLM inside the app — research report

*Research date: 2026-08-08. Confidence labels: [Fact] = verified against source; [Inference]; [Speculation].*

## 1. Cotypist findings

- [Fact] Cotypist (cotypist.app, by a solo Munich developer) runs its model fully on-device via **llama.cpp**, Apple Silicon only, no cloud. Third-party reviews (May–June 2026) describe it running "a roughly 3 GB Gemma model on-device via llama.cpp" with a **model picker** that recommends configurations per Mac, and a Pro tier that unlocks a "full model catalog." Sources: [Nic's notes](https://notes.nicolasdeville.com/apps/cotypist/), [HyperWrite review, 2026](https://www.hyperwriteai.com/blog/cotypist-review), [Volatile Inputs review, May 2026](https://volatileinputs.com/2026/05/cotypist-is-the-typing-tool-apple-should-have-built/).
- [Fact] In the June 2026 HN thread ([news.ycombinator.com/item?id=48093079](https://news.ycombinator.com/item?id=48093079)), the developer (HN username **mrmage**) wrote: "Completions are generated in real-time locally on your Mac using a variety of models (primarily **Qwen 2.5 1.5B**)." So the *default* workhorse is a ~1.5B Qwen model; the ~3 GB Gemma appears to be a catalog option, not the only model. [Inference from both sources.]
- [Inference] Distribution model: the app itself is a small `.dmg` (Developer ID, outside the Mac App Store); models are fetched via the in-app picker rather than bundled. No public write-up of packaging internals found.
- **Takeaway:** the proven indie pattern is llama.cpp embedded + small default model + optional bigger models downloaded on demand.

## 2. Inference stack comparison (state as of Aug 2026)

| Stack | Swift integration | Vision support | Size implications | Licensing | Notes |
|---|---|---|---|---|---|
| **llama.cpp embedded** (GGUF + mmproj, `libmtmd`) | Mature. Official prebuilt XCFramework; Swift wrappers: [Kuzco](https://www.productcool.com/product/kuzco), [LocalLLMClient](https://dev.to/tattn/localllmclient-a-swift-package-for-local-llms-using-llamacpp-and-mlx-1bcp), llama.swift | Yes — mtmd stack: model GGUF + mmproj GGUF; Gemma, Qwen-VL etc. ([docs/multimodal.md](https://github.com/ggml-org/llama.cpp/blob/master/docs/multimodal.md)) | Framework ~tens of MB; models are the payload (1–6 GB). Runs on Intel + Apple Silicon | MIT | **Same GGUF artifacts LM Studio uses today; GBNF/JSON-schema grammar = guaranteed valid JSON output** |
| **MLX** ([mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm) + MLXVLM) | Good and improving; v3.x SPM package, `MLXHuggingFace` macros download models at runtime; VLMEval/MLXChatExample sample apps ([guide](https://rudrank.com/exploring-mlx-swift-adding-on-device-vision-models)) | Yes — VLM support landed in mlx-swift (image + video) | Similar model sizes (safetensors 4-bit); Apple Silicon **only** | MIT | Nicest pure-Swift DX; structured-output/grammar support weaker than llama.cpp's [Inference] |
| **CoreML (FastVLM)** | Demo app in [apple/ml-fastvlm](https://github.com/apple/ml-fastvlm); 0.5B/1.5B/7B | Single-image oriented [Inference] | 0.5B is very small (<1 GB) | **Blocked: Apple ML Research Model License — research-only, no commercial use** ([LICENSE_MODEL](https://github.com/apple/ml-fastvlm/blob/main/LICENSE_MODEL), verified 2026-08-08) | Ruled out for a shipped app |
| **Apple Foundation Models** | First-party Swift API; `@Generable` guided generation is the best structured-JSON story of any option | **Yes, new**: WWDC26 added image input (`Attachment(NSImage…)`) — but requires **macOS 27**, beta now, shipping ~fall 2026 ([WWDC26 session 241](https://developer.apple.com/videos/play/wwdc2026/241/), [MacRumors, 2026-06-09](https://www.macrumors.com/2026/06/09/apple-outlines-major-ai-and-developer-tool-updates/)) | **Zero download, zero disk** — model is part of the OS | Free on-device | On-device context only **8,192 tokens** — tight for 6–8 images; sharpness-judgment quality unproven [Speculation] |

## 3. Smallest capable vision models

Multi-image-per-prompt support is the gating feature; the task needs 2–8 images in one prompt.

| Model | Size on disk (4-bit-ish) | Multi-image? | License |
|---|---|---|---|
| **Qwen3-VL-2B-Instruct** | **1.11 GB** Q4_K_M + mmproj; official GGUF ([HF](https://huggingface.co/Qwen/Qwen3-VL-2B-Instruct-GGUF)) | Yes ([Unsloth guide](https://unsloth.ai/docs/models/tutorials/qwen3-how-to-run-and-fine-tune/qwen3-vl-how-to-run-and-fine-tune)) | **Apache 2.0** |
| **Qwen3-VL-4B-Instruct** | ~2.5 GB Q4 [Inference] ([HF GGUF](https://huggingface.co/Qwen/Qwen3-VL-4B-Instruct-GGUF)) | Yes | Apache 2.0 |
| **Gemma 4 E2B / E4B** (successor to Gemma 3n) | E2B 4.2 GB, E4B 5.9 GB ([LM Studio catalog](https://lmstudio.ai/models/gemma-4)); QAT GGUFs official | Yes — interleaved; visual token budget configurable **70–1120 tokens/image** ([HF E4B-it card](https://huggingface.co/google/gemma-4-E4B-it)) | **Apache 2.0** (Gemma 4 dropped the custom Gemma Terms — [docs](https://ai.google.dev/gemma/docs/core)) |
| **SmolVLM2** 256M/500M/2.2B | 0.2–1.5 GB; MLX supported ([HF blog](https://huggingface.co/blog/smolvlm2)) | Yes | Apache 2.0 |
| **Moondream 3 preview** | 9B MoE (2B active) | **No** multi-image as of Dec 2025 ([HF discussion](https://huggingface.co/moondream/moondream3-preview/discussions/29)) | BSL 1.1 |
| **FastVLM 0.5B/1.5B** | <1–1.5 GB | Single-image [Inference] | Research-only — excluded |

**Smallest plausibly viable: Qwen3-VL-2B (~1.6 GB total with mmproj).** [Hypothesis, testable by running a burst-cluster eval set against it via llama-server before writing any Swift.] SmolVLM2 ≤500M will very likely miss subtle sharpness/eyes-open distinctions [Speculation]. Best quality/size in the 2–5 GB band: **Qwen3-VL-4B or Gemma 4 E4B**; Gemma 4 keeps prompt/behavior continuity with the gemma-4-12b-qat used today and its per-image token budget (down to 70–280 tokens/image) fits 8 images cheaply.

## 4. Distribution & licensing

- [Fact] App Store package limit is 4 GB; Apple's recommended pattern for big weights is **download-on-first-launch** via the **Background Assets** framework ([docs](https://developer.apple.com/documentation/BackgroundAssets)). Outside the Mac App Store (Developer ID + dmg — the Cotypist route) there's no hard limit, but bundling 2–6 GB makes every update multi-GB — ship a small app, fetch weights with checksum verification on first launch.
- [Fact] Licensing: Gemma 3 had custom [Gemma Terms of Use](https://ai.google.dev/gemma/terms); **Gemma 4 is plain Apache 2.0**. Qwen3-VL and SmolVLM2 are Apache 2.0. Avoid FastVLM weights (research-only) and Moondream (BSL).

## 5. Google AI Studio remote option

- [Fact] The Gemini API serves **`gemma-4-31b-it` and `gemma-4-26b-a4b-it` with image input**, $0/token on the rate-limited free tier ([docs](https://ai.google.dev/gemma/docs/core/gemma_on_gemini_api)). The small E2B/E4B are *not* served — local-vs-remote is same family, different sizes.
- [Fact] Free-tier limits were cut in Dec 2025 (order of 5–15 RPM, ~100–1,000 RPD; check live quotas in AI Studio). For batch culling sessions, requests-per-day is the binding constraint [Inference].
- [Fact] No JSON mode/structured output for Gemma via the Gemini API — keep a "prompt for JSON + tolerant parse" path for this backend.

## 6. Recommended architecture

**One `BurstJudge` protocol** — input: N downscaled images (+ per-image metadata); output: pick + reasons JSON — with interchangeable backends:

1. **Embedded local (ship target): llama.cpp XCFramework** loading **Gemma 4 E4B QAT GGUF** (5.9 GB, prompt continuity) with **Qwen3-VL-2B** (1.6 GB) as the small/default option — Cotypist-style model picker, weights downloaded on first launch, never bundled. Use llama.cpp's JSON-schema grammar so output is valid by construction.
2. **OpenAI-compatible server** (current LM Studio path): unchanged; embedded llama.cpp consumes the *same GGUF artifacts*, so evals transfer 1:1.
3. **Google AI Studio**: `gemma-4-26b-a4b-it` with inline images; same Gemma prompt dialect as backend 1.
4. (Later) **Apple Foundation Models** on macOS 27: zero-download, `@Generable` structured output; 8K context caps image count/resolution.

**Do the hybrid regardless of backend:** compute sharpness, eyes-open (face landmarks), and `VNCalculateImageAestheticsScoresRequest` natively and inject those scores as text alongside the images. That converts the VLM's job from "perceive micro-blur across 8 thumbnails" (where small models fail) to "rank given signals + explain + judge composition" — which is what lets a 2–4B model replace a 12B one.

**Main trade-off:** llama.cpp-embedded vs MLX — llama.cpp gives artifact/eval parity with LM Studio, grammar-constrained JSON, and Intel-Mac coverage, at the cost of a C++ dependency and a less Swifty API. If Apple-Silicon-only with the cleanest Swift codebase were the priority, MLXVLM would flip the choice — but loses grammar-guaranteed JSON and GGUF parity.
