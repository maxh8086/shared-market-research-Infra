# Serves one model through vLLM's OpenAI-compatible API (default Qwen3-4B-Instruct-2507,
# MXFP4 weights + FP8 KV cache, sized for an 8 GB RTX 40-series card).
# Needs an NVIDIA GPU and the NVIDIA container runtime. No credentials go in or out: the
# model is public (Apache-2.0). Weights come from the shared models/huggingface folder that
# compose mounts at /root/.cache/huggingface; models.ps1 fills it.
# Every ENV below is a knob: override it in compose or `docker compose run -e MODEL=...` to serve
# a different model to another project without a rebuild.
ARG VLLM_IMAGE=vllm/vllm-openai:v0.30.0
FROM ${VLLM_IMAGE}

ENV MODEL=Qwen/Qwen3-4B-Instruct-2507 \
    SERVED_NAME=qwen3-4b \
    MAX_MODEL_LEN=4096 \
    GPU_MEMORY_UTILIZATION=0.56 \
    MAX_NUM_SEQS=4 \
    MAX_NUM_BATCHED_TOKENS=1024 \
    QUANTIZATION=mxfp4 \
    KV_CACHE_DTYPE=fp8 \
    HF_HOME=/root/.cache/huggingface

COPY serve.sh /serve.sh
RUN sed -i 's/\r$//' /serve.sh && chmod +x /serve.sh

EXPOSE 8000
HEALTHCHECK --interval=15s --timeout=5s --start-period=900s --retries=5 \
    CMD python3 -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/health', timeout=4)"

ENTRYPOINT ["/bin/bash", "/serve.sh"]
