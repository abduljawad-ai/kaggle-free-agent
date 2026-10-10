#!/usr/bin/env bash
# ============================================================================
#  connect.sh  —  ONE command on your PC to use the Kaggle model anywhere.
#
#  Usage (run on your PC, NOT on Kaggle):
#     ./connect.sh <ZROK_SHARE_TOKEN> [ZROK_ACCOUNT_TOKEN]
#
#  The SHARE TOKEN is printed by the Kaggle cell (kaggle_cell.py).
#  The ACCOUNT TOKEN comes from https://myzrok.io (sign up there — NOT zrok.io):
#  sign in > zrok icon > "CLICK HERE TO GET STARTED!" > step 2 token.
#  It is only needed the FIRST time; afterwards it's stored in ~/.zrok2.
#  (You can also export it as ZROK_TOKEN, or you'll be prompted.)
#
#  What it does, in one shot:
#    1) installs the zrok client (zrok2) if missing
#    2) enables your zrok account/environment on this PC (first run only)
#    3) opens a private listener 127.0.0.1:2222 -> Kaggle SSH
#    4) writes/updates the `Kaggle` host in ~/.ssh/config
#    5) tests the SSH link (retries while the tunnel warms up)
#    6) forwards Kaggle's model to 127.0.0.1:8080 on this PC
#    7) registers the model in your GLOBAL opencode config
#
#  Requires: bash, python3, curl, ssh. Windows: use WSL.
# ============================================================================
set -euo pipefail

SHARE_TOKEN="${1:-}"
if [[ -z "$SHARE_TOKEN" ]]; then
  echo "Usage: $0 <ZROK_SHARE_TOKEN> [ZROK_ACCOUNT_TOKEN]"
  echo "  e.g. $0 4t1c2k3x"
  echo "  (ZROK_SHARE_TOKEN is printed by the Kaggle cell)"
  exit 1
fi

ACC_TOKEN="${2:-${ZROK_TOKEN:-}}"   # only needed the first time (see step 2)

LOCAL_PORT=2222          # PC-side port that zrok maps to Kaggle's sshd
MODEL_PORT=8080          # Kaggle llama-server port, mirrored to the PC
SSH_CFG="$HOME/.ssh/config"

# ---- 1) make sure the zrok client (zrok2) is installed ---------------------
Z=""
if command -v zrok2 >/dev/null 2>&1; then
  Z="$(command -v zrok2)"
elif command -v zrok >/dev/null 2>&1 && zrok version 2>/dev/null | grep -qi "2\."; then
  Z="$(command -v zrok)"   # system zrok already v2
fi
if [[ -z "$Z" ]]; then
  echo "==> Installing zrok client (zrok2) ..."
  TMP="$(mktemp -d)"
  curl -sSL https://github.com/openziti/zrok/releases/download/v2.0.8/zrok_2.0.8_linux_amd64.tar.gz \
    | tar -xzf - -C "$TMP"
  mkdir -p "$HOME/.local/bin"
  install -m755 "$TMP/zrok2" "$HOME/.local/bin/zrok2"
  rm -rf "$TMP"
  Z="$HOME/.local/bin/zrok2"
fi
echo "==> Using zrok client: $Z ($("$Z" version 2>/dev/null | head -1 || true))"

# ---- 2) enable this PC's environment (only if not already enabled) ----------
ENV_FILE="$HOME/.zrok2/environment.json"
if [[ -f "$ENV_FILE" ]]; then
  echo "==> zrok environment already enabled on this PC (skipping enable)."
else
  if [[ -z "$ACC_TOKEN" ]]; then
    read -rsp "Enter your zrok account token (from https://myzrok.io): " ACC_TOKEN
    echo
  fi
  echo "==> Enabling zrok environment for this PC ..."
  "$Z" config set apiEndpoint https://api-v2.zrok.io >/dev/null 2>&1 || true
  "$Z" enable "$ACC_TOKEN" --headless
fi

# ---- 3) open the private access listener -> Kaggle SSH ----------------------
pkill -f "zrok2? access private" 2>/dev/null || true   # free the port from a previous run
sleep 1
echo "==> Opening private access at 127.0.0.1:${LOCAL_PORT} ..."
# setsid => own session, survives this terminal closing (plain & dies on SIGHUP)
setsid "$Z" access private --headless --bind "127.0.0.1:${LOCAL_PORT}" "$SHARE_TOKEN" \
  >/tmp/connect_zrok_access.log 2>&1 < /dev/null &
ZROK_PID=$!
disown 2>/dev/null || true
sleep 5

if ! (exec 3<>"/dev/tcp/127.0.0.1/${LOCAL_PORT}") 2>/dev/null; then
  echo "!! Local access listener did not come up. Log (/tmp/connect_zrok_access.log):"
  cat /tmp/connect_zrok_access.log 2>/dev/null || true
  echo
  echo "   Check: is the Kaggle cell still running with the same token?"
  exit 1
