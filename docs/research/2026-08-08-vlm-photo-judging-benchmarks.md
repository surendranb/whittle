# Photo-quality judgment benchmarks for small VLMs — research report

*Research date: 2026-08-08. Labels: [Fact] = read from source; [Inference]; [Hypothesis]; [Speculation].*

## Bottom line
Direct benchmarks exist (Q-Bench2 for pairwise quality, Q-Bench-Portrait Jan-2026 incl. pairs,
MICBench/VQualA-2025 for multi-image quality MCQ), but no public leaderboard shows a ≤4B model
tested zero-shot on pairwise photo-quality comparison with current-gen models. Proxy evidence
points to **Qwen3-VL-4B as the smallest plausible candidate**; everything ≤2B (except fine-tuned
specialists) collapses. A small self-eval on real bursts remains unavoidable.

## Key benchmarks
- [Q-Bench](https://q-future.github.io/Q-Bench/) (ICLR'24) — single-image low-level perception MCQ (blur, noise, exposure).
- [Q-Bench2/Q-Bench+](https://arxiv.org/abs/2402.07116) (TPAMI'24) — **pairwise** quality comparison, 1,999 pairs; in lmms-eval. Exactly our task shape.
- [Q-Bench-Portrait](https://arxiv.org/pdf/2601.18346) (Jan 2026) — portrait quality (blur, noise, exposure, color, composition, lighting), single + pairwise, 2,765 QA.
- [A-Bench](https://github.com/Q-Future/A-Bench) — "LMMs are poor quality evaluators"; humans beat GPT-4o by ~24 pts on aesthetics (94.3 vs 70.6).
- [VQualA 2025 / MICBench](https://arxiv.org/html/2509.09190) — open-ended comparison over 2–4 images; winners ~75.7% using 7B–72B models.

## Pairwise-quality evidence
- [Fact] Q-Bench+ pairs: senior human 85.5%, GPT-4V 78.1%, best open 7B models (2024) ~52% — barely above chance.
- [Fact] [Co-Instruct](https://arxiv.org/pdf/2402.16641) (7B fine-tuned on GPT-4V-distilled comparison data) hits 80.2% — beats its teacher. Its 562K training set is open → the proven fallback path if zero-shot disappoints (LoRA a small model on it).

## Small-model scores
- [Fact] Q-Bench-Portrait overall: **Qwen3-VL-4B 56.17%** ≈ GPT-5.2 (56.67%), near Qwen3-VL-8B (58.23%). InternVL3.5-2B 40.6%, 1B 34.4% — collapse. Family/training matters more than raw size (InternVL3.5-38B scores *below* Qwen3-VL-4B).
- [Fact] Multi-image ([Qwen3-VL tech report](https://arxiv.org/abs/2511.21631)): BLINK — 2B 53.8, 4B 65.8 (beats GPT-5-nano-high 58.3); MuirBench — 2B-Instruct 47.4, 4B-Instruct 63.8.
- [Inference] **4B is the floor for zero-shot**; the 2B tier loses 12–16 pts on multi-image tasks.

## Local measurements on this machine (16 GB M-series, LM Studio, 3×768px images)
| Model | Wall time | Reasoning tokens | Notes |
|---|---|---|---|
| gemma-4-12b-qat (Q4) | 83s | 384–626 (unsuppressable; `enable_thinking:false` ignored) | memory-starved at 7.15 GB |
| qwen3-vl-4b (Q4, 3.11 GB) | ~35s cold / 3.7s cached | **0** | time dominated by vision prefill |

## Burst-culling prior art
- [Google Top Shot](https://research.google/blog/top-shot-on-pixel-3/): classical signals (smiles, open eyes, lighting, optical flow, gyro) — no VLM. Validates hybrid design.
- [facet](https://github.com/ncoevoet/facet): 9-axis native scoring (aesthetic, composition, face/eye sharpness, exposure…) + optional VLM layer.
- [pixcull](https://github.com/ChrisChen667788/pixcull), [BurstPick](https://burstpick.app/en/models): local-first culling with CoreML/ONNX signal models.

## Gaps
1. No Q-Bench2 rows for 2025–26 small models — runnable ourselves via lmms-eval (one command per model).
2. No benchmark tests true burst near-duplicates (same scene 0.1s apart) — ~100 real burst groups with human picks is the irreducible self-eval.
3. Aesthetics is weak in all models — weight sharpness/eyes/exposure over composition.
4. Small models are prompt/format-sensitive — eval must use our exact prompt format.
