# Feedback loops: learning from accept/override

**Status:** designed 2026-08-08, not yet implemented. Build #1 first; everything
else starves without it.

The model's weights are frozen (local GGUF or API), so feedback ≠ online
learning. Four loops, ascending ambition:

## 1. Implicit signal capture (foundation)
The deletion moment is a free, unambiguous label. When the user deletes
discards from a cluster that had a suggestion:
- model suggested photo A, user kept A and deleted the rest → **agreement**
- model suggested A, user deleted A / kept B → **override**
- partial keeps (kept 2 of 5, incl. A) → weak agreement

Log each resolved cluster to a local JSONL (Application Support):
`{timestamp, model, suggestedIndex, keptIndices, photoCount, signals[]}`.
No new UI, no thumbs buttons — the decision the user already makes IS the
feedback. Privacy: on-device only, opt-out toggle.

This is also the "irreducible self-eval" from the benchmark research
(real bursts + real human picks) accumulating passively.

## 2. Agreement stats → measured model recommendation
"Qwen agrees with your choices 84% (31 clusters); Gemma-cloud 62%."
The ★ recommendation becomes the user's own measured truth instead of our
eval's opinion. Pure aggregation over #1.

## 3. Taste memo (in-context personalization)
Periodically ask the judge model itself to summarize override cases:
"Summarize this user's preferences from 20 examples where they chose
differently." Store the resulting short memo locally; prepend it to every
judge prompt ("prefers candid expressions over technical sharpness…").
RLHF-lite via prompting — backend-agnostic, no training.

## 4. Personal LoRA fine-tune (post-release endgame)
Export accumulated pairs → LoRA-tune Qwen3-VL on the user's picks.
Precedent: Co-Instruct (7B fine-tuned on comparison data) beat its GPT-4V
teacher at pairwise photo judgment (see
2026-08-08-vlm-photo-judging-benchmarks.md). A few hundred resolved clusters
is a meaningful dataset.
