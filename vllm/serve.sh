#!/bin/bash
# Launch vLLM from environment variables so compose can retune without a rebuild.
set -euo pipefail

args=(
  "$MODEL"
  --served-model-name "$SERVED_NAME"
  --host 0.0.0.0 --port 8000
  --max-model-len "$MAX_MODEL_LEN"
  --gpu-memory-utilization "$GPU_MEMORY_UTILIZATION"
  --max-num-seqs "$MAX_NUM_SEQS"
  # A 4-bit model inside the JSON grammar drifted into endless whitespace after the
  # conclusion string (about 70% of stocks failed as "not JSON"); this bans it.
  --structured-outputs-config '{"backend":"xgrammar","disable_any_whitespace":true}'
  # A model with a large (150-200k) vocabulary, so the warm-up pass at the default 8192
  # batched tokens needs a multi-GB logits buffer. v0.30.0 counts that against the
  # budget and leaves -1.7 GiB for the KV cache on an 8 GB card; 2048 fits.
  --max-num-batched-tokens "$MAX_NUM_BATCHED_TOKENS"
)
# A 4B model in bf16 is ~8 GB, which does not fit an 8 GB card next to the
# desktop. Online FP8 quantisation halves the weights (needs compute capability
# 8.9+, i.e. RTX 40-series or newer). Set QUANTIZATION= to disable on bigger cards.
[ -n "${QUANTIZATION:-}" ] && args+=(--quantization "$QUANTIZATION")
[ -n "${KV_CACHE_DTYPE:-}" ] && args+=(--kv-cache-dtype "$KV_CACHE_DTYPE")
[ -n "${EXTRA_ARGS:-}" ] && args+=($EXTRA_ARGS)

echo "vllm serve ${args[*]}"
exec vllm serve "${args[@]}"