fi
echo "==> Listener is up (PID $ZROK_PID) and will survive this terminal."

# ---- 4) update ~/.ssh/config (idempotent) ----------------------------------
echo "==> Writing host 'Kaggle' (127.0.0.1:$LOCAL_PORT) into ~/.ssh/config"
python3 - "$LOCAL_PORT" "$SSH_CFG" <<'PY'
import os, re, sys
port, cfg_path = sys.argv[1], sys.argv[2]
os.makedirs(os.path.dirname(cfg_path), exist_ok=True)
block = (
    "Host Kaggle\n"
    "    HostName 127.0.0.1\n"
    f"    Port {port}\n"
    "    User root\n"
    "    IdentityFile ~/.ssh/kaggle_key\n"
    "    IdentitiesOnly yes\n"
    "    StrictHostKeyChecking no\n"      # tunnel is fresh each session -> no host-key nag
    "    UserKnownHostsFile /dev/null\n"
    "    LogLevel ERROR\n"
)
content = ""
if os.path.exists(cfg_path):
    with open(cfg_path) as f:
        content = f.read()
content = re.sub(r"^Host Kaggle\n(    .*\n)*", "", content, flags=re.M)
content = content.rstrip() + "\n\n" + block
with open(cfg_path, "w") as f:
    f.write(content)
os.chmod(cfg_path, 0o600)
PY

# ---- 5) test the SSH link (key-based; retry while the tunnel warms) --------
echo "==> Testing SSH link with: ssh Kaggle 'echo CONNECTED'"
OK=""
for i in 1 2 3 4 5 6; do
  if ssh -o ConnectTimeout=15 -o BatchMode=yes Kaggle 'echo CONNECTED_OK' 2>/dev/null | grep -q CONNECTED_OK; then
    OK=1; break
  fi
  echo "    (tunnel still warming up... attempt $i/6)"
  sleep 5
done
if [[ -z "$OK" ]]; then
  echo
  echo "!! SSH test failed. Check:"
  echo "   - Kaggle cell still running (same share token)?"
  echo "   - is 'zrok2 access private' alive?  (ps -p $ZROK_PID)"
  echo "   Re-run: $0 $SHARE_TOKEN"
  exit 1
fi
echo "==> SSH link WORKS."

# ---- 6) forward Kaggle's model to 127.0.0.1:8080 on this PC -----------------
echo "==> Forwarding Kaggle model to 127.0.0.1:${MODEL_PORT} ..."
pkill -f "[8]080:127.0.0.1:${MODEL_PORT}" 2>/dev/null || true
sleep 1
nohup setsid ssh -N -o BatchMode=yes -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 \
  -L "${MODEL_PORT}:127.0.0.1:${MODEL_PORT}" Kaggle >/tmp/connect_forward.log 2>&1 < /dev/null &
disown 2>/dev/null || true

MODEL_OK=""
for i in 1 2 3 4 5 6; do
  if curl -sf --max-time 5 "http://127.0.0.1:${MODEL_PORT}/health" >/dev/null 2>&1; then
    MODEL_OK=1; break
  fi
  sleep 3
done
if [[ -z "$MODEL_OK" ]]; then
  echo "!! Model is not reachable through the forward. Log (/tmp/connect_forward.log):"
  tail -5 /tmp/connect_forward.log 2>/dev/null || true
  exit 1
fi
echo "==> Model reachable at http://127.0.0.1:${MODEL_PORT}/v1"

# ---- 7) register the model in the GLOBAL opencode config -------------------
CFG="$HOME/.config/opencode/opencode.jsonc"
mkdir -p "$(dirname "$CFG")"
[[ -f "$CFG" && ! -f "$CFG.bak" ]] && cp "$CFG" "$CFG.bak"
cat > "$CFG" <<'JSON'
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
  }
}
JSON
echo "==> Wrote opencode config: $HOME/.config/opencode/opencode.jsonc"

# ---- 7b) register the same model with jcode (if it's installed) ------------
if command -v jcode >/dev/null 2>&1; then
  if jcode provider add kaggle --base-url "http://127.0.0.1:${MODEL_PORT}/v1" \
       --model qwen3.8-27b-rvn --no-api-key --context-window 131072 --overwrite \
       >/dev/null 2>&1; then
    echo "==> Registered jcode provider profile 'kaggle'"
  else
    echo "!! jcode provider add failed (harmless if jcode was mid-update)"
  fi
fi

echo
echo "================================================================="
echo "  READY — use the model from ANY folder:"
echo "     opencode   ->  /models  ->  Kaggle Local / qwen3.8-27b-rvn"
echo "     jcode      ->  jcode --provider-profile kaggle"
echo
echo "  Connection kept alive in the background. If it ever drops,"
echo "  just re-run:   ./connect.sh <SHARE_TOKEN>"
echo "================================================================="
