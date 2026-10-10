#!/usr/bin/env bash
# ============================================================================
#  way2_setup.sh — run INSIDE the Kaggle SSH session (Way 2)
#  Pushed to Kaggle by:  ./way2_pc.sh <zrok-share-token>
#  Then:                 ssh Kaggle && bash /kaggle/working/way2_setup.sh
#
#  What it does (idempotent — safe to re-run):
#    1) fixes CUDA env for the SSH shell
#    2) finds/reuses llama-server (starts one on localhost:8080 if none running)
#    3) installs OpenCode (the agent) if missing
#    4) prints the final "you're ready" block
# ============================================================================
set -euo pipefail

# ---- 1) CUDA env for the SSH shell (verified: /opt/bin + nvidia libs) ----
export PATH="/opt/bin:$PATH"
export LD_LIBRARY_PATH="/usr/local/nvidia/lib64:${LD_LIBRARY_PATH:-}"

echo "==> nvidia check:"
nvidia-smi --query-gpu=name,memory.total --format=csv || echo "   (no GPU in this shell — check notebook Accelerator setting)"

# ---- 2) locate llama-server (from your existing cell-2 download) -------
LLAMA=""
for cand in \
  /kaggle/working/llama.cpp/build/bin/llama-server \
  /kaggle/working/cuda-12.8/llama-server \
  /kaggle/working/llama-server \
  /usr/local/bin/llama-server; do
  if [[ -x "$cand" ]]; then LLAMA="$cand"; break; fi
done

MODEL=""
for cand in \
  /kaggle/working/models/Qwen3.8-27B-Abliterated-IQ4-MIX-MTP.gguf \
  /kaggle/working/models/Qwen3.8-9B-abliterated-25.Q4_K_M.gguf \
  /kaggle/working/models/RVN-Q4_K_M-mtp.gguf \
  /kaggle/working/RVN-Q4_K_M-mtp.gguf; do
  if [[ -f "$cand" ]]; then MODEL="$cand"; break; fi
done

# ---- 3) model server ------------------------------------------------------
if curl -sf http://localhost:8080/health >/dev/null 2>&1; then
  echo "==> model server ALREADY running on :8080 — reusing it"
elif [[ -n "$LLAMA" && -n "$MODEL" ]]; then
  echo "==> starting llama-server with: $LLAMA"
  MTP_ARGS=()
  case "$MODEL" in *MTP*|*mtp*) MTP_ARGS=(--spec-type draft-mtp --spec-draft-n-max 3);; esac
  nohup "$LLAMA" -m "$MODEL" \
    -ngl 999 --split-mode layer --ctx-size 131072 --parallel 1 --n-predict -1 \
    --cache-type-k q8_0 --cache-type-v q8_0 \
    -b 512 -ub 256 --flash-attn on --jinja --reasoning-format deepseek \
    "${MTP_ARGS[@]}" \
    --alias qwen3.8-27b-rvn \
    --host 127.0.0.1 --port 8080 \
    > /kaggle/working/llama-server.log 2>&1 &
  echo "==> booting (MTP on). Wait ~30s then:"
  echo "    curl -s http://localhost:8080/health"
else
  echo "!! Could not find llama-server or the model GGUF in /kaggle/working."
  echo "   Download them first (your cell-1/cell-2 does this) or point:"
  echo "   LLAMA=/path/to/llama-server MODEL=/path/to/model.gguf bash way2_setup.sh"
fi

# ---- 4) OpenCode -----------------------------------------------------------
if ! command -v opencode >/dev/null 2>&1; then
  echo "==> installing OpenCode ..."
  curl -fsSL https://opencode.ai/install | bash
  export PATH="$HOME/.opencode/bin:$PATH"
fi
export PATH="$HOME/.opencode/bin:$PATH"
# If node is missing too, fall back to npm route:
if ! command -v node >/dev/null 2>&1; then
  echo "==> node not found — installing via apt (for npm-based UI extras)"
  apt-get install -y -qq nodejs npm >/dev/null 2>&1 || true
fi

# ---- 4b) point OpenCode at the local llama-server (writes the config) -----
mkdir -p "$HOME/.config/opencode"
cat > "$HOME/.config/opencode/opencode.json" <<'JSON'
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "kaggle": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Kaggle Local",
      "options": {
        "baseURL": "http://127.0.0.1:8080/v1",
        "apiKey": "sk-local"
      },
      "models": {
        "qwen3.8-27b-rvn": { "name": "Qwen3.8-27B RVN (Kaggle)" }
      }
    }
  },
  "model": "kaggle/qwen3.8-27b-rvn"
}
JSON
echo "==> wrote ~/.config/opencode/opencode.json (model: kaggle/qwen3.8-27b-rvn)"
opencode --version && echo "==> opencode ready"

# ---- 5) ready ------------------------------------------------------------------
echo
echo "################################################################"
echo "  YOU ARE READY (Way 2). All on one machine:"
echo
echo "   model  : llama-server at http://127.0.0.1:8080/v1"
echo "   agent  : opencode  (model kaggle/qwen3.8-27b-rvn, config written)"
echo
echo "   Just type:  opencode"
echo "   (If opencode was already open, quit it and start it again so it"
echo "    picks up the new config.)"
echo "################################################################"