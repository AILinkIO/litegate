#!/bin/bash
# Qwen3.5-9B NVFP4 单卡服务：参数见同目录 vllm.env（VLLM_API_KEY 由 vLLM 直接从环境变量读取，不出现在命令行里）
# 只监听 docker0 网关地址：本机与容器可访问，局域网不可访问
set -a; . /mnt/storage/vllm/vllm.env; set +a
exec /mnt/storage/vllm/venv/bin/vllm serve "$VLLM_MODEL" \
    --served-model-name "$VLLM_SERVED_NAME" \
    --host "$VLLM_HOST" --port "$VLLM_PORT" \
    --max-model-len "$VLLM_MAX_LEN" \
    --max-num-seqs "$VLLM_MAX_SEQS" \
    --gpu-memory-utilization 0.90 \
    --reasoning-parser qwen3 \
    --enable-auto-tool-choice --tool-call-parser qwen3_coder
